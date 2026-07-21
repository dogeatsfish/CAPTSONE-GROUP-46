//==============================================================================
// cut_through_parser_tb  -  unit testbench for rtl/parser/cut_through_parser.sv
//
// Self-checking SystemVerilog testbench (Verilator --binary --timing).
//
// Builds real IPv4/UDP/MoldUDP64/ITCH packets byte-by-byte (with a correctly
// computed UDP checksum), streams them in at 1 B/cycle, and checks the
// resolved price-level updates emitted to the Order Book Array.
//
// Coverage:
//   P1  Add(bid), Add(ask), Executed(partial)  -> ADD, ADD, MODIFY(remaining)
//   P2  Add, Replace, Cancel                   -> ADD, DELETE+ADD, MODIFY
//         (Replace emits TWO beats and must INHERIT symbol/side from the
//          original reference -- the wire carries a deliberately WRONG locate)
//   P3  corrupted payload                      -> r_valid low, but the update
//         is still forwarded (FS-1 optimistic cut-through)
//
// Non-Add messages carry a deliberately bogus Stock Locate (99) to prove the
// parser recovers symbol/side/price from the Order Reference Table rather than
// from the wire.
//==============================================================================

`timescale 1ns/1ps

module cut_through_parser_tb
  import ct_pkg::*;
;

  //--------------------------------------------------------------------------
  // Network constants used to build packets (must satisfy the DUT's parsing)
  //--------------------------------------------------------------------------
  localparam logic [31:0] SRC_IP   = 32'h0A00_0001;   // 10.0.0.1
  localparam logic [31:0] DST_IP   = 32'h0A00_0002;   // 10.0.0.2
  localparam logic [15:0] SRC_PORT = 16'd1234;
  localparam logic [15:0] DST_PORT = 16'd5678;

  //--------------------------------------------------------------------------
  // Clock / reset / DUT
  //--------------------------------------------------------------------------
  logic core_clk;
  logic core_rst_n;

  logic [7:0]               s_axis_tdata;
  logic                     s_axis_tvalid;
  logic                     s_axis_tlast;
  logic                     s_axis_tready;
  logic [TIMESTAMP_W-1:0]   timestamp_now;
  logic [BOOK_UPDATE_W-1:0] m_axis_tdata;
  logic                     m_axis_tvalid;
  logic                     r_valid;

  initial core_clk = 1'b0;
  always #(CORE_PERIOD_NS/2.0) core_clk = ~core_clk;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) timestamp_now <= 16'd0;
    else             timestamp_now <= timestamp_now + 16'd1;
  end

  cut_through_parser dut (
    .core_clk      (core_clk),
    .core_rst_n    (core_rst_n),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tlast  (s_axis_tlast),
    .s_axis_tready (s_axis_tready),
    .timestamp_now (timestamp_now),
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tvalid (m_axis_tvalid),
    .r_valid       (r_valid)
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
      $display("  [FAIL] %-40s got=%0d exp=%0d", name, got, exp);
    end
  endtask

  //--------------------------------------------------------------------------
  // Emitted-update capture
  //--------------------------------------------------------------------------
  book_update_t cap_upd [0:63];
  logic [15:0]  cap_ts  [0:63];
  int           cap_n;

  always @(posedge core_clk) begin
    if (core_rst_n && m_axis_tvalid) begin
      cap_upd[cap_n] = book_update_t'(m_axis_tdata);
      cap_ts [cap_n] = timestamp_now;
      cap_n          = cap_n + 1;
    end
  end

  //--------------------------------------------------------------------------
  // Packet builder
  //--------------------------------------------------------------------------
  logic [7:0] pkt [0:2047];
  int         pkt_len;

  task automatic put8 (input logic [7:0]  v); pkt[pkt_len] = v; pkt_len++; endtask
  task automatic put16(input logic [15:0] v); put8(v[15:8]);  put8(v[7:0]);   endtask
  task automatic put32(input logic [31:0] v); put16(v[31:16]); put16(v[15:0]); endtask
  task automatic put48(input logic [47:0] v); put16(v[47:32]); put32(v[31:0]); endtask
  task automatic put64(input logic [63:0] v); put32(v[63:32]); put32(v[31:0]); endtask

  // IPv4 (20) + UDP (8) + MoldUDP64 (20) = 48 bytes of encapsulation.
  task automatic build_encap(input logic [15:0] num_msgs);
    pkt_len = 0;
    // ---- IPv4 ----
    put8(8'h45); put8(8'h00);
    put16(16'd0);                 // [2:3]  total length   (patched)
    put16(16'd0);                 // [4:5]  identification
    put16(16'h4000);              // [6:7]  DF
    put8(8'd64); put8(8'd17);     // TTL, protocol = UDP
    put16(16'd0);                 // [10:11] IP checksum (not checked by DUT)
    put32(SRC_IP); put32(DST_IP);
    // ---- UDP ----
    put16(SRC_PORT); put16(DST_PORT);
    put16(16'd0);                 // [24:25] UDP length   (patched)
    put16(16'd0);                 // [26:27] UDP checksum (patched)
    // ---- MoldUDP64 ----
    for (int i = 0; i < 10; i++) put8(8'h20);   // session (10 B, spaces)
    put64(64'd1);                               // sequence number
    put16(num_msgs);                            // message count
  endtask

  // ---- ITCH message builders (each prefixed by the MoldUDP64 length) ------
  task automatic itch_add(input logic [15:0] locate, input logic [63:0] ref_num,
                          input logic [7:0]  side_ch, input logic [31:0] shares,
                          input logic [63:0] stock,  input logic [31:0] price);
    put16(16'd36);
    put8("A"); put16(locate); put16(16'd0); put48(48'd0);
    put64(ref_num); put8(side_ch); put32(shares); put64(stock); put32(price);
  endtask

  task automatic itch_exec(input logic [15:0] locate, input logic [63:0] ref_num,
                           input logic [31:0] exec_shares);
    put16(16'd31);
    put8("E"); put16(locate); put16(16'd0); put48(48'd0);
    put64(ref_num); put32(exec_shares); put64(64'd0);
  endtask

  task automatic itch_cancel(input logic [15:0] locate, input logic [63:0] ref_num,
                             input logic [31:0] canc_shares);
    put16(16'd23);
    put8("X"); put16(locate); put16(16'd0); put48(48'd0);
    put64(ref_num); put32(canc_shares);
  endtask

  task automatic itch_delete(input logic [15:0] locate, input logic [63:0] ref_num);
    put16(16'd19);
    put8("D"); put16(locate); put16(16'd0); put48(48'd0); put64(ref_num);
  endtask

  task automatic itch_replace(input logic [15:0] locate, input logic [63:0] orig_ref,
                              input logic [63:0] new_ref, input logic [31:0] shares,
                              input logic [31:0] price);
    put16(16'd35);
    put8("U"); put16(locate); put16(16'd0); put48(48'd0);
    put64(orig_ref); put64(new_ref); put32(shares); put32(price);
  endtask

  // Patch lengths and compute the UDP checksum over pseudo-header + datagram.
  task automatic finalize_packet();
    int unsigned sum;
    int          udp_l;
    logic [15:0] csum;
    logic [7:0]  hi, lo;

    pkt[2]  = 8'(pkt_len >> 8);  pkt[3]  = 8'(pkt_len);
    udp_l   = pkt_len - 20;
    pkt[24] = 8'(udp_l >> 8);    pkt[25] = 8'(udp_l);
    pkt[26] = 8'h00;             pkt[27] = 8'h00;   // zero before computing

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
    if (csum == 16'h0000) csum = 16'hFFFF;          // RFC 768
    pkt[26] = csum[15:8];  pkt[27] = csum[7:0];
  endtask

  // Stream the packet in at 1 byte per cycle, tlast on the final byte.
  task automatic send_packet();
    @(negedge core_clk);
    for (int i = 0; i < pkt_len; i++) begin
      s_axis_tdata  = pkt[i];
      s_axis_tvalid = 1'b1;
      s_axis_tlast  = (i == pkt_len - 1);
      @(negedge core_clk);
    end
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
    s_axis_tdata  = 8'h00;
    repeat (12) @(posedge core_clk);   // let the resolve/emit pipeline drain
  endtask

  //--------------------------------------------------------------------------
  // Expectation helper
  //--------------------------------------------------------------------------
  task automatic expect_upd(input int idx, input string label,
                            input logic [7:0]  sym,  input logic side,
                            input logic [31:0] price, input logic [31:0] qty,
                            input msg_type_e   mt);
    book_update_t u;
    u = cap_upd[idx];
    check_int({label, " symbol_id"}, int'(u.symbol_id), int'(sym));
    check_int({label, " side"},      int'(u.side),      int'(side));
    check_int({label, " price"},     int'(u.price),     int'(price));
    check_int({label, " quantity"},  int'(u.quantity),  int'(qty));
    check_int({label, " msg_type"},  int'(u.msg_type),  int'(mt));
    // timestamp is registered one cycle before the strobe is observed
    check_int({label, " timestamp"}, int'(u.timestamp), int'(cap_ts[idx]) - 1);
  endtask

  //--------------------------------------------------------------------------
  // Test sequence
  //--------------------------------------------------------------------------
  initial begin
    s_axis_tdata  = 8'h00;
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
    cap_n         = 0;

    core_rst_n = 1'b0;
    repeat (5) @(posedge core_clk);
    @(negedge core_clk);
    core_rst_n = 1'b1;
    repeat (2) @(posedge core_clk);

    check_int("s_axis_tready tied high", int'(s_axis_tready), 1);

    //------------------------------------------------------------------ P1
    // Add bid (ref 100, 500 @ 1,000,000), Add ask (ref 101, 300 @ 1,010,000),
    // then execute 200 of ref 100 -> 300 remaining.
    $display("\n[P1] Add(bid) + Add(ask) + Executed(partial)");
    cap_n = 0;
    build_encap(16'd3);
    itch_add   (16'd1,  64'd100, "B", 32'd500, 64'h4141_504C_2020_2020, 32'd1000000);
    itch_add   (16'd1,  64'd101, "S", 32'd300, 64'h4141_504C_2020_2020, 32'd1010000);
    itch_exec  (16'd99, 64'd100, 32'd200);      // bogus locate on purpose
    finalize_packet();
    send_packet();

    check_int("P1 update count", cap_n, 3);
    check_int("P1 r_valid (good checksum)", int'(r_valid), 1);
    expect_upd(0, "P1.add-bid", 8'd1, SIDE_BID, 32'd1000000, 32'd500, MSG_ADD);
    expect_upd(1, "P1.add-ask", 8'd1, SIDE_ASK, 32'd1010000, 32'd300, MSG_ADD);
    // resolved from the ref table, NOT from the bogus locate on the wire
    expect_upd(2, "P1.exec",    8'd1, SIDE_BID, 32'd1000000, 32'd300, MSG_MODIFY);

    //------------------------------------------------------------------ P2
    // Add (ref 200, 400 @ 2,000,000), Replace -> ref 201, 250 @ 2,050,000,
    // then cancel 100 of ref 201 -> 150 remaining.
    $display("\n[P2] Add + Replace(2 beats, inherited identity) + Cancel");
    cap_n = 0;
    build_encap(16'd3);
    itch_add    (16'd2,  64'd200, "B", 32'd400, 64'h4D53_4654_2020_2020, 32'd2000000);
    itch_replace(16'd99, 64'd200, 64'd201, 32'd250, 32'd2050000);
    itch_cancel (16'd99, 64'd201, 32'd100);
    finalize_packet();
    send_packet();

    check_int("P2 update count", cap_n, 4);
    check_int("P2 r_valid (good checksum)", int'(r_valid), 1);
    expect_upd(0, "P2.add",      8'd2, SIDE_BID, 32'd2000000, 32'd400, MSG_ADD);
    // Replace beat 1: remove the old level (identity inherited from ref 200)
    expect_upd(1, "P2.repl-del", 8'd2, SIDE_BID, 32'd2000000, 32'd400, MSG_DELETE);
    // Replace beat 2: add the new level, still symbol 2 / bid despite locate 99
    expect_upd(2, "P2.repl-add", 8'd2, SIDE_BID, 32'd2050000, 32'd250, MSG_ADD);
    expect_upd(3, "P2.cancel",   8'd2, SIDE_BID, 32'd2050000, 32'd150, MSG_MODIFY);

    //------------------------------------------------------------------ P3
    // Corrupt a payload byte AFTER the checksum was computed. The update must
    // still be forwarded (cut-through is optimistic); only r_valid drops.
    $display("\n[P3] Corrupted payload -> r_valid low, update still forwarded");
    cap_n = 0;
    build_encap(16'd1);
    itch_add(16'd3, 64'd300, "B", 32'd700, 64'h5445_5354_2020_2020, 32'd3000000);
    finalize_packet();
    pkt[60] = pkt[60] ^ 8'hFF;      // flip a byte inside the ITCH message
    send_packet();

    check_int("P3 r_valid (corrupt)", int'(r_valid), 0);
    check_int("P3 update still forwarded", cap_n, 1);

    //------------------------------------------------------------------ P4
    // A clean packet after a corrupt one must restore r_valid.
    $display("\n[P4] Recovery: clean packet restores r_valid");
    cap_n = 0;
    build_encap(16'd1);
    itch_delete(16'd99, 64'd300);   // deletes the order added in P3
    finalize_packet();
    send_packet();

    check_int("P4 r_valid restored", int'(r_valid), 1);
    check_int("P4 update count", cap_n, 1);
    expect_upd(0, "P4.delete", 8'd3, SIDE_BID, 32'd3000000, 32'd700, MSG_DELETE);

    //------------------------------------------------------------------ Summary
    $display("\n==================================================");
    $display("  cut_through_parser_tb : %0d checks, %0d failures", checks, errors);
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
