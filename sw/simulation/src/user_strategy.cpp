#include "user_strategy.h"

Strategy::Strategy() 
    : next_strategy_order_id(900000000), // High ID range to separate from CSV MBO orders
      theoretical_fair_value(100.0)      // Example static fair value for simulation
{}

std::optional<Order> Strategy::on_market_update(uint64_t tick_timestamp_ns, const L1State& current_l1) {
    // 1. Ensure the order book has liquidity before making decisions
    if (current_l1.best_ask == 0.0 || current_l1.best_bid == 0.0) {
        return std::nullopt;
    }

    // 2. The "Arbitrage" Logic: 
    // Is the market irrationally cheap compared to our fair value?
    if (current_l1.best_ask < theoretical_fair_value - 0.50) {
        
        Order aggressive_buy;
        aggressive_buy.order_id = next_strategy_order_id++;
        aggressive_buy.price    = current_l1.best_ask; // Cross the spread
        aggressive_buy.size     = 100.0;
        aggressive_buy.side     = 'B';
        aggressive_buy.is_synthetic = true;
        
        // Update theoretical value to prevent infinite looping on the same anomaly
        theoretical_fair_value -= 0.10; 

        return aggressive_buy;
    }

    // Is the market irrationally expensive?
    if (current_l1.best_bid > theoretical_fair_value + 0.50) {
        
        Order aggressive_sell;
        aggressive_sell.order_id = next_strategy_order_id++;
        aggressive_sell.price    = current_l1.best_bid; // Cross the spread
        aggressive_sell.size     = 100.0;
        aggressive_sell.side     = 'S';
        aggressive_sell.is_synthetic = true;

        theoretical_fair_value += 0.10;

        return aggressive_sell;
    }

    // 3. No edge found, do nothing this tick
    return std::nullopt;
}