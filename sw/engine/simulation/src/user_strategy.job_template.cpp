// Template used by strategy_compile_manager.py to build a per-job strategy:
// the marker comment inside on_market_update below is replaced (plain string
// substitution, not brace-matching) with a user-submitted function body, and
// the result is written into that job's workspace as user_strategy.cpp. The
// marker text itself is deliberately not repeated here in this docblock --
// str.replace() matches every occurrence, and an incidental match up here
// would splice user code into the top of the file instead of the function.
//
// The fixed Strategy machinery (constructor, on_fill, get_unrealized_pnl)
// lives in strategy_base.cpp and is linked in unchanged -- see that file's
// header comment. This template only needs to provide on_market_update, so
// unlike an earlier version of this file there is nothing here that could
// drift from sw/engine/simulation/src/user_strategy.cpp's real boilerplate.
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
