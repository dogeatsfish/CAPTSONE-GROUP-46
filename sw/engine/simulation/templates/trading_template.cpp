// The user-editable half of Strategy: on_market_update only. The fixed
// machinery (constructor, on_fill, get_unrealized_pnl) lives in
// strategy_base.cpp -- see that file's header comment for why the split
// exists (the UI's software-compile path reuses this function's body
// against a template, and needs the rest to be a single source of truth).
#include "user_strategy.h"
#include <cmath>

std::optional<Order> Strategy::on_market_update(const L1State& current_l1) {
    // 1. Ensure the order book has a two-sided quote before making decisions.
    if (current_l1.best_ask == 0.0 || current_l1.best_bid == 0.0) {
        return std::nullopt;
    }

    const double mid = (current_l1.best_bid + current_l1.best_ask) / 2.0;

    // --- Skew tunables ---
    // ALPHA: EMA smoothing for the fair-value baseline.
    // ENTRY_THRESHOLD: minimum edge (as a fraction of fair value) required
    //   before we cross the spread, so we don't churn on noise. 0.001 == 0.1%.
    // SKEW_FRAC: how far (as a fraction of fair value) the reservation price
    //   is shifted when inventory is at the cap. This is the "skew": long
    //   inventory pushes the reservation price down (biases us to sell),
    //   short inventory pushes it up (biases us to buy), pulling the book
    //   back toward flat.
    // TRADE_SIZE: shares per marketable order.
    // MAX_POSITION: absolute inventory cap.
    constexpr double ALPHA           = 0.05;
    constexpr double ENTRY_THRESHOLD = 0.001;
    constexpr double SKEW_FRAC       = 0.001;
    constexpr double TRADE_SIZE      = 100.0;
    constexpr double MAX_POSITION    = 500.0;

    // 2. On the first two-sided quote we have no baseline yet: seed the EMA
    //    with the current mid and wait for the next tick.
    if (!have_mean) {
        mean_mid  = mid;
        have_mean = true;
        return std::nullopt;
    }

    // 3. Update the fair-value baseline toward the new mid.
    mean_mid = ALPHA * mid + (1.0 - ALPHA) * mean_mid;

    // 4. Skew the reservation price against current inventory. When long,
    //    (position_size > 0) the reservation price drops below fair value,
    //    making the resting ask look attractive to sell into and suppressing
    //    further buys; when short, it rises, biasing us to buy back. This is
    //    the inventory-skew mechanism that keeps the position mean-reverting
    //    toward flat.
    const double inv_fraction  = position_size / MAX_POSITION;      // -1..1 at the caps
    const double skew          = mean_mid * SKEW_FRAC * inv_fraction;
    const double reservation   = mean_mid - skew;
    const double threshold     = mean_mid * ENTRY_THRESHOLD;

    std::optional<Order> order_to_send = std::nullopt;

    // 5. Trade only when a quote sits beyond the skewed reservation price by
    //    at least the entry threshold. Cross the spread so the order fills.
    if (current_l1.best_ask < reservation - threshold && position_size < MAX_POSITION) {
        // The offer is cheap relative to our skewed fair value -> buy it.
        Order buy;
        buy.order_id     = next_strategy_order_id++;
        buy.price        = current_l1.best_ask; // lift the offer to get filled
        buy.size         = TRADE_SIZE;
        buy.side         = 'B';
        buy.is_synthetic = true;
        order_to_send    = buy;
    } else if (current_l1.best_bid > reservation + threshold && position_size > -MAX_POSITION) {
        // The bid is rich relative to our skewed fair value -> sell into it.
        Order sell;
        sell.order_id     = next_strategy_order_id++;
        sell.price        = current_l1.best_bid; // hit the bid to get filled
        sell.size         = TRADE_SIZE;
        sell.side         = 'S';
        sell.is_synthetic = true;
        order_to_send     = sell;
    }

    // 6. Keep the legacy L1 trackers current in case other tooling reads them.
    last_bid    = current_l1.best_bid;
    last_ask    = current_l1.best_ask;
    last_spread = current_l1.best_ask - current_l1.best_bid;
    have_last_l1 = true;

    return order_to_send;
}
