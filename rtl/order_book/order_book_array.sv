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
//   1 (decode) + 2 (search) + NUM_LEVELS (shift) + 2 (commit) = 21 cycles
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
  //--------------------------------------------------------------------------
  level_t book [NUM_ASSETS][2][NUM_LEVELS];

  // Registered top-of-book cache. Mirrors book[asset][side][0], committed
  // atomically in the same cycle as the BRAM write so the Alpha Engine can
  // never observe a torn top-of-book.
  level_t                tob      [NUM_ASSETS][2];
  logic [TIMESTAMP_W-1:0] tob_ts  [NUM_ASSETS];

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
  // MAX_FANOUT (TIMING): tgt_asset/tgt_side still steer the book slice mux in
  // LOAD and the write-enable decode in STORE (~10k flops), so they remain
  // high-fanout and are replicated into regional copies. hit_idx/shift_idx now
  // address only the 16-entry `sel`, so they no longer need replication.
  //--------------------------------------------------------------------------
  (* max_fanout = 512 *) logic [ASSET_IDX_W-1:0] tgt_asset;
  (* max_fanout = 512 *) logic                   tgt_side;
  logic [PRICE_W-1:0]     tgt_price;
  logic [QTY_W-1:0]       tgt_qty;
  msg_type_e              tgt_type;
  logic [TIMESTAMP_W-1:0] tgt_ts;

  //--------------------------------------------------------------------------
  // Search results (registered out of the search stages)
  //--------------------------------------------------------------------------
  logic [LEVEL_IDX_W-1:0] hit_idx;    // level the update targets
  logic                   hit_exact;  // price matches an existing level
  logic                   hit_valid;  // a level was found / insertion point valid

  //--------------------------------------------------------------------------
  // Shift bookkeeping
  //--------------------------------------------------------------------------
  logic [LEVEL_IDX_W:0]   shift_idx;  // one extra bit: counts to NUM_LEVELS

  //--------------------------------------------------------------------------
  // Commit pipeline registers (TIMING)
  //   hit_qty    -- quantity of the exact-match level, pre-read in SHIFT's
  //                 pass-through cycle so WRITE_COMMIT's aggregate-add starts
  //                 from a flop rather than a variable-indexed array mux.
  //   commit_tob -- the ToB candidate, registered in WRITE_COMMIT so the
  //                 64-bit "did the top change" compare and the ToB registers'
  //                 clock-enables live in their own cycle (STORE).
  //--------------------------------------------------------------------------
  logic [QTY_W-1:0] hit_qty;
  level_t           commit_tob;

  //--------------------------------------------------------------------------
  // FSM
  //--------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    LOAD,           // copy the active book slice into `sel`, mark book busy
    SEARCH_CMP,     // stage 1: register the per-level comparator results
    SEARCH_ENC,     // stage 2: priority-encode the registered results
    SHIFT,
    WRITE_COMMIT,   // write the level into `sel`, register the ToB candidate
    STORE           // write `sel` back to the book, commit ToB atomically
  } book_state_e;

  (* max_fanout = 512 *) book_state_e state;

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

  always_comb begin
    for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
      automatic level_t lvl = sel[l];

      cmp_exact_next[l]  = (lvl.quantity != '0) && (lvl.price == tgt_price);
      cmp_insert_next[l] = (lvl.quantity == '0) ||
                           (tgt_side == SIDE_BID ? tgt_price > lvl.price
                                                 : tgt_price < lvl.price);
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
  //--------------------------------------------------------------------------
  logic needs_shift;
  logic is_removal;

  always_comb begin
    is_removal  = (tgt_type == MSG_DELETE);
    needs_shift = (tgt_type == MSG_ADD && !hit_exact) || is_removal;
  end

  //--------------------------------------------------------------------------
  // Main sequential process
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      state       <= IDLE;
      book_busy   <= '0;
      tob_updated <= '0;
      shift_idx   <= '0;

      // Reset the transaction control registers too. Functionally they are
      // don't-care until loaded, but giving them a reset makes synthesis infer
      // plain resettable flops (FDCE) rather than no-reset flops it is free to
      // implement with logic-driven async set/reset -- the round-2 max_fanout
      // build produced exactly those (self-preset FDPE on hit_idx/tgt_asset),
      // which then failed recovery. Clean async-clear-from-core_rst_n only.
      tgt_asset <= '0;
      tgt_side  <= '0;
      hit_idx   <= '0;
      hit_exact <= 1'b0;
      hit_valid <= 1'b0;

      for (int unsigned a = 0; a < NUM_ASSETS; a++) begin
        tob_ts[a] <= '0;
        for (int unsigned s = 0; s < 2; s++) begin
          tob[a][s] <= '0;
          for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
            book[a][s][l] <= '0;
          end
        end
      end

    end else begin
      // tob_updated is a single-cycle strobe.
      tob_updated <= '0;

      unique case (state)

        //--------------------------------------------------------------------
        // symbol_id is 8 bits wide but only NUM_ASSETS books exist, and
        // ASSET_IDX_W rounds UP to 3 bits. Truncating to symbol_id[2:0] would
        // let locates 5..7 index past the end of the book array. The parser
        // takes symbol_id straight from the ITCH Stock Locate field, so a feed
        // carrying an unexpected locate must be discarded HERE, in the block
        // that owns the array -- not silently aliased onto a real asset.
        IDLE: begin
          if (s_axis_tvalid && upd.symbol_id < SYMBOL_W'(NUM_ASSETS)) begin
            tgt_asset <= upd.symbol_id[ASSET_IDX_W-1:0];
            tgt_side  <= upd.side;
            tgt_price <= upd.price;
            tgt_qty   <= upd.quantity;
            tgt_type  <= upd.msg_type;
            tgt_ts    <= upd.timestamp;
            state     <= LOAD;
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
          book_busy[tgt_asset] <= 1'b1;
          state                <= SEARCH_CMP;
        end

        //--------------------------------------------------------------------
        // Register the per-level comparator results (search stage 1).
        //--------------------------------------------------------------------
        SEARCH_CMP: begin
          cmp_exact  <= cmp_exact_next;
          cmp_insert <= cmp_insert_next;
          state      <= SEARCH_ENC;
        end

        //--------------------------------------------------------------------
        // Priority-encode the registered results (search stage 2).
        //--------------------------------------------------------------------
        SEARCH_ENC: begin
          hit_idx   <= srch_idx;
          hit_exact <= srch_exact;
          hit_valid <= srch_valid;
          shift_idx <= '0;

          // A price worse than every tracked level, on a full book, falls
          // outside the maintained depth window and is simply dropped.
          if (!srch_valid) begin
            book_busy[tgt_asset] <= 1'b0;
            state                <= IDLE;
          end else begin
            state <= SHIFT;
          end
        end

        //--------------------------------------------------------------------
        // SHIFT: keep each side price-ordered.
        //   insert -> slide levels [hit_idx .. N-2] down one slot
        //   remove -> slide levels [hit_idx+1 .. N-1] up one slot
        // A modify at an existing price skips this entirely.
        //--------------------------------------------------------------------
        SHIFT: begin
          automatic logic [LEVEL_IDX_W:0] src_i;
          automatic logic [LEVEL_IDX_W:0] dst_i;

          if (!needs_shift) begin
            // Pass-through cycle (modify, or add aggregating into an existing
            // level): pre-read the hit level's quantity into a register so the
            // aggregate-add in WRITE_COMMIT starts from a flop. `sel` is local,
            // but keeping the pre-read preserves the exact cycle count.
            hit_qty <= sel[hit_idx].quantity;
            state   <= WRITE_COMMIT;
          end else if (is_removal) begin
            // Shift up: dst = hit_idx + shift_idx, src = dst + 1
            dst_i = {1'b0, hit_idx} + shift_idx;
            src_i = dst_i + 1'b1;

            if (src_i < (LEVEL_IDX_W+1)'(NUM_LEVELS)) begin
              sel[dst_i[LEVEL_IDX_W-1:0]] <= sel[src_i[LEVEL_IDX_W-1:0]];
              shift_idx <= shift_idx + 1'b1;
            end else begin
              // Tail slot is now vacant.
              sel[NUM_LEVELS-1] <= '0;
              state <= WRITE_COMMIT;
            end
          end else begin
            // Insertion: shift down from the tail toward hit_idx, so we never
            // overwrite a level we still need.
            dst_i = (LEVEL_IDX_W+1)'(NUM_LEVELS-1) - shift_idx;
            src_i = dst_i - 1'b1;

            if (dst_i > {1'b0, hit_idx}) begin
              sel[dst_i[LEVEL_IDX_W-1:0]] <= sel[src_i[LEVEL_IDX_W-1:0]];
              shift_idx <= shift_idx + 1'b1;
            end else begin
              state <= WRITE_COMMIT;
            end
          end
        end

        //--------------------------------------------------------------------
        // WRITE_COMMIT: write the affected level into the local slice and
        // REGISTER the ToB candidate. The "did the top change" compare and the
        // ToB commit moved to STORE so the level-mux/adder and the 64-bit
        // compare + ToB clock-enables are two shallow cycles instead of one
        // deep one (TIMING: this was the -6.7 ns critical path).
        //--------------------------------------------------------------------
        WRITE_COMMIT: begin
          automatic level_t new_lvl;

          new_lvl.price    = tgt_price;
          new_lvl.quantity = tgt_qty;

          unique case (tgt_type)
            MSG_ADD: begin
              if (hit_exact) begin
                // Aggregate into the existing level (hit_qty was pre-read into
                // a register during SHIFT's pass-through cycle).
                new_lvl.quantity = hit_qty + tgt_qty;
              end
              sel[hit_idx] <= new_lvl;
            end

            MSG_MODIFY: begin
              // Quantity-only change at an existing price.
              sel[hit_idx] <= new_lvl;
            end

            MSG_DELETE: begin
              // The level was already removed by the shift; nothing to write.
            end

            default: ;
          endcase

          // The new top of book is level 0 after this update. For a delete the
          // shift has already moved the successor into place (sel[0] is final
          // by now); for an add/modify at index 0 it is the level being written
          // this cycle.
          if (tgt_type != MSG_DELETE && hit_idx == '0) begin
            commit_tob <= new_lvl;
          end else begin
            commit_tob <= sel[0];
          end

          state <= STORE;
        end

        //--------------------------------------------------------------------
        // STORE: write the (now final) working slice back to the book, and
        // commit the ToB ATOMICALLY. This is the one die-spanning write of the
        // transaction (a demux per level -- data from local `sel`, clock-enable
        // gated by the asset/side match, no arithmetic). tob_updated pulses
        // only if the top of book actually changed -- a deep-level update must
        // not wake the Alpha Engine and burn its FS-7 budget for nothing.
        //--------------------------------------------------------------------
        STORE: begin
          for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
            book[tgt_asset][tgt_side][l] <= sel[l];
          end

          if (commit_tob != tob[tgt_asset][tgt_side]) begin
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
