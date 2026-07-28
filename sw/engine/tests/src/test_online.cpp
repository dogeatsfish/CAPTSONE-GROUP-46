// End-to-end test for the online (real-time) simulation.
//
// Market data comes from the book produced by tests/src/gen_market_ladder.py
// (EventGenerator.generate_events): 100 Add orders forming a rising BID ladder
// 100.00, 100.05, ... 104.95 (size 100, 50 ms apart), written to
// tests/data/market_ladder.bin. Run the generator before this test (the
// `make test-online` target does so automatically).
//
// The test:
//   1. Subscribes to the ITCH UDP broadcast BEFORE the run starts, so it
//      captures every market-data packet (all 'A' adds).
//   2. Runs OnlineSimulation::run() on a background thread.
//   3. Connects to the OUCH TCP port and, because the resting book is bids,
//      sends two aggressive-side (SELL) orders:
//        - one that WILL execute  (priced <= the resting bids -> crosses),
//        - one that WON'T execute (priced far above any bid -> rests).
//   4. Verifies the two OUCH responses (EXECUTED vs ACCEPTED) and the run's
//      final telemetry.

#include "online_simulation.h"
#include "offline_simulation.h" // MBORecord (layout reference)
#include "protocol.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <thread>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>

namespace {

const char*        MARKET_BOOK = "tests/data/market_ladder.bin";
constexpr uint16_t ITCH_PORT   = 27100;
constexpr uint16_t OUCH_PORT   = 27101;

// Bind a UDP socket to receive the ITCH broadcast. Returns -1 on failure.
int open_itch_subscriber(uint16_t port) {
    const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;

    int yes = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    timeval tv{0, 300'000}; // 300 ms so the listener can poll its run flag
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    ::inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

int connect_ouch(uint16_t port) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    ::inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

bool recv_exact(int fd, uint8_t* buf, size_t len, double timeout_s) {
    size_t have = 0;
    while (have < len) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        timeval tv{static_cast<time_t>(timeout_s),
                   static_cast<suseconds_t>((timeout_s - static_cast<long>(timeout_s)) * 1e6)};
        const int ready = ::select(fd + 1, &rfds, nullptr, nullptr, &tv);
        if (ready <= 0) return false;
        const ssize_t n = ::recv(fd, buf + have, len - have, 0);
        if (n <= 0) return false;
        have += static_cast<size_t>(n);
    }
    return true;
}

// Send one OUCH ENTER order and return its decoded response.
bool send_and_recv(int fd, uint64_t id, char side, double price, double size,
                   protocol::OuchResponse& out) {
    const std::vector<uint8_t> pkt = protocol::to_ouch_enter(id, side, price, size);
    if (::send(fd, pkt.data(), pkt.size(), 0) != static_cast<ssize_t>(pkt.size())) {
        std::cerr << "FAIL: send OUCH id=" << id << "\n";
        return false;
    }
    std::cout << "-> OUCH ENTER id=" << id << " " << side << " " << size
              << " @ " << price << "\n";

    uint8_t resp[protocol::OUCH_RESPONSE_LEN];
    if (!recv_exact(fd, resp, sizeof(resp), 2.0)) {
        std::cerr << "FAIL: no OUCH response for id=" << id << "\n";
        return false;
    }
    if (!protocol::from_ouch_response(resp, sizeof(resp), out)) {
        std::cerr << "FAIL: bad OUCH response for id=" << id << "\n";
        return false;
    }
    std::cout << "<- OUCH " << (out.type == protocol::OUCH_EXECUTED ? "EXECUTED" : "ACCEPTED")
              << " id=" << out.order_id << " size=" << out.size
              << " price=" << out.price << "\n";
    return true;
}

} // namespace

int main() {
    std::cout << "=== OnlineSimulation end-to-end test ===\n";

    std::cout << "Market data: " << MARKET_BOOK << " (100 bid adds, 100.00 step +0.05)\n";

    // --- Subscribe to the ITCH broadcast BEFORE the simulation runs ---
    const int itch_fd = open_itch_subscriber(ITCH_PORT);
    if (itch_fd < 0) {
        std::cerr << "FAIL: could not bind ITCH subscriber on port " << ITCH_PORT << "\n";
        return 1;
    }

    std::atomic<bool> udp_running{true};
    std::vector<char> itch_types;

    std::thread itch_listener([&]() {
        uint8_t buf[2048];
        while (udp_running.load(std::memory_order_relaxed)) {
            const ssize_t n = ::recv(itch_fd, buf, sizeof(buf), 0);
            if (n <= 0) continue;
            itch_types.push_back(static_cast<char>(buf[0]));
        }
    });

    OnlineSimulation::Config cfg;
    cfg.itch_port  = ITCH_PORT;
    cfg.ouch_port  = OUCH_PORT;
    cfg.time_scale = 1.0; // real time; the 100-order ladder streams over ~5s

    OnlineSimulation sim(MARKET_BOOK, cfg);

    SimulationResult result;
    std::thread sim_thread([&]() { result = sim.run(); });

    // Let part of the bid ladder rest (first bid @100.00 is present from t0).
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    bool ok = true;

    const int fd = connect_ouch(OUCH_PORT);
    if (fd < 0) {
        std::cerr << "FAIL: could not connect to OUCH port " << OUCH_PORT << "\n";
        ok = false;
    } else {
        protocol::OuchResponse r_exec, r_rest;

        if (send_and_recv(fd, 900'000'001ULL, 'S', 100.00, 100.0, r_exec)) {
            if (r_exec.type != protocol::OUCH_EXECUTED) {
                std::cerr << "FAIL: order 1 expected EXECUTED, got '" << r_exec.type << "'\n";
                ok = false;
            }
        } else {
            ok = false;
        }

        // Order that WON'T execute: SELL @ 200.00 is above every bid, so it
        // cannot cross and rests in the book -> accepted, not executed.
        if (send_and_recv(fd, 900'000'002ULL, 'S', 200.00, 100.0, r_rest)) {
            if (r_rest.type != protocol::OUCH_ACCEPTED) {
                std::cerr << "FAIL: order 2 expected ACCEPTED, got '" << r_rest.type << "'\n";
                ok = false;
            }
        } else {
            ok = false;
        }

        ::close(fd);
    }

    sim_thread.join();

    // Stop the ITCH listener (allow a moment to drain the last datagrams).
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    udp_running.store(false, std::memory_order_relaxed);
    itch_listener.join();
    ::close(itch_fd);

    // --- Verify the ITCH broadcast: 100 Add packets from the 100-order book ---
    std::cout << "ITCH packets received: " << itch_types.size() << "\n";
    if (itch_types.empty()) {
        std::cerr << "FAIL: no ITCH packets received\n";
        ok = false;
    }
    for (char t : itch_types) {
        if (t != protocol::ITCH_ADD) {
            std::cerr << "FAIL: non-Add ITCH packet '" << t << "'\n";
            ok = false;
            break;
        }
    }

    // Only the executing SELL produced a trade; the resting SELL did not.
    std::cout << "Total trades: " << result.total_trades << "\n";
    if (result.total_trades != 1) {
        std::cerr << "FAIL: expected exactly 1 executed trade, got "
                  << result.total_trades << "\n";
        ok = false;
    }

    std::cout << (ok ? "PASS" : "FAILED") << "\n";
    return ok ? 0 : 1;
}
