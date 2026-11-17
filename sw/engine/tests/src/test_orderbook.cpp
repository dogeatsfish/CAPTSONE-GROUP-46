// Unit tests for the OrderBook's order-lifecycle events (make test).
// Plain asserts, no framework: each CHECK prints the failing line and the
// process exits non-zero if any failed.

#include <cstdio>
#include "orderbook.h"

namespace {
int failures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);  \
            ++failures;                                                    \
        }                                                                  \
    } while (0)

using T = BookEventType;

Order make(uint64_t id, char side, double price, double size) {
    return Order{id, price, size, side, false};
}

// An order that crosses nothing is accepted and rests.
void test_accept_and_rest() {
    OrderBook book;
    Order o = make(1, 'B', 10.0, 100);
    const BookEvents ev = book.process_add(o, 5);

    CHECK(ev.size() == 1);
    CHECK(ev[0].type == T::Accepted);
    CHECK(ev[0].order_id == 1 && ev[0].side == 'B');
    CHECK(ev[0].price == 10.0 && ev[0].size == 100 && ev[0].remaining == 100);
    CHECK(ev[0].timestamp_ns == 5);
    CHECK(book.get_l1_state().best_bid == 10.0);
    CHECK(fill_report(ev).filled_size == 0.0);
}

// Taker fully fills against one maker that is left partially filled.
void test_full_fill_partial_maker() {
    OrderBook book;
    Order maker = make(1, 'S', 10.0, 100);
    book.process_add(maker, 1);

    Order taker = make(2, 'B', 10.5, 40);
    const BookEvents ev = book.process_add(taker, 2);

    CHECK(ev.size() == 4);
    CHECK(ev[0].type == T::Accepted && ev[0].order_id == 2);

    CHECK(ev[1].type == T::Trade);
    CHECK(ev[1].order_id == 2 && ev[1].contra_order_id == 1);
    CHECK(ev[1].price == 10.0 && ev[1].size == 40); // trades at the maker's price

    CHECK(ev[2].type == T::Filled && ev[2].order_id == 2);
    CHECK(ev[2].liquidity == 'T' && ev[2].side == 'B' && ev[2].remaining == 0);

    CHECK(ev[3].type == T::PartialFill && ev[3].order_id == 1);
    CHECK(ev[3].liquidity == 'M' && ev[3].side == 'S' && ev[3].remaining == 60);
    CHECK(ev[3].contra_order_id == 2);

    CHECK(taker.size == 0);
    CHECK(book.get_l1_state().best_ask == 10.0); // 60 still resting
    CHECK(book.get_l1_state().best_bid == 0.0);  // taker did not rest
}

// Taker sweeps two levels, runs out of liquidity and rests its remainder.
void test_sweep_then_rest() {
    OrderBook book;
    Order a = make(1, 'S', 10.0, 30);
    Order b = make(2, 'S', 11.0, 30);
    book.process_add(a, 1);
    book.process_add(b, 1);

    Order taker = make(3, 'B', 11.0, 100);
    const BookEvents ev = book.process_add(taker, 2);

    // Accepted + 2 x (Trade, taker fill, maker fill)
    CHECK(ev.size() == 7);
    CHECK(ev[2].type == T::PartialFill && ev[2].order_id == 3 && ev[2].remaining == 70);
    CHECK(ev[3].type == T::Filled && ev[3].order_id == 1);
    CHECK(ev[5].type == T::PartialFill && ev[5].order_id == 3 && ev[5].remaining == 40);
    CHECK(ev[6].type == T::Filled && ev[6].order_id == 2);

    const FillReport fill = fill_report(ev);
    CHECK(fill.filled_size == 60);
    CHECK(fill.avg_fill_price == 10.5); // (30*10 + 30*11) / 60

    CHECK(taker.size == 40);
    CHECK(book.get_l1_state().best_bid == 11.0); // remainder rests
    CHECK(book.get_l1_state().best_ask == 0.0);
}

// Time priority: at one price the older order is hit first.
void test_fifo_priority() {
    OrderBook book;
    Order first  = make(1, 'B', 10.0, 10);
    Order second = make(2, 'B', 10.0, 10);
    book.process_add(first, 1);
    book.process_add(second, 2);

    Order taker = make(3, 'S', 10.0, 10);
    const BookEvents ev = book.process_add(taker, 3);
    CHECK(ev.size() == 4);
    CHECK(ev[1].type == T::Trade && ev[1].contra_order_id == 1);
}

// Cancel reports the unexecuted size; a second cancel is rejected.
void test_cancel() {
    OrderBook book;
    Order maker = make(1, 'S', 10.0, 100);
    book.process_add(maker, 1);
    Order taker = make(2, 'B', 10.0, 25);
    book.process_add(taker, 2);

    const BookEvents ev = book.process_cancel(1, 3); // side unknown
    CHECK(ev.size() == 1);
    CHECK(ev[0].type == T::Cancelled && ev[0].order_id == 1);
    CHECK(ev[0].side == 'S' && ev[0].price == 10.0 && ev[0].size == 75);
    CHECK(ev[0].remaining == 0 && ev[0].timestamp_ns == 3);
    CHECK(book.get_l1_state().best_ask == 0.0);

    const BookEvents again = book.process_cancel(1, 4);
    CHECK(again.size() == 1);
    CHECK(again[0].type == T::Rejected);
    CHECK(again[0].reason == RejectReason::UnknownOrderId);
}

// A side-specific cancel only looks on that side.
void test_cancel_wrong_side() {
    OrderBook book;
    Order o = make(1, 'B', 10.0, 10);
    book.process_add(o, 1);

    const BookEvents miss = book.process_cancel(1, 2, 'S');
    CHECK(miss[0].type == T::Rejected);
    CHECK(book.get_l1_state().best_bid == 10.0); // still there

    const BookEvents hit = book.process_cancel(1, 3, 'B');
    CHECK(hit[0].type == T::Cancelled);
}

// Invalid orders are rejected and leave the book untouched.
void test_rejects() {
    OrderBook book;
    Order bad_side  = make(1, 'X', 10.0, 10);
    Order bad_size  = make(2, 'B', 10.0, 0);
    Order bad_price = make(3, 'S', -1.0, 10);

    const BookEvents a = book.process_add(bad_side, 1);
    const BookEvents b = book.process_add(bad_size, 1);
    const BookEvents c = book.process_add(bad_price, 1);

    CHECK(a.size() == 1 && a[0].type == T::Rejected && a[0].reason == RejectReason::InvalidSide);
    CHECK(b.size() == 1 && b[0].type == T::Rejected && b[0].reason == RejectReason::InvalidSize);
    CHECK(c.size() == 1 && c[0].type == T::Rejected && c[0].reason == RejectReason::InvalidPrice);
    CHECK(book.get_l1_state().best_bid == 0.0 && book.get_l1_state().best_ask == 0.0);
    CHECK(book.trade_log.empty());
}

// seq increases by one per event across calls: a total order for the log.
void test_sequence_numbers() {
    OrderBook book;
    Order maker = make(1, 'S', 10.0, 10);
    Order taker = make(2, 'B', 10.0, 10);
    BookEvents all = book.process_add(maker, 1);
    const BookEvents more = book.process_add(taker, 2);
    all.insert(all.end(), more.begin(), more.end());
    const BookEvents miss = book.process_cancel(99, 3);
    all.insert(all.end(), miss.begin(), miss.end());

    CHECK(all.size() == 6);
    for (size_t i = 0; i < all.size(); ++i) CHECK(all[i].seq == i + 1);
}
} // namespace

int main() {
    struct { const char* name; void (*fn)(); } tests[] = {
        {"accept_and_rest",          test_accept_and_rest},
        {"full_fill_partial_maker",  test_full_fill_partial_maker},
        {"sweep_then_rest",          test_sweep_then_rest},
        {"fifo_priority",            test_fifo_priority},
        {"cancel",                   test_cancel},
        {"cancel_wrong_side",        test_cancel_wrong_side},
        {"rejects",                  test_rejects},
        {"sequence_numbers",         test_sequence_numbers},
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
