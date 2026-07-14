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
//   1 (decode) + 1 (search) + NUM_LEVELS (shift) + 1 (commit) = 19 cycles
// versus 168 cycles of minimum packet inter-arrival, so s_axis_tready never
// needs to de-assert.
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
  // Latched update fields (captured on accept, held for the whole transaction)
  //--------------------------------------------------------------------------
  logic [ASSET_IDX_W-1:0] tgt_asset;
  logic                   tgt_side;
  logic [PRICE_W-1:0]     tgt_price;
  logic [QTY_W-1:0]       tgt_qty;
  msg_type_e              tgt_type;
  logic [TIMESTAMP_W-1:0] tgt_ts;

  //--------------------------------------------------------------------------
  // Search results (registered out of the SEARCH state)
  //--------------------------------------------------------------------------
  logic [LEVEL_IDX_W-1:0] hit_idx;    // level index the update targets
  logic                   hit_exact;  // price matches an existing level
  logic                   hit_valid;  // a level was found / insertion point valid

  //--------------------------------------------------------------------------
  // Shift bookkeeping
  //--------------------------------------------------------------------------
  logic [LEVEL_IDX_W:0]   shift_idx;  // one extra bit: counts to NUM_LEVELS

  //--------------------------------------------------------------------------
  // FSM
  //--------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    DECODE,
    SEARCH,
    SHIFT,
    WRITE_COMMIT
  } book_state_e;

  book_state_e state;

  //--------------------------------------------------------------------------
  // SEARCH: parallel comparator bank.
  //
  // Scans all NUM_LEVELS of the target side in one cycle and reports:
  //   - the index of an exact price match (modify / decrement in place), or
  //   - the index where a new price should be inserted to preserve ordering.
  //
  // Bids are sorted descending (highest first), asks ascending (lowest first),
  // so the "better price" comparison flips with the side.
  //--------------------------------------------------------------------------
  logic [LEVEL_IDX_W-1:0] srch_idx;
  logic                   srch_exact;
  logic                   srch_valid;

  always_comb begin
    srch_idx   = '0;
    srch_exact = 1'b0;
    srch_valid = 1'b0;

    for (int unsigned l = 0; l < NUM_LEVELS; l++) begin
      automatic level_t lvl = book[tgt_asset][tgt_side][l];

      // Exact price match on an occupied level -> modify in place.
      if (!srch_valid && lvl.quantity != '0 && lvl.price == tgt_price) begin
        srch_idx   = LEVEL_IDX_W'(l);
        srch_exact = 1'b1;
        srch_valid = 1'b1;
      end
      // Empty slot, or a level whose price is worse than ours -> insert here.
      else if (!srch_valid &&
               (lvl.quantity == '0 ||
                (tgt_side == SIDE_BID ? tgt_price > lvl.price
                                      : tgt_price < lvl.price))) begin
        srch_idx   = LEVEL_IDX_W'(l);
        srch_exact = 1'b0;
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
        IDLE: begin
          if (s_axis_tvalid) begin
            tgt_asset <= upd.symbol_id[ASSET_IDX_W-1:0];
            tgt_side  <= upd.side;
            tgt_price <= upd.price;
            tgt_qty   <= upd.quantity;
            tgt_type  <= upd.msg_type;
            tgt_ts    <= upd.timestamp;
            state     <= DECODE;
          end
        end

        //--------------------------------------------------------------------
        // Select the target book and mark it busy for the duration.
        //--------------------------------------------------------------------
        DECODE: begin
          book_busy[tgt_asset] <= 1'b1;
          state                <= SEARCH;
        end

        //--------------------------------------------------------------------
        // Register the parallel comparator result.
        //--------------------------------------------------------------------
        SEARCH: begin
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
            state <= WRITE_COMMIT;
          end else if (is_removal) begin
            // Shift up: dst = hit_idx + shift_idx, src = dst + 1
            dst_i = {1'b0, hit_idx} + shift_idx;
            src_i = dst_i + 1'b1;

            if (src_i < (LEVEL_IDX_W+1)'(NUM_LEVELS)) begin
              book[tgt_asset][tgt_side][dst_i[LEVEL_IDX_W-1:0]] <=
                book[tgt_asset][tgt_side][src_i[LEVEL_IDX_W-1:0]];
              shift_idx <= shift_idx + 1'b1;
            end else begin
              // Tail slot is now vacant.
              book[tgt_asset][tgt_side][NUM_LEVELS-1] <= '0;
              state <= WRITE_COMMIT;
            end
          end else begin
            // Insertion: shift down from the tail toward hit_idx, so we never
            // overwrite a level we still need.
            dst_i = (LEVEL_IDX_W+1)'(NUM_LEVELS-1) - shift_idx;
            src_i = dst_i - 1'b1;

            if (dst_i > {1'b0, hit_idx}) begin
              book[tgt_asset][tgt_side][dst_i[LEVEL_IDX_W-1:0]] <=
                book[tgt_asset][tgt_side][src_i[LEVEL_IDX_W-1:0]];
              shift_idx <= shift_idx + 1'b1;
            end else begin
              state <= WRITE_COMMIT;
            end
          end
        end

        //--------------------------------------------------------------------
        // WRITE_COMMIT: write the affected level, then commit the ToB
        // registers ATOMICALLY in the same cycle. tob_updated pulses only if
        // the top of book actually changed -- a deep-level update must not
        // wake the Alpha Engine and burn its FS-7 budget for nothing.
        //--------------------------------------------------------------------
        WRITE_COMMIT: begin
          automatic level_t new_lvl;
          automatic level_t new_tob;

          new_lvl.price    = tgt_price;
          new_lvl.quantity = tgt_qty;

          unique case (tgt_type)
            MSG_ADD: begin
              if (hit_exact) begin
                // Aggregate into the existing level.
                new_lvl.quantity = book[tgt_asset][tgt_side][hit_idx].quantity
                                 + tgt_qty;
              end
              book[tgt_asset][tgt_side][hit_idx] <= new_lvl;
            end

            MSG_MODIFY: begin
              // Quantity-only change at an existing price.
              book[tgt_asset][tgt_side][hit_idx] <= new_lvl;
            end

            MSG_DELETE: begin
              // The level was already removed by the shift; nothing to write.
            end

            default: ;
          endcase

          // The new top of book is level 0 after this update. For a delete the
          // shift has already moved the successor into place; for an insert at
          // index 0 the new level is what we are writing this cycle.
          if (tgt_type != MSG_DELETE && hit_idx == '0) begin
            new_tob = new_lvl;
          end else begin
            new_tob = book[tgt_asset][tgt_side][0];
          end

          if (new_tob != tob[tgt_asset][tgt_side]) begin
            tob[tgt_asset][tgt_side] <= new_tob;
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
