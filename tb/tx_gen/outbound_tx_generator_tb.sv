//==============================================================================
// outbound_tx_generator_tb  -  unit testbench for
//   rtl/tx_gen/outbound_tx_generator.sv
//
// Self-checking SystemVerilog testbench (Verilator --binary --timing).
//
// Strategy: drive an approved trade, capture the serialised byte stream, and
// compare it against a golden packet rebuilt independently in the bench. On top
// of the byte-exact compare, several structural invariants are checked so a
// wiring bug can't hide behind a matching golden model:
//   * IPv4 header checksum verified by the RECEIVER property (one's-complement
//     sum of the 20 header bytes == 0xFFFF), independent of how the DUT computed
//     it.
//   * IP total-length and UDP-length fields equal the observed byte counts.
//   * m_axis_tlast asserted on exactly the final byte, nowhere else.
//   * s_axis_trade_tready high when idle, low throughout serialisation.
//   * UserRefNum strictly increases (1, 2, ...) across trades.
//   * Latency == (timestamp_now @ accept) - trade.timestamp.
//   * Big-endian field order and Buy/Sell side byte.
//==============================================================================

`timescale 1ns/1ps

module outbound_tx_generator_tb
  import ct_pkg::*;
;

  //--------------------------------------------------------------------------
  // Packet geometry / constants -- MUST MIRROR the DUT localparams.
  //--------------------------------------------------------------------------
  localparam int PKT_LEN     = 77;
  localparam int IP_HDR_LEN  = 20;
  localparam int UDP_HDR_LEN = 8;

  localparam logic [31:0] SRC_IP   = 32'hC0A8_0001;
  localparam logic [31:0] DST_IP   = 32'hC0A8_0002;
  localparam logic [15:0] SRC_PORT = 16'd50000;
  localparam logic [15:0] DST_PORT = 16'd50001;
  localparam logic [7:0]  IP_TTL   = 8'd64;
  localparam logic [7:0]  IP_PROTO = 8'd17;

  localparam logic [7:0]  OUCH_SPACE  = 8'h20;
  localparam logic [7:0]  OUCH_TYPE_O = 8'h4F;
  localparam logic [7:0]  SIDE_BUY    = 8'h42;   // 'B'
  localparam logic [7:0]  SIDE_SELL   = 8'h53;   // 'S'

  //--------------------------------------------------------------------------
  // Clock / reset / DUT ports
  //--------------------------------------------------------------------------
  logic core_clk;
  logic core_rst_n;

  logic [TRADE_W-1:0]     s_axis_trade_tdata;
  logic                   s_axis_trade_tuser;
  logic                   s_axis_trade_tvalid;
  logic                   s_axis_trade_tready;
  logic                   fifo_has_room;
  logic [TIMESTAMP_W-1:0] timestamp_now;
  logic [7:0]             m_axis_tdata;
  logic                   m_axis_tvalid;
  logic                   m_axis_tlast;

  initial core_clk = 1'b0;
  always #(CORE_PERIOD_NS/2.0) core_clk = ~core_clk;   // 250 MHz

  // Shared free-running timestamp counter (top-level in the real system).
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) timestamp_now <= 16'd0;
    else             timestamp_now <= timestamp_now + 16'd1;
  end

  outbound_tx_generator dut (
    .core_clk            (core_clk),
    .core_rst_n          (core_rst_n),
    .s_axis_trade_tdata  (s_axis_trade_tdata),
    .s_axis_trade_tuser  (s_axis_trade_tuser),
    .s_axis_trade_tvalid (s_axis_trade_tvalid),
    .s_axis_trade_tready (s_axis_trade_tready),
    .fifo_has_room       (fifo_has_room),
    .timestamp_now       (timestamp_now),
    .m_axis_tdata        (m_axis_tdata),
    .m_axis_tvalid       (m_axis_tvalid),
    .m_axis_tlast        (m_axis_tlast)
  );

  //--------------------------------------------------------------------------
  // Scoreboard
  //--------------------------------------------------------------------------
  int unsigned checks = 0;
  int unsigned errors = 0;

  task automatic check_byte(input string name, input logic [7:0] got, input logic [7:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-34s got=0x%02h exp=0x%02h", name, got, exp);
    end
  endtask

  task automatic check_int(input string name, input int got, input int exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-34s got=%0d exp=%0d", name, got, exp);
    end else begin
      $display("  [ OK ] %-34s = %0d", name, got);
    end
  endtask

  //--------------------------------------------------------------------------
  // Golden packet builder (independent re-implementation of the encoding).
  //--------------------------------------------------------------------------
  function automatic logic [15:0] ip_checksum(input logic [15:0] tot_len,
                                              input logic [15:0] id16);
    logic [31:0] s;
    s = 32'h0;
    s += 32'h0000_4500;
    s += {16'h0, tot_len};
    s += {16'h0, id16};
    s += 32'h0000_4000;
    s += {16'h0, IP_TTL, IP_PROTO};
    s += {16'h0, SRC_IP[31:16]};
    s += {16'h0, SRC_IP[15:0]};
    s += {16'h0, DST_IP[31:16]};
    s += {16'h0, DST_IP[15:0]};
    s = (s & 32'h0000_FFFF) + (s >> 16);
    s = (s & 32'h0000_FFFF) + (s >> 16);
    return ~s[15:0];
  endfunction

  // exp[] is filled with the expected 77-byte packet.
  task automatic build_expected(input logic        dir,
                                input logic [63:0] symbol,
                                input logic [31:0] qty,
                                input logic [31:0] price,
                                input logic [31:0] uref,
                                input logic [15:0] ident,
                                input logic [15:0] latency,
                                ref   logic [7:0]  exp [0:127]);
    logic [15:0] csum;
    for (int i = 0; i < 128; i++) exp[i] = 8'h00;
    csum = ip_checksum(16'(PKT_LEN), ident);

    // IPv4
    exp[0]  = 8'h45;
    exp[2]  = 8'(PKT_LEN >> 8);      exp[3]  = 8'(PKT_LEN);
    exp[4]  = ident[15:8];           exp[5]  = ident[7:0];
    exp[6]  = 8'h40;
    exp[8]  = IP_TTL;                exp[9]  = IP_PROTO;
    exp[10] = csum[15:8];            exp[11] = csum[7:0];
    exp[12] = SRC_IP[31:24]; exp[13] = SRC_IP[23:16]; exp[14] = SRC_IP[15:8]; exp[15] = SRC_IP[7:0];
    exp[16] = DST_IP[31:24]; exp[17] = DST_IP[23:16]; exp[18] = DST_IP[15:8]; exp[19] = DST_IP[7:0];
    // UDP
    exp[20] = SRC_PORT[15:8]; exp[21] = SRC_PORT[7:0];
    exp[22] = DST_PORT[15:8]; exp[23] = DST_PORT[7:0];
    exp[24] = 8'((PKT_LEN-IP_HDR_LEN) >> 8); exp[25] = 8'(PKT_LEN-IP_HDR_LEN);
    // 26,27 UDP checksum = 0
    // OUCH Enter Order
    exp[28] = OUCH_TYPE_O;
    exp[29] = uref[31:24]; exp[30] = uref[23:16]; exp[31] = uref[15:8]; exp[32] = uref[7:0];
    exp[33] = dir ? SIDE_BUY : SIDE_SELL;
    exp[34] = qty[31:24]; exp[35] = qty[23:16]; exp[36] = qty[15:8]; exp[37] = qty[7:0];
    exp[38] = symbol[63:56]; exp[39] = symbol[55:48]; exp[40] = symbol[47:40]; exp[41] = symbol[39:32];
    exp[42] = symbol[31:24]; exp[43] = symbol[23:16]; exp[44] = symbol[15:8];  exp[45] = symbol[7:0];
    // 46..49 price zero-extend = 0
    exp[50] = price[31:24]; exp[51] = price[23:16]; exp[52] = price[15:8]; exp[53] = price[7:0];
    // 54..58 control-field defaults = 0
    for (int i = 59; i <= 72; i++) exp[i] = OUCH_SPACE;   // ClOrdID
    // 73,74 appendage length = 0
    // Telemetry
    exp[75] = latency[15:8]; exp[76] = latency[7:0];
  endtask

  //--------------------------------------------------------------------------
  // Capture buffer (filled by run_trade's capture thread)
  //--------------------------------------------------------------------------
  logic [7:0]  cap [0:127];
  int          cap_len;
  int          tlast_count;
  int          tlast_pos;

  // Drive one trade and capture the whole serialised packet.
  // ts_used returns the timestamp_now value the DUT sampled at accept.
  task automatic run_trade(input logic        dir,
                           input logic [15:0] ts_field,
                           input logic [63:0] symbol,
                           input logic [31:0] qty,
                           input logic [31:0] price,
                           output logic [15:0] ts_used);
    trade_t tv;
    tv.timestamp = ts_field;
    tv.ticker    = symbol;
    tv.quantity  = qty;
    tv.price     = price;

    cap_len     = 0;
    tlast_count = 0;
    tlast_pos   = -1;

    fork
      //-- driver -----------------------------------------------------------
      begin
        @(negedge core_clk);
        wait (s_axis_trade_tready);          // DUT idle/ready
        s_axis_trade_tdata  = tv;
        s_axis_trade_tuser  = dir;
        s_axis_trade_tvalid = 1'b1;
        ts_used = timestamp_now;             // value the DUT uses at next posedge
        @(posedge core_clk);                 // accept
        @(negedge core_clk);
        s_axis_trade_tvalid = 1'b0;
        s_axis_trade_tdata  = '0;
        s_axis_trade_tuser  = 1'b0;
      end
      //-- capturer ---------------------------------------------------------
      begin
        // Wait for the first output byte, then collect contiguously.
        @(negedge core_clk);
        while (!m_axis_tvalid) @(negedge core_clk);
        while (m_axis_tvalid) begin
          cap[cap_len] = m_axis_tdata;
          if (m_axis_tlast) begin
            tlast_count++;
            tlast_pos = cap_len;
          end
          cap_len++;
          @(negedge core_clk);
        end
      end
    join

    // settle back to idle
    repeat (3) @(posedge core_clk);
  endtask

  //--------------------------------------------------------------------------
  // Whole-packet comparison + structural invariants
  //--------------------------------------------------------------------------
  task automatic verify_packet(input string label, ref logic [7:0] exp [0:127],
                               input logic [15:0] ident);
    logic [31:0] hsum;
    $display("\n[%s] byte-exact compare + invariants", label);

    // 1) length
    check_int("packet length (bytes)", cap_len, PKT_LEN);

    // 2) exactly one tlast, on the final byte
    check_int("tlast count", tlast_count, 1);
    check_int("tlast position", tlast_pos, PKT_LEN - 1);

    // 3) byte-exact compare against golden model
    begin
      int mism;
      mism = 0;
      for (int i = 0; i < PKT_LEN; i++) begin
        if (cap[i] !== exp[i]) begin
          mism++;
          if (mism <= 8)
            $display("  [FAIL] byte[%0d] got=0x%02h exp=0x%02h", i, cap[i], exp[i]);
        end
      end
      check_int("golden byte mismatches", mism, 0);
    end

    // 4) IPv4 header checksum: receiver-side property. One's-complement sum of
    //    the ten 16-bit header words (checksum field included) must be 0xFFFF.
    hsum = 0;
    for (int i = 0; i < IP_HDR_LEN; i += 2)
      hsum += 32'({cap[i], cap[i+1]});
    hsum = (hsum & 32'hFFFF) + (hsum >> 16);
    hsum = (hsum & 32'hFFFF) + (hsum >> 16);
    check_byte("IP checksum valid (~sum lo == 0xFF)", ~hsum[7:0],  8'h00);
    check_byte("IP checksum valid (~sum hi == 0xFF)", ~hsum[15:8], 8'h00);

    // 5) IP total-length and UDP-length fields match observed counts
    check_int("IP total-length field", int'({cap[2],  cap[3]}),  PKT_LEN);
    check_int("UDP length field",      int'({cap[24], cap[25]}), PKT_LEN - IP_HDR_LEN);

    // 6) IP identification field matches expected
    check_int("IP identification field", int'({cap[4], cap[5]}), int'(ident));
  endtask

  //--------------------------------------------------------------------------
  // tready observation across a serialisation
  //--------------------------------------------------------------------------
  logic tready_low_seen;
  logic tready_high_at_idle;

  //--------------------------------------------------------------------------
  // Test sequence
  //--------------------------------------------------------------------------
  logic [7:0]  exp [0:127];
  logic [15:0] ts_used;
  logic [15:0] exp_lat;

  initial begin
    s_axis_trade_tdata  = '0;
    s_axis_trade_tuser  = 1'b0;
    s_axis_trade_tvalid = 1'b0;
    fifo_has_room       = 1'b1;      // FIFO has room throughout T1/T2
    tready_low_seen     = 1'b0;

    // reset
    core_rst_n = 1'b0;
    repeat (5) @(posedge core_clk);
    @(negedge core_clk);
    core_rst_n = 1'b1;
    repeat (2) @(posedge core_clk);

    // idle handshake
    @(negedge core_clk);
    check_int("tready high when idle", int'(s_axis_trade_tready), 1);

    //------------------------------------------------------------------ Trade 1
    // BUY  AAPL  qty=10000 (0x2710)  price=1,000,000 (0x000F4240)  ts=3
    // Expected: UserRefNum=1, ident=0, side='B'
    fork
      begin : watch_ready_1
        // sample tready during the serialisation window
        tready_low_seen = 1'b0;
        repeat (PKT_LEN + 6) begin
          @(negedge core_clk);
          if (!s_axis_trade_tready) tready_low_seen = 1'b1;
        end
      end
    join_none
    run_trade(1'b1, 16'd1, 64'h4141_504C_2020_2020, 32'h0000_2710, 32'h000F_4240, ts_used);
    exp_lat = ts_used - 16'd1;
    build_expected(1'b1, 64'h4141_504C_2020_2020, 32'h0000_2710, 32'h000F_4240,
                   32'd1, 16'd0, exp_lat, exp);
    verify_packet("T1 Enter/BUY AAPL", exp, 16'd0);
    check_byte("T1 side byte = 'B'", cap[33], SIDE_BUY);
    check_int ("T1 UserRefNum", int'({cap[29],cap[30],cap[31],cap[32]}), 1);
    check_int ("T1 latency field", int'({cap[75],cap[76]}), int'(exp_lat));
    wait fork;
    check_int("tready dropped during TX", int'(tready_low_seen), 1);

    //------------------------------------------------------------------ Trade 2
    // SELL MSFT qty=100000 (0x000186A0) price=2,000,000 (0x001E8480) ts=7
    // Expected: UserRefNum=2, ident=1, side='S'
    run_trade(1'b0, 16'd7, 64'h4D53_4654_2020_2020, 32'h0001_86A0, 32'h001E_8480, ts_used);
    exp_lat = ts_used - 16'd7;
    build_expected(1'b0, 64'h4D53_4654_2020_2020, 32'h0001_86A0, 32'h001E_8480,
                   32'd2, 16'd1, exp_lat, exp);
    verify_packet("T2 Enter/SELL MSFT", exp, 16'd1);
    check_byte("T2 side byte = 'S'", cap[33], SIDE_SELL);
    check_int ("T2 UserRefNum increments to 2", int'({cap[29],cap[30],cap[31],cap[32]}), 2);
    check_int ("T2 latency field", int'({cap[75],cap[76]}), int'(exp_lat));

    // Symbol big-endian sanity: first ClOrdID byte is a space, symbol starts 'M'
    check_byte("T2 symbol[0] = 'M'", cap[38], 8'h4D);
    check_byte("T2 ClOrdID[0] = space", cap[59], OUCH_SPACE);

    //------------------------------------------------------------------ T3
    // Start gate (L1 fix): with the TX FIFO reporting no room, the generator
    // must NOT accept a trade -- tready stays low and no bytes are emitted --
    // and must resume the instant room appears.
    $display("\n[T3] FIFO start gate: no room -> stall, then accept");
    begin
      trade_t tv3;
      int     bytes_while_full;
      logic   ready_while_full;
      logic   started_after_room;

      tv3.timestamp = 16'd0;
      tv3.ticker    = 64'h4747_4C45_2020_2020;   // "GGLE"
      tv3.quantity  = 32'd500;
      tv3.price     = 32'h0003_0D40;

      @(negedge core_clk);
      fifo_has_room       = 1'b0;                 // FIFO cannot hold a frame
      s_axis_trade_tdata  = tv3;
      s_axis_trade_tuser  = 1'b1;
      s_axis_trade_tvalid = 1'b1;

      bytes_while_full = 0;
      ready_while_full = 1'b0;
      repeat (20) begin
        @(negedge core_clk);
        if (s_axis_trade_tready) ready_while_full = 1'b1;
        if (m_axis_tvalid)       bytes_while_full++;
      end
      check_int("no tready while FIFO full",         int'(ready_while_full), 0);
      check_int("no bytes emitted while FIFO full",  bytes_while_full,       0);

      // Open room: the pending trade must now be accepted and streamed.
      fifo_has_room      = 1'b1;
      started_after_room = 1'b0;
      repeat (10) begin
        @(negedge core_clk);
        if (m_axis_tvalid) started_after_room = 1'b1;
      end
      check_int("frame starts once room appears", int'(started_after_room), 1);

      // Deassert and let it drain back to idle.
      s_axis_trade_tvalid = 1'b0;
      s_axis_trade_tdata  = '0;
      s_axis_trade_tuser  = 1'b0;
      repeat (PKT_LEN + 8) @(negedge core_clk);
      check_int("tready restored after frame", int'(s_axis_trade_tready), 1);
    end

    //------------------------------------------------------------------ Summary
    $display("\n==================================================");
    $display("  outbound_tx_generator_tb : %0d checks, %0d failures", checks, errors);
    $display("==================================================");
    if (errors == 0) begin
      $display("  RESULT: ALL TESTS PASSED");
      $finish;
    end else begin
      $display("  RESULT: TESTBENCH FAILED");
      $fatal(1, "%0d check(s) failed", errors);
    end
  end

  // watchdog
  initial begin
    #200000;
    $display("  [FAIL] watchdog timeout");
    $fatal(1, "watchdog timeout");
  end

endmodule
