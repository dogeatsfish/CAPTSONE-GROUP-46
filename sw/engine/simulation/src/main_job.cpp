// Software strategy-compiler job entry point. Not part of the normal `make`
// targets (see Makefile) -- built per-job by strategy_compile_manager.py
// against a job-workspace-local user_strategy.cpp (see
// user_strategy.job_template.cpp), then run once and its result file parsed.
//
// Results go to a FILE (argv[2]), not stdout -- mirrors how the sibling
// Vivado pipeline reports through result.json rather than parsed stdout (see
// compile_alpha_engine.tcl). The submitted on_market_update body runs inside
// simulation.run() below and is free to std::cout/printf for debugging (very
// likely for a student to do); if the JSON payload also went to stdout,
// any such output would corrupt it and turn a working run into an opaque
// "invalid JSON" failure. Writing to a dedicated file sidesteps that
// entirely, and stdout/stderr can still be captured and shown to the user
// as ordinary log lines.
//
// No JSON library exists in this codebase, and the fields here are flat/
// numeric plus one single-char `side`, so this hand-rolls the encoding
// rather than adding a dependency. Non-finite doubles (NaN/Inf) have no
// JSON representation; rather than emit invalid or silently-wrong JSON for
// them, this detects them and fails loudly with a message that names the
// likely cause (a submitted strategy dividing by zero, etc.).
#include "offline_simulation.h"
#include <cmath>
#include <cstdio>
#include <string>

namespace {

void print_json_char(FILE* f, char c) {
    std::fputc('"', f);
    unsigned char uc = static_cast<unsigned char>(c);
    if (c == '"' || c == '\\') {
        std::fputc('\\', f);
        std::fputc(c, f);
    } else if (uc < 0x20) {
        std::fprintf(f, "\\u%04x", uc);
    } else {
        std::fputc(c, f);
    }
    std::fputc('"', f);
}

// Returns false (and prints nothing) if any of the supplied doubles is
// NaN/Inf -- the caller then reports a failure instead of writing the file.
bool print_finite(FILE* f, double v) {
    if (!std::isfinite(v)) return false;
    std::fprintf(f, "%.10g", v);
    return true;
}

bool print_trade(FILE* f, const TradeRecord& t, bool first) {
    if (!first) std::fputc(',', f);
    std::fprintf(f, "{\"timestamp_ns\":%llu,\"side\":",
                 static_cast<unsigned long long>(t.timestamp_ns));
    print_json_char(f, t.side);
    std::fprintf(f, ",\"price\":");
    if (!print_finite(f, t.price)) return false;
    std::fprintf(f, ",\"size\":");
    if (!print_finite(f, t.size)) return false;
    std::fputc('}', f);
    return true;
}

bool print_pnl(FILE* f, const PnLSnapshot& p, bool first) {
    if (!first) std::fputc(',', f);
    std::fprintf(f, "{\"timestamp_ns\":%llu,\"realized_pnl\":",
                 static_cast<unsigned long long>(p.timestamp_ns));
    if (!print_finite(f, p.realized_pnl)) return false;
    std::fprintf(f, ",\"unrealized_pnl\":");
    if (!print_finite(f, p.unrealized_pnl)) return false;
    std::fprintf(f, ",\"position_size\":");
    if (!print_finite(f, p.position_size)) return false;
    std::fputc('}', f);
    return true;
}

} // namespace

int main(int argc, char* argv[]) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: main_job <data_file> <results_file>\n");
        return 2;
    }
    const std::string data_file_path = argv[1];
    const std::string results_path = argv[2];

    OfflineSimulation simulation(data_file_path);
    SimulationResult result = simulation.run();

    FILE* f = std::fopen(results_path.c_str(), "w");
    if (f == nullptr) {
        std::fprintf(stderr, "could not open results file for writing: %s\n",
                     results_path.c_str());
        return 3;
    }

    std::fprintf(f, "{\"total_trades\":%llu,\"compute_time_us\":%lld,\"trades\":[",
                 static_cast<unsigned long long>(result.total_trades),
                 static_cast<long long>(result.compute_time_us));
    for (size_t i = 0; i < result.trades.size(); ++i) {
        if (!print_trade(f, result.trades[i], i == 0)) {
            std::fclose(f);
            std::fprintf(stderr,
                         "strategy produced a non-finite trade price/size (NaN/Inf) at "
                         "index %zu -- check for division by zero or similar in the "
                         "submitted on_market_update.\n", i);
            return 4;
        }
    }
    std::fprintf(f, "],\"pnl_curve\":[");
    for (size_t i = 0; i < result.pnl_curve.size(); ++i) {
        if (!print_pnl(f, result.pnl_curve[i], i == 0)) {
            std::fclose(f);
            std::fprintf(stderr,
                         "strategy produced a non-finite PnL/position value (NaN/Inf) at "
                         "pnl_curve index %zu -- check for division by zero or similar "
                         "in the submitted on_market_update.\n", i);
            return 4;
        }
    }
    std::fprintf(f, "]}\n");
    std::fclose(f);

    return 0;
}
