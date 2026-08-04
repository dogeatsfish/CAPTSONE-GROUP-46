//==============================================================================
// Portfolio State Tracker
//
// Snoops the egress of the Risk Gateway to build an assumed portfolio state.
// Provides 0-cycle flat structural access to the Alpha Engine.
// Uses a multi-cycle divider state machine to compute average entry prices
// off the critical path.
//==============================================================================

module portfolio_state
  import ct_pkg::*;
#(
  parameter logic [63:0] PORTFOLIO_INITIAL_CASH = INITIAL_CASH
)
(
  input  logic                    core_clk,
  input  logic                    rst_n,

  // Snooped AXI-Stream from Risk Gateway
  input  logic [TRADE_W-1:0]      s_axis_tx_tdata,
  input  logic                    s_axis_tx_tuser,
  input  logic                    s_axis_tx_tvalid,

  // Output State
  output portfolio_state_t        m_portfolio_state
);

  trade_t trade_in;
  assign trade_in = trade_t'(s_axis_tx_tdata);
  logic is_buy;
  assign is_buy = s_axis_tx_tuser;
  
  function automatic logic [ASSET_IDX_W-1:0] asset_of(input logic [TICKER_W-1:0] t);
    case (t)
      "AAPL    ": return 3'd0;
      "MSFT    ": return 3'd1;
      "AMZN    ": return 3'd2;
      "GOOG    ": return 3'd3;
      "TSLA    ": return 3'd4;
      default:    return 3'd7; // Invalid
    endcase
  endfunction

  logic [ASSET_IDX_W-1:0] s_idx;
  assign s_idx = asset_of(trade_in.ticker);
  logic valid_trade;
  assign valid_trade = s_axis_tx_tvalid && (s_idx < NUM_ASSETS);

  // State registers
  asset_state_t [NUM_ASSETS-1:0] assets;
  logic signed [63:0]            cash;

  assign m_portfolio_state.assets = assets;
  assign m_portfolio_state.available_cash = cash;

  // Divider State Machine for avg_entry_price
  typedef enum logic [1:0] { IDLE, DIVIDE } div_state_e;
  div_state_e [NUM_ASSETS-1:0] div_state;
  
  // Non-restoring divider regs per asset
  logic [63:0] div_num   [NUM_ASSETS];
  logic [31:0] div_den   [NUM_ASSETS];
  logic [31:0] div_quot  [NUM_ASSETS];
  logic [63:0] div_rem   [NUM_ASSETS];
  logic [5:0]  div_count [NUM_ASSETS];

  // Pipeline control signals (4 cycle delay to match multiplier)
  logic p_valid [1:4];
  trade_t p_trade [1:4];
  logic p_is_buy [1:4];
  logic [ASSET_IDX_W-1:0] p_idx [1:4];

  logic signed [63:0] p5_trade_val;
  logic signed [63:0] p5_cost_basis;
  logic signed [63:0] p5_pnl_val;

  logic signed [31:0] avg_cost_in;
  assign avg_cost_in = assets[s_idx].avg_entry_price;

  pipelined_mult_32x32 u_mult_trade_val (
    .clk(core_clk),
    .a(signed'(trade_in.price)),
    .b(signed'(trade_in.quantity)),
    .p(p5_trade_val)
  );

  pipelined_mult_32x32 u_mult_cost_basis (
    .clk(core_clk),
    .a(signed'(avg_cost_in)),
    .b(signed'(trade_in.quantity)),
    .p(p5_cost_basis)
  );

  pipelined_mult_32x32 u_mult_pnl (
    .clk(core_clk),
    .a(signed'(trade_in.price) - signed'(avg_cost_in)),
    .b(signed'(trade_in.quantity)),
    .p(p5_pnl_val)
  );

  always_ff @(posedge core_clk or negedge rst_n) begin
    if (!rst_n) begin
      cash <= PORTFOLIO_INITIAL_CASH;
      for (int i = 1; i <= 4; i++) p_valid[i] <= 1'b0;
      for (int i = 0; i < NUM_ASSETS; i++) begin
        assets[i].net_position <= '0;
        assets[i].total_position_value <= '0;
        assets[i].target_position <= '0;
        assets[i].realized_pnl <= '0;
        assets[i].last_trade_timestamp <= '0;
        assets[i].avg_entry_price <= '0;
        div_state[i] <= IDLE;
      end
    end else begin
      // Default: dividers run
      for (int i = 0; i < NUM_ASSETS; i++) begin
        if (div_state[i] == DIVIDE) begin
          if (div_count[i] == 0) begin
            assets[i].avg_entry_price <= div_quot[i];
            div_state[i] <= IDLE;
          end else begin
            // Shift and subtract
            automatic logic [63:0] next_rem;
            next_rem = (div_rem[i] << 1) | {63'd0, div_num[i][div_count[i]-1]};
            
            if (next_rem >= {32'd0, div_den[i]}) begin
              div_rem[i] <= next_rem - {32'd0, div_den[i]};
              div_quot[i][div_count[i]-1] <= 1'b1;
            end else begin
              div_rem[i] <= next_rem;
              div_quot[i][div_count[i]-1] <= 1'b0;
            end
            div_count[i] <= div_count[i] - 1;
          end
        end
      end

      // Control Pipeline
      p_valid[1] <= valid_trade;
      p_trade[1] <= trade_in;
      p_is_buy[1] <= is_buy;
      p_idx[1]   <= s_idx;

      for (int i = 2; i <= 4; i++) begin
        p_valid[i] <= p_valid[i-1];
        p_trade[i] <= p_trade[i-1];
        p_is_buy[i]<= p_is_buy[i-1];
        p_idx[i]   <= p_idx[i-1];
      end

      // Stage 5 (Write-back)
      if (p_valid[4]) begin
        assets[p_idx[4]].last_trade_timestamp <= p_trade[4].timestamp;
        
        if (p_is_buy[4]) begin
          cash <= cash - p5_trade_val;
          assets[p_idx[4]].net_position <= assets[p_idx[4]].net_position + signed'(p_trade[4].quantity);
          
          if (assets[p_idx[4]].net_position < 0) begin
            // Closing a short
            if (assets[p_idx[4]].net_position >= -signed'(p_trade[4].quantity)) begin
              // Flipped to long or flat
              automatic logic signed [31:0] closed_qty = -assets[p_idx[4]].net_position;
              automatic logic signed [31:0] remaining = assets[p_idx[4]].net_position + signed'(p_trade[4].quantity);
              assets[p_idx[4]].realized_pnl <= assets[p_idx[4]].realized_pnl + closed_qty * (assets[p_idx[4]].avg_entry_price - signed'(p_trade[4].price));
              assets[p_idx[4]].total_position_value <= 64'(remaining) * signed'(p_trade[4].price);
              assets[p_idx[4]].avg_entry_price <= remaining > 0 ? p_trade[4].price : '0;
              div_state[p_idx[4]] <= IDLE;
            end else begin
              // Still short
              assets[p_idx[4]].realized_pnl <= assets[p_idx[4]].realized_pnl - p5_pnl_val;
              assets[p_idx[4]].total_position_value <= assets[p_idx[4]].total_position_value - p5_cost_basis;
            end
          end else begin
            // Opening/Adding to a long
            assets[p_idx[4]].total_position_value <= assets[p_idx[4]].total_position_value + p5_trade_val;
            div_state[p_idx[4]] <= DIVIDE;
            div_num[p_idx[4]]   <= (assets[p_idx[4]].total_position_value + p5_trade_val);
            div_den[p_idx[4]]   <= (assets[p_idx[4]].net_position + signed'(p_trade[4].quantity));
            div_quot[p_idx[4]]  <= '0; div_rem[p_idx[4]] <= '0; div_count[p_idx[4]] <= 32;
          end
        end else begin // Sell
          cash <= cash + p5_trade_val;
          assets[p_idx[4]].net_position <= assets[p_idx[4]].net_position - signed'(p_trade[4].quantity);
          
          if (assets[p_idx[4]].net_position > 0) begin
            // Closing a long
            if (assets[p_idx[4]].net_position <= signed'(p_trade[4].quantity)) begin
              // Flipped to short or flat
              automatic logic signed [31:0] closed_qty = assets[p_idx[4]].net_position;
              automatic logic signed [31:0] remaining = signed'(p_trade[4].quantity) - assets[p_idx[4]].net_position;
              assets[p_idx[4]].realized_pnl <= assets[p_idx[4]].realized_pnl + closed_qty * (signed'(p_trade[4].price) - assets[p_idx[4]].avg_entry_price);
              assets[p_idx[4]].total_position_value <= 64'(remaining) * signed'(p_trade[4].price);
              assets[p_idx[4]].avg_entry_price <= remaining > 0 ? p_trade[4].price : '0;
              div_state[p_idx[4]] <= IDLE;
            end else begin
              // Still long
              assets[p_idx[4]].realized_pnl <= assets[p_idx[4]].realized_pnl + p5_pnl_val;
              assets[p_idx[4]].total_position_value <= assets[p_idx[4]].total_position_value - p5_cost_basis;
            end
          end else begin
            // Opening/Adding to a short
            assets[p_idx[4]].total_position_value <= assets[p_idx[4]].total_position_value + p5_trade_val;
            div_state[p_idx[4]] <= DIVIDE;
            div_num[p_idx[4]]   <= (assets[p_idx[4]].total_position_value + p5_trade_val);
            div_den[p_idx[4]]   <= (-assets[p_idx[4]].net_position + signed'(p_trade[4].quantity));
            div_quot[p_idx[4]]  <= '0; div_rem[p_idx[4]] <= '0; div_count[p_idx[4]] <= 32;
          end
        end
      end
    end
  end

endmodule

module pipelined_mult_32x32 (
  input  logic clk,
  input  logic signed [31:0] a,
  input  logic signed [31:0] b,
  output logic signed [63:0] p
);
  logic signed [17:0] a_lo_sgn;
  logic signed [17:0] b_lo_sgn;
  logic signed [17:0] a_hi_sgn;
  logic signed [17:0] b_hi_sgn;
  
  always_ff @(posedge clk) begin
      a_lo_sgn <= signed'({2'b00, a[15:0]}); // Zero extended to positive
      b_lo_sgn <= signed'({2'b00, b[15:0]}); // Zero extended to positive
      a_hi_sgn <= signed'(a[31:16]);         // Sign extended
      b_hi_sgn <= signed'(b[31:16]);         // Sign extended
  end
  
  // Explicitly force DSP48E1 mapping for these multipliers
  (* use_dsp = "yes" *) logic signed [35:0] p0;
  (* use_dsp = "yes" *) logic signed [35:0] p1;
  (* use_dsp = "yes" *) logic signed [35:0] p2;
  (* use_dsp = "yes" *) logic signed [35:0] p3;
  
  always_ff @(posedge clk) begin
      p0 <= a_lo_sgn * b_lo_sgn;
      p1 <= a_hi_sgn * b_lo_sgn;
      p2 <= a_lo_sgn * b_hi_sgn;
      p3 <= a_hi_sgn * b_hi_sgn;
  end
  
  logic signed [63:0] res_stg1;
  logic signed [63:0] p3_d;
  logic signed [63:0] res_stg2;
  
  always_ff @(posedge clk) begin
      res_stg1 <= 64'(p0) + (64'(p1) <<< 16) + (64'(p2) <<< 16);
      p3_d     <= 64'(p3) <<< 32;
      res_stg2 <= res_stg1 + p3_d;
  end
  
  assign p = res_stg2;
endmodule
