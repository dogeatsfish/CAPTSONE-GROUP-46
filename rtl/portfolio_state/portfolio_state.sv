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
  logic signed [63:0] p1_avg_cost;

  logic p2_valid;
  trade_t p2_trade;
  logic p2_is_buy;
  logic [ASSET_IDX_W-1:0] p2_idx;
  logic signed [63:0] p2_trade_val_lo_raw;
  logic signed [63:0] p2_trade_val_hi_raw;
  logic signed [63:0] p2_pnl_margin;
  logic signed [63:0] p2_cost_basis_lo_raw;
  logic signed [63:0] p2_cost_basis_hi_raw;

  logic p3_valid;
  trade_t p3_trade;
  logic p3_is_buy;
  logic [ASSET_IDX_W-1:0] p3_idx;
  logic signed [63:0] p3_trade_val_lo;
  logic signed [63:0] p3_trade_val_hi;
  logic signed [63:0] p3_pnl_margin;
  logic signed [63:0] p3_cost_basis_lo;
  logic signed [63:0] p3_cost_basis_hi;

  logic p4_valid;
  trade_t p4_trade;
  logic p4_is_buy;
  logic [ASSET_IDX_W-1:0] p4_idx;
  logic signed [63:0] p4_trade_val;
  logic signed [63:0] p4_cost_basis;
  logic signed [63:0] p4_pnl_val_lo_raw;
  logic signed [63:0] p4_pnl_val_hi_raw;

  logic p5_valid;
  trade_t p5_trade;
  logic p5_is_buy;
  logic [ASSET_IDX_W-1:0] p5_idx;
  logic signed [63:0] p5_trade_val;
  logic signed [63:0] p5_cost_basis;
  logic signed [63:0] p5_pnl_val_lo;
  logic signed [63:0] p5_pnl_val_hi;

  logic p6_valid;
  trade_t p6_trade;
  logic p6_is_buy;
  logic [ASSET_IDX_W-1:0] p6_idx;
  logic signed [63:0] p6_trade_val;
  logic signed [63:0] p6_cost_basis;
  logic signed [63:0] p6_pnl_val;

  always_ff @(posedge core_clk or negedge rst_n) begin
    if (!rst_n) begin
      cash <= 64'd10_000_000; // Start with 10M cash
      p1_valid <= 1'b0;
      p2_valid <= 1'b0;
      p3_valid <= 1'b0;
      p4_valid <= 1'b0;
      p5_valid <= 1'b0;
      p6_valid <= 1'b0;
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
      p1_trade    <= trade_in;
      p1_is_buy   <= is_buy;
      p1_idx      <= s_idx;
      p1_avg_cost <= assets[s_idx].avg_entry_price;

      // Stage 2
      p2_valid <= p1_valid;
      p2_trade      <= p1_trade;
      p2_is_buy     <= p1_is_buy;
      p2_idx        <= p1_idx;
      p2_trade_val_lo_raw <= signed'({32'd0, p1_trade.price}) * signed'({33'd0, p1_trade.quantity[15:0]});
      p2_trade_val_hi_raw <= signed'({32'd0, p1_trade.price}) * signed'({33'd0, p1_trade.quantity[31:16]});
      p2_pnl_margin       <= signed'({32'd0, p1_trade.price}) - signed'(p1_avg_cost);
      p2_cost_basis_lo_raw<= signed'(p1_avg_cost) * signed'({33'd0, p1_trade.quantity[15:0]});
      p2_cost_basis_hi_raw<= signed'(p1_avg_cost) * signed'({33'd0, p1_trade.quantity[31:16]});

      // Stage 3
      p3_valid <= p2_valid;
      p3_trade      <= p2_trade;
      p3_is_buy     <= p2_is_buy;
      p3_idx        <= p2_idx;
      p3_trade_val_lo <= p2_trade_val_lo_raw;
      p3_trade_val_hi <= p2_trade_val_hi_raw;
      p3_cost_basis_lo <= p2_cost_basis_lo_raw;
      p3_cost_basis_hi <= p2_cost_basis_hi_raw;
      p3_pnl_margin   <= p2_pnl_margin;

      // Stage 4
      p4_valid <= p3_valid;
      p4_trade      <= p3_trade;
      p4_is_buy     <= p3_is_buy;
      p4_idx        <= p3_idx;
      p4_trade_val  <= p3_trade_val_lo + (p3_trade_val_hi << 16);
      p4_cost_basis <= p3_cost_basis_lo + (p3_cost_basis_hi << 16);
      p4_pnl_val_lo_raw <= p3_pnl_margin * signed'({33'd0, p3_trade.quantity[15:0]});
      p4_pnl_val_hi_raw <= p3_pnl_margin * signed'({33'd0, p3_trade.quantity[31:16]});

      // Stage 5
      p5_valid <= p4_valid;
      p5_trade      <= p4_trade;
      p5_is_buy     <= p4_is_buy;
      p5_idx        <= p4_idx;
      p5_trade_val  <= p4_trade_val;
      p5_cost_basis <= p4_cost_basis;
      p5_pnl_val_lo <= p4_pnl_val_lo_raw;
      p5_pnl_val_hi <= p4_pnl_val_hi_raw;

      // Stage 6
      p6_valid <= p5_valid;
      p6_trade      <= p5_trade;
      p6_is_buy     <= p5_is_buy;
      p6_idx        <= p5_idx;
      p6_trade_val  <= p5_trade_val;
      p6_cost_basis <= p5_cost_basis;
      p6_pnl_val    <= p5_pnl_val_lo + (p5_pnl_val_hi << 16);

      // Stage 7 (Write-back)
      if (p6_valid) begin
        assets[p6_idx].last_trade_timestamp <= p6_trade.timestamp;
        
        if (p6_is_buy) begin
          cash <= cash - p6_trade_val;
          assets[p6_idx].net_position <= assets[p6_idx].net_position + signed'(p6_trade.quantity);
          assets[p6_idx].total_position_value <= assets[p6_idx].total_position_value + p6_trade_val;
          
          // Trigger division for new average cost
          div_state[p6_idx] <= DIVIDE;
          div_num[p6_idx]   <= (assets[p6_idx].total_position_value + p6_trade_val);
          div_den[p6_idx]   <= (assets[p6_idx].net_position + signed'(p6_trade.quantity));
          div_quot[p6_idx]  <= '0;
          div_rem[p6_idx]   <= '0;
          div_count[p6_idx] <= 32;
        end else begin // Sell
          cash <= cash + p6_trade_val;
          assets[p6_idx].realized_pnl <= assets[p6_idx].realized_pnl + p6_pnl_val;
          assets[p6_idx].net_position <= assets[p6_idx].net_position - signed'(p6_trade.quantity);
          assets[p6_idx].total_position_value <= assets[p6_idx].total_position_value - p6_cost_basis;
          
          // If flat or short, reset tracking
          if (assets[p6_idx].net_position <= signed'(p6_trade.quantity)) begin
            assets[p6_idx].total_position_value <= '0;
            assets[p6_idx].avg_entry_price <= '0;
            div_state[p6_idx] <= IDLE; // cancel any running division
          end
        end
      end
    end
  end

endmodule
