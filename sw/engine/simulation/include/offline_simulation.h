#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include "orderbook.h"
#include "user_strategy.h" // Concrete class inclusion

// ---------------------------------------------------------
// Binary market-data record
// ---------------------------------------------------------
// Mirrors the Python pre-processing layout produced with struct format
// "<QcQcdd" (little-endian, packed, no alignment padding).
//   timestamp_ns : uint64
//   message_type : char   ('A' add, 'C' cancel)
//   order_id     : uint64
//   side         : char   ('B' bid, 'S' ask)
//   price        : double
//   size         : double
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
};

struct PnLSnapshot {
    uint64_t timestamp_ns;
    double   realized_pnl;
    double   unrealized_pnl;
    double   position_size;
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
