//==============================================================================
// Order Book Array  (Section 3.1.3)
//
// On-chip market database. Maintains NUM_LEVELS price levels per side for each
// of NUM_ASSETS assets. Full depth lives in true dual-port BRAM (one RAMB18 per
// book: one port for updates, one for Alpha Engine reads, so they never
// contend). The best bid/ask of each book are additionally shadowed in a
// registered top-of-book (ToB) cache, giving the Alpha Engine zero-latency
// reads with no handshake.
//
// The array applies PRICE-LEVEL updates only. It has no knowledge of ITCH or of
// order reference numbers -- both are resolved upstream by the parser. The
// 16-bit timestamp is not interpreted here; it is stored with the ToB state and
// forwarded toward the TX Generator for latency telemetry.
//
// FS-6 (real-time database, zero-wait), FS-7 (feeds Alpha Engine)
//==============================================================================
`include "interfaces.svh"

module order_book_array
  import ct_pkg::*;
(
  input  logic                       core_clk,     // 250 MHz
  input  logic                       core_rst_n,

  // --- AXI4-Stream slave from Cut-through Stream Parser ---------------------
  // tready is held high: the worst-case update (19 cycles) always completes
  // within the minimum packet inter-arrival time (168 cycles), so the array can
  // never back-pressure the bufferless parser.
  input  logic [BOOK_UPDATE_W-1:0]   s_axis_tdata,   // book_update_t, 91 bits
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,

  // --- Registered top-of-book, zero-wait combinational outputs (FS-6) -------
  output logic [PRICE_W-1:0]         tob_bid_price [NUM_ASSETS],
  output logic [QTY_W-1:0]           tob_bid_qty   [NUM_ASSETS],
  output logic [PRICE_W-1:0]         tob_ask_price [NUM_ASSETS],
  output logic [QTY_W-1:0]           tob_ask_qty   [NUM_ASSETS],
  output logic [TIMESTAMP_W-1:0]     tob_timestamp [NUM_ASSETS],

  // One-hot strobe: pulses when that asset's ToB changes. Starts the Alpha
  // Engine's 4-cycle FS-7 evaluation window.
  output logic [NUM_ASSETS-1:0]      tob_updated,

  // Per-book flag, asserted during a multi-cycle update
  output logic [NUM_ASSETS-1:0]      book_busy,

  // --- Depth read port to Alpha Engine (BRAM port B) ------------------------
  input  logic [DEPTH_ADDR_W-1:0]    depth_rd_addr,  // {asset, side, level}
  input  logic                       depth_rd_en,
  output logic [LEVEL_W-1:0]         depth_rd_data   // level_t, valid 1 cycle later
);

  //--------------------------------------------------------------------------
  // Input unpacking
  //--------------------------------------------------------------------------
  book_update_t upd;
  assign upd = book_update_t'(s_axis_tdata);

  assign s_axis_tready = 1'b1;   // see QTA: never needs to de-assert

  //--------------------------------------------------------------------------
  // Storage
  //--------------------------------------------------------------------------
  // Full depth: one true dual-port BRAM per book.
  // Port A = update writes, Port B = Alpha Engine reads. No arbitration needed.
  // TODO: infer/instantiate as BRAM. Verify aspect ratio against UG473 -- a
  //       64-bit wide level may require two RAMB18 in parallel.
  level_t book [NUM_ASSETS][2][NUM_LEVELS];   // [asset][side][level]

  // Registered top-of-book cache (level 0 of each side, in flip-flops).
  // This is what delivers the zero-wait requirement of FS-6.
  // Cost: NUM_ASSETS * 4 * 32 = 640 FFs (0.24% of device).
  // A pure-BRAM ToB would cost 2 cycles of read latency -- half the FS-7 budget.

  //--------------------------------------------------------------------------
  // Update control FSM
  //--------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,          // wait for s_axis_tvalid
    DECODE,        // select target book + side from symbol_id/side; assert busy
    SEARCH,        // parallel comparator bank locates the affected price level
    SHIFT,         // shift levels to keep the side price-ordered (add/delete)
    WRITE_COMMIT   // write back to BRAM, commit ToB regs atomically, pulse
                   // tob_updated if the top of book changed
  } book_state_e;

  book_state_e state, next_state;

  logic [ASSET_IDX_W-1:0] tgt_asset;
  logic                   tgt_side;
  logic [LEVEL_IDX_W-1:0] tgt_level;

  // TODO: FSM state register + next-state logic.
  // TODO: DECODE  -> tgt_asset = upd.symbol_id[ASSET_IDX_W-1:0]; assert
  //                  book_busy[tgt_asset].
  // TODO: SEARCH  -> parallel comparators across all NUM_LEVELS levels of the
  //                  target side (1 cycle, ~256 LUTs/book).
  // TODO: SHIFT   -> skipped for a quantity-only modify. Worst case is an
  //                  insertion at the top of a full book: NUM_LEVELS cycles.
  // TODO: WRITE_COMMIT -> write the level, commit the ToB registers and
  //                  tob_timestamp in the SAME cycle (atomic: the Alpha Engine
  //                  must never observe a torn top-of-book). Pulse
  //                  tob_updated[tgt_asset] ONLY if the top of book actually
  //                  changed -- a deep-level update should not wake the engine.

  //--------------------------------------------------------------------------
  // Depth read port (Alpha Engine, BRAM port B)
  //--------------------------------------------------------------------------
  // TODO: registered read from book[] using depth_rd_addr. 1 cycle latency
  //       (2 with the BRAM output register, which 250 MHz timing may require).

endmodule
