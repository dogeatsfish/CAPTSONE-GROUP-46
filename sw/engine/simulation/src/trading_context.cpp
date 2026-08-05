#include "user_strategy.h"
#include <cmath>

Strategy::Strategy()
    : next_strategy_order_id(900000000), // High ID range to separate from CSV MBO orders
      position_size(0.0),
      avg_entry_price(0.0),
      realized_pnl(0.0),
      have_last_l1(false),
      last_bid(0.0),
      last_ask(0.0),
      last_spread(0.0),
      have_mean(false),
      mean_mid(0.0)
{}

void Strategy::on_fill(char side, double price, double size) {
    const double qty = (side == 'B') ? size : -size; // signed incoming quantity

    const bool opposite = position_size != 0.0 &&
                          ((position_size > 0.0) != (qty > 0.0));

    if (opposite) {
        const double closing = std::fmin(size, std::fabs(position_size));
        const double dir     = (position_size > 0.0) ? 1.0 : -1.0;
        realized_pnl += dir * (price - avg_entry_price) * closing;

        const double remaining = std::fabs(position_size) - closing; // left in old direction
        const double leftover  = size - closing;                     // portion that flips

        if (remaining > 0.0) {
            position_size = dir * remaining; 
        } else if (leftover > 0.0) {
            position_size   = (qty > 0.0 ? 1.0 : -1.0) * leftover;
            avg_entry_price = price;
        } else {
            position_size   = 0.0;
            avg_entry_price = 0.0;
        }
    } else {
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
    return position_size * (mark_price - avg_entry_price);
}
