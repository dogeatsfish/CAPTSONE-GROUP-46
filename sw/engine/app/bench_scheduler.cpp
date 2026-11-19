// bench_scheduler -- how fast does the engine actually fan a trade out?
//
// The latency model (in_ns / out_ns) is bookkeeping: it adds a number to a
// timestamp and costs nothing. What would bound a real system is the engine's
// own wall-clock overhead -- heap push/pop, building the L2 snapshot,
// dispatching callbacks, updating accounts. That is what this measures.
//
// Two numbers per run:
//
//   fan-out      wall time from "the trade hits the book" to "the last
//                participant's callback has returned". This is the one that
//                matters if everyone's link is sub-microsecond: no participant
//                can hear about a trade sooner than this, whatever its
//                LatencyProfile says.
//   per recipient  the same number divided by the participant count, i.e. the
//                marginal cost of one more listener.
//
// Percentiles, not just a mean: the tail is what bites. The heap grows and
// shrinks, std::map allocates, and the OS can preempt mid-publish.
//
//   make bench                      # 1, 2, 4, ... 256 participants
//   make bench BENCH_TRIALS=20000   # more samples per point
//
// Deliberately not in CI: wall-clock timing on a shared runner is noise.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "scheduler.h"

namespace {

using Clock = std::chrono::steady_clock;

constexpr ParticipantId FEED = 0;

// Does nothing but count, so the measurement is engine overhead and not
// strategy logic. Virtual calls are still made, which is the point: that
// dispatch cost is real.
struct Listener : Participant {
    uint64_t trades = 0, books = 0, fills = 0;
    void on_trade(const BookEvent&) override { ++trades; }
    void on_book_update(const L2State&) override { ++books; }
    void on_fill(const BookEvent&) override { ++fills; }
};

Order make(uint64_t id, char side, double price, double size) {
    return Order{id, price, size, side, false};
}

double percentile(std::vector<double>& v, double p) {
    if (v.empty()) return 0.0;
    const size_t i = static_cast<size_t>(p * (v.size() - 1));
    std::nth_element(v.begin(), v.begin() + i, v.end());
    return v[i];
}

// How long does the clock itself take? Everything below is only meaningful
// well above this.
double clock_overhead_ns() {
    constexpr int N = 200000;
    const auto t0 = Clock::now();
    for (int i = 0; i < N; ++i) { volatile auto t = Clock::now(); (void)t; }
    const auto t1 = Clock::now();
    return std::chrono::duration<double, std::nano>(t1 - t0).count() / N;
}

struct Result {
    size_t participants;
    double p50, p99, max, mean;
    uint64_t deliveries;
};

Result run(size_t n_participants, int trials) {
    Scheduler s;
    std::vector<Listener> listeners(n_participants);
    for (size_t i = 0; i < n_participants; ++i) {
        s.add_participant(static_cast<ParticipantId>(i + 1), listeners[i]);
        // Sub-microsecond link for everyone: 200 ns each way. The simulated
        // numbers do not affect wall-clock cost; this is just a realistic
        // colocated setup.
        LatencyProfile lat;
        lat.uniform(200, 200);
        lat.compute_ns = 0;
        s.set_latency(static_cast<ParticipantId>(i + 1), lat);
    }

    // Resting liquidity for the trades to hit: one ask per trial, all at the
    // same price so each aggressor matches exactly one maker.
    uint64_t next_id = 1;
    uint64_t t = 0;
    for (int i = 0; i < trials + 16; ++i) {
        s.schedule(t, FEED, Action::add(make(next_id++, 'S', 100.0, 10)));
    }
    while (!s.empty()) s.step(); // settle the book and drain the setup traffic

    std::vector<double> samples;
    samples.reserve(trials);
    uint64_t deliveries = 0;

    for (int i = 0; i < trials; ++i) {
        t += 1'000'000; // a clear millisecond between trades
        s.schedule(t, FEED, Action::add(make(next_id++, 'B', 100.0, 10)));

        const auto t0 = Clock::now();
        // One BookAction (the match) plus every delivery it produced.
        size_t steps = 0;
        while (!s.empty()) { s.step(); ++steps; }
        const auto t1 = Clock::now();

        deliveries += steps;
        samples.push_back(std::chrono::duration<double, std::nano>(t1 - t0).count());
    }

    Result r{};
    r.participants = n_participants;
    r.deliveries   = deliveries / (trials ? trials : 1);
    double sum = 0;
    for (double v : samples) sum += v;
    r.mean = sum / samples.size();
    r.p50  = percentile(samples, 0.50);
    r.p99  = percentile(samples, 0.99);
    r.max  = *std::max_element(samples.begin(), samples.end());
    return r;
}

} // namespace

int main(int argc, char* argv[]) {
    int trials = 5000;
    if (argc > 1) trials = std::atoi(argv[1]);
    if (trials < 100) trials = 100;

    std::printf("Scheduler fan-out benchmark\n");
    std::printf("  %d trades per point, one maker consumed each time\n", trials);
    std::printf("  clock overhead: %.1f ns per Clock::now()\n\n", clock_overhead_ns());

    std::printf("  %12s %8s %10s %10s %10s %14s\n",
                "participants", "steps", "p50 (ns)", "p99 (ns)", "max (ns)", "p50/recipient");
    std::printf("  %12s %8s %10s %10s %10s %14s\n",
                "------------", "-----", "--------", "--------", "--------", "-------------");

    for (size_t n : {size_t(1), size_t(2), size_t(4), size_t(8), size_t(16),
                     size_t(32), size_t(64), size_t(128), size_t(256)}) {
        const Result r = run(n, trials);
        std::printf("  %12zu %8llu %10.0f %10.0f %10.0f %12.1f ns\n",
                    r.participants, (unsigned long long)r.deliveries,
                    r.p50, r.p99, r.max, r.p50 / static_cast<double>(n));
    }

    std::printf("\nRead this as: with N participants on sub-microsecond links, no one can\n");
    std::printf("hear about a trade sooner than the p50 column, because that is how long\n");
    std::printf("the engine itself takes to get through the fan-out. The last column is\n");
    std::printf("the marginal cost of adding one more listener.\n");
    return 0;
}
