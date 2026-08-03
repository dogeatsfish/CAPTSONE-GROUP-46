//==============================================================================
// Portfolio State Tracker Testbench
//==============================================================================

`timescale 1ns/1ps

module portfolio_state_tb
  import ct_pkg::*;
;

  logic             core_clk;
  logic             rst_n;
  logic [TRADE_W-1:0] s_axis_tx_tdata;
  logic             s_axis_tx_tuser;
  logic             s_axis_tx_tvalid;
  portfolio_state_t m_portfolio_state;

  portfolio_state dut (
    .core_clk(core_clk),
    .rst_n(rst_n),
    .s_axis_tx_tdata(s_axis_tx_tdata),
    .s_axis_tx_tuser(s_axis_tx_tuser),
    .s_axis_tx_tvalid(s_axis_tx_tvalid),
    .m_portfolio_state(m_portfolio_state)
  );

  always #2 core_clk = ~core_clk; // 250 MHz

  trade_t t;
  
  task automatic send_trade(
    input logic is_buy,
    input logic [63:0] ticker,
    input logic [31:0] qty,
    input logic [31:0] price
  );
    t.timestamp = 16'h1234;
    t.ticker = ticker;
    t.quantity = qty;
    t.price = price;
    s_axis_tx_tdata = t;
    s_axis_tx_tuser = is_buy;
    s_axis_tx_tvalid = 1'b1;
    @(posedge core_clk);
    s_axis_tx_tvalid = 1'b0;
    @(posedge core_clk);
  endtask

  int num_checks = 0;
  int num_fails  = 0;

  task automatic check(input string name, input logic cond);
    num_checks++;
    if (!cond) begin
      $display("  [FAIL] %s", name);
      num_fails++;
    end else begin
      $display("  [ ok ] %s", name);
    end
  endtask

  initial begin
    core_clk = 1'b0;
    rst_n = 1'b0;
    s_axis_tx_tvalid = 1'b0;
    t = '0;
    s_axis_tx_tdata = '0;
    s_axis_tx_tuser = 1'b0;

    repeat(5) @(posedge core_clk);
    rst_n = 1'b1;
    @(posedge core_clk);
    
    // Initial cash
    check("Initial Cash is 10M", m_portfolio_state.available_cash === 64'd10_000_000);

    // Buy 100 shares of AAPL at $150
    $display("\n[T1] Buy 100 AAPL @ 150");
    send_trade(DIR_BUY, "AAPL    ", 100, 150);
    
    // Wait for divider
    repeat(40) @(posedge core_clk);
    
    check("Net Position == 100", m_portfolio_state.assets[0].net_position === 100);
    check("Total Value == 15000", m_portfolio_state.assets[0].total_position_value === 15000);
    check("Avg Price == 150", m_portfolio_state.assets[0].avg_entry_price === 150);
    check("Cash == 9,985,000", m_portfolio_state.available_cash === 64'd9_985_000);

    // Buy 100 more shares of AAPL at $170
    $display("\n[T2] Buy 100 AAPL @ 170");
    send_trade(DIR_BUY, "AAPL    ", 100, 170);
    
    repeat(40) @(posedge core_clk);
    
    check("Net Position == 200", m_portfolio_state.assets[0].net_position === 200);
    check("Total Value == 32000", m_portfolio_state.assets[0].total_position_value === 32000);
    check("Avg Price == 160", m_portfolio_state.assets[0].avg_entry_price === 160);
    check("Cash == 9,968,000", m_portfolio_state.available_cash === 64'd9_968_000);
    
    // Sell 50 shares at $200
    $display("\n[T3] Sell 50 AAPL @ 200");
    send_trade(DIR_SELL, "AAPL    ", 50, 200);
    
    repeat(10) @(posedge core_clk);
    
    check("Net Position == 150", m_portfolio_state.assets[0].net_position === 150);
    check("Total Value == 24000", m_portfolio_state.assets[0].total_position_value === 24000);
    check("Realized PnL == 2000", m_portfolio_state.assets[0].realized_pnl === 2000);
    check("Cash == 9,978,000", m_portfolio_state.available_cash === 64'd9_978_000);

    $display("\n==============================================================");
    $display("portfolio_state : %0d checks, %0d failures", num_checks, num_fails);
    $display("==============================================================");
    $finish;
  end

endmodule
