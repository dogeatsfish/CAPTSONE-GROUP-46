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
  parameter int RATE_PERIOD    = 250_000          // 1 ms @ 250 MHz
)
(
  input  logic                 clk_250mhz,
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
  logic [2:0] viol_max_qty;      // combinational: quantity > MAX_QTY 
  logic viol_max_value;         // 2 cycle (DSP):  price * quantity > MAX_ORDER_VAL 
  logic viol_blacklist[0:1];    // 1 cycle (BRAM): ticker is restricted
  logic viol_rate_limit;        // combinational: token bucket empty
  logic viol_kill_switch;       // combinational: hw_kill_switch asserted 
  logic viol_crc[0:1];          // combinational: rx_error asserted 



  // TODO: Blacklist      -- hash trade_in.ticker into a BRAM address; the BRAM
  //                         is preloaded at bitstream generation from a .coe.
  // TODO: CRC drop       -- direct read of rx_error. This is what makes the
  //                         parser's optimistic cut-through forwarding SAFE:
  //                         a trade derived from a corrupt packet dies here.

  // Max Quantity Check

  always_ff @(posedge clk_250mhz or negedge rst_n) begin: Max_Quantity
    if (~rst_n) begin
      viol_max_qty <= '0; 
    end else begin
      // Cycle 0 
      viol_max_qty[0] <= (s_axis_order_tvalid) ? trade_in.quantity > MAX_QTY : 0;
      // Cycle 1
      viol_max_qty[1] <= viol_max_qty[0];
      // Cycle 2
      viol_max_qty[2] <= viol_max_qty[1]; 
    end
  end

  // Rate Limiter Check
  // No pipeline since it is not related to any one packet
  logic [$clog2(RATE_PERIOD)-1:0] cycle_cnt; 
  logic refill_pulse; 
  logic [$clog2(RATE_TOKENS)-1:0] token_bucket; 

  always_ff @(posedge clk_250mhz or negedge rst_n) begin: Rate_Limiter_Counter
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

  always_ff @(posedge clk_250mhz or negedge rst_n) begin: Token_Bucket
    if (~rst_n) begin
      token_bucket <= RATE_TOKENS; 
    end else if (m_axis_tx_tvalid && refill_pulse) begin
      token_bucket <= token_bucket; 
    end else if (m_axis_tx_tvalid) begin
      token_bucket <= (token_bucket > 0) ? token_bucket - 1 : token_bucket; 
    end else if (refill_pulse) begin
      token_bucket <= (token_bucket < RATE_TOKENS) ? token_bucket + 1 : token_bucket; 
    end
  end

  assign viol_rate_limit = (token_bucket == 0);

  // Max Value Check 

  (* use_dsp = "yes" *) logic [31:0] price_s1; 
  (* use_dsp = "yes" *) logic [31:0] quantity_s1; 
  (* use_dsp = "yes" *) logic [63:0] product_s2; 
  (* use_dsp = "yes" *) logic [63:0] product_s3; 

  always_ff @(posedge clk_250mhz or negedge rst_n) begin: Max_Value
    if (~rst_n) begin
      price_s1    <= '0; 
      quantity_s1 <= '0;
      product_s2  <= '0;
      product_s3  <= '0;
    end else begin
      if (s_axis_order_tvalid) begin
        price_s1    <= trade_in.price; 
        quantity_s1 <= trade_in.quantity; 
      end
      product_s2 <= price_s1 * quantity_s1;
      product_s3 <= product_s2; 
    end
  end
  assign viol_max_value = (product_s3 > MAX_ORDER_VAL);

  // Hardware Kill Switch check
  // No pipeline since it is not related to any one packet
  // Stop entire pipeline if asserted
  always_ff @(posedge clk_250mhz or negedge rst_n) begin: HW_Kill_Switch
    if (~rst_n) begin
      viol_kill_switch <= 0; 
    end else begin
      // Stays asserted until reset
      viol_kill_switch <= hw_kill_switch || viol_kill_switch; 
    end
  end

  trade_t trade [0:2];
  logic   [2:0] tuser;
  logic   [2:0] tvalid;

  always_ff @(posedge clk_250mhz or negedge rst_n) begin: Data_Pipeline
    if (~rst_n) begin
      trade[0]  <= '0;
      trade[1]  <= '0;
      trade[2]  <= '0;
      tuser  <= '0;
      tvalid <= '0;
    end else begin
      tuser   <= {tuser[1:0], s_axis_order_tuser};
      tvalid  <= {tvalid[1:0], s_axis_order_tvalid};  
      if (s_axis_order_tvalid) begin
        trade[0] <= trade_in;
        trade[1] <= trade[0];
        trade[2] <= trade[1]; 
      end
    end
  end

// -------------------------------------------------------------------------------------
// Egress Generation 
// -------------------------------------------------------------------------------------

logic [5:0] violations;
logic violation;

assign violations = {viol_max_qty[2], viol_max_value, viol_rate_limit, viol_kill_switch, 0, 0/*, viol_crc[2], viol_blacklist[1]*/};
assign violation = |violations; 

always_ff @(posedge clk_250mhz or negedge rst_n) begin
  if (~rst_n) begin
    m_axis_tx_tvalid <= 0;
    m_axis_tx_tdata  <= '0; 
    m_axis_tx_tuser  <= 0; 
  end else begin
    if (tvalid[2]) begin
      if (violation) begin
        m_axis_tx_tvalid <= 0;
        m_axis_tx_tdata  <= '0;
        m_axis_tx_tuser  <= 0; 
      end else begin
        // Approved Trade
        m_axis_tx_tvalid <= 1;
        m_axis_tx_tdata  <= trade[2];
        m_axis_tx_tuser  <= tuser[2];
      end
    end else begin
      m_axis_tx_tvalid <= 0;
      m_axis_tx_tdata  <= '0;
      m_axis_tx_tuser  <= 0; 
    end
  end
end

endmodule
