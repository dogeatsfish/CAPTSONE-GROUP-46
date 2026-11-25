#pragma once

#include <cstdint>
#include <utility>
#include <vector>

// Latency model: how long messages take between a participant and an exchange.
//
//      exchange event at t
//            │  L_in   (exchange -> participant: market data, fills, acks)
//            ▼
//      participant sees it at  t + L_in
//            │  compute (time the participant takes to decide)
//            │  L_out  (participant -> exchange: orders, cancels)
//            ▼
//      its order reaches the book at  t + L_in + compute + L_out
//
// Both legs are per exchange: a participant co-located at venue A is a few
// microseconds from A but hundreds of microseconds from venue B.

using ExchangeId = uint16_t;

struct LatencyLeg {
    uint64_t in_ns  = 0; // exchange -> participant
    uint64_t out_ns = 0; // participant -> exchange
};

struct LatencyProfile {
    LatencyLeg fallback;      // any exchange without its own entry below
    std::vector<std::pair<ExchangeId, LatencyLeg>> per_exchange; // a handful at most
    uint64_t   compute_ns = 0; // decision time, added to every outgoing message

    const LatencyLeg& leg(ExchangeId exchange) const {
        for (const auto& entry : per_exchange) {
            if (entry.first == exchange) return entry.second;
        }
        return fallback;
    }

    void set(ExchangeId exchange, LatencyLeg leg_for_exchange) {
        for (auto& entry : per_exchange) {
            if (entry.first == exchange) {
                entry.second = leg_for_exchange;
                return;
            }
        }
        per_exchange.emplace_back(exchange, leg_for_exchange);
    }

    // Same delay to every exchange.
    static LatencyProfile uniform(uint64_t in_ns, uint64_t out_ns, uint64_t compute_ns = 0) {
        LatencyProfile p;
        p.fallback   = LatencyLeg{in_ns, out_ns};
        p.compute_ns = compute_ns;
        return p;
    }
};

// Named presets. The numbers are illustrative one-way delays chosen to keep
// the tiers an order of magnitude apart, not measurements of any real venue.
enum class LatencyTier : uint8_t {
    Retail,     // broker app over the public internet
    Direct,     // direct market access over a leased line, not co-located
    Colo,       // server in the home exchange's data centre; fibre to the others
    Microwave   // co-located at home, microwave links to the others
};

inline const char* to_string(LatencyTier tier) {
    switch (tier) {
        case LatencyTier::Retail:    return "Retail";
        case LatencyTier::Direct:    return "Direct";
        case LatencyTier::Colo:      return "Colo";
        case LatencyTier::Microwave: return "Microwave";
    }
    return "?";
}

// Builds the per-venue table for a tier. `home` is the exchange the
// participant sits next to (only matters for Colo / Microwave).
inline LatencyProfile latency_preset(LatencyTier tier, ExchangeId home = 0) {
    constexpr uint64_t US = 1'000ULL;      // one microsecond in ns
    constexpr uint64_t MS = 1'000'000ULL;  // one millisecond in ns

    LatencyProfile p;
    switch (tier) {
        case LatencyTier::Retail:
            p.fallback   = LatencyLeg{25 * MS, 25 * MS};
            p.compute_ns = 1 * MS;
            break;
        case LatencyTier::Direct:
            p.fallback   = LatencyLeg{1 * MS, 1 * MS};
            p.compute_ns = 50 * US;
            break;
        case LatencyTier::Colo:
            p.fallback   = LatencyLeg{400 * US, 400 * US}; // fibre to the other venues
            p.set(home, LatencyLeg{5 * US, 5 * US});       // cross-connect in the building
            p.compute_ns = 5 * US;
            break;
        case LatencyTier::Microwave:
            p.fallback   = LatencyLeg{200 * US, 200 * US}; // microwave beats fibre
            p.set(home, LatencyLeg{5 * US, 5 * US});
            p.compute_ns = 5 * US;
            break;
    }
    return p;
}
