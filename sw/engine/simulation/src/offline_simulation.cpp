#include "offline_simulation.h"
#include <iostream>
#include <cstdio>
#include <vector>
#include <chrono>


OfflineSimulation::OfflineSimulation(const std::string& file_path) 
    : mbo_file_path(file_path) {}


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
    FILE* fp = std::fopen(mbo_file_path.c_str(), "rb");
    if (fp == nullptr) {
        std::cerr << "CRITICAL: Failed to open MBO binary stream at " << mbo_file_path << std::endl;
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

    std::vector<MBORecord> buffer(READ_CHUNK);
    uint64_t next_sample_ns = 0; // fires on the first record, then every second
    bool have_prev_state = false;
    L1State prev_l1_state{};

    size_t n;
    while ((n = std::fread(buffer.data(), sizeof(MBORecord), READ_CHUNK, fp)) > 0) {
        for (size_t i = 0; i < n; ++i) {
            const MBORecord& rec = buffer[i];
            const uint64_t tick_timestamp_ns = rec.timestamp_ns;

            // --- 0. Backfill flat samples across any gap since the last record ---
            // A stoppage/halt leaves a stretch with no MBO records at all, and
            // sampling used to happen only inside this per-record loop -- so a
            // gap produced zero samples and the chart just interpolated a
            // straight line across it. Emit a real, held-PnL sample at every
            // second boundary the gap crosses, using the book state as it was
            // going into the gap, so the curve reflects the stoppage instead
            // of silently skipping over it.
            if (have_prev_state) {
                const double mark = (prev_l1_state.best_bid > 0.0 && prev_l1_state.best_ask > 0.0)
                                        ? 0.5 * (prev_l1_state.best_bid + prev_l1_state.best_ask)
                                        : 0.0;
                uint64_t backfilled = 0;
                while (next_sample_ns < tick_timestamp_ns && backfilled < MAX_BACKFILL_SAMPLES) {
                    result.pnl_curve.push_back(PnLSnapshot{
                        next_sample_ns,
                        strategy.get_realized_pnl(),
                        strategy.get_unrealized_pnl(mark),
                        strategy.get_position(),
                        result.trades.size()});
                    next_sample_ns += SAMPLE_INTERVAL_NS;
                    ++backfilled;
                }
                // Gap bigger than the cap (e.g. a corrupted/garbage
                // timestamp): stop backfilling and jump straight to this
                // record's boundary instead of continuing to loop.
                if (next_sample_ns < tick_timestamp_ns) {
                    next_sample_ns = tick_timestamp_ns;
                }
            } else {
                next_sample_ns = tick_timestamp_ns;
            }

            // --- 1. Process the market stream event ---
            if (rec.message_type == 'A') {
                Order mkt_order{rec.order_id, rec.price, rec.size, rec.side, false};
                matching_engine.process_add(mkt_order, tick_timestamp_ns);
            } else if (rec.message_type == 'X') {
                matching_engine.process_cancel(rec.order_id, rec.side);
            }

            // --- 2. Extract the updated L1 state ---
            const L1State current_l1 = matching_engine.get_l1_state();
            prev_l1_state = current_l1;
            have_prev_state = true;

            // --- 3. Inline strategy call (resolved directly, no vtable) ---
            std::optional<Order> user_order = strategy.on_market_update(current_l1);

            // --- 4. Process the user order if triggered ---
            if (user_order.has_value()) {
                Order& uo = user_order.value();

                // Feed the order into the engine and capture what actually filled.
                const FillReport fill = matching_engine.process_add(uo, tick_timestamp_ns);

                // Only update PnL/telemetry for the volume that truly executed;
                // any unfilled remainder now rests passively in the book.
                if (fill.filled_size > 0.0) {
                    strategy.on_fill(uo.side, fill.avg_fill_price, fill.filled_size);

                    result.trades.push_back(TradeRecord{
                        tick_timestamp_ns, uo.side, fill.avg_fill_price, fill.filled_size});
                }
            }

            // --- 5. Sample the PnL curve once per simulated second ---
            if (tick_timestamp_ns >= next_sample_ns) {
                const double mark = (current_l1.best_bid > 0.0 && current_l1.best_ask > 0.0)
                                        ? 0.5 * (current_l1.best_bid + current_l1.best_ask)
                                        : 0.0;
                result.pnl_curve.push_back(PnLSnapshot{
                    tick_timestamp_ns,
                    strategy.get_realized_pnl(),
                    strategy.get_unrealized_pnl(mark),
                    strategy.get_position(),
                    result.trades.size()});
                next_sample_ns = tick_timestamp_ns + SAMPLE_INTERVAL_NS;
            }
        }
    }

    std::fclose(fp);

    auto end_sim_time = std::chrono::high_resolution_clock::now();
    result.compute_time_us =
        std::chrono::duration_cast<std::chrono::microseconds>(end_sim_time - start_sim_time).count();
    result.total_trades = result.trades.size();

    return result;
}
