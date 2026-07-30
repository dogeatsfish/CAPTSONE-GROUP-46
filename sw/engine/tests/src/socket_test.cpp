// socket_test: drive the ONLINE simulation with a generated market-data book
// and act as the external "user strategy" over the OUCH socket.
//
// Market data (tests/data/market_ladder.bin, produced by
// tests/src/gen_market_ladder.py): 100 Add orders forming a rising BID ladder
// 100.00, 100.05, ... (size 100, 50 ms apart). Because the resting book is
// bids, an incoming SELL that crosses is aggressive.
//
// This test:
//   1. runs OnlineSimulation on the ladder file (real-time pacing),
//   2. connects to the engine's OUCH TCP port,
//   3. sends an aggressive SELL add order @ 99  (crosses -> sweeps top bids),
//   4. sends another SELL add order        @ 100 (crosses remaining bids),
//   5. reads the OUCH execution report for each, then prints final telemetry.
//
// The online engine makes NO trading decision itself; every order here arrives
// over the socket, exactly like a co-located FPGA/strategy would send it.

#include "online_simulation.h"
#include "offline_simulation.h" // MBORecord
#include "protocol.h"
#include "ini_config.h"

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

const char* DEFAULT_CONFIG_PATH = "tests/config/socket_test.ini";

// Fallback: regenerate the ladder book if it is missing, so the test is
// self-contained. Must match tests/src/gen_market_ladder.py.
bool ensure_market_book(const std::string& path) {
    struct stat st;
    if (::stat(path.c_str(), &st) == 0 && st.st_size > 0) return true; // already present

    ::mkdir("tests/data", 0755);
    FILE* fp = std::fopen(path.c_str(), "wb");
    if (fp == nullptr) return false;

    const uint64_t base_ns = 1'000'000'000'000'000'000ULL;
    const uint64_t step_ns = 50'000'000ULL; // 50 ms
    for (uint64_t i = 0; i < 100; ++i) {
        MBORecord rec{
            base_ns + i * step_ns,
            'A',
            i + 1,
            'B',
            100.00 + static_cast<double>(i) * 0.05,
            100.0};
        std::fwrite(&rec, sizeof(MBORecord), 1, fp);
    }
    std::fclose(fp);
    return true;
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

// Send one OUCH ENTER order and print the execution/accept report.
bool send_order(int fd, uint64_t id, char side, double price, double size) {
    const std::vector<uint8_t> pkt = protocol::to_ouch_enter(id, side, price, size);
    if (::send(fd, pkt.data(), pkt.size(), 0) != static_cast<ssize_t>(pkt.size())) {
        std::cerr << "FAIL: send OUCH order id=" << id << "\n";
        return false;
    }
    std::cout << "-> OUCH ENTER  id=" << id << " " << side << " " << size
              << " @ " << price << "\n";

    uint8_t resp[protocol::OUCH_RESPONSE_LEN];
    if (!recv_exact(fd, resp, sizeof(resp), 2.0)) {
        std::cerr << "FAIL: no OUCH response for id=" << id << "\n";
        return false;
    }
    protocol::OuchResponse r;
    if (!protocol::from_ouch_response(resp, sizeof(resp), r)) {
        std::cerr << "FAIL: bad OUCH response for id=" << id << "\n";
        return false;
    }
    std::cout << "<- OUCH " << (r.type == protocol::OUCH_EXECUTED ? "EXECUTED" : "ACCEPTED")
              << " id=" << r.order_id << " size=" << r.size << " price=" << r.price << "\n";
    return true;
}

} // namespace

int main(int argc, char* argv[]) {
    std::cout << "=== socket_test: OUCH client vs rising bid ladder ===\n";

    const std::string config_path = argc > 1 ? argv[1] : DEFAULT_CONFIG_PATH;
    IniConfig ini;
    if (!ini.load(config_path)) return 1;

    const std::string itch_address = ini.get_string("itch_address", "127.0.0.1");
    const uint16_t     ITCH_PORT   = ini.get_port("itch_port", 27200);
    const uint16_t     OUCH_PORT   = ini.get_port("ouch_port", 27201);
    const std::string ouch_transport = ini.get_string("ouch_transport", "tcp");
    const std::string market_book  = ini.get_string("market_book", "tests/data/market_ladder.bin");

    // The OUCH client below only speaks TCP; catch a udp-configured .ini here
    // instead of silently hanging on connect_ouch().
    if (ouch_transport != "tcp") {
        std::cerr << "FAIL: " << config_path << " sets ouch_transport=" << ouch_transport
                  << ", but this test's OUCH client only supports TCP\n";
        return 1;
    }

    if (!ensure_market_book(market_book)) {
        std::cerr << "FAIL: could not find or create " << market_book << "\n";
        return 1;
    }
    std::cout << "Config: " << config_path << "\n";
    std::cout << "Market data: " << market_book << " (100 bid adds, 100.00 step +0.05, 50ms)\n";

    OnlineSimulation::Config cfg;
    cfg.itch_address   = itch_address;
    cfg.ouch_transport = OnlineSimulation::OuchTransport::TCP;
    cfg.itch_port  = ITCH_PORT;
    cfg.ouch_port  = OUCH_PORT;
    cfg.time_scale = ini.get_double("time_scale", 1.0);

    OnlineSimulation sim(market_book, cfg);

    SimulationResult result;
    std::thread sim_thread([&]() { result = sim.run(); });

    // Let a chunk of the bid ladder rest (each record is 50 ms apart), then act.
    std::this_thread::sleep_for(std::chrono::milliseconds(1000));

    bool ok = true;
    const int fd = connect_ouch(OUCH_PORT);
    if (fd < 0) {
        std::cerr << "FAIL: could not connect to OUCH port " << OUCH_PORT << "\n";
        ok = false;
    } else {
        // (3) aggressive SELL @ 99 -> crosses the highest resting bid(s).
        ok &= send_order(fd, 900'000'001ULL, 'S', 99.0, 100.0);
        // (4) another SELL @ 100 -> crosses the next resting bid(s).
        ok &= send_order(fd, 900'000'002ULL, 'S', 100.0, 100.0);
        ::close(fd);
    }

    sim_thread.join();

    std::cout << "\n--- Result ---\n";
    std::cout << "Total trades: " << result.total_trades << "\n";
    if (!result.pnl_curve.empty()) {
        const PnLSnapshot& last = result.pnl_curve.back();
        std::cout << "Final position:   " << last.position_size << "\n";
        std::cout << "Final realized:   " << last.realized_pnl << "\n";
        std::cout << "Final unrealized: " << last.unrealized_pnl << "\n";
    }

    if (result.total_trades < 2) {
        std::cerr << "FAIL: expected at least 2 OUCH-driven trades\n";
        ok = false;
    }

    std::cout << (ok ? "PASS" : "FAILED") << "\n";
    return ok ? 0 : 1;
}
