#pragma once // Prevents the compiler from including this file more than once

#include <cstdint>
#include <deque>
#include <map>
#include <unordered_map>
#include <vector>
#include "common.h" // Gives access to Order, Trade, and L1State structs

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

public:
    std::vector<Trade> trade_log;

    // Constructor
    OrderBook();

    // Public methods that other files can call.
    // process_add returns a FillReport describing what actually executed.
    FillReport process_add(Order& aggressive_order, uint64_t timestamp_ns);

    // Side-known cancel (e.g. the offline/market-data MBO_CANCEL path, which
    // carries a real side): looks in exactly one index.
    void process_cancel(uint64_t order_id, char side);

    // Side-unknown cancel: tries the bid index, then the ask index. Needed
    // for OUCH Cancel, whose wire format carries no side at all (see
    // protocol::from_ouch) -- passing a guessed/default side into the
    // side-known overload above silently no-ops on the wrong book half.
    void process_cancel(uint64_t order_id);

    L1State get_l1_state() const;
};
