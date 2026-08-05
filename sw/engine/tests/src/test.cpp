#include "online_simulation.h"
#include "test.h"
#include <iostream>
#include <string>
#include <cstdlib>

int main(int argc, char* argv[]) {
    OnlineConfig cfg;
    // CLI default file (matches the Makefile's FILE default); overridden below
    // by a positional path or a config's market_book. Everything else keeps
    // its OnlineConfig default unless a config/arg overrides it -- the config
    // defaults live in exactly one place (OnlineConfig), not duplicated here.
    cfg.file_path = "../data_pipeline/data/synthetic_mbo_stream.bin";

    // Config-file mode: the first argument ends in ".ini". Detected on argv[1]
    // alone (not argc), so `make run FILE=foo.ini` works even though the recipe
    // appends SCALE -- any trailing args are ignored, since the .ini carries
    // its own settings (time_scale included).
    const bool from_ini = argc >= 2 &&
        std::string(argv[1]).size() > 4 &&
        std::string(argv[1]).substr(std::string(argv[1]).size() - 4) == ".ini";

    if (from_ini) {
        TestConfig ini;
        if (!ini.load(argv[1])) return 1;
        cfg.file_path      = ini.get_string("market_book", cfg.file_path);
        cfg.itch_address   = ini.get_string("itch_address", cfg.itch_address);
        cfg.itch_port      = ini.get_port("itch_port", cfg.itch_port);
        cfg.ouch_port      = ini.get_port("ouch_port", cfg.ouch_port);
        cfg.time_scale     = ini.get_double("time_scale", cfg.time_scale);
        // Only override the transport when the key is present, so an absent
        // one keeps OnlineConfig's default rather than a duplicated literal.
        if (ini.has("ouch_transport")) {
            const std::string t = ini.get_string("ouch_transport", "udp");
            cfg.ouch_transport = (t == "tcp" || t == "TCP")
                                     ? OuchTransport::TCP
                                     : OuchTransport::UDP;
        }
    } else {
        if (argc > 1) cfg.file_path = argv[1];
        if (argc > 2) cfg.time_scale = std::atof(argv[2]);
        if (argc > 3) cfg.itch_port  = static_cast<uint16_t>(std::atoi(argv[3]));
        if (argc > 4) cfg.ouch_port  = static_cast<uint16_t>(std::atoi(argv[4]));
        if (argc > 5) cfg.itch_address = argv[5];
        if (argc > 6) {
            const std::string t = argv[6];
            cfg.ouch_transport = (t == "tcp" || t == "TCP")
                                     ? OuchTransport::TCP
                                     : OuchTransport::UDP;
        }
    }

    const char* ouch_proto =
        (cfg.ouch_transport == OuchTransport::UDP) ? "udp" : "tcp";

    std::cout << "========================================\n";
    std::cout << "Online (Real-Time) Trading Engine\n";
    std::cout << "Market data (MBO): " << cfg.file_path << "\n";
    std::cout << "ITCH broadcast:    udp " << cfg.itch_address << ":" << cfg.itch_port << "\n";
    std::cout << "OUCH order entry:  " << ouch_proto << " 0.0.0.0:" << cfg.ouch_port << "\n";
    std::cout << "Time scale:        " << cfg.time_scale << "x\n";
    std::cout << "========================================\n";

    OnlineSimulation simulation(cfg);
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
