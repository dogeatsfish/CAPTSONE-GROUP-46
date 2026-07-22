//==============================================================================
// cdc_fifo  -  asynchronous (dual-clock) FIFO
//
// Replaces the vendor async FIFO IP originally planned for the RX and TX clock
// domain crossings. Written from the standard Gray-pointer architecture
// (C. Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO
// Design", SNUG 2002) rather than copied from any third-party source, so the
// group owns the result outright and inherits no licence obligations.
//
// Why Gray-coded pointers: a binary pointer crossing a clock domain can be
// sampled mid-transition and land on a value that was never written (multiple
// bits changing at once). Gray code changes exactly ONE bit per increment, so a
// metastable sample can only ever resolve to the old or the new value -- both
// of which are safe, merely conservative (a stale pointer makes the FIFO look
// slightly fuller/emptier than it is, never the reverse).
//
// The pointers are one bit WIDER than the address, so the extra MSB
// distinguishes "wrapped once more" (full) from "same position" (empty).
//
// Read is combinational (first-word fall-through): when rd_empty is low,
// rd_data already presents the next word and rd_en simply advances. This maps
// to distributed RAM (LUTRAM), which supports asynchronous read; do not expect
// block RAM inference at these depths.
//==============================================================================

module cdc_fifo #(
  parameter int DATA_W = 9,             // payload width
  parameter int ADDR_W = 5,             // depth = 2**ADDR_W
  parameter int ALMOST_FULL_THRESH = 0  // wr_almost_full asserts when fewer than
                                        // THRESH entries are free (0 = never)
)(
  // --- write domain ---------------------------------------------------------
  input  logic              wr_clk,
  input  logic              wr_rst_n,
  input  logic              wr_en,
  input  logic [DATA_W-1:0] wr_data,
  output logic              wr_full,
  output logic              wr_almost_full,

  // --- read domain ----------------------------------------------------------
  input  logic              rd_clk,
  input  logic              rd_rst_n,
  input  logic              rd_en,
  output logic [DATA_W-1:0] rd_data,
  output logic              rd_empty
);

  localparam int DEPTH = 1 << ADDR_W;

  // Storage. Simple dual-port: one write port (wr_clk), one async read port.
  logic [DATA_W-1:0] mem [DEPTH];

  //--------------------------------------------------------------------------
  // Pointers. *_bin drives the memory address, *_gray crosses the domain.
  //--------------------------------------------------------------------------
  logic [ADDR_W:0] wbin, wgray, wbin_nxt, wgray_nxt;
  logic [ADDR_W:0] rbin, rgray, rbin_nxt, rgray_nxt;

  // Synchronisers (2 flops each direction)
  logic [ADDR_W:0] wq1_rgray, wq2_rgray;   // read pointer seen by write domain
  logic [ADDR_W:0] rq1_wgray, rq2_wgray;   // write pointer seen by read domain

  // Flag values are combinational, but the FLAGS THEMSELVES are registered.
  // This is not cosmetic: the pointer increment is gated by the flag, so a
  // purely combinational flag would close the loop
  // full -> bin_nxt -> gray_nxt -> full. Registering breaks it, and costs
  // nothing in correctness because both flags are conservative by construction.
  logic wr_full_val, rd_empty_val;

  //--------------------------------------------------------------------------
  // Write domain
  //--------------------------------------------------------------------------
  assign wbin_nxt  = wbin + {{ADDR_W{1'b0}}, (wr_en & ~wr_full)};
  assign wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wbin  <= '0;
      wgray <= '0;
    end else begin
      wbin  <= wbin_nxt;
      wgray <= wgray_nxt;
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_en && !wr_full) mem[wbin[ADDR_W-1:0]] <= wr_data;
  end

  // Sync the read pointer into the write domain.
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wq1_rgray <= '0;
      wq2_rgray <= '0;
    end else begin
      wq1_rgray <= rgray;
      wq2_rgray <= wq1_rgray;
    end
  end

  // Full: pointers at the same address but the wrap bit differs. In Gray code
  // that means the top two bits are inverted and the rest match.
  assign wr_full_val = (wgray_nxt == {~wq2_rgray[ADDR_W:ADDR_W-1],
                                       wq2_rgray[ADDR_W-2:0]});

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) wr_full <= 1'b0;
    else           wr_full <= wr_full_val;
  end

  //--------------------------------------------------------------------------
  // Programmable almost-full (write domain).
  //
  // Asserts when fewer than ALMOST_FULL_THRESH entries are free -- i.e. the FIFO
  // can no longer promise room for another THRESH writes. The TX Generator uses
  // this (threshold = one full outbound frame) to hold off starting a packet it
  // could not fit, which keeps the crossing lossless. Default 0 -> never asserts.
  //
  // Occupancy needs the read pointer as BINARY in the write domain, so the
  // synchronised Gray read pointer is converted back. That pointer lags the true
  // one by up to two cycles, so occupancy is OVER-estimated and the flag is
  // conservative (asserts early), never optimistic -- exactly the safe direction.
  // Registered like wr_full, for the same timing reasons; it does not gate the
  // write pointer, so there is no combinational loop to worry about.
  //--------------------------------------------------------------------------
  function automatic logic [ADDR_W:0] gray2bin(input logic [ADDR_W:0] g);
    logic [ADDR_W:0] b;
    b[ADDR_W] = g[ADDR_W];
    for (int i = ADDR_W - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  logic [ADDR_W:0] wr_occ;      // 0..DEPTH, wrap-safe unsigned subtraction
  assign wr_occ = wbin - gray2bin(wq2_rgray);

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) wr_almost_full <= 1'b0;
    else           wr_almost_full <= (wr_occ > (ADDR_W+1)'(DEPTH - ALMOST_FULL_THRESH));
  end

  //--------------------------------------------------------------------------
  // Read domain
  //--------------------------------------------------------------------------
  assign rbin_nxt  = rbin + {{ADDR_W{1'b0}}, (rd_en & ~rd_empty)};
  assign rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rbin  <= '0;
      rgray <= '0;
    end else begin
      rbin  <= rbin_nxt;
      rgray <= rgray_nxt;
    end
  end

  // Sync the write pointer into the read domain.
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rq1_wgray <= '0;
      rq2_wgray <= '0;
    end else begin
      rq1_wgray <= wgray;
      rq2_wgray <= rq1_wgray;
    end
  end

  // Empty: read pointer has caught the (synchronised) write pointer exactly.
  // Resets ASSERTED -- a FIFO comes out of reset empty, and releasing reset
  // with empty low would hand the reader a garbage word.
  assign rd_empty_val = (rgray_nxt == rq2_wgray);

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) rd_empty <= 1'b1;
    else           rd_empty <= rd_empty_val;
  end

  // First-word fall-through read.
  assign rd_data = mem[rbin[ADDR_W-1:0]];

endmodule
