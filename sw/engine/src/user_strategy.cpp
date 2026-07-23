#include "user_strategy.h"
#include <cmath>

Strategy::Strategy() 
    : next_strategy_order_id(900000000), // High ID range to separate from CSV MBO orders
      position_size(0.0),
      avg_entry_price(0.0),
      realized_pnl(0.0)
{}

// ---------------------------------------------------------
// Position / PnL accounting (weighted-average cost)
// ---------------------------------------------------------
void Strategy::on_fill(char side, double price, double size) {
    const double qty = (side == 'B') ? size : -size; // signed incoming quantity

    const bool opposite = position_size != 0.0 &&
                          ((position_size > 0.0) != (qty > 0.0));

    if (opposite) {
        // Reducing, closing, or flipping the current position.
        const double closing = std::fmin(size, std::fabs(position_size));
        const double dir     = (position_size > 0.0) ? 1.0 : -1.0;

        // Realize PnL on the portion that offsets the existing position.
        realized_pnl += dir * (price - avg_entry_price) * closing;

        const double remaining = std::fabs(position_size) - closing; // left in old direction
        const double leftover  = size - closing;                     // portion that flips

        if (remaining > 0.0) {
            position_size = dir * remaining; // avg_entry_price unchanged
        } else if (leftover > 0.0) {
            // Fully closed then flipped: new position opened at fill price.
            position_size   = (qty > 0.0 ? 1.0 : -1.0) * leftover;
            avg_entry_price = price;
        } else {
            // Fully flat.
            position_size   = 0.0;
            avg_entry_price = 0.0;
        }
    } else {
        // Opening or adding in the same direction: blend the entry price.
        const double new_pos = position_size + qty;
        avg_entry_price =
            (std::fabs(position_size) * avg_entry_price + size * price) / std::fabs(new_pos);
        position_size = new_pos;
    }
}

double Strategy::get_unrealized_pnl(double mark_price) const {
    if (position_size == 0.0 || mark_price == 0.0) {
        return 0.0;
    }
    // position_size carries the sign, so this handles both long and short.
    return position_size * (mark_price - avg_entry_price);
}

std::optional<Order> Strategy::on_market_update(const L1State& current_l1) {
    // 1. Ensure the order book has liquidity before making decisions
    if (current_l1.best_ask == 0.0 || current_l1.best_bid == 0.0) {
        return std::nullopt;
    }

    // Static variables persist across function calls to track market state
    // (If you prefer, you can move these to user_strategy.h as class members)
    static double last_bid = current_l1.best_bid;
    static double last_ask = current_l1.best_ask;
    static double last_spread = current_l1.best_ask - current_l1.best_bid;

    double current_spread = current_l1.best_ask - current_l1.best_bid;
    std::optional<Order> order_to_send = std::nullopt;

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
