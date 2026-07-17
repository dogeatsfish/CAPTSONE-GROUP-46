#include "offline_simulation.h"
#include <iostream>
#include <string>

int main(int argc, char* argv[]) {
    // 1. Define the default path to your historical data
    std::string data_file_path = "data/mbo_stream.csv";

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

    // 4. Execute the event loop
    simulation.run();

    std::cout << "Simulation finished successfully.\n";

    return 0;
}