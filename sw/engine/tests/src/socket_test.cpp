// socket_test: drive the ONLINE simulation with a generated market-data book
// and act as the external "user strategy" over the OUCH socket.
//
// One binary, three scenarios selected entirely by .ini (see tests/config/):
//   socket_test.ini   -- loopback smoke test: two aggressive SELLs that both
//                         cross a rising bid ladder (`make socket-test`).
//   flood_test.ini    -- same client behavior, far denser resting book
//                         (`make flood-test`); see tests/src/gen_test_datasets.py.
//   test_online.ini   -- fuller end-to-end check: also subscribes to and
//                         verifies the ITCH broadcast, and checks each OUCH
//                         response's exact type (EXECUTED vs ACCEPTED), not
//                         just a trade count (`make test-online`).
//
// Market data (tests/data/market_ladder.bin, produced by
// tests/src/gen_market_ladder.py): 100 Add orders forming a rising BID ladder
// 100.00, 100.05, ... (size 100, 50 ms apart). Because the resting book is
// bids, an incoming SELL that crosses is aggressive.
//
// Config keys (defaults reproduce the original hardcoded socket_test
// behavior, so socket_test.ini/flood_test.ini don't need to set any of
// these -- only test_online.ini overrides them):
//   [orders]     order_count (default 2), orderN_side/price/size (defaults:
//                order1 = S 99.0, order2+ = S 100.0, size 100.0),
//                orderN_expect = EXECUTED | ACCEPTED | any (default any --
//                print the response but don't assert its type)
//   [assertions] min_trades (default 2), max_trades (default -1 = unbounded),
//                verify_itch (default false)
//   [timing]     pre_send_delay_ms (default 1000) -- how long to let the book
//                build up before sending the configured orders

#include "online_simulation.h"
#include "offline_simulation.h" // MBORecord
#include "protocol.h"
#include "ini_config.h"

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

const char* DEFAULT_CONFIG_PATH = "tests/config/socket_test.ini";

struct OrderSpec {
    uint64_t id;
    char side;
    double price;
    double size;
    char expect_type; // 0 = "any" -- print the response, don't assert its type
};

char parse_expect(const std::string& s) {
    if (s == "EXECUTED") return protocol::OUCH_EXECUTED;
    if (s == "ACCEPTED") return protocol::OUCH_ACCEPTED;
    return 0;
}

// order1 defaults to the aggressive-sweep price (99.0), every order after it
// defaults to 100.0 -- this reproduces the two scenarios that used to be
// hardcoded verbatim, so neither needs to spell out order1_price/order2_price.
std::vector<OrderSpec> load_orders(const IniConfig& ini) {
    const int count = ini.get_int("order_count", 2);
    std::vector<OrderSpec> orders;
    orders.reserve(static_cast<size_t>(count));
    for (int i = 1; i <= count; ++i) {
        const std::string prefix = "order" + std::to_string(i) + "_";
        OrderSpec spec;
        spec.id = 900'000'000ULL + static_cast<uint64_t>(i);
        spec.side = ini.get_string(prefix + "side", "S")[0];
        spec.price = ini.get_double(prefix + "price", i == 1 ? 99.0 : 100.0);
        spec.size = ini.get_double(prefix + "size", 100.0);
        spec.expect_type = parse_expect(ini.get_string(prefix + "expect", "any"));
        orders.push_back(spec);
    }
    return orders;
}

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

// Bind a UDP socket to receive the ITCH broadcast. Returns -1 on failure.
int open_itch_subscriber(const std::string& address, uint16_t port) {
    const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;

    int yes = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    timeval tv{0, 300'000}; // 300 ms so the listener can poll its run flag
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    ::inet_pton(AF_INET, address.c_str(), &addr.sin_addr);

    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

// Connects into the OnlineSimulation's OUCH listener, which always binds
// 0.0.0.0:port -- so this is loopback regardless of cfg.itch_address.
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

// Print a received OUCH packet: raw is binary/gibberish on a terminal, so
// dump the bytes as hex AND decode them into readable fields.
bool print_ouch_packet(const uint8_t* buf, size_t len, protocol::OuchResponse& out) {
    std::printf("   raw OUCH [%zu B]:", len);
    for (size_t i = 0; i < len; ++i) std::printf(" %02X", buf[i]);
    std::printf("\n");

    const bool decoded_ok = protocol::from_ouch_response(buf, len, out);
    if (decoded_ok) {
        const char* kind = (out.type == protocol::OUCH_EXECUTED) ? "EXECUTED"
                          : (out.type == protocol::OUCH_ACCEPTED) ? "ACCEPTED"
                          : "UNKNOWN";
        std::printf("   decoded: type=%s('%c')  order_id=%llu  size=%.4f  price=%.4f\n",
                    kind, (out.type ? out.type : '?'),
                    static_cast<unsigned long long>(out.order_id), out.size, out.price);
    } else {
        std::printf("   decoded: <unrecognised OUCH response frame>\n");
    }
    return decoded_ok;
}

// Send one OUCH ENTER order, print/decode the response, and check it against
// spec.expect_type if the config asked for one ("any" skips the check).
// Clears `ok` (does not set it) on any failure; never sets it true.
void send_order(int fd, const OrderSpec& spec, bool& ok) {
    const std::vector<uint8_t> pkt = protocol::to_ouch_enter(spec.id, spec.side, spec.price, spec.size);
    if (::send(fd, pkt.data(), pkt.size(), 0) != static_cast<ssize_t>(pkt.size())) {
        std::cerr << "FAIL: send OUCH order id=" << spec.id << "\n";
        ok = false;
        return;
    }
    std::cout << "-> OUCH ENTER id=" << spec.id << " " << spec.side << " " << spec.size
              << " @ " << spec.price << "\n";

    uint8_t resp[protocol::OUCH_RESPONSE_LEN];
    if (!recv_exact(fd, resp, sizeof(resp), 2.0)) {
        std::cerr << "FAIL: no OUCH response for id=" << spec.id << "\n";
        ok = false;
        return;
    }

    protocol::OuchResponse r;
    if (!print_ouch_packet(resp, sizeof(resp), r)) {
        std::cerr << "FAIL: bad OUCH response for id=" << spec.id << "\n";
        ok = false;
        return;
    }

    if (spec.expect_type != 0 && r.type != spec.expect_type) {
        std::cerr << "FAIL: order id=" << spec.id << " expected '" << spec.expect_type
                  << "', got '" << r.type << "'\n";
        ok = false;
    }
}

} // namespace

int main(int argc, char* argv[]) {
    std::cout << "=== socket_test: OUCH client vs rising bid ladder ===\n";

    const std::string config_path = argc > 1 ? argv[1] : DEFAULT_CONFIG_PATH;
    IniConfig ini;
    if (!ini.load(config_path)) return 1;
    std::cout << "Config: " << config_path << "\n";

    const std::string itch_address   = ini.get_string("itch_address", "127.0.0.1");
    const uint16_t     ITCH_PORT     = ini.get_port("itch_port", 27200);
    const uint16_t     OUCH_PORT     = ini.get_port("ouch_port", 27201);
    const std::string ouch_transport = ini.get_string("ouch_transport", "tcp");
    const std::string market_book    = ini.get_string("market_book", "tests/data/market_ladder.bin");
    const int  pre_send_delay_ms     = ini.get_int("pre_send_delay_ms", 1000);
    const int  min_trades            = ini.get_int("min_trades", 2);
    const int  max_trades            = ini.get_int("max_trades", -1); // -1 = unbounded
    const bool verify_itch           = ini.get_bool("verify_itch", false);
    const std::vector<OrderSpec> orders = load_orders(ini);

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
    std::cout << "Market data: " << market_book << "\n";

    // --- Optionally subscribe to the ITCH broadcast BEFORE the run starts ---
    int itch_fd = -1;
    std::atomic<bool> udp_running{true};
    std::vector<char> itch_types;
    std::thread itch_listener;

    if (verify_itch) {
        itch_fd = open_itch_subscriber(itch_address, ITCH_PORT);
        if (itch_fd < 0) {
            std::cerr << "FAIL: could not bind ITCH subscriber on " << itch_address
                      << ":" << ITCH_PORT << "\n";
            return 1;
        }
        itch_listener = std::thread([&]() {
            uint8_t buf[2048];
            // The ITCH message sits after the MoldUDP64 header (20 B) and the
            // per-message 2-byte length prefix.
            constexpr size_t type_off =
                protocol::MOLD_HEADER_LEN + protocol::MOLD_MSGLEN_LEN;
            while (udp_running.load(std::memory_order_relaxed)) {
                const ssize_t n = ::recv(itch_fd, buf, sizeof(buf), 0);
                if (n <= 0) continue;
                if (static_cast<size_t>(n) <= type_off) continue; // malformed frame
                itch_types.push_back(static_cast<char>(buf[type_off]));
            }
        });
    }

    OnlineConfig cfg;
    cfg.file_path = market_book;
    cfg.itch_address = "127.0.0.1"; // loopback (the subscriber above, if any, binds here)
    cfg.itch_port  = ITCH_PORT;
    cfg.ouch_port  = OUCH_PORT;
    cfg.time_scale = 1.0; // real time
    // The OUCH client below is a TCP stream client, so run order entry in TCP
    // mode. (The engine defaults to UDP to match the FPGA; see online_simulation.h.)
    cfg.ouch_transport = OuchTransport::TCP;

    OnlineSimulation sim(cfg);

    SimulationResult result;
    std::thread sim_thread([&]() { result = sim.run(); });

    // Let part of the resting book build up before acting.
    std::this_thread::sleep_for(std::chrono::milliseconds(pre_send_delay_ms));

    bool ok = true;
    const int fd = connect_ouch(OUCH_PORT);
    if (fd < 0) {
        std::cerr << "FAIL: could not connect to OUCH port " << OUCH_PORT << "\n";
        ok = false;
    } else {
        for (const OrderSpec& spec : orders) {
            send_order(fd, spec, ok);
        }
        ::close(fd);
    }

    sim_thread.join();

    if (verify_itch) {
        // Allow a moment to drain the last datagrams before stopping.
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        udp_running.store(false, std::memory_order_relaxed);
        itch_listener.join();
        ::close(itch_fd);

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
    }

    std::cout << "\n--- Result ---\n";
    std::cout << "Total trades: " << result.total_trades << "\n";
    if (!result.pnl_curve.empty()) {
        const PnLSnapshot& last = result.pnl_curve.back();
        std::cout << "Final position:   " << last.position_size << "\n";
        std::cout << "Final realized:   " << last.realized_pnl << "\n";
        std::cout << "Final unrealized: " << last.unrealized_pnl << "\n";
    }

    if (result.total_trades < static_cast<uint64_t>(min_trades)) {
        std::cerr << "FAIL: expected at least " << min_trades << " trade(s), got "
                  << result.total_trades << "\n";
        ok = false;
    }
    if (max_trades >= 0 && result.total_trades > static_cast<uint64_t>(max_trades)) {
        std::cerr << "FAIL: expected at most " << max_trades << " trade(s), got "
                  << result.total_trades << "\n";
        ok = false;
    }

    std::cout << (ok ? "PASS" : "FAILED") << "\n";
    return ok ? 0 : 1;
}
