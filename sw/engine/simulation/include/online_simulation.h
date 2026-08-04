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

    explicit OnlineSimulation(const OnlineConfig& config);
    explicit OnlineSimulation(const std::string& file_path);
    ~OnlineSimulation();

    OnlineSimulation(const OnlineSimulation&) = delete;
    OnlineSimulation& operator=(const OnlineSimulation&) = delete;

    using SampleCallback = std::function<void(const PnLSnapshot&, const L1State&)>;
    using OuchObserver =
        std::function<void(const protocol::OuchMessage&, const uint8_t*, size_t)>;
    using TradeObserver = std::function<void(const TradeRecord&)>;
    
    SimulationResult run(SampleCallback on_sample = {});
    void set_ouch_observer(OuchObserver cb) { ouch_observer_ = std::move(cb); }
    void set_trade_observer(TradeObserver cb) { trade_observer_ = std::move(cb); }
    
    void stop() { running = false; }

private:
    OnlineConfig cfg; 
    OrderBook   matching_engine;
    Strategy    strategy;

    // Guards
    std::mutex        book_mutex;
    SimulationResult* active_result = nullptr; 

    // Networking state.
    int itch_fd        = -1; // UDP send socket (ITCH market data)
    int ouch_listen_fd = -1; // TCP listen socket (OUCH order entry)

    std::atomic<bool>     running{false};
    std::thread           ouch_thread;
    SampleCallback        on_sample_cb; 
    OuchObserver          ouch_observer_; 
    TradeObserver         trade_observer_;
    std::atomic<uint64_t> last_market_ts_ns{0};

    double market_bid_ = 0.0;
    double market_ask_ = 0.0;

    uint64_t itch_seq_num = 1;

    // --- Setup / teardown ---
    bool open_itch_socket();
    bool open_ouch_listener();
    void close_sockets();

    // --- Market-data side ---
    void broadcast_itch(const std::vector<uint8_t>& packet);
    void apply_market_event(const MBORecord& rec, uint64_t& next_sample_ns);
    void finalize_auto_fill(Order& order, FillReport& fill);
    void note_market_quote(char side, double price);
    double market_mid() const;
    void ouch_server_loop();      // dispatches to the TCP or UDP loop
    void ouch_tcp_loop();         // accept() + per-connection stream reader
    void ouch_udp_loop();         // recvfrom() datagram reader
    void handle_ouch_client(int client_fd);
    FillReport apply_ouch_order(const protocol::OuchMessage& msg);

    static bool send_all(int fd, const uint8_t* data, size_t len);
};
