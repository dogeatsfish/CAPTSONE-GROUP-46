// fpga_test: hardware bring-up harness for the real FPGA over Ethernet.
//
// Streams the synthetic MBO market-data stream to the board as ITCH/UDP using
// the DEFAULT networking config (ITCH -> 192.168.0.1:50001, OUCH order entry
// received over UDP on 0.0.0.0:50001), then decodes and prints every OUCH
// packet the FPGA sends back.
//
// Unlike the loopback tests (test_online / socket_test), this talks to real
// hardware: the "client" sending OUCH orders IS the FPGA. Raw OUCH bytes are
// binary, so each received packet is printed as hex AND decoded into fields.
//
// Prerequisites (see docs/connection-test.md):
//   - host NIC configured for the board link:  sudo ./setup/net_setup.sh
//   - board programmed with the bitstream and the Ethernet link up
//
// Usage (from sw/engine):
//   ./fpga_test [mbo_file] [time_scale]
//     mbo_file    default ../data_pipeline/data/synthetic_mbo_stream.bin
//     time_scale  default 1.0 (real time); 0 = no pacing (blast as fast as able)

#include "online_simulation.h"
#include "protocol.h"

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

// Print one received OUCH packet: raw hex followed by decoded fields.
void print_ouch(size_t index, const protocol::OuchMessage& m,
                const uint8_t* raw, size_t len) {
    std::printf("[OUCH #%zu] raw [%zu B]:", index, len);
    for (size_t i = 0; i < len; ++i) std::printf(" %02X", raw[i]);
    std::printf("\n");

    const char* kind = (m.msg_type == protocol::OUCH_ENTER)  ? "ENTER"
                     : (m.msg_type == protocol::OUCH_CANCEL) ? "CANCEL"
                     : "UNKNOWN";
    std::printf("          decoded: type=%s('%c')  order_id=%llu  side=%c  "
                "qty=%.0f  price=%.4f\n",
                kind, (m.msg_type ? m.msg_type : '?'),
                static_cast<unsigned long long>(m.order_id),
                (m.side ? m.side : '-'), m.size, m.price);
}

} // namespace

int main(int argc, char* argv[]) {
    std::string mbo_file = "../data_pipeline/data/synthetic_mbo_stream.bin";
    double      scale    = 1.0;

    if (argc > 1) mbo_file = argv[1];
    if (argc > 2) scale    = std::atof(argv[2]);

    // DEFAULT config: ITCH -> 192.168.0.1:50001, OUCH intake over UDP on 50001.
    OnlineSimulation::Config cfg;
    cfg.time_scale = scale;

    const char* proto =
        (cfg.ouch_transport == OnlineSimulation::OuchTransport::UDP) ? "udp" : "tcp";

    std::cout << "========================================\n";
    std::cout << "FPGA hardware test (real board over Ethernet)\n";
    std::cout << "Market data (MBO): " << mbo_file << "\n";
    std::cout << "ITCH broadcast:    udp " << cfg.itch_address << ":" << cfg.itch_port << "\n";
    std::cout << "OUCH order entry:  " << proto << " 0.0.0.0:" << cfg.ouch_port << "\n";
    std::cout << "Time scale:        " << cfg.time_scale << "x\n";
    std::cout << "Waiting for OUCH orders from the FPGA...\n";
    std::cout << "========================================\n";

    std::atomic<size_t> ouch_count{0};

    OnlineSimulation sim(mbo_file, cfg);

    // Print + decode every OUCH packet the FPGA sends back.
    sim.set_ouch_observer(
        [&ouch_count](const protocol::OuchMessage& m, const uint8_t* raw, size_t len) {
            const size_t n = ++ouch_count;
            print_ouch(n, m, raw, len);
        });

    SimulationResult result = sim.run();

    std::cout << "\n=== FPGA test complete ===\n";
    std::cout << "OUCH packets received from FPGA: " << ouch_count.load() << "\n";
    std::cout << "Elapsed (wall):  " << result.compute_time_us << " us\n";
    if (ouch_count.load() == 0) {
        std::cout << "No OUCH received. Check: bitstream loaded, link up "
                     "(sudo ./setup/net_setup.sh), and that the stream triggers an order.\n";
    }
    return 0;
}
