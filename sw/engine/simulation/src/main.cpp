#include "offline_simulation.h"
#include <iostream>
#include <string>

int main(int argc, char* argv[]) {
    // 1. Define the default path to your historical data (packed binary stream)
    std::string data_file_path = "data/synthetic_mbo_stream.bin";

    // 2. Allow overriding the file path via command-line arguments
    if (argc > 1) {
        data_file_path = argv[1];
    }

    std::cout << "========================================\n";
    std::cout << "Initializing Quantitative Trading Engine\n";
    std::cout << "Loading Market Data: " << data_file_path << "\n";
    std::cout << "========================================\n";

    // 3. Initialize the simulation environment
    OfflineSimulation simulation(data_file_path);

    // 4. Execute the event loop and collect the telemetry payload
    SimulationResult result = simulation.run();

    // 5. Report summary stats (the hot loop itself does no I/O)
    std::cout << "\n=== Simulation Complete ===\n";
    std::cout << "Execution time:    " << result.compute_time_us << " us ("
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
