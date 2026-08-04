//==============================================================================
// Order Book Array  (Section 3.1.3)
//
// On-chip market database. Maintains NUM_LEVELS price levels per side for each
// of NUM_ASSETS assets.
//
// Hybrid storage:
//   - Full depth in BRAM (one block per book): dense, 1-2 cycle read latency.
//   - Top-of-book (level 0 of each side) shadowed in flip-flops: zero read
//     latency, no handshake. This is what satisfies FS-6's zero-wait
//     requirement and preserves the Alpha Engine's 4-cycle FS-7 budget.
//
// The array applies PRICE-LEVEL updates only. It has no knowledge of ITCH or of
// order reference numbers; both are resolved upstream by the parser. The 16-bit
// timestamp is not interpreted here, only stored with the ToB state and
// forwarded toward the TX Generator for latency telemetry (FS-12).
//
// Worst-case update (top-of-book insertion into a full book):
//   1 (load) + 2 (search) + 1 (shift) + 3 (commit) = 7 cycles  (ROUND 8: the
//   shift is now a single parallel cycle, was NUM_LEVELS sequential slides)
// versus 168 cycles of minimum packet inter-arrival, so s_axis_tready never
// needs to de-assert.
//
// TIMING PIPELINE (250 MHz closure -- see docs/timing_closure.md)
//   The first synthesis run failed timing by -6.7 ns: SEARCH resolved the
//   asset/side mux + 16 parallel 32-bit comparators + a serial 16-level
//   priority cascade in ONE cycle, and WRITE_COMMIT read a variable-indexed
//   level, aggregated, and gated the ToB registers' clock-enable through a
//   64-bit compare in ONE cycle (19 logic levels end to end). Both are now
//   split in two:
//     SEARCH  -> SEARCH_CMP (register per-level match/insert bits)
//              + SEARCH_ENC (priority-encode the registered bits)
//     COMMIT  -> WRITE_COMMIT (write level, register the ToB candidate)
//              + TOB_COMMIT  (compare candidate vs ToB, commit atomically)
//   Each stage is now a shallow cone; the cost is +2 cycles on an update,
//   absorbed trivially by the 168-cycle budget.
//
//   ROUND 3 -- LOCAL WORKING SLICE ("load-modify-store"). Splitting the cones
//   was not enough: the book is NUM_ASSETS x 2 x NUM_LEVELS registers scattered
//   across the die, so ANY cone that muxed book[tgt_asset][tgt_side][*] and the
//   high-fanout control nets (tgt_asset fo=452, hit_idx fo=162) that steer it
//   were route-bound (78-90% route), not logic-bound -- pipelining logic depth
//   could not help. Fix: the transaction now copies the active slice into a
//   compact local array `sel[NUM_LEVELS]` in LOAD, does ALL search/shift/
//   compare/write on `sel` (which the placer keeps together -> short routes),
//   and writes `sel` back to the book in STORE. The only die-spanning steps are
//   the LOAD mux and the STORE demux -- both shallow (mux/CE, no arithmetic).
//   hit_idx/shift_idx now address only the 16-entry `sel`, so their fanout and
//   the max_fanout replicas (and the async-reset artifacts those produced) are
//   gone. State count and every cycle latency are UNCHANGED (LOAD replaces
//   DECODE, STORE replaces TOB_COMMIT), so the verification timing is identical.
//
//   ROUND 4 -- two residual order-book paths, both now closed:
//     (a) SETUP (-1.862 ns): STORE evaluated `commit_tob != tob[tgt][side]` --
//         a 64-bit compare that read the die-spanning ToB cache AND gated the
//         ToB/timestamp clock-enables in ONE cycle (11 logic levels, 6xCARRY4).
//         Split off into a new STORE_CMP state: the "did the top change"
//         decision is now a clean reg->compare->flag cycle over LOCAL flops
//         (`commit_tob` vs `orig_tob`, the ToB captured at LOAD), and STORE
//         just does a flag-gated write. +1 cycle (21 -> 22), still << 168.
//     (b) RECOVERY (-1.086 ns): the ~11k book/tob/tob_ts flops were ASYNC-reset,
//         so core_rst_n's release was a recovery arc on a 13k-load, 3.6 ns net.
//         ROUND 4 moved to a synchronous reset; ROUND 6 then found that still
//         failed SETUP (core_rst_sync -> book_reg/R at -1.78 ns, pure route) --
//         11k scattered flops are long-route to reach with ANY reset. FINAL:
//         book/tob/tob_ts carry NO runtime reset and are GSR-initialised at
//         configuration; only the ~1.3k control/`sel` flops keep the sync reset.
//         See the storage-declaration note for the behavioural implication.
//
//   ROUND 8 -- SINGLE-CYCLE PARALLEL SHIFT (-0.748 ns). Once every other cone
//   closed, the last WNS was the SHIFT slide: `sel[dst_i] <= sel[src_i]` with
//   variable indices is a 16:1 read mux over `sel` steered by hit_idx -- 4 logic
//   levels but 77% route (hit_idx -> sel_reg/D). Replaced by a fixed-neighbour
//   shift (each level reads sel[k-1]/sel[k+1], gated by k vs hit_idx) done in one
//   cycle; the placer keeps each lane local so the long mux net is gone. Also
//   collapses the slide from NUM_LEVELS cycles to 1 (worst-case update 22 -> 7).
//   Behaviour/final book contents identical (non-blocking reads the old slice).
//
// FS-6 (real-time database, zero-wait), FS-7 (feeds Alpha Engine)
//==============================================================================

module order_book_array
  import ct_pkg::*;
(
  input  logic                       core_clk,     // 250 MHz
  input  logic                       core_rst_n,

  // --- AXI4-Stream slave from Cut-through Stream Parser ---------------------
  input  logic [BOOK_UPDATE_W-1:0]   s_axis_tdata,   // book_update_t, 91 bits
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,

  // --- Registered top-of-book, zero-wait combinational outputs (FS-6) -------
  output logic [PRICE_W-1:0]         tob_bid_price [NUM_ASSETS],
  output logic [QTY_W-1:0]           tob_bid_qty   [NUM_ASSETS],
  output logic [PRICE_W-1:0]         tob_ask_price [NUM_ASSETS],
  output logic [QTY_W-1:0]           tob_ask_qty   [NUM_ASSETS],
  output logic [TIMESTAMP_W-1:0]     tob_timestamp [NUM_ASSETS],

  output logic [NUM_ASSETS-1:0]      tob_updated,  // pulses on real ToB change
  output logic [NUM_ASSETS-1:0]      book_busy,    // multi-cycle update in flight

  // --- Depth read port to Alpha Engine --------------------------------------
  input  logic [DEPTH_ADDR_W-1:0]    depth_rd_addr,  // {asset, side, level}
  input  logic                       depth_rd_en,
  output logic [LEVEL_W-1:0]         depth_rd_data
);

  //--------------------------------------------------------------------------
  // Input unpacking
  //--------------------------------------------------------------------------
  book_update_t upd;
  assign upd = book_update_t'(s_axis_tdata);

  // Never back-pressures: the worst-case update completes well inside the
  // minimum packet inter-arrival time. See QTA.
  assign s_axis_tready = 1'b1;

  //--------------------------------------------------------------------------
  // Storage
  //
  // book[asset][side][level] holds the full depth. Level 0 is the best price
  // (highest bid / lowest ask). Levels are kept price-ordered at all times.
  //
  // POWER-UP INIT, NO RUNTIME RESET (TIMING -- ROUND 6). The market-data state
  // (book/tob/tob_ts, ~11k flops) is initialised to zero by the declaration
  // initialiser, which synthesis maps to the flops' INIT attribute -> the FPGA
  // global set/reset (GSR) clears them at configuration. It is NOT in the
  // runtime reset branch below. Reason: whether the reset was async (recovery)
  // or synchronous (setup, ROUND 4), a reset net reaching ~11k flops SCATTERED
  // across a 5%-utilised die is inherently long-route -- the round-6 report
  // showed the replicated sync-reset -> book_reg/R paths failing at -1.78 ns
  // (0 logic levels, pure route), ~24 of the 30 worst paths. Removing the net
  // removes the whole class. The control/FSM path IS still reset (below), so on
  // a runtime core_rst_n the engine restarts cleanly in IDLE; the accumulated
  // book is simply not wiped (it is rebuilt from the feed). book, tob and tob_ts
  // are dropped together so the "tob mirrors book[0]" invariant is preserved.
  //--------------------------------------------------------------------------
  level_t book [NUM_ASSETS][2][NUM_LEVELS] = '{default: '0};

  // Top-of-book cache. Mirrors book[asset][side][0], committed atomically in the
  // same cycle as the book write so the Alpha Engine never observes a torn top.
  // GSR-initialised with the book (see the storage note above).
  level_t                tob      [NUM_ASSETS][2]   = '{default: '0};
  logic [TIMESTAMP_W-1:0] tob_ts  [NUM_ASSETS]      = '{default: '0};

  //--------------------------------------------------------------------------
  // Local working slice (TIMING -- see the ROUND 3 note in the header).
  //
  // A transaction copies book[tgt_asset][tgt_side][*] into `sel` in LOAD and
  // operates exclusively on `sel` thereafter; STORE writes it back. `sel` is a
  // fixed 16-entry array the placer keeps together, so the comparators, the
  // shift, and the ToB compare read/write LOCAL flops instead of the book
  // registers scattered across the die. This is what turns the route-bound
  // (78-90% route) search/shift cones into short local ones.
  //--------------------------------------------------------------------------
  level_t sel [NUM_LEVELS];

  //--------------------------------------------------------------------------
  // Latched update fields (captured on accept, held for the whole transaction)
  //
  // MAX_FANOUT (TIMING): tgt_asset/tgt_side steer the book slice mux in LOAD and
  // the write-enable decode in STORE (~10k flops), so they are replicated into
  // regional copies. tgt_type steers the sel write-enable decode across the
  // 16x64 `sel` array (ROUND 4 report: tgt_type -> sel_reg/CE was route-bound),
  // so it is replicated too.
  //--------------------------------------------------------------------------
  (* max_fanout = 32 *) logic [ASSET_IDX_W-1:0] tgt_asset;
  (* max_fanout = 8 *) logic                   tgt_side;
  // tgt_price feeds BOTH comparators of EVERY level in SEARCH_CMP
  // (lvl.price == tgt_price, and tgt_price >/< lvl.price), i.e. ~32 comparator
  // instances spread across the whole `sel` array. Round 13 showed
  // tgt_price_reg -> cmp_exact_reg[12]/D as the WNS at 63% route -- the same
  // high-fanout-control-over-a-spread-array profile that made hit_idx the
  // -1.48 ns path until it was replicated. Replicated here for the same reason.
  (* max_fanout = 8 *) logic [PRICE_W-1:0]     tgt_price;
  (* max_fanout = 16 *) logic [QTY_W-1:0]       tgt_qty;
  (* max_fanout = 8 *) msg_type_e              tgt_type;
  logic [TIMESTAMP_W-1:0] tgt_ts;

  //--------------------------------------------------------------------------
  // Search results (registered out of the search stages)
  //
  // MAX_FANOUT (TIMING -- ROUND 5): hit_idx steers the WRITE_COMMIT level write
  // and the per-level shift compares over the 16x64 `sel` array. Round 5 showed
  // it at fanout 158 (the dominant -1.48 ns order-book failure), so it is
  // replicated. SAFE only because the module is synchronous-reset (ROUND 4):
  // the round-2/3 reason for dropping the attribute was the async self-preset
  // FDPE artifact max_fanout produced on no-reset flops -- FDRE cells have no
  // async set/reset, so it cannot recur. (ROUND 8 removed the old shift counter
  // `shift_idx` when the multi-cycle slide became the single-cycle parallel one.)
  //--------------------------------------------------------------------------
  // hit_idx_central is driven by the priority encoder.
  logic [LEVEL_IDX_W-1:0] hit_idx_central;
  logic                   hit_exact_central;
  logic                   hit_valid_central;

  (* max_fanout = 8 *) logic [LEVEL_IDX_W-1:0] hit_idx;    // level the update targets
  (* max_fanout = 16 *) logic                   hit_exact;  // price matches an existing level
  logic                   hit_valid;  // a level was found / insertion point valid

  //--------------------------------------------------------------------------
  // Commit pipeline registers (TIMING)
  //   agg_qty    -- per-level aggregate (sel[l].quantity + tgt_qty), computed for
  //                 ALL levels in SEARCH_CMP (ROUND 13). An ADD at an existing
  //                 price needs sel[hit_idx].quantity + tgt_qty; doing that in
  //                 WRITE_COMMIT put a 32-bit add (7xCARRY4) IN FRONT of the
  //                 sel write demux -- 11 logic levels, 56 % logic, one of the
  //                 last two logic-bound cones. Computing it here instead costs
  //                 16 adders (free at ~5 % utilisation) but needs no hit_idx,
  //                 so it is a clean reg->add->reg cycle, and WRITE_COMMIT is
  //                 left with only a mux. Valid because an exact-price ADD never
  //                 shifts (needs_shift is false), so sel is unchanged between
  //                 SEARCH_CMP and WRITE_COMMIT for the case that reads it.
  //   commit_tob -- the ToB candidate, registered in WRITE_COMMIT so the
  //                 64-bit "did the top change" compare and the ToB registers'
  //                 clock-enables live in their own cycle (STORE_CMP -> STORE).
  //   orig_tob   -- the top-of-book as it stood at LOAD (= book[tgt][side][0],
  //                 which the ToB cache mirrors), captured BEFORE any shift or
  //                 write touched `sel`. STORE_CMP compares commit_tob against
  //                 this LOCAL register instead of muxing the die-spanning ToB
  //                 cache -- identical result, short routes (ROUND 4).
  //   tob_changed-- registered "top of book actually changed" decision, so STORE
  //                 is a flag-gated write with no wide compare in its cone.
  //--------------------------------------------------------------------------
  logic [QTY_W-1:0] agg_qty [NUM_LEVELS];
  level_t           commit_tob;
  level_t           orig_tob;
  logic             tob_changed;

  //--------------------------------------------------------------------------
  // FSM
  //--------------------------------------------------------------------------
  typedef enum logic [3:0] {
    IDLE,
    LOAD,           // copy the active book slice into `sel`, mark book busy
    SEARCH_PRE_CMP, // stage 0: precompute per-level occupancy and price compares
    SEARCH_CMP,     // stage 1: register the per-level comparator results
    SEARCH_ENC,     // stage 2: priority-encode the registered results
    SEARCH_DIST,    // stage 3: distribute central hit_idx to replicated registers
    SHIFT,
    WRITE_COMMIT,   // write the level into `sel`, register the ToB candidate
    STORE_CMP,      // decide (and register) whether the top of book changed
    STORE           // write `sel` back to the book, commit ToB atomically
  } book_state_e;

  // max_fanout tightened 512 -> 64 (ROUND 13). `state` gates the write-enable of
  // every book AND `sel` flop, so at 512 each replica still had to physically
  // reach ~512 loads spread across the array -- run 13 showed
  // state_reg[0] -> book_reg/CE at 83 % route on a TWO-logic-level path, and
  // state_reg[2]_rep -> sel_reg/D at 80 % route on ONE level. With the congestion
  // report clean ("no congestion windows above level 5") and ~90 % of the die
  // unused, the long routes are pure fanout reach, not detours -- so more, shorter
  // replicas are both safe and the correct lever.
  (* max_fanout = 64 *) book_state_e state;

  //--------------------------------------------------------------------------
  // REGISTERED WRITE ENABLES (TIMING -- ROUND 19)
  //
  // Run 18 left 240 failing paths and 184 of them were ONE structural problem:
  // the write-enable decode reaching the scattered arrays.
  //
  //   STORE  : `book[tgt_asset][tgt_side][l] <= sel[l]` inside the FSM case made
  //            every one of the ~10 k book flops carry
  //            CE = (state == STORE) && (a == tgt_asset) && (s == tgt_side).
  //            Synthesis built that as LUT6 -> LUT4 -> a fanout-832 net:
  //              tgt_side_rep/Q -> book[..]_i_2 (fo=38) -> book[..]_i_1 (fo=832)
  //            2 logic levels, 84 % route, and it owned the whole top of the
  //            failing list (state/tgt_side/tgt_asset -> book_reg/CE).
  //
  //   sel    : the same shape one array down -- state -> LUT3 -> LUT6 -> a
  //            per-level enable over the 16x64 slice (3 levels, 81 % route),
  //            which was the WNS at -0.173 ns.
  //
  // Both decodes are functions of registers that are known a FULL CYCLE before
  // the write happens, so both are now precomputed into registers:
  //
  //   store_we[a][s] -- one-hot asset/side select, set in STORE_CMP, so a book
  //                     flop's CE is a SINGLE REGISTER BIT (zero logic levels)
  //                     and each bit's loads are one contiguous 1024-flop slice
  //                     instead of a decode spanning the whole array.
  //   sh_en / wc_en  -- per-level SHIFT / WRITE_COMMIT enables, computed in
  //                     SEARCH_DIST. A `sel` clock-enable then folds into ONE
  //                     LUT6: {state[3:0], sh_en[k], wc_en[k]} is exactly six
  //                     inputs.
  //
  // This is the same lever that fixed hit_idx and tgt_price in earlier rounds --
  // move the decode off the wide net -- but applied to the enables themselves
  // rather than to their inputs.
  //--------------------------------------------------------------------------
  (* max_fanout = 128 *) logic [NUM_ASSETS-1:0][1:0] store_we;
  (* max_fanout = 64 *)  logic [NUM_LEVELS-1:0]      sh_en;
  (* max_fanout = 64 *)  logic [NUM_LEVELS-1:0]      wc_en;

  //--------------------------------------------------------------------------
  // SEARCH stage 1 (SEARCH_CMP): parallel comparator bank.
  //
  // For every level of the target side, compute two bits:
  //   cmp_exact[l]  -- occupied level whose price matches exactly
  //   cmp_insert[l] -- empty slot, or a level priced worse than the update
  // The two are mutually exclusive per level (an exact match can be neither
  // empty nor worse-priced). Bids are sorted descending, asks ascending, so
  // the "worse price" comparison flips with the side.
  //
  // TIMING: the results are REGISTERED here rather than fed straight into the
  // priority encode -- the comparators alone are a full cycle at 250 MHz.
  // Chaining the 16-level priority cascade behind them was the original -6.7 ns
  // critical path. The operands are now the LOCAL `sel` slice (loaded in LOAD),
  // not the die-spanning book -- that removed the -3.1 ns route-bound residue.
  //--------------------------------------------------------------------------
  logic [NUM_LEVELS-1:0] cmp_exact_next, cmp_insert_next;   // combinational
  logic [NUM_LEVELS-1:0] cmp_exact,      cmp_insert;        // registered

  logic [NUM_LEVELS-1:0] sel_valid;
  logic [NUM_LEVELS-1:0] sel_price_match;
  logic [NUM_LEVELS-1:0] sel_price_greater;
  logic [NUM_LEVELS-1:0] sel_price_less;

  always_comb begin
    for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
      cmp_exact_next[l]  = sel_valid[l] && sel_price_match[l];
      cmp_insert_next[l] = !sel_valid[l] ||
                           (tgt_side == SIDE_BID ? sel_price_greater[l]
                                                 : sel_price_less[l]);
    end
  end

  //--------------------------------------------------------------------------
  // SEARCH stage 2 (SEARCH_ENC): priority encode over the REGISTERED bits.
  // First level (lowest index = best price) that matches or accepts an insert
  // wins -- identical semantics to the original serial scan, but the encode now
  // starts from flops instead of the far end of 16 comparators.
  //--------------------------------------------------------------------------
  logic [LEVEL_IDX_W-1:0] srch_idx;
  logic                   srch_exact;
  logic                   srch_valid;

  always_comb begin
    srch_idx   = '0;
    srch_exact = 1'b0;
    srch_valid = 1'b0;

    for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
      if (!srch_valid && (cmp_exact[l] || cmp_insert[l])) begin
        srch_idx   = LEVEL_IDX_W'(l);
        srch_exact = cmp_exact[l];
        srch_valid = 1'b1;
      end
    end
  end

  //--------------------------------------------------------------------------
  // Whether this update needs a level shift.
  //   - ADD at a new price      -> insert, shift down
  //   - DELETE (or qty -> 0)    -> remove, shift up
  //   - MODIFY at existing price-> write in place, no shift
  //
  // TIMING (ROUND 18): these were COMBINATIONAL from tgt_type/hit_exact and sat
  // directly in front of the `sel` write-enable decode:
  //     tgt_type_reg -> LUT2(is_removal, fo=977) -> LUT4(needs_shift)
  //                  -> LUT6 -> LUT6 -> sel_reg[*][*]/CE
  // -- a 4-LUT cone, 78 % route, and 8 of the 40 failing paths. Both are pure
  // functions of registers that are STABLE from SEARCH_ENC onward, so they are
  // computed once in SEARCH_DIST (a stage that does nothing but fan registers
  // out, and has slack to spare) and consumed as REGISTERS in SHIFT. That takes
  // two LUT levels and the fanout-977 net out of the enable cone entirely.
  //
  // hit_exact_central is used rather than the replicated hit_exact because it is
  // the value hit_exact will HOLD during SHIFT -- SEARCH_DIST is exactly the
  // cycle that copies one into the other, so the two are equal by construction.
  //
  // max_fanout mirrors `state`: these gate every `sel` flop, so the replicas
  // must be able to reach the whole 16x64 array on short routes.
  //--------------------------------------------------------------------------
  (* max_fanout = 64 *) logic needs_shift;
  (* max_fanout = 64 *) logic is_removal;

  //--------------------------------------------------------------------------
  // Synchronous reset for the CONTROL path only (TIMING -- ROUND 4 / ROUND 6).
  //
  // Only the FSM/control registers and the working slice `sel` are reset here
  // (~1.3k flops). The big market-data arrays (book/tob/tob_ts, ~11k flops) are
  // GSR-initialised instead and carry no runtime reset -- see the storage note.
  //
  // History: ROUND 4 moved the whole module from async to synchronous reset to
  // kill the -1.086 ns reset-RELEASE recovery arc. That worked, but ROUND 6
  // showed the ~11k-flop book clear then failed SETUP (replicated core_rst_sync
  // -> book_reg/R at -1.78 ns, 0 logic levels, pure route): a reset reaching 11k
  // scattered flops is long-route no matter which kind. GSR init removes that
  // net entirely; the small control clear that remains routes fine. `core_rst_sync`
  // is registered/replicated and takes effect one cycle after core_rst_n, which
  // is immaterial (the block is idle throughout reset).
  //--------------------------------------------------------------------------
  (* max_fanout = 256 *) logic core_rst_sync;
  always_ff @(posedge core_clk) begin
    core_rst_sync <= ~core_rst_n;
  end

  //--------------------------------------------------------------------------
  // Main sequential process
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk) begin
    if (core_rst_sync) begin
      state       <= IDLE;
      book_busy   <= '0;
      tob_updated <= '0;

      // Reset the transaction control registers too. Functionally they are
      // don't-care until loaded, but giving them a reset makes synthesis infer
      // plain resettable flops rather than no-reset flops it is free to
      // implement with logic-driven set/reset. With the synchronous reset
      // (ROUND 4) these are FDRE, so there are no async set/reset artifacts at
      // all -- the round-2 self-preset FDPE recovery arcs cannot recur.
      tgt_asset   <= '0;
      tgt_side    <= '0;
      hit_idx_central <= '0;
      hit_exact_central <= 1'b0;
      hit_valid_central <= 1'b0;
      hit_idx     <= '0;
      hit_exact   <= 1'b0;
      hit_valid   <= 1'b0;
      is_removal  <= 1'b0;
      needs_shift <= 1'b0;
      store_we    <= '0;
      sh_en       <= '0;
      wc_en       <= '0;
      orig_tob    <= '0;
      tob_changed <= 1'b0;
      sel_valid         <= '0;
      sel_price_match   <= '0;
      sel_price_greater <= '0;
      sel_price_less    <= '0;

      // NOTE: book / tob / tob_ts are deliberately NOT reset here -- they are
      // GSR-initialised at configuration (see the storage declaration). A runtime
      // reset restarts the control path only; the market-data state is not wiped.

    end else begin
      // tob_updated is a single-cycle strobe.
      tob_updated <= '0;

      // store_we is likewise a single-cycle strobe: STORE_CMP raises exactly one
      // bit, it is high for the STORE cycle only, and it self-clears here. That
      // is what lets the book write live outside this FSM with no state term in
      // its clock-enable (TIMING -- ROUND 19).
      store_we    <= '0;

      unique case (state)

        //--------------------------------------------------------------------
        // symbol_id is 8 bits wide but only NUM_ASSETS books exist, and
        // ASSET_IDX_W rounds UP to 3 bits. Truncating to symbol_id[2:0] would
        // let locates 5..7 index past the end of the book array. The parser
        // takes symbol_id straight from the ITCH Stock Locate field, so a feed
        // carrying an unexpected locate must be discarded HERE, in the block
        // that owns the array -- not silently aliased onto a real asset.
        //
        // TIMING (ROUND 18): the range compare used to gate the tgt_* CAPTURE as
        // well as the state move, which put it in front of every tgt_* flop:
        //     upd_reg[symbol_id] -> LUT5 -> LUT5 -> (fo=72) -> LUT4
        //                        -> tgt_price_reg[9]_rep/D
        // -- the WNS path at -0.127 ns. `symbol_id < 5` is an 8-bit compare and
        // cannot fold into one LUT6, so it is two levels no matter how it is
        // written; the fix is to keep it OFF the wide capture enable instead.
        //
        // Capture is now gated on s_axis_tvalid alone (one level), and only the
        // STATE MOVE carries the range check. Latching a rejected update into
        // tgt_* is harmless: the FSM stays in IDLE, nothing reads tgt_* in IDLE,
        // and the next accepted update overwrites every field. The discard still
        // happens HERE, in the block that owns the array -- an out-of-range
        // locate never reaches LOAD and so never indexes the book.
        IDLE: begin
          if (s_axis_tvalid) begin
            tgt_asset <= upd.symbol_id[ASSET_IDX_W-1:0];
            tgt_side  <= upd.side;
            tgt_price <= upd.price;
            tgt_qty   <= upd.quantity;
            tgt_type  <= upd.msg_type;
            tgt_ts    <= upd.timestamp;
            if (upd.symbol_id < SYMBOL_W'(NUM_ASSETS)) state <= LOAD;
          end
        end

        //--------------------------------------------------------------------
        // LOAD: copy the target book slice into the local working array `sel`
        // and mark the book busy. This is the one die-spanning read of the
        // transaction (a mux per level, no arithmetic behind it); everything
        // downstream operates on `sel` (TIMING -- see the ROUND 3 header note).
        //--------------------------------------------------------------------
        LOAD: begin
          for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
            sel[l] <= book[tgt_asset][tgt_side][l];
          end
          // Snapshot the current top of book (level 0) for the STORE_CMP
          // change-detect. Taken from the same die-spanning read as sel[0], so
          // it costs nothing extra and stays a LOCAL flop thereafter (ROUND 4).
          orig_tob             <= book[tgt_asset][tgt_side][0];
          book_busy[tgt_asset] <= 1'b1;
          state                <= SEARCH_PRE_CMP;
        end

        //--------------------------------------------------------------------
        // SEARCH_PRE_CMP: Evaluate 32-bit width operations (occupancy and
        // price compares) into per-level fabric flops. Breaking these off here
        // converts the routing-dominant SEARCH_CMP comparisons from 32-bit
        // cross-slice wide checks into simple 1-bit boolean local gates.
        //--------------------------------------------------------------------
        SEARCH_PRE_CMP: begin
          for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
            sel_valid[l]         <= (sel[l].quantity != 32'd0);
            sel_price_match[l]   <= (sel[l].price == tgt_price);
            sel_price_greater[l] <= (tgt_price > sel[l].price);
            sel_price_less[l]    <= (tgt_price < sel[l].price);
          end
          state <= SEARCH_CMP;
        end

        //--------------------------------------------------------------------
        // Register the per-level comparator results (search stage 1).
        //--------------------------------------------------------------------
        SEARCH_CMP: begin
          cmp_exact  <= cmp_exact_next;
          cmp_insert <= cmp_insert_next;

          // Precompute the aggregate for EVERY level (TIMING -- ROUND 13, see
          // the agg_qty note above). hit_idx is not known yet, which is exactly
          // why this works: no mux in front of the adder, both operands are S0/
          // LOAD registers, so it is a clean reg -> add -> reg cycle and the
          // 32-bit add leaves WRITE_COMMIT's write path entirely.
          for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
            agg_qty[l] <= sel[l].quantity + tgt_qty;
          end

          state <= SEARCH_ENC;
        end

        //--------------------------------------------------------------------
        // Priority-encode the registered results (search stage 2).
        //--------------------------------------------------------------------
        // ROUND 19: the transition out of here is now UNCONDITIONAL. It used to
        // branch on the combinational `srch_valid`, which put the 16-level
        // priority cascade over cmp_exact/cmp_insert directly into the FSM's
        // next-state cone (`cmp_exact_reg[4] -> state_reg[2]_rep/D`, 4 logic
        // levels -- the deepest cone left in run 18 outside the enable clusters).
        // srch_valid is already being registered into hit_valid_central on this
        // same edge, so the drop decision simply moves to SEARCH_DIST where it
        // reads a flop. Cost: a REJECTED update takes one extra cycle to return
        // to IDLE (and holds book_busy one cycle longer). Accepted transactions
        // are unchanged at 7 cycles, and the benches bound book_busy by
        // NUM_LEVELS+5 = 21 against an observed maximum of 8.
        SEARCH_ENC: begin
          hit_idx_central   <= srch_idx;
          hit_exact_central <= srch_exact;
          hit_valid_central <= srch_valid;
          state             <= SEARCH_DIST;
        end

        //--------------------------------------------------------------------
        // SEARCH_DIST: pipeline stage to distribute the central hit_idx
        // to the replicated max_fanout registers. This removes the massive
        // routing delay from the priority encoder to the scattered replicas.
        //--------------------------------------------------------------------
        SEARCH_DIST: begin
          hit_idx   <= hit_idx_central;
          hit_exact <= hit_exact_central;
          hit_valid <= hit_valid_central;

          // Shift-kind decode, registered here so SHIFT/WRITE_COMMIT see flops
          // instead of a 2-LUT cone in front of every `sel` clock-enable
          // (TIMING -- ROUND 18, see the declaration note).
          begin
            automatic logic rem_c, nsh_c, wc_c;

            rem_c = (tgt_type == MSG_DELETE);
            nsh_c = (tgt_type == MSG_ADD && !hit_exact_central) || rem_c;
            // A level is written by WRITE_COMMIT only for ADD / MODIFY. DELETE
            // writes nothing (the shift already removed the level) and MSG_RSVD
            // is ignored -- this reproduces the `unique case (tgt_type)` with its
            // empty DELETE arm and `default: ;` EXACTLY, including MSG_RSVD.
            wc_c  = (tgt_type == MSG_ADD) || (tgt_type == MSG_MODIFY);

            is_removal  <= rem_c;
            needs_shift <= nsh_c;

            // Per-level enables (TIMING -- ROUND 19). Constant k against a
            // registered hit_idx_central, one cycle before the write, so SHIFT
            // and WRITE_COMMIT read a flop per level instead of rebuilding the
            // compare inside the enable cone.
            //   removal : levels [hit_idx .. N-2] take their successor AND the
            //             tail is always vacated -> level N-1 always written.
            //   insert  : levels [hit_idx+1 .. N-1] take their predecessor.
            for (int unsigned k = 0; k < NUM_LEVELS; k++) begin
              sh_en[k] <= nsh_c &&
                          (rem_c ? ((k >= hit_idx_central) || (k == NUM_LEVELS-1))
                                 : ((k >= 1) && (k > hit_idx_central)));
              wc_en[k] <= wc_c && (k == hit_idx_central);
            end
          end

          // A price worse than every tracked level, on a full book, falls
          // outside the maintained depth window and is simply dropped. Decided
          // here (ROUND 19) rather than in SEARCH_ENC so the test reads the
          // REGISTERED hit_valid_central instead of the priority cascade -- see
          // the SEARCH_ENC note. The sh_en/wc_en written above are harmless on
          // this path: nothing consumes them before the next transaction
          // overwrites them in its own SEARCH_DIST.
          if (!hit_valid_central) begin
            book_busy[tgt_asset] <= 1'b0;
            state                <= IDLE;
          end else begin
            state                <= SHIFT;
          end
        end

        //--------------------------------------------------------------------
        // SHIFT: keep each side price-ordered, in a SINGLE cycle.
        //   insert -> slide levels [hit_idx .. N-2] down one slot
        //   remove -> slide levels [hit_idx+1 .. N-1] up one slot
        // A modify at an existing price skips the slide entirely.
        //
        // TIMING (ROUND 8): the previous version slid ONE slot per cycle using a
        // variable-indexed copy `sel[dst_i] <= sel[src_i]`. That is a 16:1 read
        // mux over the whole `sel` array, steered by hit_idx/shift_idx, whose
        // output fans to every level -- route-bound (77% route, the -0.748 ns
        // WNS: hit_idx -> sel_reg/D). Here every level instead reads a FIXED
        // neighbour (sel[k+1] on a remove, sel[k-1] on an insert), gated by a
        // per-level compare of the constant k against hit_idx. Fixed neighbours
        // let the placer keep each 64-bit lane as a local chain, so the long mux
        // net is gone. Non-blocking assignment reads the OLD slice, so doing all
        // levels at once is equivalent to the old tail-to-head ordering. The
        // whole slide now costs 1 cycle instead of up to NUM_LEVELS (worst-case
        // update 22 -> ~7); the benches wait a fixed 30 cycles and bound
        // book_busy by <= NUM_LEVELS+5, both of which a shorter slide satisfies.
        //--------------------------------------------------------------------
        // ROUND 19: the per-level "is this level written" test is no longer
        // rebuilt here from hit_idx -- it is the registered `sh_en[k]`, decided
        // in SEARCH_DIST. The DATA mux is unchanged (still a fixed neighbour);
        // only the enable moved. Behaviour is identical arm for arm:
        //   !needs_shift -> sh_en is all zero          -> nothing slides
        //   removal      -> sh_en[k] for k >= hit_idx, plus the tail
        //   insert       -> sh_en[k] for k >= 1 && k > hit_idx
        SHIFT: begin
          for (int unsigned k = 0; k < NUM_LEVELS-1; k++) begin
            if (sh_en[k]) begin
              if (is_removal) begin
                // Levels [hit_idx .. N-2] take their successor.
                sel[k] <= sel[k+1];
              end else if (k >= 1) begin
                // Insert: levels [hit_idx+1 .. N-2] take their predecessor.
                sel[k] <= sel[k-1];
              end
            end
          end
          // Tail element handled separately to avoid out-of-bounds sel[k+1] access in xsim
          if (sh_en[NUM_LEVELS-1]) begin
            if (is_removal) begin
              sel[NUM_LEVELS-1] <= '0;
            end else begin
              sel[NUM_LEVELS-1] <= sel[NUM_LEVELS-2];
            end
          end
          state <= WRITE_COMMIT;
        end

        //--------------------------------------------------------------------
        // WRITE_COMMIT: write the affected level into the local slice and
        // REGISTER the ToB candidate. The "did the top change" compare and the
        // ToB commit moved downstream (STORE_CMP then STORE) so the level-mux/
        // adder, the 64-bit compare, and the ToB clock-enables are three shallow
        // cycles instead of one deep one (TIMING: was the -6.7 ns and -1.86 ns
        // critical paths).
        //--------------------------------------------------------------------
        // ROUND 19: the `unique case (tgt_type)` + `k == hit_idx` decode that
        // gated these writes is now the registered `wc_en[k]` from SEARCH_DIST.
        // Equivalent arm for arm -- wc_en is set only for ADD and MODIFY, so
        // DELETE (level already removed by the shift) and MSG_RSVD still write
        // nothing -- and the quantity mux folds the two live arms exactly:
        //   ADD  + hit_exact -> agg_qty[k]   (aggregate into the existing level)
        //   ADD  + !hit_exact-> tgt_qty      (fresh level opened by the shift)
        //   MODIFY           -> tgt_qty
        WRITE_COMMIT: begin
          for (int unsigned k = 0; k < NUM_LEVELS; k++) begin
            if (wc_en[k]) begin
              sel[k].price    <= tgt_price;
              sel[k].quantity <= (tgt_type == MSG_ADD && hit_exact) ? agg_qty[k]
                                                                   : tgt_qty;
            end
          end

          // The new top of book is level 0 after this update. For a delete the
          // shift has already moved the successor into place (sel[0] is final
          // by now); for an add/modify at index 0 it is the level being written
          // this cycle.
          if (tgt_type != MSG_DELETE && hit_idx == '0) begin
            commit_tob.price <= tgt_price;
            commit_tob.quantity <= (tgt_type == MSG_ADD && hit_exact) ? agg_qty[0] : tgt_qty;
          end else begin
            commit_tob <= sel[0];
          end

          state <= STORE_CMP;
        end

        //--------------------------------------------------------------------
        // STORE_CMP (TIMING -- ROUND 4): decide whether the top of book
        // actually changed, in its OWN cycle. `commit_tob` and `orig_tob` are
        // both plain LOCAL registers by now, so this is a clean reg -> 64-bit
        // compare -> flag-reg path: no die-spanning ToB-cache mux and no
        // clock-enable gating share this cone. `orig_tob` is the ToB as it stood
        // at LOAD (book[tgt][side][0], which the ToB cache mirrors), so
        // `commit_tob != orig_tob` is identical to the old
        // `commit_tob != tob[tgt_asset][tgt_side]` -- just on local flops.
        //--------------------------------------------------------------------
        STORE_CMP: begin
          tob_changed <= (commit_tob != orig_tob);

          // Raise the one-hot book write-enable for the slice this transaction
          // owns (TIMING -- ROUND 19). Written as an explicit compare loop, not
          // `store_we[tgt_asset][tgt_side] <= 1'b1`, for two reasons: it is the
          // asset/side decode itself, moved a cycle earlier into a register
          // where there is slack, and it cannot index out of range if tgt_asset
          // ever holds a locate >= NUM_ASSETS.
          for (int unsigned a = 0; a < NUM_ASSETS; a++)
            for (int unsigned s = 0; s < 2; s++)
              if (a == unsigned'(tgt_asset) && s == unsigned'(tgt_side))
                store_we[a][s] <= 1'b1;

          state       <= STORE;
        end

        //--------------------------------------------------------------------
        // STORE: write the (now final) working slice back to the book, and
        // commit the ToB ATOMICALLY. This is the one die-spanning write of the
        // transaction (a demux per level -- data from local `sel`, clock-enable
        // gated by the asset/side match, no arithmetic). tob_updated pulses
        // only if the top of book actually changed (tob_changed, decided in
        // STORE_CMP) -- a deep-level update must not wake the Alpha Engine and
        // burn its FS-7 budget for nothing.
        //--------------------------------------------------------------------
        // ROUND 19: the book write-back has MOVED OUT of this case, into its own
        // always_ff gated purely by `store_we` (see below the FSM). Keeping it
        // here is what forced every book flop's clock-enable to carry a
        // `state == STORE` term on top of the asset/side compare. The write
        // still happens in exactly this cycle -- store_we is a one-cycle strobe
        // raised in STORE_CMP -- and `sel` is stable throughout (nothing writes
        // it after WRITE_COMMIT), so the data is identical.
        STORE: begin
          if (tob_changed) begin
            tob[tgt_asset][tgt_side] <= commit_tob;
            tob_ts[tgt_asset]        <= tgt_ts;
            tob_updated[tgt_asset]   <= 1'b1;
          end

          book_busy[tgt_asset] <= 1'b0;
          state                <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // BOOK WRITE-BACK (TIMING -- ROUND 19)
  //
  // Deliberately its OWN always_ff, outside the FSM, and deliberately with NO
  // reset (the book is GSR-initialised -- see the storage note; adding a reset
  // here would recreate the round-4/6 reset-net problem on ~10 k flops).
  //
  // Every book flop's clock-enable is now exactly one register bit,
  // `store_we[a][s]`, with ZERO logic levels in front of it. Previously this
  // write lived in the FSM's STORE arm, so each flop carried
  // `(state == STORE) && (a == tgt_asset) && (s == tgt_side)` -- a two-LUT
  // decode ending in a fanout-832 net, which was 184 of run 18's 240 failing
  // paths. The decode still happens, but one cycle earlier in STORE_CMP where
  // there is slack, and its result is a register.
  //
  // Each store_we bit now drives ONE contiguous asset/side slice
  // (NUM_LEVELS x 64 = 1024 flops) rather than a decode net spanning the whole
  // array, so `max_fanout` replicas are physically local to the slice they
  // enable -- which is also what should pull the placement back together.
  //
  // Timing and data are unchanged: store_we is a one-cycle strobe raised in
  // STORE_CMP, so this fires in exactly the cycle the old STORE arm did, and
  // `sel` is stable from WRITE_COMMIT onward.
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk) begin
    for (int unsigned a = 0; a < NUM_ASSETS; a++) begin
      for (int unsigned s = 0; s < 2; s++) begin
        if (store_we[a][s]) begin
          for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
            book[a][s][l] <= sel[l];
          end
        end
      end
    end
  end

  //--------------------------------------------------------------------------
  // Top-of-book outputs: driven straight from the registers, no handshake and
  // no read latency (FS-6).
  //--------------------------------------------------------------------------
  always_comb begin
    for (int unsigned a = 0; a < NUM_ASSETS; a++) begin
      tob_bid_price[a] = tob[a][SIDE_BID].price;
      tob_bid_qty  [a] = tob[a][SIDE_BID].quantity;
      tob_ask_price[a] = tob[a][SIDE_ASK].price;
      tob_ask_qty  [a] = tob[a][SIDE_ASK].quantity;
      tob_timestamp[a] = tob_ts[a];
    end
  end

  //--------------------------------------------------------------------------
  // Depth read port (Alpha Engine). Synchronous read: data is valid one cycle
  // after depth_rd_en, matching a BRAM port B access.
  //--------------------------------------------------------------------------
  logic [ASSET_IDX_W-1:0] rd_asset;
  logic                   rd_side;
  logic [LEVEL_IDX_W-1:0] rd_level;

  assign {rd_asset, rd_side, rd_level} = depth_rd_addr;

  always_ff @(posedge core_clk) begin
    if (depth_rd_en) begin
      depth_rd_data <= book[rd_asset][rd_side][rd_level];
    end
  end

endmodule
