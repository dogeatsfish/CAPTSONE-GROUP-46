#pragma once

#include "orderbook.h"
#include <optional>
#include <cstdint>

class Strategy {
public:
    Strategy();

    // Called on every market update; may return an order to send.
    std::optional<Order> on_market_update(const L1State& current_l1);

    // Notify the strategy that one of its orders executed so it can update
    // its position and realized PnL (weighted-average-cost accounting).
    void on_fill(char side, double price, double size);

    // --- Telemetry accessors (queried by the simulation sampler) ---
    double get_position() const { return position_size; }
    double get_realized_pnl() const { return realized_pnl; }
    // Unrealized PnL marked against the supplied reference price (e.g. L1 mid).
    double get_unrealized_pnl(double mark_price) const;

private:
    uint64_t next_strategy_order_id;

    // Position / PnL state
    double position_size;    // signed: positive = long, negative = short
    double avg_entry_price;  // weighted-average cost of the open position
    double realized_pnl;     // cumulative realized PnL
};
