#pragma once

#include "participant.h"
#include "user_strategy.h"

// Adapter that lets the Strategy Compiler's single-function Strategy take part
// in the simulation as a Participant: each book update is boiled down to the
// top of book, handed to on_market_update, and any order it returns is sent as
// a limit order.
class StrategyParticipant : public Participant {
public:
    explicit StrategyParticipant(Strategy& strategy) : strategy_(strategy) {}

    void on_book_update(const L2State& book) override {
        L1State l1;
        if (!book.bids.empty()) l1.best_bid = book.bids.front().price;
        if (!book.asks.empty()) l1.best_ask = book.asks.front().price;

        const Account& acct = account();
        strategy_.sync_account(acct.position(), acct.avg_entry_price(), acct.realized_pnl());

        const std::optional<Order> order = strategy_.on_market_update(l1);
        if (order.has_value()) {
            send_limit(order->side, order->price, order->size);
        }
    }

private:
    Strategy& strategy_;
};
