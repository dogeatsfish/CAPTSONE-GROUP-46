#include "user_strategy.h"
#include <cmath>

std::optional<Order> Strategy::on_market_update(const L1State& current_l1) {
    // 1. Ensure the order book has a two-sided quote before making decisions.
    if (current_l1.best_ask == 0.0 || current_l1.best_bid == 0.0) {
        return std::nullopt;
    }

    const double mid = (current_l1.best_bid + current_l1.best_ask) / 2.0;
    constexpr double ALPHA           = 0.05;
    constexpr double ENTRY_THRESHOLD = 0.001;
    constexpr double SKEW_FRAC       = 0.001;
    constexpr double TRADE_SIZE      = 100.0;
    constexpr double MAX_POSITION    = 500.0;
    if (!have_mean) {
        mean_mid  = mid;
        have_mean = true;
        return std::nullopt;
    }

    mean_mid = ALPHA * mid + (1.0 - ALPHA) * mean_mid;
    const double inv_fraction  = position_size / MAX_POSITION;      // -1..1 at the caps
    const double skew          = mean_mid * SKEW_FRAC * inv_fraction;
    const double reservation   = mean_mid - skew;
    const double threshold     = mean_mid * ENTRY_THRESHOLD;

    std::optional<Order> order_to_send = std::nullopt;
    if (current_l1.best_ask < reservation - threshold && position_size < MAX_POSITION) {
        Order buy;
        buy.order_id     = next_strategy_order_id++;
        buy.price        = current_l1.best_ask; // lift the offer to get filled
        buy.size         = TRADE_SIZE;
        buy.side         = 'B';
        buy.is_synthetic = true;
        order_to_send    = buy;
    } else if (current_l1.best_bid > reservation + threshold && position_size > -MAX_POSITION) {
        Order sell;
        sell.order_id     = next_strategy_order_id++;
        sell.price        = current_l1.best_bid; // hit the bid to get filled
        sell.size         = TRADE_SIZE;
        sell.side         = 'S';
        sell.is_synthetic = true;
        order_to_send     = sell;
    }

    last_bid    = current_l1.best_bid;
    last_ask    = current_l1.best_ask;
    last_spread = current_l1.best_ask - current_l1.best_bid;
    have_last_l1 = true;

    return order_to_send;
}
