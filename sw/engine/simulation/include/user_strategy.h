#pragma once

#include "orderbook.h"
#include <optional>
#include <cstdint>

// The player's strategy as written in the Strategy Compiler page: one function
// body, on_market_update, that looks at the top of book and may return an
// order. It is plugged into the simulation through StrategyParticipant (see
// strategy_participant.h).
//
// PnL bookkeeping does NOT live here any more -- the participant's Account
// owns it. position_size / avg_entry_price / realized_pnl below are read-only
// copies refreshed from the Account before every on_market_update call, kept
// so existing strategy bodies that read them still compile and behave.
class Strategy {
public:
    Strategy();

    std::optional<Order> on_market_update(const L1State& current_l1);

    // Refreshes the copies of the account state that strategy bodies read.
    void sync_account(double position, double entry_price, double realized);

private:
    uint64_t next_strategy_order_id;

    double position_size;    // signed: positive = long, negative = short
    double avg_entry_price;  // weighted-average cost of the open position
    double realized_pnl;     // cumulative realized PnL
    bool   have_last_l1;     // false until the first two-sided quote is seen
    double last_bid;
    double last_ask;
    double last_spread;
    // Mean-reversion state: exponential moving average of the L1 mid price,
    // used as the "fair value" the strategy expects price to revert toward.
    bool   have_mean;        // false until the EMA has been seeded
    double mean_mid;         // EMA of the mid price ((best_bid + best_ask) / 2)
};
