#pragma once // Prevents multiple inclusion in the same translation unit

#include <cstdint>
#include <string>


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
