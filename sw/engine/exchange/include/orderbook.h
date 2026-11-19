#pragma once // Prevents the compiler from including this file more than once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <unordered_map>
#include <vector>
#include "common.h" // Order, Trade, L1State, BookEvent

class OrderBook {
public:
    using BidBook = std::map<double, std::deque<Order>, std::greater<double>>;
    using AskBook = std::map<double, std::deque<Order>>;
    using IdIndex = std::unordered_map<uint64_t, double>;

private:
    BidBook bids;
    AskBook asks;
    IdIndex bid_index;
    IdIndex ask_index;
    uint64_t next_event_seq = 1; // stamps BookEvent::seq

    // Shared by process_add and process_replace: order is already validated.
    // rest_remainder = false cancels whatever did not match (market orders).
    void add_validated(Order& order, uint64_t timestamp_ns, BookEvents& events,
                       bool rest_remainder = true);

public:
    std::vector<Trade> trade_log;

    OrderBook();

    // Both calls return the order-lifecycle events they caused, in order
    // (see BookEvent in common.h). fill_report(events) reduces an add's events
    // to the aggressor's filled size + average price.

    // Matches the order against the opposite side, then rests any remainder.
    // On return aggressive_order.size is the unfilled remainder.
    // Emits Accepted, then per match Trade + taker fill + maker fill; or a
    // single Rejected if the order is invalid.
    BookEvents process_add(Order& aggressive_order, uint64_t timestamp_ns);

    // Market order: trades against whatever is resting, at any price, and
    // never rests -- an unfilled remainder is cancelled. order.price is
    // ignored. Emits Accepted, the matches, then Cancelled if size was left.
    BookEvents process_market(Order& order, uint64_t timestamp_ns);

    // Removes a resting order. side 'B'/'S' looks on that side only; the
    // default 0 searches both (OUCH cancels carry no side).
    // Emits Cancelled, or Rejected(UnknownOrderId) if nothing was resting.
    BookEvents process_cancel(uint64_t order_id, uint64_t timestamp_ns, char side = 0);

    // Partial cancel (ITCH 'X'): takes qty off a resting order, which keeps its
    // place in the queue. qty >= the resting size removes the order entirely.
    // Emits Reduced, or Cancelled if nothing is left; Rejected if qty is not
    // positive or the order is not resting.
    BookEvents process_reduce(uint64_t order_id, double qty, uint64_t timestamp_ns, char side = 0);

    // Replace (ITCH 'U'): removes old_order_id and enters new_order in its
    // place. The new order takes the old one's side, goes to the BACK of the
    // queue at its price, and can match immediately if it crosses.
    // Emits Cancelled(old) then the new order's add events; a single Rejected
    // (and no change to the book) if the old order is not resting or the new
    // one is invalid.
    BookEvents process_replace(uint64_t old_order_id, Order& new_order, uint64_t timestamp_ns);

    L1State get_l1_state() const;

    // Aggregated depth: total size and order count per price level, for the
    // best n_levels levels on each side.
    L2State get_l2_state(size_t n_levels) const;

    // How much is queued ahead of a resting order at its price level; empty
    // if the order is not resting. Computed from the live queue on each call,
    // so it always reflects every add / cancel / trade so far.
    std::optional<QueuePosition> queue_position(uint64_t order_id) const;

    // Full order-by-order (L3) copy of the book, stamped with timestamp_ns.
    BookSnapshot snapshot(uint64_t timestamp_ns) const;
    // Replaces the book's contents with a snapshot's: same orders, same queue
    // order, same next event seq. (trade_log is left as it is.)
    void restore(const BookSnapshot& snapshot);
};
