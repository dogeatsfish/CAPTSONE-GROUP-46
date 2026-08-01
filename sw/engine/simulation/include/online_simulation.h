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
#include "offline_simulation.h" 
#include "protocol.h"

class OnlineSimulation {
public:
    // OUCH order-entry transport selector.
    //   UDP : connectionless datagrams, one OUCH frame per packet. Matches the
    //         FPGA, which emits IP/UDP order packets (outbound_tx_generator.sv).
    //   TCP : byte stream with a listen/accept handshake. For software clients
    //         and the loopback tests.
    enum class OuchTransport { UDP, TCP };

    struct Config {
        // (UDP). Market data is sent TO the FPGA, whose IP is the RTL's
        // SRC_IP (192.168.0.1). The FPGA parser does not validate the UDP
        // destination port, so it is kept equal to the OUCH port for symmetry.
        std::string itch_address = "192.168.0.1";
        uint16_t    itch_port    = 50001;
        // (TCP/UDP). Must match the FPGA's OUCH DST_PORT (outbound_tx_generator.sv).
        uint16_t    ouch_port    = 50001;

        // OUCH order-entry transport. Defaults to UDP so order intake matches
        // the hardware; flip to TCP for a streaming software client.
        OuchTransport ouch_transport = OuchTransport::UDP;

        // Wall-clock pacing.
        // 1.0 = true real time, 0.001 = 1000x faster, 0.0 = no pacing.
        double      time_scale   = 1;

        // Cap on any single sleep so a large timestamp gap can't stall the
        // replay indefinitely (nanoseconds). 0 disables the cap.
        uint64_t    max_sleep_ns = 5'000'000'000ULL; // 5 s

        // Numeric security id ("stock locate") stamped on every ITCH message
        // (2-byte field right after the message type). Defaults to ticker 1.
        uint16_t    stock_locate = protocol::DEFAULT_STOCK_LOCATE;

        // MoldUDP64 session id (ASCII, up to protocol::MOLD_SESSION_LEN bytes,
        // zero-padded). Stamped on every market-data datagram.
        std::string session = "";
    };

    explicit OnlineSimulation(const std::string& file_path);
    OnlineSimulation(const std::string& file_path, const Config& config);
    ~OnlineSimulation();

    // Non-copyable: owns sockets, a thread, and a mutex.
    OnlineSimulation(const OnlineSimulation&) = delete;
    OnlineSimulation& operator=(const OnlineSimulation&) = delete;

    using SampleCallback = std::function<void(const PnLSnapshot&)>;
    SimulationResult run(SampleCallback on_sample = {});

    // Observer invoked for every OUCH order-entry message received from a
    // connected client or the FPGA, with the decoded message and the raw frame
    // bytes. Set before run(); it is invoked on the OUCH thread. Optional, used
    // by the hardware bring-up harness to print/decode inbound orders.
    using OuchObserver =
        std::function<void(const protocol::OuchMessage&, const uint8_t*, size_t)>;
    void set_ouch_observer(OuchObserver cb) { ouch_observer_ = std::move(cb); }

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
    OuchObserver          ouch_observer_; // optional inbound-OUCH observer
    // Most recent market timestamp seen on the ITCH side. Used to stamp trades
    // that originate from OUCH orders (OUCH frames carry no timestamp).
    std::atomic<uint64_t> last_market_ts_ns{0};

    // MoldUDP64 sequence number of the next market-data message (starts at 1,
    // the MoldUDP64 convention). Only touched on the market-data thread.
    uint64_t itch_seq_num = 1;

    // --- Setup / teardown ---
    bool open_itch_socket();
    bool open_ouch_listener();
    void close_sockets();

    // --- Market-data side ---
    void broadcast_itch(const std::vector<uint8_t>& packet);
    void apply_market_event(const MBORecord& rec, uint64_t& next_sample_ns);

    // --- Order-entry side (runs on ouch_thread) ---
    void ouch_server_loop();      // dispatches to the TCP or UDP loop
    void ouch_tcp_loop();         // accept() + per-connection stream reader
    void ouch_udp_loop();         // recvfrom() datagram reader
    void handle_ouch_client(int client_fd);
    FillReport apply_ouch_order(const protocol::OuchMessage& msg);

    // Send all bytes of a buffer on a socket (handles partial writes).
    static bool send_all(int fd, const uint8_t* data, size_t len);
};
