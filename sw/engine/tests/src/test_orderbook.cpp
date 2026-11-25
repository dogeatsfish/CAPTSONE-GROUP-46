// Unit tests for the OrderBook: lifecycle events, L2 depth, partial cancel
// and replace (make test).
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
// L2 depth: size and order count summed per level, best first, capped at N.
void test_l2_depth() {
    OrderBook book;
    Order b1 = make(1, 'B', 10.0, 10);
    Order b2 = make(2, 'B', 10.0, 15);
    Order b3 = make(3, 'B', 9.0, 5);
    Order b4 = make(4, 'B', 8.0, 7);
    Order a1 = make(5, 'S', 11.0, 20);
    Order a2 = make(6, 'S', 12.0, 30);
    for (Order* o : {&b1, &b2, &b3, &b4, &a1, &a2}) book.process_add(*o, 1);

    const L2State l2 = book.get_l2_state(2);
    CHECK(l2.bids.size() == 2 && l2.asks.size() == 2);
    CHECK(l2.bids[0].price == 10.0 && l2.bids[0].size == 25 && l2.bids[0].order_count == 2);
    CHECK(l2.bids[1].price == 9.0 && l2.bids[1].size == 5 && l2.bids[1].order_count == 1);
    CHECK(l2.asks[0].price == 11.0 && l2.asks[0].size == 20);
    CHECK(l2.asks[1].price == 12.0 && l2.asks[1].size == 30);

    CHECK(book.get_l2_state(10).bids.size() == 3); // fewer levels than asked for
    CHECK(book.get_l2_state(0).bids.empty());

    OrderBook empty;
    CHECK(empty.get_l2_state(5).bids.empty() && empty.get_l2_state(5).asks.empty());
}

// Partial cancel shrinks the order but it keeps its place in the queue.
void test_reduce_keeps_priority() {
    OrderBook book;
    Order first  = make(1, 'B', 10.0, 50);
    Order second = make(2, 'B', 10.0, 50);
    book.process_add(first, 1);
    book.process_add(second, 1);

    const BookEvents ev = book.process_reduce(1, 30, 2);
    CHECK(ev.size() == 1 && ev[0].type == T::Reduced);
    CHECK(ev[0].order_id == 1 && ev[0].side == 'B' && ev[0].price == 10.0);
    CHECK(ev[0].size == 30 && ev[0].remaining == 20);
    CHECK(book.get_l2_state(1).bids[0].size == 70);

    // Order 1 is still first in line: a 20-lot sell hits it, not order 2.
    Order taker = make(3, 'S', 10.0, 20);
    const BookEvents hit = book.process_add(taker, 3);
    CHECK(hit[1].type == T::Trade && hit[1].contra_order_id == 1);
    CHECK(hit[3].type == T::Filled && hit[3].order_id == 1);
}

// Reducing by everything that is left (or more) is a full cancel.
void test_reduce_to_zero_and_rejects() {
    OrderBook book;
    Order o = make(1, 'S', 10.0, 50);
    book.process_add(o, 1);

    const BookEvents bad = book.process_reduce(1, 0, 2);
    CHECK(bad[0].type == T::Rejected && bad[0].reason == RejectReason::InvalidSize);
    const BookEvents unknown = book.process_reduce(99, 5, 2);
    CHECK(unknown[0].type == T::Rejected && unknown[0].reason == RejectReason::UnknownOrderId);
    const BookEvents wrong_side = book.process_reduce(1, 5, 2, 'B');
    CHECK(wrong_side[0].type == T::Rejected);
    CHECK(book.get_l2_state(1).asks[0].size == 50); // untouched by the rejects

    const BookEvents ev = book.process_reduce(1, 80, 3);
    CHECK(ev.size() == 1 && ev[0].type == T::Cancelled);
    CHECK(ev[0].size == 50 && ev[0].remaining == 0);
    CHECK(book.get_l1_state().best_ask == 0.0);
}

// Replace keeps the side but sends the order to the back of the queue.
void test_replace_loses_priority() {
    OrderBook book;
    Order first  = make(1, 'B', 10.0, 50);
    Order second = make(2, 'B', 10.0, 50);
    book.process_add(first, 1);
    book.process_add(second, 1);

    Order replacement = make(3, 0, 10.0, 40); // side comes from the old order
    const BookEvents ev = book.process_replace(1, replacement, 2);
    CHECK(ev.size() == 2);
    CHECK(ev[0].type == T::Cancelled && ev[0].order_id == 1 && ev[0].contra_order_id == 3);
    CHECK(ev[1].type == T::Accepted && ev[1].order_id == 3 && ev[1].side == 'B');
    CHECK(replacement.side == 'B');

    // Order 2 is now ahead of the replacement.
    Order taker = make(4, 'S', 10.0, 10);
    const BookEvents hit = book.process_add(taker, 3);
    CHECK(hit[1].type == T::Trade && hit[1].contra_order_id == 2);
}

// A replace that crosses the spread trades straight away.
void test_replace_can_match() {
    OrderBook book;
    Order bid = make(1, 'B', 9.0, 10);
    Order ask = make(2, 'S', 10.0, 10);
    book.process_add(bid, 1);
    book.process_add(ask, 1);

    Order repriced = make(3, 0, 10.0, 10); // bid moved up to the ask
    const BookEvents ev = book.process_replace(1, repriced, 2);
    CHECK(ev.size() == 5); // Cancelled, Accepted, Trade, Filled(taker), Filled(maker)
    CHECK(ev[2].type == T::Trade && ev[2].price == 10.0 && ev[2].contra_order_id == 2);
    CHECK(book.get_l1_state().best_bid == 0.0 && book.get_l1_state().best_ask == 0.0);
}

// A bad replace leaves the original order resting.
void test_replace_rejects() {
    OrderBook book;
    Order o = make(1, 'B', 10.0, 50);
    book.process_add(o, 1);

    Order fresh = make(2, 0, 10.0, 10);
    const BookEvents unknown = book.process_replace(99, fresh, 2);
    CHECK(unknown.size() == 1 && unknown[0].type == T::Rejected);
    CHECK(unknown[0].reason == RejectReason::UnknownOrderId);

    Order bad = make(3, 0, 10.0, -5);
    const BookEvents invalid = book.process_replace(1, bad, 2);
    CHECK(invalid.size() == 1 && invalid[0].type == T::Rejected);
    CHECK(invalid[0].reason == RejectReason::InvalidSize);

    const L2State l2 = book.get_l2_state(1);
    CHECK(l2.bids.size() == 1 && l2.bids[0].size == 50 && l2.bids[0].order_count == 1);
}
// Queue position: shares ahead shrink as the orders in front trade or cancel.
void test_queue_position() {
    OrderBook book;
    Order a = make(1, 'B', 10.0, 30);
    Order b = make(2, 'B', 10.0, 20);
    Order c = make(3, 'B', 10.0, 50);
    Order other = make(4, 'B', 9.0, 99); // a different level never counts
    for (Order* o : {&a, &b, &c, &other}) book.process_add(*o, 1);

    CHECK(!book.queue_position(999).has_value());
    CHECK(book.queue_position(1)->shares_ahead == 0 && book.queue_position(1)->orders_ahead == 0);
    const QueuePosition p = *book.queue_position(3);
    CHECK(p.side == 'B' && p.price == 10.0 && p.remaining == 50);
    CHECK(p.shares_ahead == 50 && p.orders_ahead == 2);

    Order sell = make(5, 'S', 10.0, 10); // trades 10 off the front order
    book.process_add(sell, 2);
    CHECK(book.queue_position(3)->shares_ahead == 40);

    book.process_cancel(2, 3);           // the middle order leaves
    CHECK(book.queue_position(3)->shares_ahead == 20 && book.queue_position(3)->orders_ahead == 1);

    book.process_reduce(1, 5, 4);        // the front order shrinks
    CHECK(book.queue_position(3)->shares_ahead == 15);

    Order sweep = make(6, 'S', 10.0, 15); // front order fully filled
    book.process_add(sweep, 5);
    CHECK(book.queue_position(3)->shares_ahead == 0);
    CHECK(!book.queue_position(1).has_value());

    Order ask = make(7, 'S', 11.0, 5);   // works on the ask side too
    Order ask2 = make(8, 'S', 11.0, 5);
    book.process_add(ask, 6);
    book.process_add(ask2, 6);
    CHECK(book.queue_position(8)->side == 'S' && book.queue_position(8)->shares_ahead == 5);
}

// A restored snapshot is the same book: same depth, same queue order, and it
// answers the next actions with the same events (same seq numbers too).
void test_snapshot_restore() {
    OrderBook book;
    Order o1 = make(1, 'B', 10.0, 30);
    Order o2 = make(2, 'B', 10.0, 20);
    Order o3 = make(3, 'B', 9.0, 40);
    Order o4 = make(4, 'S', 11.0, 25);
    Order o5 = make(5, 'S', 12.0, 35);
    for (Order* o : {&o1, &o2, &o3, &o4, &o5}) book.process_add(*o, 1);
    book.process_reduce(1, 10, 2); // partly used front order

    const BookSnapshot snap = book.snapshot(77);
    CHECK(snap.timestamp_ns == 77);
    CHECK(snap.bids.size() == 3 && snap.asks.size() == 2);
    CHECK(snap.bids[0].order_id == 1 && snap.bids[0].size == 20); // best price, oldest first
    CHECK(snap.bids[1].order_id == 2 && snap.bids[2].order_id == 3);
    CHECK(snap.asks[0].order_id == 4 && snap.asks[1].order_id == 5);

    OrderBook copy;
    copy.restore(snap);
    CHECK(copy.get_l1_state().best_bid == 10.0 && copy.get_l1_state().best_ask == 11.0);
    CHECK(copy.queue_position(2)->shares_ahead == 20);

    // Same follow-up on both books -> identical events.
    Order s1 = make(9, 'S', 9.0, 60);
    Order s2 = make(9, 'S', 9.0, 60);
    const BookEvents x = book.process_add(s1, 5);
    const BookEvents y = copy.process_add(s2, 5);
    CHECK(x.size() == y.size() && x.size() > 4);
    for (size_t i = 0; i < x.size() && i < y.size(); ++i) {
        CHECK(x[i].seq == y[i].seq && x[i].type == y[i].type);
        CHECK(x[i].order_id == y[i].order_id && x[i].size == y[i].size);
    }
    CHECK(copy.process_cancel(5, 6)[0].type == T::Cancelled); // ids still cancellable

    // Restoring over a non-empty book replaces it.
    copy.restore(BookSnapshot{});
    CHECK(copy.get_l2_state(5).bids.empty() && copy.get_l2_state(5).asks.empty());
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
        {"l2_depth",                 test_l2_depth},
        {"reduce_keeps_priority",    test_reduce_keeps_priority},
        {"reduce_to_zero_and_rejects", test_reduce_to_zero_and_rejects},
        {"replace_loses_priority",   test_replace_loses_priority},
        {"replace_can_match",        test_replace_can_match},
        {"replace_rejects",          test_replace_rejects},
        {"queue_position",           test_queue_position},
        {"snapshot_restore",         test_snapshot_restore},
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
