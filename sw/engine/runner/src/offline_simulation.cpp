#include "feed.h"
#include "offline_simulation.h"
#include <iostream>
#include <cstdio>
#include <vector>
#include <algorithm>
#include <chrono>


OfflineSimulation::OfflineSimulation(const std::string& file_path)
    : mbo_file_path_(file_path) {
    // The strategy only looks at the top of book, so one level is enough.
    scheduler_.set_book_depth(1);
    scheduler_.add_participant(PLAYER, player_);
}


SimulationResult OfflineSimulation::run() {
    SimulationResult result;

    // Sample the PnL curve once per simulated second.
    constexpr uint64_t SAMPLE_INTERVAL_NS = 1'000'000'000ULL;
    // Number of MBO records to pull off disk per fread call.
    constexpr size_t READ_CHUNK = 8192;
    // Cap on how many samples a single gap-backfill can emit (~1 day at 1Hz,
    // generously covering any real trading session). Without this, a
    // corrupted or garbage record timestamp turns the backfill below into an
    // effectively unbounded loop instead of just failing to sample a bogus
    // span.
    constexpr uint64_t MAX_BACKFILL_SAMPLES = 24ULL * 60 * 60;

    // Open the packed binary MBO stream.
    FILE* fp = std::fopen(mbo_file_path_.c_str(), "rb");
    if (fp == nullptr) {
        std::cerr << "CRITICAL: Failed to open MBO binary stream at " << mbo_file_path_ << std::endl;
        return result;
    }

    // Pre-allocate the telemetry vectors so the hot loop never reallocates.
    // Estimate capacity from the file size (bytes / record size).
    std::fseek(fp, 0, SEEK_END);
    const long file_bytes = std::ftell(fp);
    std::fseek(fp, 0, SEEK_SET);
    const size_t est_records = (file_bytes > 0)
                                   ? static_cast<size_t>(file_bytes) / sizeof(MBORecord)
                                   : 0;
    // Trades are a fraction of events; PnL samples are far sparser. Reserve
    // generously to guarantee no reallocation on the hot path.
    result.trades.reserve(est_records / 4 + 1);
    result.pnl_curve.reserve(est_records / 1024 + 16);

    auto start_sim_time = std::chrono::high_resolution_clock::now();

    const Account& account = scheduler_.account(PLAYER);

    // --- Buffered reader over the MBO file ---
    std::vector<MBORecord> buffer(READ_CHUNK);
    size_t buffered = 0; // records currently in buffer
    size_t cursor   = 0; // next one to hand out

    // The next file record, held back until the scheduler has caught up to it.
    MBORecord next_rec{};
    bool have_next_rec = false;
    auto read_next_record = [&]() {
        if (cursor == buffered) {
            buffered = std::fread(buffer.data(), sizeof(MBORecord), READ_CHUNK, fp);
            cursor = 0;
        }
        have_next_rec = cursor < buffered;
        if (have_next_rec) next_rec = buffer[cursor++];
    };

    uint64_t next_sample_ns = 0; // fires on the first record, then every second
    bool     have_prev_state = false;
    L1State  prev_l1_state{};    // top of book right after the latest feed record
    uint64_t last_tick_ns = 0;   // time of that record
    size_t   fills_seen = 0;     // how much of the account's fill history is logged

    auto mid_of = [](const L1State& l1) {
        return (l1.best_bid > 0.0 && l1.best_ask > 0.0) ? 0.5 * (l1.best_bid + l1.best_ask) : 0.0;
    };

    auto push_sample = [&](uint64_t ts_ns) {
        result.pnl_curve.push_back(PnLSnapshot{
            ts_ns,
            account.realized_pnl(),
            account.unrealized_pnl(mid_of(prev_l1_state)),
            account.position(),
            result.trades.size()});
    };

    // Samples the PnL curve once per simulated second, at the end of a tick
    // (after everything the tick set in motion "now" has been processed).
    auto sample_tick = [&]() {
        if (!have_prev_state || last_tick_ns < next_sample_ns) return;
        push_sample(last_tick_ns);
        next_sample_ns = last_tick_ns + SAMPLE_INTERVAL_NS;
    };

    read_next_record();
    while (true) {
        // The queue goes first whenever it has something due at or before the
        // next record: deliveries and orders already in flight outrank a new
        // record that carries the same timestamp.
        const bool queue_first =
            !scheduler_.empty() && (!have_next_rec || scheduler_.next_time() <= next_rec.timestamp_ns);

        if (!queue_first) {
            if (!have_next_rec) break; // file finished and nothing left in flight

            // --- Start a new tick: put the next feed record on the queue ---
            sample_tick(); // close out the previous tick first
            const uint64_t tick_ns = std::max(next_rec.timestamp_ns, scheduler_.now());

            // Backfill flat samples across any gap since the last record.
            // A stoppage/halt leaves a stretch with no MBO records at all, and
            // sampling only happens on ticks -- so a gap would produce zero
            // samples and the chart would interpolate a straight line across
            // it. Emit a real, held-PnL sample at every second boundary the
            // gap crosses, using the book state going into the gap.
            if (have_prev_state) {
                uint64_t backfilled = 0;
                while (next_sample_ns < tick_ns && backfilled < MAX_BACKFILL_SAMPLES) {
                    push_sample(next_sample_ns);
                    next_sample_ns += SAMPLE_INTERVAL_NS;
                    ++backfilled;
                }
                // Gap bigger than the cap (e.g. a corrupted/garbage timestamp):
                // stop backfilling and jump straight to this record's boundary.
                if (next_sample_ns < tick_ns) {
                    next_sample_ns = tick_ns;
                }
            } else {
                next_sample_ns = tick_ns;
            }

            Action action = Action::wake(); // unknown record types still tick the strategy
            if (next_rec.message_type == 'A') {
                action = Action::add(Order{next_rec.order_id, next_rec.price, next_rec.size,
                                           next_rec.side, false});
            } else if (next_rec.message_type == 'X') {
                // ITCH Order Cancel: takes size shares off the order (all of
                // it when size covers what is left).
                action = Action::reduce(next_rec.order_id, next_rec.size, next_rec.side);
            }
            scheduler_.schedule(tick_ns, MARKET_FEED, action);
            read_next_record();
            continue;
        }

        // --- Process the earliest thing on the queue ---
        // This is where everything happens: the scheduler applies book actions,
        // updates the player's account, and calls the strategy (through the
        // StrategyParticipant adapter) when its market data arrives.
        const StepResult step = scheduler_.step();
        if (step.kind != StepKind::BookAction) continue;

        if (step.participant == MARKET_FEED) {
            prev_l1_state   = scheduler_.book().get_l1_state();
            have_prev_state = true;
            last_tick_ns    = step.time_ns;
        }

        // Log any executions this action gave the player.
        const std::vector<FillRecord>& fills = account.fills();
        if (fills.size() > fills_seen) {
            if (step.participant == PLAYER) {
                // The player's own order: one line for the whole order, at
                // its volume-weighted average price.
                const FillReport fill = fill_report(step.events);
                result.trades.push_back(TradeRecord{
                    step.time_ns, step.action.order.side, fill.avg_fill_price, fill.filled_size});
            } else {
                // Someone else traded into the player's resting orders.
                for (size_t i = fills_seen; i < fills.size(); ++i) {
                    result.trades.push_back(TradeRecord{
                        fills[i].timestamp_ns, fills[i].side, fills[i].price, fills[i].size});
                }
            }
            fills_seen = fills.size();
        }
    }
    sample_tick(); // the last tick

    std::fclose(fp);

    auto end_sim_time = std::chrono::high_resolution_clock::now();
    result.compute_time_us =
        std::chrono::duration_cast<std::chrono::microseconds>(end_sim_time - start_sim_time).count();
    result.total_trades = result.trades.size();
    result.events = scheduler_.event_log();
    result.book_snapshots = scheduler_.snapshots();

    return result;
}
