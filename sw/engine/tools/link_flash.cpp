// link_flash -- "is anything reaching the board?"
//
// Sends well-formed ITCH Add-Order messages at the FPGA, one at a time, at a
// rate slow enough to watch. Every packet the board receives flashes its green
// LED, so this is a visual link check: run it, look at the board.
//
// There is nothing to assert and nothing to grep. The board has no ARP, no
// ICMP and no TCP, so it never acknowledges anything -- this tool cannot tell
// you a packet arrived, only that it was sent. Your eyes close the loop.
// That is also why this is NOT in CI.
//
//   make flash                               # 192.168.0.1, 5/sec, forever
//   make flash FLASH_RATE=1                  # one per second, easier to count
//   make flash FLASH_COUNT=10                # exactly 10, then stop
//   make flash FLASH_ADDR=127.0.0.1          # loopback, to test this tool
//
// If the LED does not flash, the problem is below the software: cabling, the
// PHY, or the host not transmitting. See docs/connection-test.md -- in
// particular, confirm the host has an inet address on the board's subnet and a
// static ARP entry, or the OS silently drops every packet before the wire.
//
// Real ITCH is sent rather than arbitrary bytes so this works whichever way
// the LED is wired: a PHY-driven LED flashes on any frame, an FPGA-driven one
// only flashes on a message the parser accepted.

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include "feed.h"          // MBORecord
#include "online_config.h"      // OnlineConfig, for the shared defaults
#include "protocol.h"
#include "socket_compat.h"

namespace {

std::atomic<bool> g_running{true};

void on_signal(int) { g_running = false; } // Ctrl-C: fall out and report

// A plausible Add Order: a buy that walks between 100.00 and 100.09 so
// successive packets differ, in case anything downstream dedupes.
MBORecord make_record(uint64_t n) {
    MBORecord rec{};
    rec.timestamp_ns = n * 1'000'000ULL;
    rec.message_type = protocol::ITCH_ADD;
    rec.order_id     = n + 1;
    rec.side         = 'B';
    rec.price        = 100.00 + static_cast<double>(n % 10) * 0.01;
    rec.size         = 100.0;
    return rec;
}

} // namespace

int main(int argc, char* argv[]) {
    const OnlineConfig defaults;

    std::string address = defaults.itch_address; // 192.168.0.1
    uint16_t    port    = defaults.itch_port;    // 50001
    double      rate    = 5.0;                   // packets per second
    uint64_t    count   = 0;                     // 0 = until Ctrl-C

    if (argc > 1) address = argv[1];
    if (argc > 2) rate    = std::atof(argv[2]);
    if (argc > 3) count   = std::strtoull(argv[3], nullptr, 10);
    if (argc > 4) port    = static_cast<uint16_t>(std::atoi(argv[4]));

    if (rate <= 0.0) {
        std::fprintf(stderr, "Rate must be greater than 0 (got %g).\n", rate);
        return 2;
    }

    std::signal(SIGINT, on_signal);
#ifdef SIGTERM
    std::signal(SIGTERM, on_signal);
#endif

    net::Session session; // no-op off Windows; brings up Winsock there
    if (!session.ok()) {
        std::fprintf(stderr, "Could not initialise the socket library.\n");
        return 1;
    }

    const net::socket_t fd = net::open_udp();
    if (fd == net::INVALID_SOCK) {
        std::fprintf(stderr, "Could not open a UDP socket.\n");
        return 1;
    }
    const sockaddr_in dest = net::make_addr(address.c_str(), port);

    std::printf("========================================\n");
    std::printf("Link flash -- watch the board's LED\n");
    std::printf("Sending to:  udp %s:%u\n", address.c_str(), port);
    std::printf("Rate:        %g packet%s/sec\n", rate, rate == 1.0 ? "" : "s");
    if (count > 0) std::printf("Count:       %llu\n", (unsigned long long)count);
    else           std::printf("Count:       continuous -- Ctrl-C to stop\n");
    std::printf("========================================\n");

    const auto interval = std::chrono::duration<double>(1.0 / rate);
    uint64_t sent = 0, failed = 0;

    while (g_running && (count == 0 || sent < count)) {
        const std::vector<uint8_t> itch = protocol::to_itch(make_record(sent),
                                                            defaults.stock_locate);
        const std::vector<uint8_t> packet =
            protocol::to_moldudp64({itch}, sent + 1, defaults.session);

        const long n = net::send_to(fd, packet.data(), packet.size(), dest);
        if (n < 0) {
            ++failed;
            // Almost always a host-side problem: no route to the board's
            // subnet, or no static ARP entry so the OS cannot resolve a MAC.
            std::printf("  packet %llu FAILED to send\n", (unsigned long long)(sent + 1));
        } else {
            std::printf("  sent packet %llu  (%zu bytes)\n",
                        (unsigned long long)(sent + 1), packet.size());
        }
        std::fflush(stdout); // unbuffered, so the console keeps pace with the LED
        ++sent;

        if (count == 0 || sent < count) std::this_thread::sleep_for(interval);
    }

    net::close_socket(fd);

    std::printf("\n=== Done ===\n");
    std::printf("Packets sent:   %llu\n", (unsigned long long)(sent - failed));
    if (failed > 0) {
        std::printf("Packets failed: %llu  <- the host could not put these on the wire;\n",
                    (unsigned long long)failed);
        std::printf("                see docs/connection-test.md step 1 (IP + static ARP)\n");
        return 1;
    }
    std::printf("\nDid the board's LED flash? If yes, frames are reaching it and\n");
    std::printf("anything still broken is inside the FPGA. If no, see\n");
    std::printf("docs/connection-test.md -- the host may not be transmitting at all.\n");
    return 0;
}
