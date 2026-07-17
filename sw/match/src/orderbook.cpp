#include "orderbook.h"
#include <algorithm> // Required for std::min and std::stable_sort

// ---------------------------------------------------------
// Constructor
// ---------------------------------------------------------
OrderBook::OrderBook() {
    // Pre-allocate capacity to prevent vector resizing/reallocation on the hot path
    bids.reserve(1000);
    asks.reserve(1000);
    trade_log.reserve(10000);
}

// ---------------------------------------------------------
// Public Methods
// ---------------------------------------------------------
void OrderBook::process_add(Order& aggressive_order, uint64_t timestamp_ns) {
    if (aggressive_order.side == 'B') {
        match(aggressive_order, asks, true, timestamp_ns);
        if (aggressive_order.size > 0) {
            insert_order(aggressive_order, bids, true);
        }
    } else {
        match(aggressive_order, bids, false, timestamp_ns);
        if (aggressive_order.size > 0) {
            insert_order(aggressive_order, asks, false);
        }
    }
}

void OrderBook::process_cancel(uint64_t order_id, char side) {
    auto& book = (side == 'B') ? bids : asks;
    for (auto it = book.begin(); it != book.end(); ++it) {
        if (it->order_id == order_id) {
            book.erase(it); // Packed shifting in contiguous memory
            break;
        }
    }
}

L1State OrderBook::get_l1_state() const {
    L1State state;
    if (!bids.empty()) state.best_bid = bids.front().price;
    if (!asks.empty()) state.best_ask = asks.front().price;
    return state;
}

// ---------------------------------------------------------
// Private Helper Methods
// ---------------------------------------------------------
void OrderBook::match(Order& aggressive_order, std::vector<Order>& passive_book, bool is_bid, uint64_t timestamp_ns) {
    while (!passive_book.empty() && aggressive_order.size > 0) {
        auto& best_passive = passive_book.front();

        // Check if prices cross
        if (is_bid && aggressive_order.price < best_passive.price) break;
        if (!is_bid && aggressive_order.price > best_passive.price) break;

        // Execute trade
        double trade_size = std::min(aggressive_order.size, best_passive.size);
        aggressive_order.size -= trade_size;
        best_passive.size -= trade_size;

        trade_log.push_back(Trade{
            timestamp_ns,
            best_passive.price,
            trade_size,
            best_passive.order_id,
            aggressive_order.order_id
        });

        if (best_passive.size == 0) {
            passive_book.erase(passive_book.begin()); // Pop front
        }
    }
}

void OrderBook::insert_order(const Order& order, std::vector<Order>& book, bool descending) {
    book.push_back(order);
    if (descending) {
        // Sort by Price Descending
        std::stable_sort(book.begin(), book.end(), [](const Order& a, const Order& b) {
            return a.price > b.price;
        });
    } else {
        // Sort by Price Ascending
        std::stable_sort(book.begin(), book.end(), [](const Order& a, const Order& b) {
            return a.price < b.price;
        });
    }
}