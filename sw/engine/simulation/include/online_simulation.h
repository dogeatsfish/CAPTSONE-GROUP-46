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

        // If true, the engine's own Strategy (the same one OfflineSimulation
        // runs) trades directly against the locally-replayed book, exactly
        // like the offline path -- see apply_market_event(). Off by default:
        // must stay false for the hardware target, where trades are meant to
        // reflect only the real board's own OUCH orders, not a second,
        // independent phantom strategy running in software. The loopback
        // demo (no board attached) turns this on so it actually shows live
        // trading activity instead of always being flat.
        bool        enable_local_strategy = false;

        // If true, force a complete fill for every aggressive order the engine
        // submits (the local strategy's orders and inbound OUCH ENTER orders):
        // any size left unmatched after walking the book is filled at the
        // order's own limit price instead of resting. Lets a run show full
        // trading activity even against this dataset's thin, often one-sided
        // book, where a marketable order would otherwise only partially fill
        // (or not at all) and just rest. Off by default: a real hardware run
        // should reflect only genuine fills against the actual book, not
        // synthesized ones. Applies only to these aggressive orders, never to
        // the market-data adds that build the book.
        bool        auto_fill = false;

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

    // Second arg is the current top-of-book (best bid/ask) at the same
    // instant as the PnL sample -- both are read under the same book_mutex
    // hold in apply_market_event, so they're always mutually consistent.
    using SampleCallback = std::function<void(const PnLSnapshot&, const L1State&)>;
    SimulationResult run(SampleCallback on_sample = {});

    // Requests an early stop of an in-progress run() -- e.g. from a SIGINT
    // handler on Ctrl+C. Safe to call from any thread/signal context (just an
    // atomic store). run() notices on its next loop iteration and unwinds
    // through its normal end-of-file path: stop the OUCH thread, close
    // itch_fd/ouch_listen_fd, return whatever telemetry was collected so far.
    // A no-op if no run() is in progress.
    void stop() { running = false; }

    // Observer invoked for every OUCH order-entry message received from a
    // connected client or the FPGA, with the decoded message and the raw frame
    // bytes. Set before run(); it is invoked on the OUCH thread. Optional, used
    // by the hardware bring-up harness to print/decode inbound orders.
    using OuchObserver =
        std::function<void(const protocol::OuchMessage&, const uint8_t*, size_t)>;
    void set_ouch_observer(OuchObserver cb) { ouch_observer_ = std::move(cb); }

    // Observer invoked for every trade fill as it happens -- both the
    // loopback local-strategy path (apply_market_event) and a real inbound
    // OUCH order (apply_ouch_order) -- so a live consumer (the streaming
    // demo's Order Blotter) can populate per-fill instead of waiting for
    // run() to return. Set before run(); fires on whichever thread produced
    // the fill (market-data thread for loopback, OUCH thread for a real
    // order), always after book_mutex is released, same as on_sample_cb.
    using TradeObserver = std::function<void(const TradeRecord&)>;
    void set_trade_observer(TradeObserver cb) { trade_observer_ = std::move(cb); }

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
    TradeObserver         trade_observer_; // optional per-fill observer
    // Most recent market timestamp seen on the ITCH side. Used to stamp trades
    // that originate from OUCH orders (OUCH frames carry no timestamp).
    std::atomic<uint64_t> last_market_ts_ns{0};

    // The market's own top of book, tracked straight from the market-data
    // stream (not the live order book, which the local strategy consumes -- so
    // marking off it would read one-sided/empty right after every strategy
    // fill and zero out unrealized PnL). Stub/erroneous quotes in the data
    // (asks at 199999.99, bids at 0.0001, etc.) are filtered out in
    // note_market_quote so they can't corrupt the mark. Guarded by book_mutex.
    double market_bid_ = 0.0;
    double market_ask_ = 0.0;

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

    // When cfg.auto_fill is set, force `order` to a complete fill: pull the
    // remainder process_add() rested back out of the book and fold it into
    // `fill` at the order's limit price. A no-op if auto_fill is off or the
    // order already filled completely. Must be called with book_mutex held.
    void finalize_auto_fill(Order& order, FillReport& fill);

    // Record a market-data quote (one side, from an MBO add) into
    // market_bid_/market_ask_, rejecting stub/erroneous prices that sit wildly
    // off the current market mid. Call with book_mutex held.
    void note_market_quote(char side, double price);

    // Current market mid used to mark an open position: the mid when both
    // sides are known, otherwise whichever side is, otherwise 0. Built only
    // from stub-filtered market data, so it tracks fair value regardless of
    // how the strategy churns the live book. Call with book_mutex held.
    double market_mid() const;

    // --- Order-entry side (runs on ouch_thread) ---
    void ouch_server_loop();      // dispatches to the TCP or UDP loop
    void ouch_tcp_loop();         // accept() + per-connection stream reader
    void ouch_udp_loop();         // recvfrom() datagram reader
    void handle_ouch_client(int client_fd);
    FillReport apply_ouch_order(const protocol::OuchMessage& msg);

    // Send all bytes of a buffer on a socket (handles partial writes).
    static bool send_all(int fd, const uint8_t* data, size_t len);
};
