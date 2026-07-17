#include "offline_simulation.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <chrono>

// ---------------------------------------------------------
// Constructor
// ---------------------------------------------------------
OfflineSimulation::OfflineSimulation(const std::string& file_path) 
    : mbo_file_path(file_path) {}

// ---------------------------------------------------------
// Main Execution Loop
// ---------------------------------------------------------
void OfflineSimulation::run() {
    std::ifstream file(mbo_file_path);
    if (!file.is_open()) {
        std::cerr << "CRITICAL: Failed to open MBO stream file at " << mbo_file_path << std::endl;
        return;
    }

    std::string line;
    // Skip the CSV header row
    std::getline(file, line);

    std::cout << "Starting simulation with direct strategy composition..." << std::endl;
    auto start_sim_time = std::chrono::high_resolution_clock::now();

    // Loop through every line in the pre-generated MBO stream
    while (std::getline(file, line)) {
        std::stringstream ss(line);
        std::string temp;

        std::string timestamp_str;
        char message_type;
        uint64_t order_id;
        char side;
        double price;
        double size;

        // --- 1. Parse CSV Line ---
        std::getline(ss, timestamp_str, ',');
        std::getline(ss, temp, ','); message_type = temp[0];
        std::getline(ss, temp, ','); order_id = std::stoull(temp);
        std::getline(ss, temp, ','); side = temp[0];
        std::getline(ss, temp, ','); price = std::stod(temp);
        std::getline(ss, temp, ','); size = std::stod(temp);

        // Dummy timestamp for the C++ side since string parsing dates is slow
        uint64_t tick_timestamp_ns = 100000000; 

        // --- 2. Process the Market Stream Event ---
        if (message_type == 'A') {
            Order mkt_order{order_id, price, size, side, true};
            matching_engine.process_add(mkt_order, tick_timestamp_ns);
        } else if (message_type == 'C') {
            matching_engine.process_cancel(order_id, side);
        }

        // --- 3. Extract the Updated L1 State ---
        L1State current_l1 = matching_engine.get_l1_state();

        // --- 4. Inline Execution Strategy Call ---
        // Because strategy is a concrete class, the compiler resolves this directly.
        std::optional<Order> user_order = strategy.on_market_update(tick_timestamp_ns, current_l1);

        // --- 5. Process the User Order if Triggered ---
        if (user_order.has_value()) {
            std::cout << "[SIM] Strategy crossing the spread at price " << user_order->price 
                      << " for size " << user_order->size << std::endl;
            
            // Pass the generated user order back into the engine
            matching_engine.process_add(user_order.value(), tick_timestamp_ns);
        }
    }

    auto end_sim_time = std::chrono::high_resolution_clock::now();
    auto duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(end_sim_time - start_sim_time).count();

    std::cout << "\n=== Hardware Execution Simulation Complete ===" << std::endl;
    std::cout << "Execution time: " << duration_ms << " ms" << std::endl;
    std::cout << "Total trades crossed: " << matching_engine.trade_log.size() << std::endl;
}