//==============================================================================
// Pre-Trade Risk Gateway  (Section 3.1.5)
//
// Static boundary between the (user-replaceable) Alpha Engine and the network.
// Evaluates six risk conditions IN PARALLEL and suppresses any trade that fails
// one. Protects the system from flawed user logic.
//
// 2-cycle latency: fast combinational checks are pipelined one stage to
// align with the DSP/BRAM checks, then all six flags are OR-reduced.
//
// Future Optimizations will have streamed, serial data from Alpha Engine
//==============================================================================

module pre_trade_risk_gateway
  import ct_pkg::*;
#(
  parameter int MAX_QTY        = 32'd10_000,      // max shares per order
  parameter int MAX_ORDER_VAL  = 32'd1_000_000,   // max price*qty
  parameter int RATE_TOKENS    = 16,               // token bucket depth
  parameter int RATE_PERIOD    = 225_000          // 1 ms @ 225 MHz
)
(
  input  logic                 core_clk,
  input  logic                 rst_n,

  // --- AXI4-Stream slave from Alpha Engine ----------------------------------
  input  logic [TRADE_W-1:0]   s_axis_order_tdata,   // trade_t, 144 bits
  input  logic                 s_axis_order_tuser,   // 1 = Buy, 0 = Sell
  input  logic                 s_axis_order_tvalid,

  // --- Kill inputs ----------------------------------------------------------
  input  logic                 rx_error,         // from RX MAC CRC checker
  input  logic                 hw_kill_switch,   // physical IO / SW register

  // --- AXI4-Stream master to Outbound TX Generator --------------------------
  output logic [TRADE_W-1:0]   m_axis_tx_tdata,  // trade_t, forwarded unchanged
  output logic                 m_axis_tx_tuser,
  output logic                 m_axis_tx_tvalid  // high 2 cycles after input,
                                                 // iff all checks pass
);

  //--------------------------------------------------------------------------
  // Input unpacking
  //--------------------------------------------------------------------------
  trade_t trade_in;
  assign trade_in = trade_t'(s_axis_order_tdata);

  //--------------------------------------------------------------------------
  // Six parallel risk checks.
  // Convention: each flag is asserted HIGH ON VIOLATION.
  //--------------------------------------------------------------------------
  logic [3:0] viol_max_qty;      // combinational: quantity > MAX_QTY 
  logic viol_max_value;         // 3 cycle (DSP):  price * quantity > MAX_ORDER_VAL 
  logic viol_blacklist[0:1];    // 1 cycle (BRAM): ticker is restricted
  logic [3:0] viol_rate_limit;        // combinational: token bucket empty
  logic viol_kill_switch;       // combinational: hw_kill_switch asserted 
  logic viol_crc[0:1];          // combinational: rx_error asserted

  logic [3:0] tvalid;            // data-pipeline valid shift reg, declared here
                                  // (ahead of Data_Pipeline below) since the
                                  // rate limiter's refund_pulse reads tvalid[3]

  // TODO: Blacklist      -- hash trade_in.ticker into a BRAM address; the BRAM
  //                         is preloaded at bitstream generation from a .coe.
  // TODO: CRC drop       -- direct read of rx_error. This is what makes the
  //                         parser's optimistic cut-through forwarding SAFE:
  //                         a trade derived from a corrupt packet dies here.

  // Max Quantity Check

  always_ff @(posedge core_clk) begin: Max_Quantity
    if (~rst_n) begin
      viol_max_qty <= '0; 
    end else begin
      // Cycle 0 
      viol_max_qty[0] <= (s_axis_order_tvalid) ? trade_in.quantity > MAX_QTY : 0;
      // Cycle 1
      viol_max_qty[1] <= viol_max_qty[0];
      // Cycle 2
      viol_max_qty[2] <= viol_max_qty[1]; 
      // Cycle 3
      viol_max_qty[3] <= viol_max_qty[2]; 
    end
  end

  // Rate Limiter Check
  // No pipeline since it is not related to any one packet
  logic [$clog2(RATE_PERIOD)-1:0] cycle_cnt; 
  logic refill_pulse; 
  logic [$clog2(RATE_TOKENS):0] token_bucket; 
  logic refund_pulse;
  logic non_rate_limit_violation;  
  
  // Refund a token on egress if trade is rejected
  assign non_rate_limit_violation = viol_max_qty[3] | viol_max_value | viol_kill_switch;
  assign refund_pulse = tvalid[3] & non_rate_limit_violation & ~viol_rate_limit[3];
  
  // Handle refill and refund collision
  logic [1:0] tokens_to_add;
  logic       tokens_to_sub; 
  
  assign tokens_to_add = refill_pulse + refund_pulse;
  assign tokens_to_sub = s_axis_order_tvalid; 

  always_ff @(posedge core_clk) begin: Rate_Limiter_Counter
    if (~rst_n) begin
      refill_pulse <= 0; 
      cycle_cnt <= '0; 
    end else begin
      if (cycle_cnt < RATE_PERIOD - 1) begin
        cycle_cnt <= cycle_cnt + 1; 
        refill_pulse <= 0; 
      end else begin
        cycle_cnt <= 0;
        refill_pulse <= 1;  
      end
    end
  end

    always_ff @(posedge core_clk) begin: Token_Bucket
      if (~rst_n) begin
          token_bucket <= RATE_TOKENS;
      end else begin
          // TIMING (ROUND 11): next_bucket was declared `integer` -- a 32-BIT
          // SIGNED intermediate for what is a 5-bit counter. Synthesis therefore
          // built a 32-bit add/subtract AND 32-bit saturation compares, which is
          // why this trivial token counter kept surfacing as a 4x CARRY4 cone
          // (the -0.490 ns WNS self-loop token_bucket -> token_bucket/R, and the
          // same cluster in runs 5 and 10). Sized to the real range instead:
          //   token_bucket 0..RATE_TOKENS, + tokens_to_add (0..2),
          //   - tokens_to_sub (0..1)  =>  -1 .. RATE_TOKENS+2
          // which fits 7 bits signed. Arithmetic and saturation are unchanged.
          automatic logic signed [6:0] next_bucket =
                signed'({2'b00,     token_bucket})
              + signed'({5'b00000,  tokens_to_add})
              - signed'({6'b000000, tokens_to_sub});

          if (next_bucket > signed'(7'(RATE_TOKENS))) begin
              token_bucket <= RATE_TOKENS;
          end else if (next_bucket < 0) begin
              token_bucket <= 0;
          end else begin
              token_bucket <= next_bucket[4:0];
          end
       end
    end

    always_ff @(posedge core_clk) begin: Rate_Limiter_Pipeline
      if (~rst_n) begin
        viol_rate_limit <= '0;
      end else begin
        // '0 (context-sized) rather than a bare 0: the unsized literal is a
        // 32-bit int, which widens the add into a 32-bit compare context for
        // what is 5-bit + 2-bit arithmetic (same class of bug as next_bucket
        // above, and this expression sits in the same token-bucket cone).
        viol_rate_limit[0] <= s_axis_order_tvalid ? ((token_bucket + tokens_to_add) == '0)
                                                  : 1'b0;
        viol_rate_limit[1] <= viol_rate_limit[0]; 
        viol_rate_limit[2] <= viol_rate_limit[1]; 
        viol_rate_limit[3] <= viol_rate_limit[2]; 
      end
    end

//  always_ff @(posedge core_clk or negedge rst_n) begin: Token_Bucket
//    if (~rst_n) begin
//      token_bucket <= RATE_TOKENS; 
//    end else if (m_axis_tx_tvalid && refill_pulse) begin
//      token_bucket <= token_bucket; 
//    end else if (m_axis_tx_tvalid) begin
//      token_bucket <= (token_bucket > 0) ? token_bucket - 1 : token_bucket; 
//    end else if (refill_pulse) begin
//      token_bucket <= (token_bucket < RATE_TOKENS) ? token_bucket + 1 : token_bucket; 
//    end
//  end


  // Max Value Check 

  // Number of bits MAX_ORDER_VAL occupies, i.e. the smallest MOV_BITS with
  // 2**MOV_BITS > MAX_ORDER_VAL (20 for the 1e6 default). Used to split the
  // max-value compare -- see the note in Max_Value below. Guarded so a zero cap
  // (reject everything) cannot produce a null slice.
  localparam int MOV_BITS = (MAX_ORDER_VAL <= 0) ? 1 : $clog2(MAX_ORDER_VAL + 1);

  logic [31:0] price_s1;
  logic [31:0] quantity_s1;
  logic [63:0] product_m;
  logic [63:0] product [1:3];

  always_ff @(posedge core_clk) begin: Max_Value_Pipeline
    price_s1    <= trade_in.price;
    quantity_s1 <= trade_in.quantity;
      
    product_m  <= price_s1 * quantity_s1;
    product[1] <= product_m;
    product[2] <= product[1];
    product[3] <= product[2];
  end

  always_ff @(posedge core_clk) begin: Max_Value
    if (~rst_n) begin
      viol_max_value <= 1'b0;
    end else begin
      viol_max_value <= (|product[1][63:MOV_BITS])
                       || (product[1][MOV_BITS-1:0] > MOV_BITS'(MAX_ORDER_VAL));
    end
  end

  // Hardware Kill Switch check
  // No pipeline since it is not related to any one packet
  // Stop entire pipeline if asserted
  always_ff @(posedge core_clk) begin: HW_Kill_Switch
    if (~rst_n) begin
      viol_kill_switch <= 0; 
    end else begin
      // Stays asserted until reset
      viol_kill_switch <= hw_kill_switch || viol_kill_switch; 
    end
  end

  trade_t trade [0:3];
  logic   [3:0] tuser;

  always_ff @(posedge core_clk) begin: Data_Pipeline
    if (~rst_n) begin
      trade[0]  <= '0;
      trade[1]  <= '0;
      trade[2]  <= '0;
      trade[3]  <= '0;
      tuser  <= '0;
      tvalid <= '0;
    end else begin
      tuser   <= {tuser[2:0], s_axis_order_tuser};
      tvalid  <= {tvalid[2:0], s_axis_order_tvalid};  
      trade[0] <= trade_in;
      trade[1] <= trade[0];
      trade[2] <= trade[1]; 
      trade[3] <= trade[2]; 
    end
  end

// -------------------------------------------------------------------------------------
// Egress Generation 
// -------------------------------------------------------------------------------------

logic [5:0] violations;
logic violation;

assign violations = {viol_max_qty[3], viol_max_value, viol_rate_limit[3], viol_kill_switch, 1'b0, 1'b0/*, viol_crc[3], viol_blacklist[2]*/};
assign violation = |violations; 

always_ff @(posedge core_clk) begin
  if (~rst_n) begin
    m_axis_tx_tvalid <= 0;
    m_axis_tx_tdata  <= '0; 
    m_axis_tx_tuser  <= 0; 
  end else begin
    if (tvalid[3]) begin
      if (violation) begin
        m_axis_tx_tvalid <= 0;
        m_axis_tx_tdata  <= '0;
        m_axis_tx_tuser  <= 0; 
      end else begin
        // Approved Trade
        m_axis_tx_tvalid <= 1;
        m_axis_tx_tdata  <= trade[3];
        m_axis_tx_tuser  <= tuser[3];
      end
    end else begin
      m_axis_tx_tvalid <= 0;
      m_axis_tx_tdata  <= '0;
      m_axis_tx_tuser  <= 0; 
    end
  end
end

endmodule
