#include "online_simulation.h"
#include <iostream>
#include <string>
#include <cstdlib>

int main(int argc, char* argv[]) {
    // Usage: online_run [mbo_file] [time_scale] [itch_port] [ouch_port] [itch_addr]
    // Anything not given on the command line keeps its OnlineConfig default,
    // so those defaults live in exactly one place and are not duplicated here.
    OnlineConfig cfg;
    cfg.file_path = "../data_pipeline/data/synthetic_mbo_stream.bin";

    if (argc > 1) cfg.file_path    = argv[1];
    if (argc > 2) cfg.time_scale   = std::atof(argv[2]);
    if (argc > 3) cfg.itch_port    = static_cast<uint16_t>(std::atoi(argv[3]));
    if (argc > 4) cfg.ouch_port    = static_cast<uint16_t>(std::atoi(argv[4]));
    if (argc > 5) cfg.itch_address = argv[5];

    std::cout << "========================================\n";
    std::cout << "Online (Real-Time) Trading Engine\n";
    std::cout << "Market data (MBO): " << cfg.file_path << "\n";
    std::cout << "ITCH broadcast:    udp " << cfg.itch_address << ":" << cfg.itch_port << "\n";
    std::cout << "OUCH order entry:  udp 0.0.0.0:" << cfg.ouch_port << "\n";
    std::cout << "Time scale:        " << cfg.time_scale << "x\n";
    std::cout << "========================================\n";

    OnlineSimulation simulation(cfg);
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
