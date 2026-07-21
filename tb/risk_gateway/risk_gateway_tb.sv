//==============================================================================
// Testbench: tb_pre_trade_risk_gateway
// Features: Cycle-accurate pipeline scoreboard, Back-to-back burst testing, 
//           parallel constraint checking, and automated Pass/Fail flags.
//==============================================================================
module tb_pre_trade_risk_gateway;
  import ct_pkg::*;

  // Parameters matching the DUT defaults
  localparam int MAX_QTY       = 32'd10_000;
  localparam int MAX_ORDER_VAL = 32'd1_000_000;
  localparam int RATE_TOKENS   = 16;
  localparam int RATE_PERIOD   = 250_000;

  // Clock and Reset
  logic clk_250mhz;
  logic rst_n;

  // AXI4-Stream Inputs
  logic [TRADE_W-1:0] s_axis_order_tdata;
  logic               s_axis_order_tuser;
  logic               s_axis_order_tvalid;

  // Kill Inputs
  logic rx_error;
  logic hw_kill_switch;

  // AXI4-Stream Outputs
  logic [TRADE_W-1:0] m_axis_tx_tdata;
  logic               m_axis_tx_tuser;
  logic               m_axis_tx_tvalid;

  // Global Test Tracking
  int tests_passed = 0;
  int tests_failed = 0;
  bit all_tests_passed = 1;
  
  string current_test_name = "IDLE";
  logic  current_test_expected = 0;

  // DUT Instantiation
  pre_trade_risk_gateway #(
    .MAX_QTY(MAX_QTY),
    .MAX_ORDER_VAL(MAX_ORDER_VAL),
    .RATE_TOKENS(RATE_TOKENS),
    .RATE_PERIOD(RATE_PERIOD)
  ) dut (
    .clk_250mhz(clk_250mhz),
    .rst_n(rst_n),
    .s_axis_order_tdata(s_axis_order_tdata),
    .s_axis_order_tuser(s_axis_order_tuser),
    .s_axis_order_tvalid(s_axis_order_tvalid),
    .rx_error(rx_error),
    .hw_kill_switch(hw_kill_switch),
    .m_axis_tx_tdata(m_axis_tx_tdata),
    .m_axis_tx_tuser(m_axis_tx_tuser),
    .m_axis_tx_tvalid(m_axis_tx_tvalid)
  );

  // 250 MHz Clock Generation (4 ns period)
  initial begin
    clk_250mhz = 0;
    forever #2 clk_250mhz = ~clk_250mhz;
  end

  //==============================================================================
  // CYCLE-ACCURATE PIPELINE SCOREBOARD
  // Validates that outputs arrive exactly 4 cycles after input insertion.
  //==============================================================================
  typedef struct {
      string name;
      logic  expected;
  } check_t;

  check_t check_pipe [0:4];

  always @(negedge clk_250mhz) begin
      if (rst_n) begin
          // Shift the pipeline forward
          for (int i = 4; i > 0; i--) begin
              check_pipe[i] = check_pipe[i-1];
          end
          
          // Insert the current cycle's expectation
          check_pipe[0].name     = current_test_name;
          check_pipe[0].expected = current_test_expected;
          
          // Check the tail of the pipe (Cycle 4 output)
          if (check_pipe[4].name != "IDLE") begin
              if (m_axis_tx_tvalid === check_pipe[4].expected) begin
                  $display("[PASS] %s | Expected=%b, Got=%b", 
                            check_pipe[4].name, check_pipe[4].expected, m_axis_tx_tvalid);
                  tests_passed++;
              end else begin
                  $display("[FAIL] %s | Expected=%b, Got=%b", 
                            check_pipe[4].name, check_pipe[4].expected, m_axis_tx_tvalid);
                  tests_failed++;
                  all_tests_passed = 0;
              end
          end
      end else begin
          for (int i = 0; i < 5; i++) begin
              check_pipe[i].name = "IDLE";
              check_pipe[i].expected = 0;
          end
      end
  end

  //==============================================================================
  // TEST DRIVER TASKS
  // Drives data on negedge so the DUT properly captures it on the posedge.
  //==============================================================================
  task drive_trade(
    input string name,
    input logic [15:0] t_stamp,
    input logic [63:0] t_ticker,
    input logic [31:0] t_qty,
    input logic [31:0] t_price,
    input logic        t_user,
    input logic        expect_pass
  );
    begin
      @(negedge clk_250mhz);
      current_test_name     = name;
      current_test_expected = expect_pass;
      
      s_axis_order_tvalid <= 1'b1;
      s_axis_order_tuser  <= t_user;
      // Pack struct bits: [143:128] Timestamp, [127:64] Ticker, [63:32] Qty, [31:0] Price
      s_axis_order_tdata  <= {t_stamp, t_ticker, t_qty, t_price}; 
    end
  endtask

  task drive_idle();
    begin
      @(negedge clk_250mhz);
      current_test_name     = "IDLE";
      current_test_expected = 0;
      
      s_axis_order_tvalid <= 1'b0;
      s_axis_order_tdata  <= '0;
      s_axis_order_tuser  <= 1'b0;
    end
  endtask

  //==============================================================================
  // MAIN STIMULUS
  //==============================================================================
  initial begin
    // Init
    rst_n               = 0;
    rx_error            = 0; 
    hw_kill_switch      = 0;
    drive_idle();

    // Apply Reset
    #20;
    rst_n = 1;
    #20;

    $display("--- Starting Pre-Trade Risk Gateway Tests ---");

    // TEST 1: Valid Trade (Qty = 500, Price = 1000)
    drive_trade("TEST 1: Valid Trade", 16'h1111, "AAPL    ", 32'd500, 32'd1000, 1'b1, 1'b1);
    drive_idle();
    repeat(6) @(posedge clk_250mhz); 

    // TEST 2: Max Quantity Violation (Qty = 15,000 > 10,000)
    drive_trade("TEST 2: Max Qty Violation (15k shares)", 16'h2222, "MSFT    ", 32'd15000, 32'd10, 1'b1, 1'b0);
    drive_idle();
    repeat(6) @(posedge clk_250mhz);

    // TEST 3: Max Value Violation (Qty = 2k, Price = 1000 -> 2,000,000 > 1,000,000)
    drive_trade("TEST 3: Max Value Violation ($2M Order)", 16'h3333, "TSLA    ", 32'd2000, 32'd1000, 1'b0, 1'b0);
    drive_idle();
    repeat(6) @(posedge clk_250mhz);

    // TEST 4: Parallelization - Multiple simultaneous violations on one order
    // Qty = 15,000 (Fails) AND Value = 15,000,000 (Fails)
    drive_trade("TEST 4: Parallel Violations (Qty & Value)", 16'h4444, "META    ", 32'd15000, 32'd1000, 1'b1, 1'b0);
    drive_idle();
    repeat(6) @(posedge clk_250mhz);

    // TEST 5: Pipeline Parallelization - Burst back-to-back trades without gaps
    $display("--- Starting Back-to-Back Pipeline Test ---");
    drive_trade("TEST 5A: Pipe Burst (Valid)",     16'h500A, "MSFT    ", 32'd100, 32'd100, 1'b1, 1'b1);
    drive_trade("TEST 5B: Pipe Burst (Qty Fail)",  16'h500B, "MSFT    ", 32'd20000, 32'd10, 1'b1, 1'b0);
    drive_trade("TEST 5C: Pipe Burst (Val Fail)",  16'h500C, "MSFT    ", 32'd2000, 32'd1000, 1'b1, 1'b0);
    drive_trade("TEST 5D: Pipe Burst (Valid)",     16'h500D, "MSFT    ", 32'd100, 32'd100, 1'b1, 1'b1);
    drive_idle();
    repeat(8) @(posedge clk_250mhz);

    // Refill the token bucket by resetting the system before the burst
    rst_n = 0;
    repeat(4) @(posedge clk_250mhz);
    rst_n = 1;
    repeat(4) @(posedge clk_250mhz);

    // TEST 6: Rate Limiter Exhaustion (Tokens = 16)
    $display("--- Starting Rate Limiter Token Burst ---");
    for (int i = 0; i < 16; i++) begin
      drive_trade($sformatf("TEST 6: Token Bucket Fill #%0d", i+1), 16'h6000+i, "NVDA    ", 32'd10, 32'd10, 1'b1, 1'b1);
    end
    // 17th consecutive order must drop
    drive_trade("TEST 6: Rate Limiter Exhausted (Fail)", 16'h60FF, "NVDA    ", 32'd10, 32'd10, 1'b1, 1'b0);
    drive_idle();
    repeat(10) @(posedge clk_250mhz);

    // TEST 7: Hardware Kill Switch 
    @(negedge clk_250mhz);
    hw_kill_switch = 1'b1;
    drive_trade("TEST 7: HW Kill Switch Latched (Fail)", 16'h7777, "AMD     ", 32'd100, 32'd100, 1'b1, 1'b0);
    drive_idle();
    repeat(6) @(posedge clk_250mhz);

    //==============================================================================
    // FINAL PASS/FAIL SUMMARY
    //==============================================================================
    $display("\n=================================================");
    $display("              SIMULATION SUMMARY                 ");
    $display("=================================================");
    $display(" Tests Passed : %0d", tests_passed);
    $display(" Tests Failed : %0d", tests_failed);
    $display("-------------------------------------------------");
    
    if (all_tests_passed && tests_passed > 0) begin
        $display(" >>>  FLAG: ALL TESTS PASSED SUCCESSFULLY!  <<<");
    end else begin
        $display(" >>>  FLAG: SOME TESTS FAILED. CHECK LOGS.  <<<");
    end
    $display("=================================================\n");
    
    $finish;
  end

endmodule