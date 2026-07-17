#pragma once // Prevents the compiler from including this file more than once

#include <vector>
#include "common.h" // Gives access to Order, Trade, and L1State structs

class OrderBook {
private:
    // Contiguous memory blocks to optimize cache locality
    std::vector<Order> bids;
    std::vector<Order> asks;

    // Private helper methods (internal logic only)
    void match(Order& aggressive_order, std::vector<Order>& passive_book, bool is_bid, uint64_t timestamp_ns);
    void insert_order(const Order& order, std::vector<Order>& book, bool descending);

public:
    std::vector<Trade> trade_log;

    // Constructor
    OrderBook();

    // Public methods that other files can call
    void process_add(Order& aggressive_order, uint64_t timestamp_ns);
    void process_cancel(uint64_t order_id, char side);
    L1State get_l1_state() const;
};