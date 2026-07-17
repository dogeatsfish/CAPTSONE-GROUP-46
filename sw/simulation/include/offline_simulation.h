#pragma once

#include <string>
#include "orderbook.h"
#include "user_strategy.h" // Concrete class inclusion

class OfflineSimulation {
private:
    std::string mbo_file_path;
    OrderBook matching_engine; // The order book / matching engine used by the simulation
    Strategy strategy;         // Direct memory composition (no vtable)

public:
    // Constructor
    OfflineSimulation(const std::string& file_path);

    // Main execution loop
    void run();
};