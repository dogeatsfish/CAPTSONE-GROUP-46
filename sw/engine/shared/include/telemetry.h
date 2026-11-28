#pragma once

#include <cstdint>
#include <vector>

#include "common.h" // BookEvents, BookSnapshot

// What a simulation run hands back. Offline and online produce the same
// payload from entirely different machinery, the service serializes it to
// JSON, and the strategy-compile job writes it to result.json -- so it lives
// here rather than inside either runner.

struct TradeRecord {
    uint64_t timestamp_ns;
    char     side; // 'B' / 'S'
    double   price;
    double   size;
    uint64_t decision_latency_ns = 0;
};

struct PnLSnapshot {
    uint64_t timestamp_ns;
    double   realized_pnl;
    double   unrealized_pnl;
    double   position_size;
    uint64_t trade_count = 0;
};

struct SimulationResult {
    std::vector<TradeRecord> trades;
    std::vector<PnLSnapshot> pnl_curve;
    uint64_t total_trades    = 0;
    int64_t  compute_time_us = 0; // microseconds

    // Filled only when asked for (see OfflineSimulation::set_record_events /
    // set_snapshot_interval); empty otherwise.
    BookEvents                events;         // every order-lifecycle event, in seq order
    std::vector<BookSnapshot> book_snapshots; // periodic full copies of the book
};
