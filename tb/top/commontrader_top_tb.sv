//==============================================================================
// commontrader_top_tb  -  full-chip integration testbench
//
// Drives real RGMII nibbles into the PHY pins and decodes real RGMII nibbles
// back out. Nothing between the two is stubbed: every block, both CDC FIFOs,
// the MMCM replacement and both MACs are in the path. If a frame comes out with
// the right OUCH order in it, the whole datapath works.
//
//   ITCH/MoldUDP64/UDP/IPv4 in an Ethernet frame
//        -> RGMII -> RX MAC -> RX CDC FIFO -> Parser -> Order Book
//        -> Alpha Engine -> Risk Gateway -> TX Gen -> TX CDC FIFO -> TX MAC
//        -> RGMII -> OUCH Enter Order in an Ethernet frame
//
// Runs under Verilator (--binary --timing). rx_mac_core's IDDR stage and
// tx_mac_core's ODDR stage both fall back to behavioural DDR outside
// `SYNTHESIS`, so no vendor libraries are needed.
//
// Coverage:
//   T1  reset / idle          -- no spurious TX, telemetry clear
//   T2  end-to-end order      -- 2 ITCH Adds produce exactly one OUCH order
//   T3  egress frame decode   -- Ethernet + IPv4 + UDP + OUCH field-by-field
//   T4  egress FCS            -- 802.3 residue over the received frame
//   T5  latency telemetry     -- FS-12 delta is non-zero and plausible
//   T6  flow control          -- no FIFO overflow, no dropped orders, no
//                                back-pressure on a path that cannot absorb it
//   T7  out-of-range symbol   -- ITCH locate >= NUM_ASSETS is discarded
//   T8  sustained operation   -- a second packet still produces a valid order,
//                                and UserRefNum increments as OUCH requires
//   T9  ingress FCS error     -- corrupt frame raises rx_error and it crosses
//                                into the core domain (see KNOWN GAP below)
//   T10 kill switch (FS-10)   -- destroys the outbound path, latching
//
// KNOWN GAP asserted by T9: the Risk Gateway declares viol_crc and
// viol_blacklist but hardwires both to 0 in its violations vector, so 4 of the
// 6 required checks are live. T9 proves rx_error reaches the core domain
// correctly and then asserts that the order is STILL emitted -- documenting the
// hole rather than hiding it. When viol_crc is enabled, T9 will fail loudly and
// its expectation is what needs flipping.
//==============================================================================

`timescale 1ns/1ps

module commontrader_top_tb
  import ct_pkg::*;
;

  //--------------------------------------------------------------------------
  // Clocks / reset
  //--------------------------------------------------------------------------
  logic sys_clk;
  logic sys_rst_n;
  logic rgmii_rx_clk;

  initial sys_clk = 1'b0;
  always #5 sys_clk = ~sys_clk;             // 100 MHz, unused by the datapath

  initial rgmii_rx_clk = 1'b0;
  always #4 rgmii_rx_clk = ~rgmii_rx_clk;   // 125 MHz RGMII

  //--------------------------------------------------------------------------
  // DUT
  //--------------------------------------------------------------------------
  logic [3:0] rgmii_rxd;
  logic       rgmii_rx_ctl;
  logic       rgmii_tx_clk;
  logic [3:0] rgmii_txd;
  logic       rgmii_tx_ctl;
  logic       hw_kill_switch;

  logic [15:0] order_drop_count;
  logic        tx_fifo_overflow;
  logic        ts_wrapped;

  commontrader_top dut (
    .sys_clk          (sys_clk),
    .sys_rst_n        (sys_rst_n),
    .rgmii_rx_clk     (rgmii_rx_clk),
    .rgmii_rxd        (rgmii_rxd),
    .rgmii_rx_ctl     (rgmii_rx_ctl),
    .rgmii_tx_clk     (rgmii_tx_clk),
    .rgmii_txd        (rgmii_txd),
    .rgmii_tx_ctl     (rgmii_tx_ctl),
    .hw_kill_switch   (hw_kill_switch),
    .order_drop_count (order_drop_count),
    .tx_fifo_overflow (tx_fifo_overflow),
    .ts_wrapped       (ts_wrapped)
  );

  //--------------------------------------------------------------------------
  // Scoreboard
  //--------------------------------------------------------------------------
  int unsigned checks = 0;
  int unsigned errors = 0;

  task automatic check_int(input string name, input int got, input int exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-46s got %0d, expected %0d", name, got, exp);
    end else begin
      $display("  [ ok ] %-46s %0d", name, got);
    end
  endtask

  task automatic check_hex(input string name, input logic [63:0] got,
                           input logic [63:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-46s got 0x%0h, expected 0x%0h", name, got, exp);
    end else begin
      $display("  [ ok ] %-46s 0x%0h", name, got);
    end
  endtask

  //--------------------------------------------------------------------------
  // CRC-32 (IEEE 802.3, reflected). Same form the RX and TX MACs use.
  //--------------------------------------------------------------------------
  function automatic logic [31:0] crc32_byte(input logic [31:0] c_in,
                                             input logic [7:0]  d);
    logic [31:0] c;
    c = c_in ^ {24'h0, d};
    for (int i = 0; i < 8; i++)
      c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    return c;
  endfunction

  //--------------------------------------------------------------------------
  // Ingress packet builder (IPv4 / UDP / MoldUDP64 / ITCH)
  //--------------------------------------------------------------------------
  localparam logic [31:0] SRC_IP   = 32'h0A00_0001;   // 10.0.0.1
  localparam logic [31:0] DST_IP   = 32'h0A00_0002;   // 10.0.0.2
  localparam logic [15:0] SRC_PORT = 16'd1234;
  localparam logic [15:0] DST_PORT = 16'd5678;

  logic [7:0] pkt [0:1023];
  int         pkt_len;

  task automatic put8 (input logic [7:0]  v); pkt[pkt_len] = v; pkt_len++; endtask
  task automatic put16(input logic [15:0] v); put8(v[15:8]);   put8(v[7:0]);   endtask
  task automatic put32(input logic [31:0] v); put16(v[31:16]); put16(v[15:0]); endtask
  task automatic put48(input logic [47:0] v); put16(v[47:32]); put32(v[31:0]); endtask
  task automatic put64(input logic [63:0] v); put32(v[63:32]); put32(v[31:0]); endtask

  // IPv4 (20) + UDP (8) + MoldUDP64 (20) = 48 bytes of encapsulation.
  task automatic build_encap(input logic [15:0] num_msgs);
    pkt_len = 0;
    put8(8'h45); put8(8'h00);
    put16(16'd0);                 // [2:3]   total length   (patched)
    put16(16'd0);                 // [4:5]   identification
    put16(16'h4000);              // [6:7]   DF
    put8(8'd64); put8(8'd17);     // TTL, protocol = UDP
    put16(16'd0);                 // [10:11] IP checksum (not checked by the DUT)
    put32(SRC_IP); put32(DST_IP);
    put16(SRC_PORT); put16(DST_PORT);
    put16(16'd0);                 // [24:25] UDP length   (patched)
    put16(16'd0);                 // [26:27] UDP checksum (patched)
    for (int i = 0; i < 10; i++) put8(8'h20);   // MoldUDP64 session (spaces)
    put64(64'd1);                               // sequence number
    put16(num_msgs);                            // message count
  endtask

  task automatic itch_add(input logic [15:0] locate, input logic [63:0] ref_num,
                          input logic [7:0]  side_ch, input logic [31:0] shares,
                          input logic [63:0] stock,  input logic [31:0] price);
    put16(16'd36);
    put8("A"); put16(locate); put16(16'd0); put48(48'd0);
    put64(ref_num); put8(side_ch); put32(shares); put64(stock); put32(price);
  endtask

  // Patch the length fields and compute the UDP checksum over pseudo-header
  // plus datagram.
  task automatic finalize_packet();
    int unsigned sum;
    int          udp_l;
    logic [15:0] csum;
    logic [7:0]  hi, lo;

    pkt[2]  = 8'(pkt_len >> 8);  pkt[3]  = 8'(pkt_len);
    udp_l   = pkt_len - 20;
    pkt[24] = 8'(udp_l >> 8);    pkt[25] = 8'(udp_l);
    pkt[26] = 8'h00;             pkt[27] = 8'h00;

    sum  = 0;
    sum += 32'(SRC_IP[31:16]); sum += 32'(SRC_IP[15:0]);
    sum += 32'(DST_IP[31:16]); sum += 32'(DST_IP[15:0]);
    sum += 32'h0000_0011;
    sum += 32'(udp_l);
    for (int i = 20; i < pkt_len; i += 2) begin
      hi   = pkt[i];
      lo   = (i + 1 < pkt_len) ? pkt[i+1] : 8'h00;
      sum += 32'({hi, lo});
    end
    sum  = (sum & 32'h0000_FFFF) + (sum >> 16);
    sum  = (sum & 32'h0000_FFFF) + (sum >> 16);
    csum = ~sum[15:0];
    if (csum == 16'h0000) csum = 16'hFFFF;      // RFC 768
    pkt[26] = csum[15:8];  pkt[27] = csum[7:0];
  endtask

  //--------------------------------------------------------------------------
  // RGMII ingress driver
  //
  // Low nibble is set up before the rising edge, high nibble before the
  // falling edge -- the ordering rx_mac_core's IDDR stage expects.
  //--------------------------------------------------------------------------
  // Each nibble is placed in the MIDDLE of its half period using blocking
  // assignments, not on the clock edge. Driving stimulus with a non-blocking
  // assignment AT the edge races the DUT's capture flops: whether the flop sees
  // the old or the new value then depends on the simulator's NBA ordering. The
  // --timing scheduler used here resolves it the opposite way to xsim, so the
  // nibbles land half a byte out of phase and every frame decodes to garbage.
  // Changing the bus mid-phase removes the race entirely.
  task automatic send_byte(input logic [7:0] data, input logic err = 1'b0);
    @(negedge rgmii_rx_clk);
    #2;                                 // settle inside the low phase
    rgmii_rxd    = data[3:0];           // sampled by the DUT on the rising edge
    rgmii_rx_ctl = 1'b1;
    @(posedge rgmii_rx_clk);
    #2;                                 // settle inside the high phase
    rgmii_rxd    = data[7:4];           // sampled on the falling edge
    rgmii_rx_ctl = 1'b1 ^ err;          // falling edge carries RXDV ^ RXER
  endtask

  // Wrap the built packet in an Ethernet frame and clock it in.
  task automatic send_frame(input bit corrupt_fcs = 1'b0);
    logic [7:0]  frame [0:1279];
    int          flen;
    logic [31:0] crc;

    // 14-byte L2 header, then the IP packet.
    for (int i = 0; i < 6;  i++) frame[i]      = 8'hAA;   // dst MAC
    for (int i = 6; i < 12; i++) frame[i]      = 8'hBB;   // src MAC
    frame[12] = 8'h08; frame[13] = 8'h00;                 // ethertype IPv4
    for (int i = 0; i < pkt_len; i++) frame[14 + i] = pkt[i];
    flen = 14 + pkt_len;

    crc = 32'hFFFF_FFFF;
    for (int i = 0; i < flen; i++) crc = crc32_byte(crc, frame[i]);
    crc = ~crc;
    if (corrupt_fcs) crc = ~crc;        // deliberately wrong

    for (int i = 0; i < 7; i++) send_byte(8'h55);
    send_byte(8'hD5);
    for (int i = 0; i < flen; i++) send_byte(frame[i]);
    send_byte(crc[7:0]);  send_byte(crc[15:8]);
    send_byte(crc[23:16]); send_byte(crc[31:24]);

    @(negedge rgmii_rx_clk);
    #2;
    rgmii_rx_ctl = 1'b0;
    rgmii_rxd    = 4'h0;
    repeat (12) @(posedge rgmii_rx_clk);   // inter-frame gap
  endtask

  //--------------------------------------------------------------------------
  // RGMII egress monitor
  //
  // Reassembles bytes from the DDR pins and captures each complete frame.
  // tx_en high on the rising edge means the byte is real.
  //--------------------------------------------------------------------------
  logic [7:0] txf [0:511];      // last completed frame
  int         txf_len;
  int         tx_frame_count;

  logic [7:0] mon [0:511];
  int         mon_len;
  logic       mon_active;

  initial begin
    txf_len        = 0;
    tx_frame_count = 0;
    mon_len        = 0;
    mon_active     = 1'b0;

    forever begin
      logic [3:0] lo_nib, hi_nib;
      logic       tx_en;

      @(posedge rgmii_rx_clk);
      #1;
      lo_nib = rgmii_txd;
      tx_en  = rgmii_tx_ctl;

      @(negedge rgmii_rx_clk);
      #1;
      hi_nib = rgmii_txd;

      if (tx_en) begin
        if (mon_len < 512) begin
          mon[mon_len] = {hi_nib, lo_nib};
          mon_len++;
        end
        mon_active = 1'b1;
      end else if (mon_active) begin
        for (int i = 0; i < mon_len; i++) txf[i] = mon[i];
        txf_len = mon_len;
        tx_frame_count++;
        mon_len    = 0;
        mon_active = 1'b0;
      end
    end
  end

  // Block until another frame lands, or give up.
  task automatic wait_tx_frame(input int timeout_cycles, output bit got);
    int start_count;
    start_count = tx_frame_count;
    got = 1'b0;
    for (int i = 0; i < timeout_cycles; i++) begin
      @(posedge rgmii_rx_clk);
      if (tx_frame_count > start_count) begin
        got = 1'b1;
        repeat (2) @(posedge rgmii_rx_clk);   // let txf settle
        break;
      end
    end
  endtask

  // Big-endian field extraction from the captured frame.
  function automatic logic [31:0] txf32(input int off);
    return {txf[off], txf[off+1], txf[off+2], txf[off+3]};
  endfunction

  function automatic logic [63:0] txf64(input int off);
    return {txf[off],   txf[off+1], txf[off+2], txf[off+3],
            txf[off+4], txf[off+5], txf[off+6], txf[off+7]};
  endfunction

  //--------------------------------------------------------------------------
  // Egress frame geometry (see the byte map in outbound_tx_generator.sv)
  //   0..7    preamble + SFD
  //   8..21   L2 header
  //   22..98  IP(20) + UDP(8) + OUCH(47) + telemetry(2)   = 77-byte payload
  //   99..102 FCS
  //--------------------------------------------------------------------------
  localparam int L2_OFF    = 8;
  localparam int PAY_OFF   = 22;         // first IPv4 byte
  localparam int OUCH_OFF  = PAY_OFF + 28;
  localparam int TELEM_OFF = PAY_OFF + 75;
  localparam int FRAME_LEN = 103;

  //--------------------------------------------------------------------------
  // Continuous flow-control monitors. These paths physically cannot absorb
  // back-pressure, so a single violation anywhere in the run is a failure.
  //--------------------------------------------------------------------------
  // Counters rather than sticky single-bit flags. A `logic` flag written by a
  // monitor process and read by the test process does not reliably propagate
  // under every simulator's optimiser, and the failure mode is silent: the
  // check reads the reset value and passes vacuously. An int counter both
  // propagates and tells you HOW MANY times the condition fired.
  int rx_fifo_stall_n;   // RX CDC FIFO refused a byte the RX MAC had to write
  int book_stall_n;      // Order Book de-asserted tready on the parser
  int rx_error_n;        // rx_error observed in the core domain (T9)

  initial begin
    rx_fifo_stall_n = 0;
    book_stall_n    = 0;
    rx_error_n      = 0;
  end

  always @(negedge rgmii_rx_clk) begin
    if (sys_rst_n && dut.mac_tvalid && !dut.rx_fifo_wr_ready)
      rx_fifo_stall_n++;
  end

  always @(negedge dut.core_clk) begin
    if (dut.core_rst_n && dut.upd_tvalid && !dut.upd_tready)
      book_stall_n++;
    if (dut.core_rst_n && dut.rx_error_sync)
      rx_error_n++;
  end

  //--------------------------------------------------------------------------
  // Shared field checks over a captured OUCH order frame.
  //--------------------------------------------------------------------------
  task automatic check_order_frame(input string     label,
                                   input logic [7:0]  exp_side,
                                   input logic [31:0] exp_qty,
                                   input logic [63:0] exp_symbol,
                                   input logic [31:0] exp_price,
                                   input logic [31:0] exp_userref);
    logic [31:0] residue;
    bit          preamble_ok;

    check_int({label, " frame length"}, txf_len, FRAME_LEN);

    preamble_ok = 1'b1;
    for (int i = 0; i < 7; i++) if (txf[i] !== 8'h55) preamble_ok = 1'b0;
    if (txf[7] !== 8'hD5) preamble_ok = 1'b0;
    check_int({label, " preamble + SFD"}, int'(preamble_ok), 1);

    // ---- Ethernet ----
    check_hex({label, " dst MAC"}, {16'h0, txf[L2_OFF+0], txf[L2_OFF+1],
              txf[L2_OFF+2], txf[L2_OFF+3], txf[L2_OFF+4], txf[L2_OFF+5]},
              64'h0000_AABB_CCDD_EEFF);
    check_hex({label, " src MAC"}, {16'h0, txf[L2_OFF+6], txf[L2_OFF+7],
              txf[L2_OFF+8], txf[L2_OFF+9], txf[L2_OFF+10], txf[L2_OFF+11]},
              64'h0000_000A_3501_0203);
    check_hex({label, " ethertype"}, {txf[L2_OFF+12], txf[L2_OFF+13]}, 16'h0800);

    // ---- IPv4 ----
    check_hex({label, " IP version/IHL"}, txf[PAY_OFF], 8'h45);
    check_int({label, " IP total length"},
              int'({txf[PAY_OFF+2], txf[PAY_OFF+3]}), 77);
    check_int({label, " IP protocol (UDP)"}, int'(txf[PAY_OFF+9]), 17);

    // ---- UDP ----
    check_int({label, " UDP src port"},
              int'({txf[PAY_OFF+20], txf[PAY_OFF+21]}), 50000);
    check_int({label, " UDP dst port"},
              int'({txf[PAY_OFF+22], txf[PAY_OFF+23]}), 50001);
    check_int({label, " UDP length"},
              int'({txf[PAY_OFF+24], txf[PAY_OFF+25]}), 57);

    // ---- OUCH 5.0 Enter Order ----
    check_hex({label, " OUCH type 'O'"},   txf[OUCH_OFF],        8'h4F);
    check_int({label, " OUCH UserRefNum"}, int'(txf32(OUCH_OFF+1)), int'(exp_userref));
    check_hex({label, " OUCH side"},       txf[OUCH_OFF+5],      exp_side);
    check_int({label, " OUCH quantity"},   int'(txf32(OUCH_OFF+6)), int'(exp_qty));
    check_hex({label, " OUCH symbol"},     txf64(OUCH_OFF+10),   exp_symbol);
    check_hex({label, " OUCH price hi 4B (zero-ext)"},
              txf32(OUCH_OFF+18), 32'h0);
    check_int({label, " OUCH price"},      int'(txf32(OUCH_OFF+22)), int'(exp_price));

    // ---- 802.3 FCS residue over L2 header + payload + FCS ----
    residue = 32'hFFFF_FFFF;
    for (int i = L2_OFF; i < txf_len; i++) residue = crc32_byte(residue, txf[i]);
    check_hex({label, " FCS residue (802.3)"}, residue, 32'hDEBB20E3);
  endtask

  //--------------------------------------------------------------------------
  // Test sequence
  //--------------------------------------------------------------------------
  bit          got;
  int          frames_before;
  logic [15:0] latency;

  initial begin
    $display("\n==============================================================");
    $display(" CommonTrader full-chip integration testbench");
    $display("==============================================================");

    sys_rst_n      = 1'b0;
    rgmii_rxd      = 4'h0;
    rgmii_rx_ctl   = 1'b0;
    hw_kill_switch = 1'b0;

    repeat (20) @(posedge rgmii_rx_clk);
    sys_rst_n = 1'b1;
    repeat (40) @(posedge rgmii_rx_clk);   // MMCM lock + reset release

    //------------------------------------------------------------------------
    $display("\n[T1] Reset and idle");
    //------------------------------------------------------------------------
    check_int("T1 no TX frames while idle",   tx_frame_count,        0);
    check_int("T1 TX FIFO overflow clear",    int'(tx_fifo_overflow), 0);
    check_int("T1 order drop count zero",     int'(order_drop_count), 0);
    check_int("T1 timestamp has not wrapped", int'(ts_wrapped),       0);
    check_int("T1 core reset released",       int'(dut.core_rst_n),   1);

    //------------------------------------------------------------------------
    $display("\n[T2] End-to-end: two ITCH Adds produce one OUCH order");
    //------------------------------------------------------------------------
    // Add #1 primes the EMA for asset 0 (mid = (5000 + 0)/2 = 2500).
    // Add #2 sets the ask, so mid = (5000 + 5100)/2 = 5050 and the mean
    // reversion delta of +2550 clears the +/-100 threshold -> SELL at the bid.
    //   qty   = min(bid qty 500, LOT_SIZE 100) = 100
    //   value = 5000 * 100 = 500_000, inside the 1_000_000 risk cap
    build_encap(16'd2);
    itch_add(16'd0, 64'd1, "B", 32'd500, "AAPL    ", 32'd5000);
    itch_add(16'd0, 64'd2, "S", 32'd500, "AAPL    ", 32'd5100);
    finalize_packet();

    send_frame();
    wait_tx_frame(2000, got);
    check_int("T2 order frame emitted", int'(got), 1);
    check_int("T2 exactly one frame",   tx_frame_count, 1);

    //------------------------------------------------------------------------
    $display("\n[T3/T4] Egress frame decode and FCS");
    //------------------------------------------------------------------------
    check_order_frame("T3", 8'h53 /* 'S' */, 32'd100, "AAPL    ",
                      32'd5000, 32'd1 /* first UserRefNum */);

    //------------------------------------------------------------------------
    $display("\n[T5] FS-12 latency telemetry");
    //------------------------------------------------------------------------
    latency = {txf[TELEM_OFF], txf[TELEM_OFF+1]};
    $display("  measured latency = %0d ticks (%0d ns @ 4 ns/tick)",
             latency, latency * 4);
    // Parser stamp to TX Gen accept. Must be non-zero (they are separated by
    // the book, alpha and risk stages) and far below the 16-bit wrap.
    check_int("T5 latency non-zero",       int'(latency > 16'd0),     1);
    check_int("T5 latency below 1000 ticks", int'(latency < 16'd1000), 1);
    check_int("T5 timestamp did not wrap",  int'(ts_wrapped),          0);

    //------------------------------------------------------------------------
    $display("\n[T6] Flow control");
    //------------------------------------------------------------------------
    check_int("T6 RX CDC FIFO never back-pressured", rx_fifo_stall_n,        0);
    check_int("T6 Order Book never stalled parser",  book_stall_n,           0);
    check_int("T6 TX CDC FIFO never overflowed",     int'(tx_fifo_overflow),  0);
    check_int("T6 no orders dropped",                int'(order_drop_count),  0);

    //------------------------------------------------------------------------
    $display("\n[T7] ITCH Stock Locate >= NUM_ASSETS is discarded");
    //------------------------------------------------------------------------
    // Locate 6 truncates to book index 6, which is past the end of the
    // NUM_ASSETS=5 array. The Order Book must drop it outright.
    frames_before = tx_frame_count;
    build_encap(16'd2);
    itch_add(16'd6, 64'd10, "B", 32'd500, "ZZZZ    ", 32'd9000);
    itch_add(16'd6, 64'd11, "S", 32'd500, "ZZZZ    ", 32'd9100);
    finalize_packet();

    send_frame();
    repeat (600) @(posedge rgmii_rx_clk);
    check_int("T7 no order from out-of-range symbol",
              tx_frame_count - frames_before, 0);
    check_int("T7 no drop counted (update discarded, not lost)",
              int'(order_drop_count), 0);

    //------------------------------------------------------------------------
    $display("\n[T8] Sustained operation and UserRefNum allocation");
    //------------------------------------------------------------------------
    // Push the ask down hard on asset 1. First Add primes it, second triggers.
    frames_before = tx_frame_count;
    build_encap(16'd2);
    itch_add(16'd1, 64'd20, "B", 32'd400, "MSFT    ", 32'd8000);
    itch_add(16'd1, 64'd21, "S", 32'd400, "MSFT    ", 32'd8200);
    finalize_packet();

    send_frame();
    wait_tx_frame(2000, got);
    check_int("T8 second order frame emitted", int'(got), 1);
    // mid1 = 4000 (prime), mid2 = (8000 + 8200)/2 = 8100, delta = +4100 -> SELL
    //   at the bid 8000, qty min(400, 100) = 100, value 800_000 < 1_000_000
    check_order_frame("T8", 8'h53 /* 'S' */, 32'd100, "MSFT    ",
                      32'd8000, 32'd2 /* UserRefNum increments */);

    //------------------------------------------------------------------------
    $display("\n[T9] Ingress FCS error -> rx_error crosses to the core domain");
    //------------------------------------------------------------------------
    // KNOWN GAP: the Risk Gateway hardwires viol_crc to 0, so a corrupt packet
    // does NOT currently suppress the order. This test asserts the CDC path
    // works AND pins the present (incorrect) behaviour, so enabling viol_crc
    // will fail here and point straight at the expectation to flip.
    frames_before = tx_frame_count;
    build_encap(16'd2);
    itch_add(16'd2, 64'd30, "B", 32'd300, "AMZN    ", 32'd6000);
    itch_add(16'd2, 64'd31, "S", 32'd300, "AMZN    ", 32'd6300);
    finalize_packet();

    send_frame(1'b1);                       // corrupt FCS
    wait_tx_frame(2000, got);

    check_int("T9 rx_error reached the core domain", (rx_error_n > 0) ? 1 : 0, 1);
    check_int("T9 order still emitted (viol_crc stubbed -- KNOWN GAP)",
              int'(got), 1);

    //------------------------------------------------------------------------
    $display("\n[T10] Hardware kill switch (FS-10)");
    //------------------------------------------------------------------------
    // viol_kill_switch latches until reset, so this must run last.
    hw_kill_switch = 1'b1;
    repeat (20) @(posedge rgmii_rx_clk);

    frames_before = tx_frame_count;
    build_encap(16'd2);
    itch_add(16'd3, 64'd40, "B", 32'd200, "GOOG    ", 32'd7000);
    itch_add(16'd3, 64'd41, "S", 32'd200, "GOOG    ", 32'd7400);
    finalize_packet();

    send_frame();
    repeat (800) @(posedge rgmii_rx_clk);
    check_int("T10 kill switch suppressed the order",
              tx_frame_count - frames_before, 0);

    //------------------------------------------------------------------------
    $display("\n==============================================================");
    $display("  commontrader_top_tb : %0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("  RESULT: ALL TESTS PASSED");
    else             $display("  RESULT: %0d FAILURE(S)", errors);
    $display("==============================================================\n");
    $finish;
  end

  //--------------------------------------------------------------------------
  // Global watchdog
  //--------------------------------------------------------------------------
  initial begin
    #200_000;
    $display("  [FAIL] watchdog timeout -- the chip stopped making progress");
    $display("  commontrader_top_tb : %0d checks, %0d failures", checks, errors + 1);
    $display("  RESULT: TIMEOUT");
    $finish;
  end

endmodule
