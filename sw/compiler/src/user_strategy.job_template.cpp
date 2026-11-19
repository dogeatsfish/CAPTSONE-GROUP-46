// Template used by strategy_compile_manager.py to build a per-job strategy:
// the marker comment inside on_market_update below is replaced (plain string
// substitution, not brace-matching) with a user-submitted function body, and
// the result is written into that job's workspace as user_strategy.cpp. The
// marker text itself is deliberately not repeated here in this docblock --
// str.replace() matches every occurrence, and an incidental match up here
// would splice user code into the top of the file instead of the function.
//
// The fixed Strategy machinery (constructor, sync_account) lives in
// sw/engine/strategy/src/trading_context.cpp and is linked in unchanged.
// This template only needs to provide on_market_update. The body runs inside
// the simulation through the StrategyParticipant adapter
// (strategy_participant.h); position_size, avg_entry_price and realized_pnl
// are refreshed from the player's Account before every call, so a body may
// read them but assigning to them has no effect.
// <iostream> is included so a submitted body can std::cout/std::cerr for
// debugging (very likely for a student to reach for). That output is safe
// to use now: main_job.cpp writes its JSON result to a file rather than
// stdout specifically so it can't collide with whatever the body prints --
// see that file's header comment.
#include "user_strategy.h"
#include <iostream>

std::optional<Order> Strategy::on_market_update(const L1State& current_l1) {
    /*__ON_MARKET_UPDATE_BODY__*/
}
