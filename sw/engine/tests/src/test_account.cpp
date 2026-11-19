// Unit tests for Account: position, PnL, fees and open-order tracking (make test).

#include <cmath>
#include <cstdio>
#include "account.h"

namespace {
int failures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);  \
            ++failures;                                                    \
        }                                                                  \
    } while (0)

bool near(double a, double b) { return std::fabs(a - b) < 1e-9; }

const FeeSchedule NO_FEES{};

void buy(Account& a, double price, double size, char liq = 'T', const FeeSchedule& f = NO_FEES) {
    a.apply_fill(0, 1, 'B', liq, price, size, f);
}
void sell(Account& a, double price, double size, char liq = 'T', const FeeSchedule& f = NO_FEES) {
    a.apply_fill(0, 1, 'S', liq, price, size, f);
}

// Buying twice blends the entry price; nothing is realized yet.
void test_open_and_add() {
    Account a;
    buy(a, 10.0, 100);
    buy(a, 12.0, 100);
    CHECK(a.position() == 200);
    CHECK(near(a.avg_entry_price(), 11.0));
    CHECK(a.realized_pnl() == 0.0);
    CHECK(near(a.unrealized_pnl(11.5), 100.0)); // 200 * (11.5 - 11)
    CHECK(a.unrealized_pnl(0.0) == 0.0);        // no mark -> no number
    CHECK(near(a.cash(), -2200.0));
    CHECK(a.volume() == 200 && a.fills().size() == 2);
}

// Selling part of a long realizes PnL on that part only.
void test_partial_close() {
    Account a;
    buy(a, 10.0, 100);
    sell(a, 13.0, 40);
    CHECK(a.position() == 60);
    CHECK(near(a.avg_entry_price(), 10.0)); // entry price of what is left is unchanged
    CHECK(near(a.realized_pnl(), 120.0));   // 40 * (13 - 10)
}

// Selling more than the long flips it short at the new price.
void test_flip() {
    Account a;
    buy(a, 10.0, 100);
    sell(a, 12.0, 150);
    CHECK(a.position() == -50);
    CHECK(near(a.avg_entry_price(), 12.0));
    CHECK(near(a.realized_pnl(), 200.0));        // 100 * (12 - 10)
    CHECK(near(a.unrealized_pnl(11.0), 50.0));   // short 50, price fell 1
}

// A round trip back to flat: cash equals realized PnL.
void test_round_trip_short() {
    Account a(1000.0);
    sell(a, 20.0, 10);
    buy(a, 18.0, 10);
    CHECK(a.position() == 0 && a.avg_entry_price() == 0.0);
    CHECK(near(a.realized_pnl(), 20.0));
    CHECK(near(a.cash(), 1020.0));
}

// Takers pay the fee, makers earn the rebate; realized PnL stays gross.
void test_fees() {
    const FeeSchedule fees{0.003, 0.002};
    Account a;
    buy(a, 10.0, 100, 'T', fees);   // pays 0.30
    sell(a, 10.5, 100, 'M', fees);  // earns 0.20
    CHECK(near(a.realized_pnl(), 50.0));
    CHECK(near(a.fees_paid(), 0.10));
    CHECK(near(a.net_pnl(10.5), 49.90));
    CHECK(near(a.cash(), 49.90));
    CHECK(near(a.fills()[0].fee, 0.30) && near(a.fills()[1].fee, -0.20));
    CHECK(a.fills()[1].liquidity == 'M');
}

BookEvent ev(BookEventType type, uint64_t id, char side, double price, double size,
             double remaining, char liq = 0) {
    BookEvent e;
    e.type = type; e.order_id = id; e.side = side; e.price = price;
    e.size = size; e.remaining = remaining; e.liquidity = liq;
    return e;
}

// Open orders follow the lifecycle events.
void test_open_orders() {
    using T = BookEventType;
    Account a;
    a.on_event(ev(T::Accepted, 7, 'B', 10.0, 100, 100), NO_FEES);
    CHECK(a.open_orders().size() == 1 && a.open_orders().at(7).remaining == 100);

    a.on_event(ev(T::PartialFill, 7, 'B', 10.0, 30, 70, 'M'), NO_FEES);
    CHECK(a.open_orders().at(7).remaining == 70 && a.position() == 30);

    a.on_event(ev(T::Reduced, 7, 'B', 10.0, 20, 50), NO_FEES);
    CHECK(a.open_orders().at(7).remaining == 50);

    a.on_event(ev(T::Filled, 7, 'B', 10.0, 50, 0, 'M'), NO_FEES);
    CHECK(a.open_orders().empty() && a.position() == 80);

    a.on_event(ev(T::Accepted, 8, 'S', 11.0, 10, 10), NO_FEES);
    a.on_event(ev(T::Cancelled, 8, 'S', 11.0, 10, 0), NO_FEES);
    CHECK(a.open_orders().empty());

    a.on_event(ev(T::Rejected, 9, 'B', 0, 0, 0), NO_FEES);
    CHECK(a.rejects() == 1);
}

// The three counters: orders_sent, cancels_sent and rejects. They count
// different things and must not bleed into each other. Who calls
// note_order_sent / note_cancel_sent, and for which action, is the
// scheduler's job -- test_participant.cpp's sent_counters covers that.
void test_counters() {
    using T = BookEventType;
    Account a;

    // A fresh account has counted nothing.
    CHECK(a.orders_sent() == 0 && a.cancels_sent() == 0 && a.rejects() == 0);

    // Each note_* bumps exactly its own counter, once per call.
    a.note_order_sent();
    CHECK(a.orders_sent() == 1 && a.cancels_sent() == 0 && a.rejects() == 0);
    a.note_cancel_sent();
    CHECK(a.orders_sent() == 1 && a.cancels_sent() == 1 && a.rejects() == 0);

    // They keep accumulating rather than saturating or resetting.
    for (int i = 0; i < 10; ++i) { a.note_order_sent(); a.note_cancel_sent(); }
    CHECK(a.orders_sent() == 11 && a.cancels_sent() == 11);

    // Events never touch the sent counters -- those count what the
    // participant asked for, not what came back.
    a.on_event(ev(T::Accepted, 1, 'B', 10.0, 100, 100), NO_FEES);
    a.on_event(ev(T::PartialFill, 1, 'B', 10.0, 40, 60, 'T'), NO_FEES);
    a.on_event(ev(T::Filled, 1, 'B', 10.0, 60, 0, 'T'), NO_FEES);
    a.on_event(ev(T::Cancelled, 1, 'B', 10.0, 0, 0), NO_FEES);
    a.on_event(ev(T::Reduced, 1, 'B', 10.0, 10, 50), NO_FEES);
    a.on_event(ev(T::Trade, 1, 'B', 10.0, 100, 0), NO_FEES);
    CHECK(a.orders_sent() == 11 && a.cancels_sent() == 11);
    CHECK(a.position() == 100); // the fills did land

    // Only Rejected moves rejects(), and it does not touch the others.
    CHECK(a.rejects() == 0);
    a.on_event(ev(T::Rejected, 2, 'B', 0, 0, 0), NO_FEES);
    a.on_event(ev(T::Rejected, 3, 'S', 0, 0, 0), NO_FEES);
    CHECK(a.rejects() == 2);
    CHECK(a.orders_sent() == 11 && a.cancels_sent() == 11);

    // Counters are per-account, not shared state.
    Account b;
    CHECK(b.orders_sent() == 0 && b.cancels_sent() == 0 && b.rejects() == 0);
}
} // namespace

int main() {
    struct { const char* name; void (*fn)(); } tests[] = {
        {"open_and_add", test_open_and_add},
        {"partial_close", test_partial_close},
        {"flip", test_flip},
        {"round_trip_short", test_round_trip_short},
        {"fees", test_fees},
        {"open_orders", test_open_orders},
        {"counters", test_counters},
    };
    for (const auto& t : tests) {
        const int before = failures;
        t.fn();
        std::printf("%s  %s\n", failures == before ? "ok  " : "FAIL", t.name);
    }
    std::printf("%s (%d failed check%s)\n", failures ? "FAILED" : "PASSED",
                failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
