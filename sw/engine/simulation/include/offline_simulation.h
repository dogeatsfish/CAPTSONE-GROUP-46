#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include "orderbook.h"
#include "user_strategy.h" // Concrete class inclusion

#pragma pack(push, 1)
struct MBORecord {
    uint64_t timestamp_ns;
    char     message_type;
    uint64_t order_id;
    char     side;
    double   price;
    double   size;
};
#pragma pack(pop)

// The on-disk record must be exactly 34 bytes to match the Python packer.
static_assert(sizeof(MBORecord) == 34, "MBORecord layout must match Python '<QcQcdd'");

// ---------------------------------------------------------
// Telemetry structs (results payload for the Pybind11 wrapper)
// ---------------------------------------------------------
struct TradeRecord {
    uint64_t timestamp_ns;
    char     side;   // 'B' / 'S'
    double   price;
    double   size;
    // Real wall-clock decision-to-fill latency in nanoseconds -- how long it
    // took *this software* to decide on and execute the trade, as opposed to
    // timestamp_ns which is simulated market time. 0 means "not measured":
    // only OnlineSimulation's local-strategy (loopback) path times this
    // today (see apply_market_event in online_simulation.cpp); offline runs
    // and real-hardware-originated fills leave it at the default. A genuine
    // measurement is never exactly 0ns, so 0 is an unambiguous sentinel.
    uint64_t decision_latency_ns = 0;
};

struct PnLSnapshot {
    uint64_t timestamp_ns;
    double   realized_pnl;
    double   unrealized_pnl;
    double   position_size;
    // Cumulative fill count at this sample, i.e. trades.size() at the time
    // of sampling -- lets a live consumer (the online SSE stream) derive a
    // running trades/s without waiting for the run to finish.
    uint64_t trade_count = 0;
};

struct SimulationResult {
    std::vector<TradeRecord> trades;
    std::vector<PnLSnapshot> pnl_curve;

    // Summary stats
    uint64_t total_trades   = 0;
    int64_t  compute_time_us = 0; // microseconds
};

class OfflineSimulation {
private:
    std::string mbo_file_path;
    OrderBook matching_engine; // The order book / matching engine used by the simulation
    Strategy strategy;         // Direct memory composition (no vtable)

public:
    // Constructor
    OfflineSimulation(const std::string& file_path);

    // Main execution loop. Returns the collected telemetry payload.
    SimulationResult run();
};
