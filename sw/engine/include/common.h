#pragma once // This prevents the file from being included multiple times in the same compilation

#include <cstdint>

struct Order {
    uint64_t order_id;
    double price;
    double size;
    char side;        // 'B' for Bid, 'S' for Ask
    bool is_synthetic;
};

struct Trade {
    uint64_t timestamp_ns;
    double price;
    double size;
    uint64_t maker_id;
    uint64_t taker_id;
};

struct L1State {
    double best_bid = 0.0;
    double best_ask = 0.0;
};

// Summary of what actually executed when an aggressive order hit the book.
struct FillReport {
    double filled_size = 0.0;     // total volume that executed against the book
    double avg_fill_price = 0.0;  // volume-weighted average execution price
};
