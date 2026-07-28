#include "online_simulation.h"
#include <iostream>
#include <string>
#include <cstdlib>

// Usage:
//   online_run [mbo_file] [time_scale] [itch_port] [ouch_port] [itch_address]
//
//   mbo_file      packed binary MBO stream (default: data/synthetic_mbo_stream.bin)
//   time_scale    wall-clock pacing factor (default 1.0 = real time; e.g. 0.001
//                 replays 1000x faster; 0 disables pacing)
//   itch_port     UDP port ITCH market data is broadcast to (default 26000)
//   ouch_port     TCP port the OUCH order-entry server listens on (default 26001)
//   itch_address  destination IP for the ITCH UDP feed (default 127.0.0.1).
//                 For a hardware target, set this to the FPGA's IP (unicast)
//                 or a multicast group the FPGA subscribes to (e.g. 239.1.1.1).
//                 The OUCH server always listens on 0.0.0.0:ouch_port, so the
//                 FPGA connects in to HOST_IP:ouch_port.
int main(int argc, char* argv[]) {
    std::string data_file_path = "data/synthetic_mbo_stream.bin";

    OnlineSimulation::Config cfg; // defaults

    if (argc > 1) data_file_path = argv[1];
    if (argc > 2) cfg.time_scale = std::atof(argv[2]);
    if (argc > 3) cfg.itch_port  = static_cast<uint16_t>(std::atoi(argv[3]));
    if (argc > 4) cfg.ouch_port  = static_cast<uint16_t>(std::atoi(argv[4]));
    if (argc > 5) cfg.itch_address = argv[5];

    std::cout << "========================================\n";
    std::cout << "Online (Real-Time) Trading Engine\n";
    std::cout << "Market data (MBO): " << data_file_path << "\n";
    std::cout << "ITCH broadcast:    udp " << cfg.itch_address << ":" << cfg.itch_port << "\n";
    std::cout << "OUCH order entry:  tcp 0.0.0.0:" << cfg.ouch_port << "\n";
    std::cout << "Time scale:        " << cfg.time_scale << "x\n";
    std::cout << "========================================\n";

    OnlineSimulation simulation(data_file_path, cfg);
    SimulationResult result = simulation.run();

    std::cout << "\n=== Simulation Complete ===\n";
    std::cout << "Elapsed (wall):    " << result.compute_time_us << " us ("
              << (result.compute_time_us / 1000.0) << " ms)\n";
    std::cout << "Total trades:      " << result.total_trades << "\n";
    std::cout << "PnL samples:       " << result.pnl_curve.size() << "\n";
    if (!result.pnl_curve.empty()) {
        const PnLSnapshot& last = result.pnl_curve.back();
        std::cout << "Final position:    " << last.position_size << "\n";
        std::cout << "Final realized:    " << last.realized_pnl << "\n";
        std::cout << "Final unrealized:  " << last.unrealized_pnl << "\n";
    }
    std::cout << "Simulation finished successfully.\n";

    return 0;
}
