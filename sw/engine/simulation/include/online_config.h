#pragma once // Prevents multiple inclusion in the same translation unit

#include <cstdint>
#include <string>


// OUCH order entry is UDP only (one OUCH frame per datagram), matching what
// the FPGA's outbound_tx_generator.sv emits.
struct OnlineConfig {
    std::string file_path = "";
    std::string itch_address = "192.168.0.1";
    uint16_t    itch_port    = 50001;
    uint16_t    ouch_port    = 50001;
    double      time_scale   = 1;
    uint16_t    stock_locate = 1;
    bool        enable_local_strategy = false;
    bool        auto_fill = false;
    std::string session = "";
};
