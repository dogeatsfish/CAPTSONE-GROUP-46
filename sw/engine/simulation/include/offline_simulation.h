#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include "orderbook.h"
#include "scheduler.h"
#include "user_strategy.h" // Concrete class inclusion
#include "strategy_participant.h"

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

struct TradeRecord {
    uint64_t timestamp_ns;
    char     side;   // 'B' / 'S'
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
    uint64_t total_trades   = 0;
    int64_t  compute_time_us = 0; // microseconds

    // Filled only when asked for (see OfflineSimulation::set_record_events /
    // set_snapshot_interval); empty otherwise.
    BookEvents                events;         // every order-lifecycle event, in seq order
    std::vector<BookSnapshot> book_snapshots; // periodic full copies of the book
};

class OfflineSimulation {
private:
    std::string mbo_file_path_;
    Scheduler scheduler_;       // Event queue; owns the order book, accounts and clock
    Strategy strategy_;         // The player's compiled on_market_update
    StrategyParticipant player_{strategy_}; // ...taking part as a Participant

public:
    // Who is who on the scheduler in an offline run.
    static constexpr ParticipantId MARKET_FEED = 0; // the recorded data file
    static constexpr ParticipantId PLAYER      = 1; // the strategy

    // Constructor
    OfflineSimulation(const std::string& file_path);

    OfflineSimulation(const OfflineSimulation&) = delete; // scheduler points at `player`
    OfflineSimulation& operator=(const OfflineSimulation&) = delete;

    // Optional, before run(). Defaults are zero latency and no fees.
    void set_player_latency(const LatencyProfile& latency) {
        scheduler_.set_latency(PLAYER, latency);
    }
    void set_fees(const FeeSchedule& fees) { scheduler_.set_fees(fees); }
    // Keep the full event log / a book snapshot every interval_ns of sim time
    // (0 = off) in the SimulationResult. Both off by default: they cost memory.
    void set_record_events(bool on) { scheduler_.record_events(on); }
    void set_snapshot_interval(uint64_t interval_ns) {
        scheduler_.set_snapshot_interval(interval_ns);
    }

    // The player's account (position, PnL, fees, fill history) after run().
    const Account& player_account() const { return scheduler_.account(PLAYER); }

    // Main execution loop. Returns the collected telemetry payload.
    SimulationResult run();
};
