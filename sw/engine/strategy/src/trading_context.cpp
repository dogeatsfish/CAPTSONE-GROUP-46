#include "user_strategy.h"

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

void Strategy::sync_account(double position, double entry_price, double realized) {
    position_size   = position;
    avg_entry_price = entry_price;
    realized_pnl    = realized;
}
