//==============================================================================
// tx_mac_core_tb  -  unit testbench for rtl/ip/tx_mac/tx_mac_core.sv
//
// Captures the GMII byte stream and dissects the emitted frame:
//
//   [7x 0x55][0xD5][dst 6][src 6][ethertype 2][payload][pad][FCS 4]  then IFG
//
// Coverage:
//   T1 long frame (77 B payload, the TX Generator's packet size): preamble,
//      SFD, L2 header, payload passthrough, no padding, total length
//   T2 FCS correctness, checked two independent ways:
//        (a) recomputed over the captured frame body and compared byte-wise
//        (b) the RECEIVER property -- running CRC over body+FCS must land on
//            the IEEE 802.3 residue 0xDEBB20E3
//   T3 short frame (10 B payload) zero-padded to the 60-byte minimum, giving a
//      64-byte frame on the wire, with the pad covered by the FCS
//   T4 inter-frame gap of at least 12 byte times
//   T5 tx_er never asserted on a well-fed frame
//==============================================================================

`timescale 1ns/1ps

module tx_mac_core_tb;

  // Must mirror the DUT parameter defaults.
  localparam logic [47:0] DST_MAC   = 48'hAA_BB_CC_DD_EE_FF;
  localparam logic [47:0] SRC_MAC   = 48'h00_0A_35_01_02_03;
  localparam logic [15:0] ETHERTYPE = 16'h0800;

  localparam int PRE_LEN   = 8;    // preamble + SFD
  localparam int L2_LEN    = 14;
  localparam int MIN_FRAME = 60;
  localparam int FCS_LEN   = 4;
  localparam int IFG_LEN   = 12;

  //--------------------------------------------------------------------------
  // Clock / reset / DUT
  //--------------------------------------------------------------------------
  logic gmii_tx_clk, rst_n;
  initial gmii_tx_clk = 1'b0;
  always #4 gmii_tx_clk = ~gmii_tx_clk;     // 125 MHz

  logic [7:0] s_axis_tdata;
  logic       s_axis_tvalid, s_axis_tlast, s_axis_tready;
  logic       rgmii_txc;
  logic [3:0] rgmii_txd;
  logic       rgmii_tx_ctl;

  tx_mac_core dut (
    .gmii_tx_clk   (gmii_tx_clk),
    .rst_n         (rst_n),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tlast  (s_axis_tlast),
    .s_axis_tready (s_axis_tready),
    .rgmii_txc     (rgmii_txc),
    .rgmii_txd     (rgmii_txd),
    .rgmii_tx_ctl  (rgmii_tx_ctl)
  );

  // The MAC now ends at RGMII, so the frame is dissected from the internal GMII
  // stage via hierarchical reference -- the same technique rx_mac_tb uses to
  // peek at dut.crc_reg. The DDR stage below it is checked separately (T6).
  wire [7:0] gmii_txd   = dut.gmii_txd;
  wire       gmii_tx_en = dut.gmii_tx_en;
  wire       gmii_tx_er = dut.gmii_tx_er;

  //--------------------------------------------------------------------------
  // Scoreboard
  //--------------------------------------------------------------------------
  int unsigned checks = 0, errors = 0;

  task automatic check_int(input string name, input int got, input int exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-42s got=%0d exp=%0d", name, got, exp);
    end
  endtask

  task automatic check_hex(input string name, input logic [31:0] got,
                           input logic [31:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-42s got=0x%08h exp=0x%08h", name, got, exp);
    end
  endtask

  //--------------------------------------------------------------------------
  // CRC-32 reference (independent re-implementation of the DUT's function)
  //--------------------------------------------------------------------------
  function automatic logic [31:0] crc32_byte(input logic [31:0] crc_in,
                                             input logic [7:0]  data);
    logic [31:0] c;
    c = crc_in ^ {24'h0, data};
    for (int i = 0; i < 8; i++)
      c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    return c;
  endfunction

  //--------------------------------------------------------------------------
  // GMII capture: record each frame and the idle gap preceding it
  //--------------------------------------------------------------------------
  logic [7:0] fr [0:511];
  int         fr_n, frame_len, frames_done;
  int         gap_cnt, last_gap;
  logic       in_frame;
  logic       er_seen;

  always @(posedge gmii_tx_clk) begin
    if (!rst_n) begin
      fr_n = 0; in_frame = 1'b0; frames_done = 0;
      gap_cnt = 0; last_gap = 0; frame_len = 0; er_seen = 1'b0;
    end else if (gmii_tx_en) begin
      if (!in_frame) begin
        fr_n     = 0;
        in_frame = 1'b1;
        last_gap = gap_cnt;
        gap_cnt  = 0;
      end
      fr[fr_n] = gmii_txd;
      fr_n     = fr_n + 1;
      if (gmii_tx_er) er_seen = 1'b1;
    end else begin
      if (in_frame) begin
        in_frame    = 1'b0;
        frame_len   = fr_n;
        frames_done = frames_done + 1;
      end
      gap_cnt = gap_cnt + 1;
    end
  end

  //--------------------------------------------------------------------------
  // RGMII DDR reassembly: sample the bus in BOTH clock phases and rebuild the
  // byte, exactly as the PHY (and rx_mac_core's IDDR) would.
  //   clock high -> low nibble  + TX_EN
  //   clock low  -> high nibble + TX_EN ^ TX_ER
  // Period is 8 ns, so +1 ns lands in the high phase and +5 ns in the low one.
  //--------------------------------------------------------------------------
  logic [7:0] dfr [0:511];
  int         dfr_n, dframe_len, dframes_done;
  logic       d_in_frame;

  always @(posedge gmii_tx_clk) begin
    logic [3:0] lo_nib, hi_nib;
    logic       ctl_r, ctl_f, ddr_en;
    logic [7:0] ddr_byte;

    #1;  lo_nib = rgmii_txd;  ctl_r = rgmii_tx_ctl;   // high phase
    #4;  hi_nib = rgmii_txd;  ctl_f = rgmii_tx_ctl;   // low phase

    ddr_byte = {hi_nib, lo_nib};
    ddr_en   = ctl_r;

    if (!rst_n) begin
      dfr_n = 0; d_in_frame = 1'b0; dframes_done = 0; dframe_len = 0;
    end else if (ddr_en) begin
      if (!d_in_frame) begin dfr_n = 0; d_in_frame = 1'b1; end
      dfr[dfr_n] = ddr_byte;
      dfr_n      = dfr_n + 1;
    end else if (d_in_frame) begin
      d_in_frame   = 1'b0;
      dframe_len   = dfr_n;
      dframes_done = dframes_done + 1;
    end
  end

  //--------------------------------------------------------------------------
  // Payload driver (continuous AXI-Stream: tvalid held, advance on accept)
  //--------------------------------------------------------------------------
  logic [7:0] pay [0:255];

  task automatic send_payload(input int n);
    int i;
    i = 0;
    @(negedge gmii_tx_clk);
    while (i < n) begin
      s_axis_tdata  = pay[i];
      s_axis_tlast  = (i == n - 1);
      s_axis_tvalid = 1'b1;
      @(posedge gmii_tx_clk);
      if (s_axis_tready) i++;
      @(negedge gmii_tx_clk);
    end
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
  endtask

  //--------------------------------------------------------------------------
  // Frame dissection, shared by both frame tests
  //--------------------------------------------------------------------------
  task automatic verify_frame(input string label, input int n_payload);
    int body_len, exp_len, bad;
    logic [31:0] crc, residue, fcs;

    body_len = (L2_LEN + n_payload < MIN_FRAME) ? MIN_FRAME : (L2_LEN + n_payload);
    exp_len  = PRE_LEN + body_len + FCS_LEN;

    check_int({label, " frame length"}, frame_len, exp_len);

    // ---- preamble + SFD ----
    bad = 0;
    for (int i = 0; i < 7; i++) if (fr[i] !== 8'h55) bad++;
    check_int({label, " 7x preamble 0x55"}, bad, 0);
    check_int({label, " SFD 0xD5"}, int'(fr[7]), 8'hD5);

    // ---- L2 header ----
    bad = 0;
    for (int i = 0; i < 6; i++)
      if (fr[PRE_LEN + i] !== DST_MAC[47 - 8*i -: 8]) bad++;
    check_int({label, " dst MAC"}, bad, 0);

    bad = 0;
    for (int i = 0; i < 6; i++)
      if (fr[PRE_LEN + 6 + i] !== SRC_MAC[47 - 8*i -: 8]) bad++;
    check_int({label, " src MAC"}, bad, 0);

    check_int({label, " ethertype hi"}, int'(fr[PRE_LEN + 12]), int'(ETHERTYPE[15:8]));
    check_int({label, " ethertype lo"}, int'(fr[PRE_LEN + 13]), int'(ETHERTYPE[7:0]));

    // ---- payload passthrough ----
    bad = 0;
    for (int i = 0; i < n_payload; i++)
      if (fr[PRE_LEN + L2_LEN + i] !== pay[i]) bad++;
    check_int({label, " payload passthrough"}, bad, 0);

    // ---- zero padding (if any) ----
    if (L2_LEN + n_payload < MIN_FRAME) begin
      bad = 0;
      for (int i = L2_LEN + n_payload; i < MIN_FRAME; i++)
        if (fr[PRE_LEN + i] !== 8'h00) bad++;
      check_int({label, " zero padding"}, bad, 0);
      check_int({label, " padded to 60 B body"}, body_len, MIN_FRAME);
    end

    // ---- FCS: recompute over the body and compare ----
    crc = 32'hFFFF_FFFF;
    for (int i = 0; i < body_len; i++)
      crc = crc32_byte(crc, fr[PRE_LEN + i]);
    fcs = ~crc;

    check_int({label, " FCS byte0"}, int'(fr[PRE_LEN + body_len + 0]), int'(fcs[7:0]));
    check_int({label, " FCS byte1"}, int'(fr[PRE_LEN + body_len + 1]), int'(fcs[15:8]));
    check_int({label, " FCS byte2"}, int'(fr[PRE_LEN + body_len + 2]), int'(fcs[23:16]));
    check_int({label, " FCS byte3"}, int'(fr[PRE_LEN + body_len + 3]), int'(fcs[31:24]));

    // ---- FCS: independent receiver-side residue check ----
    // Running the CRC across body AND the transmitted FCS must land on the
    // IEEE 802.3 magic residue. This validates the frame the way a real
    // receiver would, without reusing the transmit-side byte ordering.
    residue = 32'hFFFF_FFFF;
    for (int i = 0; i < body_len + FCS_LEN; i++)
      residue = crc32_byte(residue, fr[PRE_LEN + i]);
    check_hex({label, " CRC residue (802.3)"}, residue, 32'hDEBB20E3);
  endtask

  //--------------------------------------------------------------------------
  // Test sequence
  //--------------------------------------------------------------------------
  initial begin
    s_axis_tdata = '0; s_axis_tvalid = 1'b0; s_axis_tlast = 1'b0;
    for (int i = 0; i < 256; i++) pay[i] = 8'(i + 1);

    rst_n = 1'b0;
    repeat (8) @(posedge gmii_tx_clk);
    @(negedge gmii_tx_clk);
    rst_n = 1'b1;
    repeat (4) @(posedge gmii_tx_clk);

    check_int("idle: tx_en low", int'(gmii_tx_en), 0);

    //------------------------------------------------------------------ T1/T2
    // 77-byte payload = exactly what the Outbound TX Generator emits.
    $display("\n[T1/T2] 77-byte payload: framing, passthrough, FCS");
    send_payload(77);
    wait (frames_done == 1);
    repeat (20) @(posedge gmii_tx_clk);
    verify_frame("T1", 77);
    check_int("T1 no padding needed", frame_len, PRE_LEN + L2_LEN + 77 + FCS_LEN);

    //------------------------------------------------------------------ T3/T4
    // 10-byte payload -> body 24 B -> must be padded up to 60 B.
    $display("\n[T3/T4] 10-byte payload: minimum-frame zero padding");
    send_payload(10);
    wait (frames_done == 2);
    repeat (20) @(posedge gmii_tx_clk);
    verify_frame("T3", 10);
    check_int("T3 wire frame is 64 B", frame_len, PRE_LEN + MIN_FRAME + FCS_LEN);

    // IFG measured between frame 1 and frame 2.
    check_int("T4 inter-frame gap >= 12", (last_gap >= IFG_LEN) ? 1 : 0, 1);
    $display("       (observed gap = %0d byte times)", last_gap);

    //------------------------------------------------------------------ T5
    check_int("T5 tx_er never asserted", int'(er_seen), 0);

    //------------------------------------------------------------------ T6
    // The RGMII DDR stage must reproduce the GMII byte stream exactly. This is
    // what rx_mac_core's IDDR will see on the other end of the link.
    $display("\n[T6] RGMII DDR output reassembles to the same frame");
    check_int("T6 DDR frame count", dframes_done, 2);
    check_int("T6 DDR frame length matches GMII", dframe_len, frame_len);
    begin
      int bad;
      bad = 0;
      for (int i = 0; i < frame_len; i++) if (dfr[i] !== fr[i]) bad++;
      check_int("T6 DDR bytes match GMII bytes", bad, 0);
    end

    //------------------------------------------------------------------ Summary
    $display("\n==================================================");
    $display("  tx_mac_core_tb : %0d checks, %0d failures", checks, errors);
    $display("==================================================");
    if (errors == 0) begin
      $display("  RESULT: ALL TESTS PASSED");
      $finish;
    end else begin
      $display("  RESULT: TESTBENCH FAILED");
      $fatal(1, "%0d check(s) failed", errors);
    end
  end

  initial begin
    #500000;
    $display("  [FAIL] watchdog timeout");
    $fatal(1, "watchdog timeout");
  end

endmodule
