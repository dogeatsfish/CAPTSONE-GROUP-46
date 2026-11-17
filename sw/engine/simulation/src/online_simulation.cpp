#include "online_simulation.h"
#include <iostream>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <thread>
#include <optional>

namespace {
constexpr uint64_t SAMPLE_INTERVAL_NS = 1'000'000'000ULL;
constexpr size_t   READ_CHUNK = 8192;
} 


OnlineSimulation::OnlineSimulation(const OnlineConfig& config)
    : cfg(config) {}

OnlineSimulation::OnlineSimulation(const std::string& file_path)
    : cfg(OnlineConfig{}) { cfg.file_path = file_path; }

OnlineSimulation::~OnlineSimulation() {
    running = false;
    if (ouch_thread.joinable()) {
        ouch_thread.join();
    }
    close_sockets();
}

bool OnlineSimulation::open_itch_socket() {
    itch_fd = net::open_udp();
    if (itch_fd == net::INVALID_SOCK) {
        std::cerr << "WARN: ITCH UDP socket() failed; market data will not be broadcast.\n";
        return false;
    }
    return true;
}

bool OnlineSimulation::open_ouch_listener() {
    ouch_listen_fd = net::open_udp();
    if (ouch_listen_fd == net::INVALID_SOCK) {
        std::cerr << "WARN: OUCH UDP socket() failed; order entry disabled.\n";
        return false;
    }

    net::set_reuse_addr(ouch_listen_fd);

    if (!net::bind_any(ouch_listen_fd, cfg.ouch_port)) {
        std::cerr << "WARN: OUCH bind() to port " << cfg.ouch_port
                  << " failed; order entry disabled.\n";
        net::close_socket(ouch_listen_fd);
        ouch_listen_fd = net::INVALID_SOCK;
        return false;
    }
    return true;
}

void OnlineSimulation::close_sockets() {
    if (itch_fd != net::INVALID_SOCK) {
        net::close_socket(itch_fd);
        itch_fd = net::INVALID_SOCK;
    }
    if (ouch_listen_fd != net::INVALID_SOCK) {
        net::close_socket(ouch_listen_fd);
        ouch_listen_fd = net::INVALID_SOCK;
    }
}

// ---------------------------------------------------------
// Market-data (ITCH) side
// ---------------------------------------------------------
void OnlineSimulation::broadcast_itch(const std::vector<uint8_t>& itch_msg) {
    if (itch_fd == net::INVALID_SOCK || itch_msg.empty()) return;
    const std::vector<uint8_t> packet =
        protocol::to_moldudp64({itch_msg}, itch_seq_num, cfg.session);
    itch_seq_num += 1;
    const sockaddr_in dest = net::make_addr(cfg.itch_address.c_str(), cfg.itch_port);
    net::send_to(itch_fd, packet.data(), packet.size(), dest);
}

void OnlineSimulation::apply_market_event(const MBORecord& rec, uint64_t& next_sample_ns) {
    const uint64_t ts = rec.timestamp_ns;
    std::optional<PnLSnapshot> sampled;
    std::optional<TradeRecord> new_trade; 
    L1State l1; 
    {
        std::lock_guard<std::mutex> lock(book_mutex);
        if (rec.message_type == protocol::ITCH_ADD) {
            Order mkt_order{rec.order_id, rec.price, rec.size, rec.side, false};
            matching_engine.process_add(mkt_order, ts);
            note_market_quote(rec.side, rec.price);
        } else if (rec.message_type == protocol::ITCH_CANCEL) {
            matching_engine.process_cancel(rec.order_id, ts, rec.side);
        }

        l1 = matching_engine.get_l1_state();

        if (cfg.enable_local_strategy) {
            const auto decision_start = std::chrono::steady_clock::now();
            std::optional<Order> user_order = strategy.on_market_update(l1);
            if (user_order.has_value()) {
                Order& uo = user_order.value();
                FillReport fill = fill_report(matching_engine.process_add(uo, ts));
                finalize_auto_fill(uo, fill, ts); // no-op unless cfg.auto_fill
                if (fill.filled_size > 0.0) {
                    const uint64_t decision_latency_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - decision_start).count();
                    strategy.on_fill(uo.side, fill.avg_fill_price, fill.filled_size);
                    const TradeRecord tr{
                        ts, uo.side, fill.avg_fill_price, fill.filled_size, decision_latency_ns};
                    active_result->trades.push_back(tr);
                    new_trade = tr;
                }
            }
        }

        // 4. Sample the PnL curve once per simulated second.
        if (ts >= next_sample_ns) {
            const double mark = market_mid();
            const PnLSnapshot snap{
                ts,
                strategy.get_realized_pnl(),
                strategy.get_unrealized_pnl(mark),
                strategy.get_position(),
                active_result->trades.size()};
            active_result->pnl_curve.push_back(snap);
            sampled = snap;
            next_sample_ns = ts + SAMPLE_INTERVAL_NS;
        }
    } 

    // 5. Stream the sample (and any new fill) to live-telemetry consumers,
    // outside the lock.
    if (sampled && on_sample_cb) {
        on_sample_cb(*sampled, l1);
    }
    if (new_trade && trade_observer_) {
        trade_observer_(*new_trade);
    }
}

void OnlineSimulation::note_market_quote(char side, double price) {
    if (price <= 0.0) return;

    // Reject stub/erroneous quotes: a price more than MAX_STUB_RATIO times (or
    // less than 1/MAX_STUB_RATIO of) the current market mid is a bad tick, not
    // a real quote. This dataset has asks at 199999.99 and bids at 0.0001
    // against a ~$4-10 mid -- thousands of times off -- while genuine
    // tick-to-tick moves are tiny, so this cleanly separates them. The first
    // quote (no mid yet) is always accepted to seed the tracker.
    constexpr double MAX_STUB_RATIO = 5.0;
    const double ref = market_mid();
    if (ref > 0.0 && (price > ref * MAX_STUB_RATIO || price < ref / MAX_STUB_RATIO)) {
        return;
    }

    if (side == 'B') {
        market_bid_ = price;
    } else if (side == 'S') {
        market_ask_ = price;
    }
}

double OnlineSimulation::market_mid() const {
    if (market_bid_ > 0.0 && market_ask_ > 0.0) return 0.5 * (market_bid_ + market_ask_);
    if (market_bid_ > 0.0) return market_bid_;
    if (market_ask_ > 0.0) return market_ask_;
    return 0.0;
}

void OnlineSimulation::finalize_auto_fill(Order& order, FillReport& fill, uint64_t ts) {
    // Off by default, and nothing to do if the order already filled fully.
    if (!cfg.auto_fill || order.size <= 0.0) {
        return;
    }

    // process_add() rested the unmatched remainder in the book under this
    // order's id; pull it back out so we don't both rest it AND count it as
    // filled, then fold that remainder into the fill at the order's own limit
    // price. The result is a guaranteed complete fill regardless of how much
    // real liquidity the book held.
    const double remaining = order.size;
    matching_engine.process_cancel(order.order_id, ts);

    const double prior_notional = fill.avg_fill_price * fill.filled_size;
    fill.filled_size += remaining;
    fill.avg_fill_price = (fill.filled_size > 0.0)
                              ? (prior_notional + order.price * remaining) / fill.filled_size
                              : order.price;
    order.size = 0.0;
}

// ---------------------------------------------------------
// Order-entry (OUCH) side  — runs on ouch_thread
// ---------------------------------------------------------
FillReport OnlineSimulation::apply_ouch_order(const protocol::OuchMessage& msg) {
    const uint64_t ts = last_market_ts_ns.load(std::memory_order_relaxed);

    // Snapshot produced only if this order fills (if(sampled) below). Captured
    // under the lock but the telemetry callback is invoked afterwards, without
    // the lock held -- mirrors apply_market_event, so a slow SSE consumer can
    // never stall the OUCH thread.
    std::optional<PnLSnapshot> sampled;
    std::optional<TradeRecord> new_trade; // set below if this order fills
    L1State l1;
    FillReport fill{};

    {
        std::lock_guard<std::mutex> lock(book_mutex);

        if (msg.msg_type == protocol::OUCH_CANCEL) {
            // msg.side is always 0 here -- the OUCH Cancel wire format carries no
            // side (see protocol::from_ouch) -- so this leaves process_cancel's
            // side at its default and lets it search both sides of the book.
            matching_engine.process_cancel(msg.order_id, ts);
            return FillReport{};
        }

        // OUCH_ENTER: convert to an aggressive order and match it.
        Order order = protocol::ouch_to_order(msg);
        fill = fill_report(matching_engine.process_add(order, ts));
        finalize_auto_fill(order, fill, ts); // no-op unless cfg.auto_fill
        if (fill.filled_size > 0.0) {
            strategy.on_fill(order.side, fill.avg_fill_price, fill.filled_size);
            const TradeRecord tr{ts, order.side, fill.avg_fill_price, fill.filled_size};
            active_result->trades.push_back(tr);
            new_trade = tr;

            // A fill is exactly the kind of event the once-per-second
            // market-data sampler in apply_market_event can sit on for a
            // while (a long quiet gap under real-time pacing):
            // without pushing a sample here too, the live PnL/top-of-book
            // stream only reflects a board fill whenever the next scheduled
            // sample happens to land, which can make a genuinely active
            // board look frozen in the UI.
            l1 = matching_engine.get_l1_state();
            const double mark = market_mid();
            const PnLSnapshot snap{
                ts,
                strategy.get_realized_pnl(),
                strategy.get_unrealized_pnl(mark),
                strategy.get_position(),
                active_result->trades.size()};
            active_result->pnl_curve.push_back(snap);
            sampled = snap;
        }
    } // book_mutex released here

    if (sampled && on_sample_cb) {
        on_sample_cb(*sampled, l1);
    }
    if (new_trade && trade_observer_) {
        trade_observer_(*new_trade);
    }

    return fill;
}

void OnlineSimulation::ouch_udp_loop() {
    // One OUCH frame per datagram. The buffer is oversized so trailing bytes the
    // FPGA appends after the OUCH message (e.g. the 2-byte latency telemetry from
    // outbound_tx_generator.sv) are received and simply ignored.
    uint8_t buf[256];

    while (running.load(std::memory_order_relaxed)) {
        // 200 ms poll so we stay responsive to shutdown.
        const int ready = net::wait_readable(ouch_listen_fd, 200);
        if (ready < 0) break;
        if (ready == 0) continue; // timeout: re-check running flag

        sockaddr_in src{};
        const long n = net::recv_from(ouch_listen_fd, buf, sizeof(buf), src);
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

        if (ouch_observer_) ouch_observer_(msg, buf, frame_len);

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
            net::send_to(ouch_listen_fd, resp.data(), resp.size(), src);
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

    FILE* fp = std::fopen(cfg.file_path.c_str(), "rb");
    if (fp == nullptr) {
        std::cerr << "CRITICAL: Failed to open MBO binary stream at " << cfg.file_path << std::endl;
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
        ouch_thread = std::thread(&OnlineSimulation::ouch_udp_loop, this);
    }

    const auto start_sim_time = std::chrono::high_resolution_clock::now();

    std::vector<MBORecord> buffer(READ_CHUNK);
    uint64_t next_sample_ns = 0;   // fires on the first record, then every second
    uint64_t prev_ts        = 0;
    bool     have_prev      = false;

    size_t n;
    while (running.load(std::memory_order_relaxed) &&
           (n = std::fread(buffer.data(), sizeof(MBORecord), READ_CHUNK, fp)) > 0) {
        for (size_t i = 0; i < n; ++i) {
            // External stop request (e.g. stop() from a SIGINT handler) --
            // unwind now instead of finishing the file.
            if (!running.load(std::memory_order_relaxed)) break;

            const MBORecord& rec = buffer[i];

            // --- Real-time pacing: wait (future - present) before this line ---
            if (have_prev && rec.timestamp_ns > prev_ts && cfg.time_scale > 0.0) {
                uint64_t gap_ns = rec.timestamp_ns - prev_ts;
                double   scaled = static_cast<double>(gap_ns) * cfg.time_scale;
                uint64_t sleep_ns = static_cast<uint64_t>(scaled);
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

    // Market data is exhausted (or an external stop() request broke the loop
    // above): stop the OUCH server and wait for it to drain.
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
