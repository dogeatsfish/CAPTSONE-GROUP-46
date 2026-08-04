#pragma once // This prevents the file from being included multiple times in the same compilation
#include <cstdint>
#include <string>

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

struct FillReport {
    double filled_size = 0.0;     // total volume that executed against the book
    double avg_fill_price = 0.0;  // volume-weighted average execution price
};


enum class OuchTransport { UDP, TCP };
struct OnlineConfig {
    std::string file_path = "";
    std::string itch_address = "192.168.0.1";
    uint16_t    itch_port    = 50001;
    uint16_t    ouch_port    = 50001;
    OuchTransport ouch_transport = OuchTransport::UDP;
    double      time_scale   = 1;
    uint16_t    stock_locate = 1;
    bool        enable_local_strategy = false;
    bool        auto_fill = false;
    std::string session = "";
};
