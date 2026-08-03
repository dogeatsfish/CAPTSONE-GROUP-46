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

  always_ff @(posedge core_clk or negedge rst_n) begin
    if (!rst_n) begin
      cash <= 64'd10_000_000; // Start with 10M cash
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

      // Ingest valid trade
      if (valid_trade) begin
        automatic logic signed [63:0] trade_val;
        automatic logic signed [31:0] avg_cost;
        trade_val = signed'({32'd0, trade_in.price}) * signed'({32'd0, trade_in.quantity});
        assets[s_idx].last_trade_timestamp <= trade_in.timestamp;
        
        if (is_buy) begin
          cash <= cash - trade_val;
          assets[s_idx].net_position <= assets[s_idx].net_position + signed'(trade_in.quantity);
          assets[s_idx].total_position_value <= assets[s_idx].total_position_value + trade_val;
          
          // Trigger division for new average cost
          div_state[s_idx] <= DIVIDE;
          div_num[s_idx] <= (assets[s_idx].total_position_value + trade_val);
          div_den[s_idx] <= (assets[s_idx].net_position + signed'(trade_in.quantity));
          div_quot[s_idx] <= '0;
          div_rem[s_idx] <= '0;
          div_count[s_idx] <= 32;
        end else begin // Sell
          cash <= cash + trade_val;
          // Calculate PnL based on existing average cost basis
          avg_cost = assets[s_idx].avg_entry_price;
          assets[s_idx].realized_pnl <= assets[s_idx].realized_pnl + 
              (signed'({32'd0, trade_in.price}) - signed'(avg_cost)) * signed'({32'd0, trade_in.quantity});
              
          assets[s_idx].net_position <= assets[s_idx].net_position - signed'(trade_in.quantity);
          assets[s_idx].total_position_value <= assets[s_idx].total_position_value - 
              (signed'(avg_cost) * signed'({32'd0, trade_in.quantity}));
              
          // If flat or short, reset tracking
          if (assets[s_idx].net_position <= signed'(trade_in.quantity)) begin
            assets[s_idx].total_position_value <= '0;
            assets[s_idx].avg_entry_price <= '0;
            div_state[s_idx] <= IDLE; // cancel any running division
          end
        end
      end
    end
  end

endmodule
