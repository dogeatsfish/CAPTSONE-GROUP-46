#pragma once

#include <string>
#include <cstdint>
#include <atomic>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

#include "orderbook.h"
#include "user_strategy.h"
#include "offline_simulation.h" // MBORecord + telemetry structs (SimulationResult, ...)
#include "protocol.h"

// ---------------------------------------------------------
// OnlineSimulation
// ---------------------------------------------------------
// Real-time counterpart to OfflineSimulation. Instead of consuming the MBO
// stream as fast as possible, run() replays it in wall-clock time:
//
//   * Each MBO record is encoded to an ITCH packet (protocol::to_itch) and
//     broadcast over a UDP socket, then applied to the shared order book.
//   * Records are paced: before broadcasting the next record the loop sleeps
//     for (next.timestamp_ns - current.timestamp_ns), reproducing the
//     original inter-arrival gaps.
//   * Concurrently, a TCP server accepts a connected trading client and reads
//     OUCH order-entry packets. Each packet is decoded (the "OUCH converter"),
//     turned into an aggressive Order, and matched against the same book.
//
// The order book is shared between the market-data thread (run loop) and the
// OUCH ingestion thread, so all book access is guarded by a mutex.
// ---------------------------------------------------------
class OnlineSimulation {
public:
    struct Config {
        // ITCH market-data broadcast (UDP).
        std::string itch_address = "127.0.0.1";
        uint16_t    itch_port    = 26000;

        // OUCH order-entry listener (TCP).
        uint16_t    ouch_port    = 26001;

        // Wall-clock pacing. Real market timestamps span seconds/minutes, which
        // is impractical for a demo replay; this scales every inter-arrival
        // gap. 1.0 = true real time, 0.001 = 1000x faster, 0.0 = no pacing.
        double      time_scale   = 1.0;

        // Cap on any single sleep so a large timestamp gap can't stall the
        // replay indefinitely (nanoseconds). 0 disables the cap.
        uint64_t    max_sleep_ns = 5'000'000'000ULL; // 5 s
    };

    explicit OnlineSimulation(const std::string& file_path);
    OnlineSimulation(const std::string& file_path, const Config& config);
    ~OnlineSimulation();

    // Non-copyable: owns sockets, a thread, and a mutex.
    OnlineSimulation(const OnlineSimulation&) = delete;
    OnlineSimulation& operator=(const OnlineSimulation&) = delete;

    // Telemetry callback: invoked once per simulated second with the PnL
    // snapshot that was just recorded. Runs on the market-data thread, OUTSIDE
    // the book lock, so it is safe for it to block briefly (e.g. push to a
    // queue). Used to stream live telemetry while the simulation is running.
    using SampleCallback = std::function<void(const PnLSnapshot&)>;

    // Replay the MBO stream in real time while serving OUCH order entry.
    // If on_sample is set, it fires for every per-second PnL sample.
    SimulationResult run(SampleCallback on_sample = {});

private:
    std::string mbo_file_path;
    Config      cfg;

    OrderBook   matching_engine;
    Strategy    strategy;

    // Guards matching_engine, strategy, and the shared result payload.
    std::mutex        book_mutex;
    SimulationResult* active_result = nullptr; // set for the duration of run()

    // Networking state.
    int itch_fd        = -1; // UDP send socket (ITCH market data)
    int ouch_listen_fd = -1; // TCP listen socket (OUCH order entry)

    std::atomic<bool>     running{false};
    std::thread           ouch_thread;
    SampleCallback        on_sample_cb; // optional live-telemetry hook
    // Most recent market timestamp seen on the ITCH side. Used to stamp trades
    // that originate from OUCH orders (OUCH frames carry no timestamp).
    std::atomic<uint64_t> last_market_ts_ns{0};

    // --- Setup / teardown ---
    bool open_itch_socket();
    bool open_ouch_listener();
    void close_sockets();

    // --- Market-data side ---
    void broadcast_itch(const std::vector<uint8_t>& packet);
    // Apply a market event to the book and run the co-located strategy,
    // recording any resulting fills / PnL samples into *active_result.
    void apply_market_event(const MBORecord& rec, uint64_t& next_sample_ns);

    // --- Order-entry side (runs on ouch_thread) ---
    void ouch_server_loop();
    void handle_ouch_client(int client_fd);
    // Match a decoded OUCH order and record the fill into *active_result.
    // Returns what actually executed so the caller can reply to the client.
    FillReport apply_ouch_order(const protocol::OuchMessage& msg);

    // Send all bytes of a buffer on a socket (handles partial writes).
    static bool send_all(int fd, const uint8_t* data, size_t len);
};
