// The half of the player's Strategy that the player does NOT write.
//
// Strategy is split across two translation units on purpose. This one holds
// the constructor and sync_account, and is linked into every build unchanged.
// The other half -- Strategy::on_market_update -- is swappable: normal builds
// link strategy/templates/trading_template.cpp, while the Strategy Compiler
// generates a per-job replacement from sw/compiler/src/user_strategy.job_template.cpp
// and links that instead. Exactly one of the two is ever present; linking both
// is a duplicate definition.
//
// Keeping these here is what bounds what a submitted strategy can do: it
// controls one function body and nothing else -- it cannot change how the
// object is initialised, and it cannot intercept the account refresh.

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
