// End-to-end test for the online (real-time) simulation.
//
// 1. Writes a tiny "test book" binary MBO stream (tests/data/test_book.bin)
//    containing two orders at two consecutive timestamps:
//        t0      : Add ASK  @101 size 100   (rests immediately)
//        t0 + 2s : Add BID  @99  size 100   (rests; does not cross the ask)
//    The 2-second gap keeps the ask resting and the OUCH server alive long
//    enough for a client to connect and trade against it.
//
// 2. Subscribes to the ITCH UDP broadcast BEFORE the simulation starts, so it
//    captures every market-data packet. Both records are 'A' (Add) messages,
//    so exactly two ITCH packets should be received.
//
// 3. Runs OnlineSimulation::run() on a background thread (it broadcasts the
//    stream as ITCH and serves OUCH order entry over TCP).
//
// 4. Opens a TCP connection to the OUCH port, submits an aggressive BUY that
//    lifts the resting ask, and receives the OUCH execution report back.
//
// 5. Verifies: 2 ITCH packets received, the execution report, and the final
//    SimulationResult.

#include "online_simulation.h"
#include "offline_simulation.h" // MBORecord
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

const char*        TEST_DATA_DIR  = "tests/data";
const char*        TEST_BOOK_PATH = "tests/data/test_book.bin";
constexpr uint16_t ITCH_PORT      = 27100;
constexpr uint16_t OUCH_PORT      = 27101;

// --- Build the 2-order test book -----------------------------------------
bool write_test_book(const char* path) {
    const uint64_t t0 = 1'000'000'000'000'000'000ULL; // arbitrary ns epoch
    const uint64_t t1 = t0 + 2'000'000'000ULL;        // +2 s (next timestamp)

    const std::vector<MBORecord> recs = {
        MBORecord{t0, 'A', 1, 'S', 101.0, 100.0}, // resting ask
        MBORecord{t1, 'A', 2, 'B',  99.0, 100.0}, // resting bid (no cross)
    };

    FILE* fp = std::fopen(path, "wb");
    if (fp == nullptr) {
        std::cerr << "FAIL: cannot open " << path << " for writing\n";
        return false;
    }
    const size_t written = std::fwrite(recs.data(), sizeof(MBORecord), recs.size(), fp);
    std::fclose(fp);
    if (written != recs.size()) {
        std::cerr << "FAIL: short write to " << path << "\n";
        return false;
    }
    return true;
}

// Bind a UDP socket to receive the ITCH broadcast. Returns -1 on failure.
int open_itch_subscriber(uint16_t port) {
    const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;

    int yes = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    // Return from recvfrom periodically so the listener can check its run flag.
    timeval tv{0, 300'000}; // 300 ms
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

// --- TCP client helpers ---------------------------------------------------
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

// Receive exactly `len` bytes, honouring a per-call timeout.
bool recv_exact(int fd, uint8_t* buf, size_t len, double timeout_s) {
    size_t have = 0;
    while (have < len) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        timeval tv{static_cast<time_t>(timeout_s),
                   static_cast<suseconds_t>((timeout_s - static_cast<long>(timeout_s)) * 1e6)};

        const int ready = ::select(fd + 1, &rfds, nullptr, nullptr, &tv);
        if (ready <= 0) return false; // timeout or error

        const ssize_t n = ::recv(fd, buf + have, len - have, 0);
        if (n <= 0) return false;
        have += static_cast<size_t>(n);
    }
    return true;
}

} // namespace

int main() {
    std::cout << "=== OnlineSimulation end-to-end test ===\n";

    // Make sure tests/data exists, then write the 2-order book there.
    ::mkdir(TEST_DATA_DIR, 0755); // ignore EEXIST
    if (!write_test_book(TEST_BOOK_PATH)) return 1;
    std::cout << "Wrote 2-order test book: " << TEST_BOOK_PATH << "\n";

    // --- Subscribe to the ITCH broadcast BEFORE the simulation runs ---
    const int itch_fd = open_itch_subscriber(ITCH_PORT);
    if (itch_fd < 0) {
        std::cerr << "FAIL: could not bind ITCH subscriber on port " << ITCH_PORT << "\n";
        return 1;
    }

    std::atomic<bool>  udp_running{true};
    std::vector<char>  itch_types; // message type of each received ITCH packet

    std::thread itch_listener([&]() {
        uint8_t buf[2048];
        while (udp_running.load(std::memory_order_relaxed)) {
            const ssize_t n = ::recv(itch_fd, buf, sizeof(buf), 0);
            if (n <= 0) continue; // timeout / interrupted: re-check flag
            const char type = static_cast<char>(buf[0]);
            itch_types.push_back(type);
            std::cout << "Received ITCH packet #" << itch_types.size()
                      << " type=" << type << " (" << n << " bytes)\n";
        }
    });

    // Real-time pacing so the ask rests for the full 2 s serving window.
    OnlineSimulation::Config cfg;
    cfg.itch_port  = ITCH_PORT;
    cfg.ouch_port  = OUCH_PORT;
    cfg.time_scale = 1.0;

    OnlineSimulation sim(TEST_BOOK_PATH, cfg);

    // Run the simulation on a background thread; capture its result.
    SimulationResult result;
    std::thread sim_thread([&]() { result = sim.run(); });

    // Wait for the OUCH listener to bind and the ask to be resting (added at
    // t0, i.e. right at replay start), but well before the +2 s bid record.
    std::this_thread::sleep_for(std::chrono::milliseconds(800));

    bool ok = true;

    // --- Connect and submit an aggressive BUY that lifts the ask @101 ---
    const int fd = connect_ouch(OUCH_PORT);
    if (fd < 0) {
        std::cerr << "FAIL: could not connect to OUCH port " << OUCH_PORT << "\n";
        ok = false;
    } else {
        const uint64_t client_order_id = 900'000'123ULL;
        const std::vector<uint8_t> enter =
            protocol::to_ouch_enter(client_order_id, 'B', 101.0, 100.0);

        if (::send(fd, enter.data(), enter.size(), 0) != static_cast<ssize_t>(enter.size())) {
            std::cerr << "FAIL: could not send OUCH ENTER order\n";
            ok = false;
        } else {
            std::cout << "Sent OUCH ENTER: BUY 100 @ 101 (id=" << client_order_id << ")\n";

            // --- Receive the execution report back over the same socket ---
            uint8_t resp[protocol::OUCH_RESPONSE_LEN];
            if (!recv_exact(fd, resp, sizeof(resp), 2.0)) {
                std::cerr << "FAIL: did not receive an OUCH response\n";
                ok = false;
            } else {
                protocol::OuchResponse r;
                if (!protocol::from_ouch_response(resp, sizeof(resp), r)) {
                    std::cerr << "FAIL: could not decode OUCH response\n";
                    ok = false;
                } else {
                    std::cout << "Received OUCH response: type=" << r.type
                              << " id=" << r.order_id
                              << " size=" << r.size
                              << " price=" << r.price << "\n";

                    if (r.type != protocol::OUCH_EXECUTED) {
                        std::cerr << "FAIL: expected EXECUTED ('E'), got '" << r.type << "'\n";
                        ok = false;
                    }
                    if (r.order_id != client_order_id) {
                        std::cerr << "FAIL: response order id mismatch\n";
                        ok = false;
                    }
                    if (r.size != 100.0) {
                        std::cerr << "FAIL: expected executed size 100, got " << r.size << "\n";
                        ok = false;
                    }
                    if (r.price != 101.0) {
                        std::cerr << "FAIL: expected fill price 101, got " << r.price << "\n";
                        ok = false;
                    }
                }
            }
        }
        ::close(fd);
    }

    // Let the replay finish (ends just after the +2 s record) and collect result.
    sim_thread.join();

    // Give the listener a moment to drain the last datagram, then stop it.
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    udp_running.store(false, std::memory_order_relaxed);
    itch_listener.join();
    ::close(itch_fd);

    // --- Verify the ITCH broadcast ---
    std::cout << "ITCH packets received: " << itch_types.size() << "\n";
    if (itch_types.size() != 2) {
        std::cerr << "FAIL: expected 2 ITCH packets from the 2-order book, got "
                  << itch_types.size() << "\n";
        ok = false;
    } else {
        for (size_t i = 0; i < itch_types.size(); ++i) {
            if (itch_types[i] != protocol::ITCH_ADD) {
                std::cerr << "FAIL: ITCH packet " << i << " type '" << itch_types[i]
                          << "' (expected 'A')\n";
                ok = false;
            }
        }
    }

    std::cout << "Simulation total trades: " << result.total_trades << "\n";
    if (result.total_trades < 1) {
        std::cerr << "FAIL: expected at least one trade in the result payload\n";
        ok = false;
    }

    std::cout << (ok ? "PASS" : "FAILED") << "\n";
    return ok ? 0 : 1;
}
