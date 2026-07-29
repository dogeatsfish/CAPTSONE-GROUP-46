#include "online_simulation.h"

#include <iostream>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <thread>
#include <optional>

// POSIX networking (macOS / Linux).
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>

namespace {
// Sample the PnL curve once per simulated second (matches the offline sim).
constexpr uint64_t SAMPLE_INTERVAL_NS = 1'000'000'000ULL;
// Number of MBO records to pull off disk per fread call.
constexpr size_t   READ_CHUNK = 8192;
} // namespace

// ---------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------
OnlineSimulation::OnlineSimulation(const std::string& file_path)
    : mbo_file_path(file_path), cfg(Config{}) {}

OnlineSimulation::OnlineSimulation(const std::string& file_path, const Config& config)
    : mbo_file_path(file_path), cfg(config) {}

OnlineSimulation::~OnlineSimulation() {
    running = false;
    if (ouch_thread.joinable()) {
        ouch_thread.join();
    }
    close_sockets();
}

// ---------------------------------------------------------
// Socket setup / teardown
// ---------------------------------------------------------
bool OnlineSimulation::open_itch_socket() {
    itch_fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (itch_fd < 0) {
        std::cerr << "WARN: ITCH UDP socket() failed; market data will not be broadcast.\n";
        return false;
    }
    return true;
}

bool OnlineSimulation::open_ouch_listener() {
    const bool is_udp   = (cfg.ouch_transport == OuchTransport::UDP);
    const char* proto   = is_udp ? "UDP" : "TCP";
    const int  sock_type = is_udp ? SOCK_DGRAM : SOCK_STREAM;

    ouch_listen_fd = ::socket(AF_INET, sock_type, 0);
    if (ouch_listen_fd < 0) {
        std::cerr << "WARN: OUCH " << proto
                  << " socket() failed; order entry disabled.\n";
        return false;
    }

    int yes = 1;
    ::setsockopt(ouch_listen_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(cfg.ouch_port);

    if (::bind(ouch_listen_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        std::cerr << "WARN: OUCH bind() to port " << cfg.ouch_port
                  << " failed; order entry disabled.\n";
        ::close(ouch_listen_fd);
        ouch_listen_fd = -1;
        return false;
    }

    // Only a connection-oriented (TCP) socket needs to be put into the listen
    // state; UDP is connectionless and reads straight from the bound socket.
    if (!is_udp && ::listen(ouch_listen_fd, 1) < 0) {
        std::cerr << "WARN: OUCH listen() failed; order entry disabled.\n";
        ::close(ouch_listen_fd);
        ouch_listen_fd = -1;
        return false;
    }
    return true;
}

void OnlineSimulation::close_sockets() {
    if (itch_fd >= 0)        { ::close(itch_fd);        itch_fd = -1; }
    if (ouch_listen_fd >= 0) { ::close(ouch_listen_fd); ouch_listen_fd = -1; }
}

// ---------------------------------------------------------
// Market-data (ITCH) side
// ---------------------------------------------------------
void OnlineSimulation::broadcast_itch(const std::vector<uint8_t>& itch_msg) {
    if (itch_fd < 0 || itch_msg.empty()) return;

    // Wrap the ITCH message in a MoldUDP64 packet (one message per datagram),
    // matching the encapsulation the FPGA parser strips. The sequence number
    // advances per message sent.
    const std::vector<uint8_t> packet =
        protocol::to_moldudp64({itch_msg}, itch_seq_num, cfg.session);
    itch_seq_num += 1;

    sockaddr_in dest{};
    dest.sin_family = AF_INET;
    dest.sin_port   = htons(cfg.itch_port);
    ::inet_pton(AF_INET, cfg.itch_address.c_str(), &dest.sin_addr);

    ::sendto(itch_fd, packet.data(), packet.size(), 0,
             reinterpret_cast<sockaddr*>(&dest), sizeof(dest));
    // Best-effort market data: a failed sendto is non-fatal to the replay.
}

void OnlineSimulation::apply_market_event(const MBORecord& rec, uint64_t& next_sample_ns) {
    const uint64_t ts = rec.timestamp_ns;

    // Snapshot produced this call (if the per-second sampler fired). Captured
    // under the lock but the telemetry callback is invoked afterwards, without
    // the lock held, so a slow consumer can never stall the OUCH thread.
    std::optional<PnLSnapshot> sampled;

    {
        std::lock_guard<std::mutex> lock(book_mutex);

        // rec is a source MBORecord, so compare against the MBO record tags
        // ('A'/'C'), not the ITCH wire tags (Cancel is 'X' on the wire).
        if (rec.message_type == protocol::MBO_ADD) {
            Order mkt_order{rec.order_id, rec.price, rec.size, rec.side, false};
            matching_engine.process_add(mkt_order, ts);
        } else if (rec.message_type == protocol::MBO_CANCEL) {
            matching_engine.process_cancel(rec.order_id, rec.side);
        }

        const L1State l1 = matching_engine.get_l1_state();

        // 3. Sample the PnL curve once per simulated second.
        if (ts >= next_sample_ns) {
            const double mark = (l1.best_bid > 0.0 && l1.best_ask > 0.0)
                                    ? 0.5 * (l1.best_bid + l1.best_ask)
                                    : 0.0;
            const PnLSnapshot snap{
                ts,
                strategy.get_realized_pnl(),
                strategy.get_unrealized_pnl(mark),
                strategy.get_position()};
            active_result->pnl_curve.push_back(snap);
            sampled = snap;
            next_sample_ns = ts + SAMPLE_INTERVAL_NS;
        }
    } // book_mutex released here

    // 4. Stream the sample to any live-telemetry consumer (outside the lock).
    if (sampled && on_sample_cb) {
        on_sample_cb(*sampled);
    }
}

// ---------------------------------------------------------
// Order-entry (OUCH) side  — runs on ouch_thread
// ---------------------------------------------------------
FillReport OnlineSimulation::apply_ouch_order(const protocol::OuchMessage& msg) {
    const uint64_t ts = last_market_ts_ns.load(std::memory_order_relaxed);

    std::lock_guard<std::mutex> lock(book_mutex);

    if (msg.msg_type == protocol::OUCH_CANCEL) {
        matching_engine.process_cancel(msg.order_id, msg.side);
        return FillReport{};
    }

    // OUCH_ENTER: convert to an aggressive order and match it.
    Order order = protocol::ouch_to_order(msg);
    const FillReport fill = matching_engine.process_add(order, ts);
    if (fill.filled_size > 0.0) {
        strategy.on_fill(order.side, fill.avg_fill_price, fill.filled_size);
        active_result->trades.push_back(
            TradeRecord{ts, order.side, fill.avg_fill_price, fill.filled_size});
    }
    return fill;
}

bool OnlineSimulation::send_all(int fd, const uint8_t* data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        const ssize_t n = ::send(fd, data + sent, len - sent, 0);
        if (n <= 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

void OnlineSimulation::handle_ouch_client(int client_fd) {
    uint8_t buf[protocol::OUCH_MAX_LEN];

    while (running.load(std::memory_order_relaxed)) {
        // Wait (with timeout) until the client has sent at least one byte so we
        // stay responsive to shutdown between messages.
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(client_fd, &rfds);
        timeval tv{0, 200'000}; // 200 ms

        const int ready = ::select(client_fd + 1, &rfds, nullptr, nullptr, &tv);
        if (ready < 0) break;         // socket error
        if (ready == 0) continue;     // timeout: re-check running flag

        // Read the 1-byte message type to learn the frame length.
        ssize_t got = ::recv(client_fd, buf, 1, 0);
        if (got <= 0) break;          // client disconnected

        const size_t frame_len = protocol::ouch_frame_len(buf[0]);
        if (frame_len == 0 || frame_len > sizeof(buf)) {
            // Unknown message type: we can't know the frame boundary, so drop
            // the connection rather than desync the stream.
            break;
        }

        // Read the remainder of the frame (recv may return partial data).
        size_t have = 1;
        bool   ok   = true;
        while (have < frame_len) {
            got = ::recv(client_fd, buf + have, frame_len - have, 0);
            if (got <= 0) { ok = false; break; }
            have += static_cast<size_t>(got);
        }
        if (!ok) break;

        protocol::OuchMessage msg;
        if (!protocol::from_ouch(buf, frame_len, msg)) {
            continue;
        }

        const FillReport fill = apply_ouch_order(msg);

        // Reply to the client for ENTER orders: an execution report if any
        // volume filled, otherwise an accept (the remainder rests in the book).
        if (msg.msg_type == protocol::OUCH_ENTER) {
            std::vector<uint8_t> resp;
            if (fill.filled_size > 0.0) {
                resp = protocol::to_ouch_response(
                    protocol::OUCH_EXECUTED, msg.order_id,
                    fill.filled_size, fill.avg_fill_price);
            } else {
                resp = protocol::to_ouch_response(
                    protocol::OUCH_ACCEPTED, msg.order_id, msg.size, msg.price);
            }
            if (!send_all(client_fd, resp.data(), resp.size())) break;
        }
    }

    ::close(client_fd);
}

void OnlineSimulation::ouch_server_loop() {
    if (cfg.ouch_transport == OuchTransport::UDP) {
        ouch_udp_loop();
    } else {
        ouch_tcp_loop();
    }
}

void OnlineSimulation::ouch_tcp_loop() {
    while (running.load(std::memory_order_relaxed)) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(ouch_listen_fd, &rfds);
        timeval tv{0, 200'000}; // 200 ms accept poll

        const int ready = ::select(ouch_listen_fd + 1, &rfds, nullptr, nullptr, &tv);
        if (ready < 0) break;
        if (ready == 0) continue; // no pending connection: re-check running

        const int client_fd = ::accept(ouch_listen_fd, nullptr, nullptr);
        if (client_fd < 0) continue;

        handle_ouch_client(client_fd);
    }
}

void OnlineSimulation::ouch_udp_loop() {
    // One OUCH frame per datagram. The buffer is oversized so trailing bytes the
    // FPGA appends after the OUCH message (e.g. the 2-byte latency telemetry from
    // outbound_tx_generator.sv) are received and simply ignored.
    uint8_t buf[256];

    while (running.load(std::memory_order_relaxed)) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(ouch_listen_fd, &rfds);
        timeval tv{0, 200'000}; // 200 ms poll so we stay responsive to shutdown

        const int ready = ::select(ouch_listen_fd + 1, &rfds, nullptr, nullptr, &tv);
        if (ready < 0) break;
        if (ready == 0) continue; // timeout: re-check running flag

        sockaddr_in src{};
        socklen_t   src_len = sizeof(src);
        const ssize_t n = ::recvfrom(ouch_listen_fd, buf, sizeof(buf), 0,
                                     reinterpret_cast<sockaddr*>(&src), &src_len);
        if (n <= 0) continue;

        // The first byte is the OUCH message type, which fixes the frame length.
        const size_t frame_len = protocol::ouch_frame_len(buf[0]);
        if (frame_len == 0 || static_cast<size_t>(n) < frame_len) {
            continue; // unknown type or a datagram too short to hold the frame
        }

        protocol::OuchMessage msg;
        if (!protocol::from_ouch(buf, frame_len, msg)) {
            continue; // malformed frame
        }

        const FillReport fill = apply_ouch_order(msg);

        // Reply to the sender for ENTER orders: an execution report if any
        // volume filled, otherwise an accept. Best-effort: UDP replies may be
        // lost, and the FPGA does not process inbound acks in the current scope.
        if (msg.msg_type == protocol::OUCH_ENTER) {
            std::vector<uint8_t> resp;
            if (fill.filled_size > 0.0) {
                resp = protocol::to_ouch_response(
                    protocol::OUCH_EXECUTED, msg.order_id,
                    fill.filled_size, fill.avg_fill_price);
            } else {
                resp = protocol::to_ouch_response(
                    protocol::OUCH_ACCEPTED, msg.order_id, msg.size, msg.price);
            }
            ::sendto(ouch_listen_fd, resp.data(), resp.size(), 0,
                     reinterpret_cast<sockaddr*>(&src), src_len);
        }
    }
}

// ---------------------------------------------------------
// Main real-time replay loop
// ---------------------------------------------------------
SimulationResult OnlineSimulation::run(SampleCallback on_sample) {
    SimulationResult result;

    // Install the live-telemetry hook for the duration of this run.
    on_sample_cb = std::move(on_sample);

    FILE* fp = std::fopen(mbo_file_path.c_str(), "rb");
    if (fp == nullptr) {
        std::cerr << "CRITICAL: Failed to open MBO binary stream at " << mbo_file_path << std::endl;
        return result;
    }

    // Reserve telemetry storage from the file size (see offline sim rationale).
    std::fseek(fp, 0, SEEK_END);
    const long file_bytes = std::ftell(fp);
    std::fseek(fp, 0, SEEK_SET);
    const size_t est_records =
        (file_bytes > 0) ? static_cast<size_t>(file_bytes) / sizeof(MBORecord) : 0;
    result.trades.reserve(est_records / 4 + 1);
    result.pnl_curve.reserve(est_records / 1024 + 16);

    active_result = &result;
    running       = true;

    // Bring up sockets. Failures degrade gracefully: the replay still runs and
    // feeds the book, just without broadcast / order entry.
    open_itch_socket();
    if (open_ouch_listener()) {
        ouch_thread = std::thread(&OnlineSimulation::ouch_server_loop, this);
    }

    const auto start_sim_time = std::chrono::high_resolution_clock::now();

    std::vector<MBORecord> buffer(READ_CHUNK);
    uint64_t next_sample_ns = 0;   // fires on the first record, then every second
    uint64_t prev_ts        = 0;
    bool     have_prev      = false;

    size_t n;
    while ((n = std::fread(buffer.data(), sizeof(MBORecord), READ_CHUNK, fp)) > 0) {
        for (size_t i = 0; i < n; ++i) {
            const MBORecord& rec = buffer[i];

            // --- Real-time pacing: wait (future - present) before this line ---
            if (have_prev && rec.timestamp_ns > prev_ts && cfg.time_scale > 0.0) {
                uint64_t gap_ns = rec.timestamp_ns - prev_ts;
                double   scaled = static_cast<double>(gap_ns) * cfg.time_scale;
                uint64_t sleep_ns = static_cast<uint64_t>(scaled);
                if (cfg.max_sleep_ns > 0 && sleep_ns > cfg.max_sleep_ns) {
                    sleep_ns = cfg.max_sleep_ns;
                }
                if (sleep_ns > 0) {
                    std::this_thread::sleep_for(std::chrono::nanoseconds(sleep_ns));
                }
            }
            prev_ts   = rec.timestamp_ns;
            have_prev = true;
            last_market_ts_ns.store(rec.timestamp_ns, std::memory_order_relaxed);

            // --- Broadcast the ITCH packet, then apply to the book ---
            broadcast_itch(protocol::to_itch(rec, cfg.stock_locate));
            apply_market_event(rec, next_sample_ns);
        }
    }

    std::fclose(fp);

    // Market data is exhausted: stop the OUCH server and wait for it to drain.
    running = false;
    if (ouch_thread.joinable()) {
        ouch_thread.join();
    }
    close_sockets();

    const auto end_sim_time = std::chrono::high_resolution_clock::now();
    result.compute_time_us =
        std::chrono::duration_cast<std::chrono::microseconds>(end_sim_time - start_sim_time).count();
    result.total_trades = result.trades.size();

    active_result = nullptr;
    on_sample_cb = nullptr; // drop the hook once the run is complete
    return result;
}
