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

  // Pipeline Registers
  logic p1_valid;
  trade_t p1_trade;
  logic p1_is_buy;
  logic [ASSET_IDX_W-1:0] p1_idx;
  logic signed [31:0] p1_avg_cost;

  logic p2_valid;
  trade_t p2_trade;
  logic p2_is_buy;
  logic [ASSET_IDX_W-1:0] p2_idx;
  logic signed [63:0] p2_trade_val;
  logic signed [31:0] p2_pnl_margin;
  logic signed [63:0] p2_cost_basis;

  logic p3_valid;
  trade_t p3_trade;
  logic p3_is_buy;
  logic [ASSET_IDX_W-1:0] p3_idx;
  logic signed [63:0] p3_trade_val;
  logic signed [63:0] p3_pnl_val;
  logic signed [63:0] p3_cost_basis;

  always_ff @(posedge core_clk or negedge rst_n) begin
    if (!rst_n) begin
      cash <= 64'd10_000_000; // Start with 10M cash
      p1_valid <= 1'b0;
      p2_valid <= 1'b0;
      p3_valid <= 1'b0;
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

      // Stage 1
      p1_valid <= valid_trade;
      if (valid_trade) begin
        p1_trade    <= trade_in;
        p1_is_buy   <= is_buy;
        p1_idx      <= s_idx;
        p1_avg_cost <= assets[s_idx].avg_entry_price;
      end

      // Stage 2
      p2_valid <= p1_valid;
      if (p1_valid) begin
        p2_trade      <= p1_trade;
        p2_is_buy     <= p1_is_buy;
        p2_idx        <= p1_idx;
        p2_trade_val  <= signed'({32'd0, p1_trade.price}) * signed'({32'd0, p1_trade.quantity});
        p2_pnl_margin <= signed'({32'd0, p1_trade.price}) - signed'(p1_avg_cost);
        p2_cost_basis <= signed'(p1_avg_cost) * signed'({32'd0, p1_trade.quantity});
      end

      // Stage 3
      p3_valid <= p2_valid;
      if (p2_valid) begin
        p3_trade      <= p2_trade;
        p3_is_buy     <= p2_is_buy;
        p3_idx        <= p2_idx;
        p3_trade_val  <= p2_trade_val;
        p3_pnl_val    <= p2_pnl_margin * signed'({32'd0, p2_trade.quantity});
        p3_cost_basis <= p2_cost_basis;
      end

      // Stage 4 (Write-back)
      if (p3_valid) begin
        assets[p3_idx].last_trade_timestamp <= p3_trade.timestamp;
        
        if (p3_is_buy) begin
          cash <= cash - p3_trade_val;
          assets[p3_idx].net_position <= assets[p3_idx].net_position + signed'(p3_trade.quantity);
          assets[p3_idx].total_position_value <= assets[p3_idx].total_position_value + p3_trade_val;
          
          // Trigger division for new average cost
          div_state[p3_idx] <= DIVIDE;
          div_num[p3_idx]   <= (assets[p3_idx].total_position_value + p3_trade_val);
          div_den[p3_idx]   <= (assets[p3_idx].net_position + signed'(p3_trade.quantity));
          div_quot[p3_idx]  <= '0;
          div_rem[p3_idx]   <= '0;
          div_count[p3_idx] <= 32;
        end else begin // Sell
          cash <= cash + p3_trade_val;
          assets[p3_idx].realized_pnl <= assets[p3_idx].realized_pnl + p3_pnl_val;
          assets[p3_idx].net_position <= assets[p3_idx].net_position - signed'(p3_trade.quantity);
          assets[p3_idx].total_position_value <= assets[p3_idx].total_position_value - p3_cost_basis;
          
          // If flat or short, reset tracking
          if (assets[p3_idx].net_position <= signed'(p3_trade.quantity)) begin
            assets[p3_idx].total_position_value <= '0;
            assets[p3_idx].avg_entry_price <= '0;
            div_state[p3_idx] <= IDLE; // cancel any running division
          end
        end
      end
    end
  end

endmodule
