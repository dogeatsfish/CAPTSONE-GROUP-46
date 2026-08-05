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

    OrderBook();
    FillReport process_add(Order& aggressive_order, uint64_t timestamp_ns);
    void process_cancel(uint64_t order_id, char side);
    void process_cancel(uint64_t order_id);
    L1State get_l1_state() const;
};
