// Stress + correctness harness for the OrderBook matching engine.
//
// Build (from the engine/ directory):
//   g++ -std=c++17 -O2 -Ishared/include -Imatch/include \
//       tests/stress_orderbook.cpp match/src/orderbook.cpp -o tests/stress_orderbook
//   ./tests/stress_orderbook
//
// Two parts:
//   1. Deterministic correctness checks (matching, priority, cancel, VWAP, L1).
//   2. Randomized stress: millions of ops with invariant checks + throughput.

#include "orderbook.h"

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <random>
#include <vector>

// ---------------------------------------------------------------------------
// Tiny test framework
// ---------------------------------------------------------------------------
static int g_checks = 0;
static int g_failures = 0;

static bool almost_equal(double a, double b, double eps = 1e-9) {
    return std::fabs(a - b) <= eps * std::fmax(1.0, std::fmax(std::fabs(a), std::fabs(b)));
}

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        ++g_checks;                                                           \
        if (!(cond)) {                                                        \
            ++g_failures;                                                     \
            std::cerr << "  [FAIL] " << msg << "  (" #cond ")"                \
                      << " @ line " << __LINE__ << "\n";                      \
        }                                                                     \
    } while (0)

static Order mk(uint64_t id, char side, double price, double size) {
    return Order{id, price, size, side, false};
}

// ---------------------------------------------------------------------------
// 1. Correctness scenarios
// ---------------------------------------------------------------------------
static void test_no_cross_rests() {
    OrderBook ob;
    Order b = mk(1, 'B', 100.0, 10.0);
    FillReport r = ob.process_add(b, 1);
    CHECK(r.filled_size == 0.0, "resting bid should not fill");

    Order a = mk(2, 'S', 101.0, 5.0);
    r = ob.process_add(a, 2);
    CHECK(r.filled_size == 0.0, "non-crossing ask should not fill");

    L1State l1 = ob.get_l1_state();
    CHECK(almost_equal(l1.best_bid, 100.0), "best bid = 100");
    CHECK(almost_equal(l1.best_ask, 101.0), "best ask = 101");
    CHECK(ob.trade_log.empty(), "no trades on non-crossing book");
}

static void test_full_and_partial_fill() {
    OrderBook ob;
    Order a = mk(1, 'S', 100.0, 10.0);
    ob.process_add(a, 1);

    // Aggressive buy for 4 @ 100 -> full fill of the taker, maker partially left.
    Order b = mk(2, 'B', 100.0, 4.0);
    FillReport r = ob.process_add(b, 2);
    CHECK(almost_equal(r.filled_size, 4.0), "taker filled 4");
    CHECK(almost_equal(r.avg_fill_price, 100.0), "fill price = 100");
    CHECK(b.size == 0.0, "taker fully consumed");

    L1State l1 = ob.get_l1_state();
    CHECK(almost_equal(l1.best_ask, 100.0), "ask remains with leftover size");
    CHECK(ob.trade_log.size() == 1, "one trade recorded");

    // Now consume the remaining 6 and rest 2 on the bid.
    Order b2 = mk(3, 'B', 100.0, 8.0);
    r = ob.process_add(b2, 3);
    CHECK(almost_equal(r.filled_size, 6.0), "second taker filled remaining 6");
    l1 = ob.get_l1_state();
    CHECK(l1.best_ask == 0.0, "ask book empty after full consume");
    CHECK(almost_equal(l1.best_bid, 100.0), "leftover 2 rests as bid");
}

static void test_multi_level_sweep_vwap() {
    OrderBook ob;
    // Ask ladder: 100x5, 101x5, 102x5
    Order a1 = mk(1, 'S', 101.0, 5.0);
    Order a2 = mk(2, 'S', 100.0, 5.0);
    Order a3 = mk(3, 'S', 102.0, 5.0);
    ob.process_add(a1, 1);
    ob.process_add(a2, 2);
    ob.process_add(a3, 3);

    // Aggressive buy 12 @ 102 sweeps 5@100 + 5@101 + 2@102.
    Order b = mk(4, 'B', 102.0, 12.0);
    FillReport r = ob.process_add(b, 4);
    CHECK(almost_equal(r.filled_size, 12.0), "swept 12");
    const double expected_vwap = (5 * 100.0 + 5 * 101.0 + 2 * 102.0) / 12.0;
    CHECK(almost_equal(r.avg_fill_price, expected_vwap), "VWAP across 3 levels");
    CHECK(ob.trade_log.size() == 3, "three trades from sweep");

    L1State l1 = ob.get_l1_state();
    CHECK(almost_equal(l1.best_ask, 102.0), "top ask now 102 with 3 left");
}

static void test_price_time_priority() {
    OrderBook ob;
    // Two asks at the same price; earlier one (id=1) must fill first.
    Order a1 = mk(1, 'S', 100.0, 5.0);
    Order a2 = mk(2, 'S', 100.0, 5.0);
    ob.process_add(a1, 1);
    ob.process_add(a2, 2);

    Order b = mk(3, 'B', 100.0, 5.0);
    ob.process_add(b, 3);
    CHECK(ob.trade_log.size() == 1, "one trade");
    CHECK(ob.trade_log[0].maker_id == 1, "earliest order at price filled first (time priority)");
}

static void test_cancel() {
    OrderBook ob;
    Order a1 = mk(1, 'S', 100.0, 5.0);
    Order a2 = mk(2, 'S', 101.0, 5.0);
    ob.process_add(a1, 1);
    ob.process_add(a2, 2);
    ob.process_cancel(1, 'S');

    L1State l1 = ob.get_l1_state();
    CHECK(almost_equal(l1.best_ask, 101.0), "best ask moves to 101 after cancel");

    // Cancelling a non-existent id must be a no-op (no crash).
    ob.process_cancel(999, 'S');
    ob.process_cancel(999, 'B');
    l1 = ob.get_l1_state();
    CHECK(almost_equal(l1.best_ask, 101.0), "phantom cancel is a no-op");
}

// ---------------------------------------------------------------------------
// 2. Randomized stress with invariant checking
// ---------------------------------------------------------------------------
static void stress_random(size_t num_ops, unsigned seed) {
    OrderBook ob;
    std::mt19937_64 rng(seed);
    std::uniform_int_distribution<int> op_pick(0, 9);   // 0-6 add, 7-9 cancel
    std::uniform_int_distribution<int> side_pick(0, 1);
    std::uniform_real_distribution<double> price_pick(90.0, 110.0);
    std::uniform_real_distribution<double> size_pick(1.0, 100.0);

    std::vector<std::pair<uint64_t, char>> live; // ids we might cancel
    live.reserve(num_ops);
    uint64_t next_id = 1;
    size_t crossed_violations = 0;

    auto t0 = std::chrono::high_resolution_clock::now();
    for (size_t i = 0; i < num_ops; ++i) {
        int op = op_pick(rng);
        if (op <= 6 || live.empty()) {
            char side = side_pick(rng) ? 'B' : 'S';
            double price = std::round(price_pick(rng) * 100.0) / 100.0;
            double size = std::round(size_pick(rng));
            Order o = mk(next_id, side, price, size);
            ob.process_add(o, i + 1);
            if (o.size > 0.0) live.emplace_back(next_id, side); // rested (maybe partially)
            ++next_id;
        } else {
            std::uniform_int_distribution<size_t> idx(0, live.size() - 1);
            size_t k = idx(rng);
            ob.process_cancel(live[k].first, live[k].second);
            live[k] = live.back();
            live.pop_back();
        }

        // INVARIANT: the resting book must never be crossed.
        L1State l1 = ob.get_l1_state();
        if (l1.best_bid > 0.0 && l1.best_ask > 0.0 && l1.best_bid >= l1.best_ask) {
            ++crossed_violations;
        }
    }
    auto t1 = std::chrono::high_resolution_clock::now();
    double us = std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();

    CHECK(crossed_violations == 0, "resting book never crossed under random stress");

    std::printf("  ops=%zu seed=%u  time=%.2f ms  throughput=%.2f M ops/s  trades=%zu  crossed=%zu\n",
                num_ops, seed, us / 1000.0,
                (us > 0 ? num_ops / us : 0.0), ob.trade_log.size(), crossed_violations);
}

// A pathological case: one huge aggressive order sweeping a deep book.
static void stress_deep_sweep(size_t levels) {
    OrderBook ob;
    for (size_t i = 0; i < levels; ++i) {
        Order a = mk(i + 1, 'S', 100.0 + static_cast<double>(i) * 0.01, 10.0);
        ob.process_add(a, i + 1);
    }
    Order b = mk(1'000'000, 'B', 1e9, 10.0 * levels); // buy everything
    auto t0 = std::chrono::high_resolution_clock::now();
    FillReport r = ob.process_add(b, 1);
    auto t1 = std::chrono::high_resolution_clock::now();
    double us = std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();

    CHECK(almost_equal(r.filled_size, 10.0 * levels), "deep sweep fills entire book");
    L1State l1 = ob.get_l1_state();
    CHECK(l1.best_ask == 0.0, "ask book fully cleared");
    std::printf("  deep_sweep levels=%zu  filled=%.0f  sweep_time=%.2f ms  trades=%zu\n",
                levels, r.filled_size, us / 1000.0, ob.trade_log.size());
}

int main() {
    std::cout << "=== OrderBook correctness ===\n";
    test_no_cross_rests();
    test_full_and_partial_fill();
    test_multi_level_sweep_vwap();
    test_price_time_priority();
    test_cancel();
    std::cout << "  correctness checks done\n\n";

    std::cout << "=== OrderBook randomized stress ===\n";
    stress_random(100'000, 1);
    stress_random(500'000, 2);
    stress_random(1'000'000, 3);
    std::cout << "\n=== OrderBook deep-sweep stress ===\n";
    stress_deep_sweep(1'000);
    stress_deep_sweep(10'000);

    std::cout << "\n=== SUMMARY ===\n";
    std::printf("  checks: %d   failures: %d\n", g_checks, g_failures);
    if (g_failures == 0) {
        std::cout << "  ALL CHECKS PASSED\n";
        return 0;
    }
    std::cout << "  SOME CHECKS FAILED\n";
    return 1;
}
