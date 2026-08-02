// The user-editable half of Strategy: on_market_update only. The fixed
// machinery (constructor, on_fill, get_unrealized_pnl) lives in
// strategy_base.cpp -- see that file's header comment for why the split
// exists (the UI's software-compile path reuses this function's body
// against a template, and needs the rest to be a single source of truth).
#include "user_strategy.h"

std::optional<Order> Strategy::on_market_update(const L1State& current_l1) {
    // 1. Ensure the order book has liquidity before making decisions
    if (current_l1.best_ask == 0.0 || current_l1.best_bid == 0.0) {
        return std::nullopt;
    }

    double current_spread = current_l1.best_ask - current_l1.best_bid;
    std::optional<Order> order_to_send = std::nullopt;

    // On the very first two-sided quote we have no prior tick to compare
    // against, so just seed the trackers and wait for the next update.
    if (!have_last_l1) {
        last_bid = current_l1.best_bid;
        last_ask = current_l1.best_ask;
        last_spread = current_spread;
        have_last_l1 = true;
        return std::nullopt;
    }

    // 2. Spread-Reversion Logic:
    // If the spread widened compared to the last tick, we push back.
    if (current_spread > last_spread && last_spread > 0.0) {

        // Did the ask move up, widening the spread?
        if (current_l1.best_ask > last_ask) {
            Order aggressive_sell;
            aggressive_sell.order_id = next_strategy_order_id++;
            aggressive_sell.price    = current_l1.best_bid; // Cross the spread to bring price down
            aggressive_sell.size     = 100.0;
            aggressive_sell.side     = 'S';
            aggressive_sell.is_synthetic = true;

            order_to_send = aggressive_sell;
        }
        // Did the bid move down, widening the spread?
        else if (current_l1.best_bid < last_bid) {
            Order aggressive_buy;
            aggressive_buy.order_id = next_strategy_order_id++;
            aggressive_buy.price    = current_l1.best_ask; // Cross the spread to bring price up
            aggressive_buy.size     = 100.0;
            aggressive_buy.side     = 'B';
            aggressive_buy.is_synthetic = true;

            order_to_send = aggressive_buy;
        }
    }

    // 3. Update the state trackers for the next tick
    last_bid = current_l1.best_bid;
    last_ask = current_l1.best_ask;
    last_spread = current_spread;

    return order_to_send;
}
