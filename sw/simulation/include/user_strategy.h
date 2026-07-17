#pragma once

#include "orderbook.h"
#include <optional>
#include <cstdint>

class Strategy {
public:
    Strategy();

    // The exact signature required by your OfflineSimulation
    std::optional<Order> on_market_update(uint64_t tick_timestamp_ns, const L1State& current_l1);

private:
    uint64_t next_strategy_order_id;
    double theoretical_fair_value;

};  