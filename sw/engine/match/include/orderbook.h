#pragma once // Prevents the compiler from including this file more than once

#include <cstdint>
#include <deque>
#include <map>
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

    // Removes a resting order. side 'B'/'S' looks on that side only; the
    // default 0 searches both (OUCH cancels carry no side).
    // Emits Cancelled, or Rejected(UnknownOrderId) if nothing was resting.
    BookEvents process_cancel(uint64_t order_id, uint64_t timestamp_ns, char side = 0);

    L1State get_l1_state() const;
};
