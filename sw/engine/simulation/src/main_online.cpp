#include "online_simulation.h"
#include "ini_config.h"
#include <iostream>
#include <string>
#include <cstdlib>

// Usage:
//   online_run [mbo_file] [time_scale] [itch_port] [ouch_port] [itch_address] [ouch_transport]
//   online_run [config.ini]
//
//   mbo_file        packed binary MBO stream (default: data/synthetic_mbo_stream.bin)
//   time_scale      wall-clock pacing factor (default 1.0 = real time; e.g. 0.001
//                   replays 1000x faster; 0 disables pacing)
//   itch_port       UDP port ITCH market data is broadcast to (default 50001)
//   ouch_port       port the OUCH order-entry server listens on (default 50001;
//                   must match the FPGA's OUCH DST_PORT in outbound_tx_generator.sv)
//   itch_address    destination IP for the ITCH UDP feed (default 192.168.0.1, the
//                   FPGA's SRC_IP). For a hardware target, keep this as the FPGA's
//                   IP (unicast) or set a multicast group the FPGA subscribes to.
//                   The OUCH server always listens on 0.0.0.0:ouch_port, so the
//                   FPGA connects in to HOST_IP:ouch_port.
//   ouch_transport  order-entry transport: "udp" (default, matches the FPGA) or
//                   "tcp" (for a streaming software client)
//
// A single argument ending in ".ini" is read as a config file instead (see
// tests/config/*.ini) -- lets one-off scenarios (e.g. `make hw-smoke-test`)
// live as a checked-in file instead of a long positional-arg command line.
int main(int argc, char* argv[]) {
    std::string data_file_path = "data/synthetic_mbo_stream.bin";

    OnlineSimulation::Config cfg; // defaults

    const bool from_ini = argc == 2 &&
        std::string(argv[1]).size() > 4 &&
        std::string(argv[1]).substr(std::string(argv[1]).size() - 4) == ".ini";

    if (from_ini) {
        IniConfig ini;
        if (!ini.load(argv[1])) return 1;
        data_file_path     = ini.get_string("market_book", data_file_path);
        cfg.itch_address   = ini.get_string("itch_address", cfg.itch_address);
        cfg.itch_port      = ini.get_port("itch_port", cfg.itch_port);
        cfg.ouch_port      = ini.get_port("ouch_port", cfg.ouch_port);
        cfg.time_scale     = ini.get_double("time_scale", cfg.time_scale);
        const std::string t = ini.get_string("ouch_transport", "udp");
        cfg.ouch_transport = (t == "tcp" || t == "TCP")
                                 ? OnlineSimulation::OuchTransport::TCP
                                 : OnlineSimulation::OuchTransport::UDP;
    } else {
        if (argc > 1) data_file_path = argv[1];
        if (argc > 2) cfg.time_scale = std::atof(argv[2]);
        if (argc > 3) cfg.itch_port  = static_cast<uint16_t>(std::atoi(argv[3]));
        if (argc > 4) cfg.ouch_port  = static_cast<uint16_t>(std::atoi(argv[4]));
        if (argc > 5) cfg.itch_address = argv[5];
        if (argc > 6) {
            const std::string t = argv[6];
            cfg.ouch_transport = (t == "tcp" || t == "TCP")
                                     ? OnlineSimulation::OuchTransport::TCP
                                     : OnlineSimulation::OuchTransport::UDP;
        }
    }

    const char* ouch_proto =
        (cfg.ouch_transport == OnlineSimulation::OuchTransport::UDP) ? "udp" : "tcp";

    std::cout << "========================================\n";
    std::cout << "Online (Real-Time) Trading Engine\n";
    std::cout << "Market data (MBO): " << data_file_path << "\n";
    std::cout << "ITCH broadcast:    udp " << cfg.itch_address << ":" << cfg.itch_port << "\n";
    std::cout << "OUCH order entry:  " << ouch_proto << " 0.0.0.0:" << cfg.ouch_port << "\n";
    std::cout << "Time scale:        " << cfg.time_scale << "x\n";
    std::cout << "========================================\n";

    OnlineSimulation simulation(data_file_path, cfg);
    SimulationResult result = simulation.run();

    std::cout << "\n=== Simulation Complete ===\n";
    std::cout << "Elapsed (wall):    " << result.compute_time_us << " us ("
              << (result.compute_time_us / 1000.0) << " ms)\n";
    std::cout << "Total trades:      " << result.total_trades << "\n";
    std::cout << "PnL samples:       " << result.pnl_curve.size() << "\n";
    if (!result.pnl_curve.empty()) {
        const PnLSnapshot& last = result.pnl_curve.back();
        std::cout << "Final position:    " << last.position_size << "\n";
        std::cout << "Final realized:    " << last.realized_pnl << "\n";
        std::cout << "Final unrealized:  " << last.unrealized_pnl << "\n";
    }
    std::cout << "Simulation finished successfully.\n";

    return 0;
}
