// Unit tests for Participants on the Scheduler: callbacks, latency, market
// orders, accounts and fees (make test).

#include <cmath>
#include <cstdio>
#include <vector>
#include "scheduler.h"

namespace {
int failures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);  \
            ++failures;                                                    \
        }                                                                  \
    } while (0)

bool near(double a, double b) { return std::fabs(a - b) < 1e-9; }

using T = BookEventType;

constexpr ParticipantId FEED  = 0;
constexpr ParticipantId ALICE = 1;
constexpr ParticipantId BOB   = 2;
constexpr uint64_t US = 1'000ULL;

Order make(uint64_t id, char side, double price, double size) {
    return Order{id, price, size, side, false};
}

void run_all(Scheduler& s) {
    while (!s.empty()) s.step();
}

// Records everything it hears, with the time it heard it. The public do_*
// methods let a test act on its behalf from outside a callback.
struct Recorder : Participant {
    struct Heard { uint64_t at; BookEvent event; };
    std::vector<Heard>    fills, updates, trades;
    std::vector<uint64_t> book_times, timer_times;
    L2State               last_book;

    void on_book_update(const L2State& b) override { book_times.push_back(now()); last_book = b; }
    void on_trade(const BookEvent& e) override { trades.push_back({now(), e}); }
    void on_fill(const BookEvent& e) override { fills.push_back({now(), e}); }
    void on_order_update(const BookEvent& e) override { updates.push_back({now(), e}); }
    void on_timer(uint64_t t) override { timer_times.push_back(t); }

    std::optional<QueuePosition> where(uint64_t id) const { return queue_position(id); }
    uint64_t do_limit(char side, double price, double size) { return send_limit(side, price, size); }
    uint64_t do_market(char side, double size) { return send_market(side, size); }
    void     do_cancel(uint64_t id) { cancel(id); }
    void     do_reduce(uint64_t id, double qty) { reduce(id, qty); }
    uint64_t do_replace(uint64_t id, double price, double size) { return replace(id, price, size); }
    void     do_timer(uint64_t delay) { set_timer(delay); }
    const Account& acct() const { return account(); }
};

// Buys the offer the first time it sees one.
struct Lifter : Participant {
    bool sent = false;
    uint64_t saw_book_at = 0;
    void on_book_update(const L2State& b) override {
        if (sent || b.asks.empty()) return;
        sent = true;
        saw_book_at = now();
        send_limit('B', b.asks.front().price, 10);
    }
};

// The full loop: market data in, order out, fill back -- with zero latency
// it all happens at the same instant.
void test_callbacks_zero_latency() {
    Scheduler s;
    Lifter lifter;
    Recorder rec;
    s.add_participant(ALICE, lifter);
    s.add_participant(BOB, rec);

    s.schedule(100, FEED, Action::add(make(1, 'S', 10.0, 50)));
    run_all(s);

    CHECK(lifter.sent && lifter.saw_book_at == 100);
    CHECK(s.account(ALICE).position() == 10);
    CHECK(near(s.account(ALICE).cash(), -100.0));
    CHECK(s.account(ALICE).open_orders().empty());
    CHECK(s.account(ALICE).orders_sent() == 1);
    CHECK(s.book().get_l2_state(1).asks[0].size == 40);

    // Bob (a bystander) saw the book twice -- after the feed's add and after
    // Alice's order -- and heard the public trade.
    CHECK(rec.book_times.size() == 2);
    CHECK(rec.last_book.asks[0].size == 40);
    CHECK(rec.trades.size() == 1 && rec.trades[0].event.size == 10);
    CHECK(rec.fills.empty());
}

// Events arrive L_in late; orders land compute + L_out after they are sent.
void test_latency_both_legs() {
    Scheduler s;
    Lifter lifter;
    s.add_participant(ALICE, lifter, LatencyProfile::uniform(30 * US, 50 * US, 20 * US));
    s.record_events(true);

    s.schedule(1000 * US, FEED, Action::add(make(1, 'S', 10.0, 50)));
    run_all(s);

    // Saw the book at t + L_in.
    CHECK(lifter.saw_book_at == 1030 * US);
    // Order hit the book at t + L_in + compute + L_out.
    const BookEvents& log = s.event_log();
    CHECK(log.size() == 5); // feed Accepted; then Accepted, Trade, Filled, PartialFill
    CHECK(log[1].type == T::Accepted && log[1].timestamp_ns == 1100 * US);
    CHECK(log[2].type == T::Trade);
}

// The account changes at fill time; on_fill is heard L_in later.
void test_fill_notification_delay() {
    Scheduler s;
    Recorder rec;
    s.add_participant(ALICE, rec, LatencyProfile::uniform(40 * US, 0));

    const uint64_t id = rec.do_limit('B', 10.0, 20); // rests at t=0 (no outbound delay)
    s.schedule(500 * US, FEED, Action::add(make(1, 'S', 10.0, 20)));

    while (!s.empty() && s.next_time() <= 500 * US) s.step();
    CHECK(s.now() == 500 * US);
    CHECK(rec.acct().position() == 20); // already booked...
    CHECK(rec.fills.empty());           // ...but not yet heard

    run_all(s);
    CHECK(rec.fills.size() == 1);
    CHECK(rec.fills[0].at == 540 * US);
    CHECK(rec.fills[0].event.order_id == id && rec.fills[0].event.liquidity == 'M');
    CHECK(rec.fills[0].event.type == T::Filled);
}

// The lesson: same strategy, the faster participant wins the race.
void test_faster_wins_the_race() {
    Scheduler s;
    Lifter fast, slow;
    s.add_participant(ALICE, slow, latency_preset(LatencyTier::Direct));
    s.add_participant(BOB, fast, latency_preset(LatencyTier::Colo));

    s.schedule(1000 * US, FEED, Action::add(make(1, 'S', 10.0, 10))); // only 10 on offer
    run_all(s);

    CHECK(fast.sent && slow.sent); // both tried
    CHECK(s.account(BOB).position() == 10);   // colo got there first
    CHECK(s.account(ALICE).position() == 0);  // nothing left for the slow one...
    CHECK(s.account(ALICE).open_orders().size() == 1); // ...its bid is now resting
}

// Per-exchange table: colo is fast at home and slow elsewhere.
void test_latency_presets() {
    const LatencyProfile colo = latency_preset(LatencyTier::Colo, 3);
    CHECK(colo.leg(3).in_ns == 5 * US && colo.leg(3).out_ns == 5 * US);
    CHECK(colo.leg(0).in_ns == 400 * US);
    const LatencyProfile mw = latency_preset(LatencyTier::Microwave, 3);
    CHECK(mw.leg(0).in_ns < colo.leg(0).in_ns);
    const LatencyProfile retail = latency_preset(LatencyTier::Retail);
    const LatencyProfile direct = latency_preset(LatencyTier::Direct);
    CHECK(retail.leg(0).in_ns > direct.leg(0).in_ns);
    CHECK(direct.leg(0).in_ns > colo.leg(3).in_ns);

    LatencyProfile p = LatencyProfile::uniform(1, 2, 3);
    p.set(7, LatencyLeg{10, 20});
    p.set(7, LatencyLeg{11, 21}); // overwrite, not duplicate
    CHECK(p.per_exchange.size() == 1 && p.leg(7).in_ns == 11 && p.leg(8).out_ns == 2);
    CHECK(p.compute_ns == 3);
}

// Market orders trade what is there and never rest.
void test_market_order() {
    Scheduler s;
    Recorder rec;
    s.add_participant(ALICE, rec);
    s.schedule(100, FEED, Action::add(make(1, 'S', 10.0, 30)));
    s.schedule(100, FEED, Action::add(make(2, 'S', 11.0, 30)));
    run_all(s);

    rec.do_market('B', 100); // only 60 available
    run_all(s);

    CHECK(rec.acct().position() == 60);
    CHECK(near(rec.acct().cash(), -(30 * 10.0 + 30 * 11.0)));
    CHECK(rec.acct().open_orders().empty());     // remainder was cancelled
    CHECK(s.book().get_l1_state().best_bid == 0.0); // nothing rested
    CHECK(rec.fills.size() == 2);
    CHECK(rec.updates.back().event.type == T::Cancelled && rec.updates.back().event.size == 40);

    rec.do_market('S', 10); // empty bid side: accepted, then all of it cancelled
    run_all(s);
    CHECK(rec.acct().position() == 60);
    CHECK(rec.updates.back().event.type == T::Cancelled && rec.updates.back().event.size == 10);
}

// cancel / reduce / replace through the participant API.
void test_order_management() {
    Scheduler s;
    Recorder rec;
    s.add_participant(ALICE, rec);

    const uint64_t a = rec.do_limit('B', 10.0, 100);
    run_all(s);
    CHECK(a != 0 && rec.acct().open_orders().at(a).remaining == 100);

    rec.do_reduce(a, 30);
    run_all(s);
    CHECK(rec.acct().open_orders().at(a).remaining == 70);

    const uint64_t b = rec.do_replace(a, 9.5, 40);
    run_all(s);
    CHECK(b != a && rec.acct().open_orders().count(a) == 0);
    CHECK(rec.acct().open_orders().at(b).side == 'B'); // side inherited
    CHECK(rec.acct().open_orders().at(b).price == 9.5);

    rec.do_cancel(b);
    rec.do_cancel(12345); // unknown -> rejected
    run_all(s);
    CHECK(rec.acct().open_orders().empty());
    CHECK(rec.acct().rejects() == 1);
    CHECK(rec.acct().orders_sent() == 2 && rec.acct().cancels_sent() == 3);
    CHECK(s.book().get_l1_state().best_bid == 0.0);
}

// Which action bumps which counter. Scheduler::submit decides this, and the
// mapping is not obvious: a replace counts as an order sent (it creates one)
// and NOT as a cancel, while a reduce counts as a cancel even though the order
// survives. Wake counts as neither.
void test_sent_counters() {
    Scheduler s;
    Recorder alice, bob;
    s.add_participant(ALICE, alice);
    s.add_participant(BOB, bob);

    CHECK(alice.acct().orders_sent() == 0 && alice.acct().cancels_sent() == 0);

    // --- the three that count as orders sent ---
    const uint64_t lim = alice.do_limit('B', 10.0, 100);
    run_all(s);
    CHECK(alice.acct().orders_sent() == 1 && alice.acct().cancels_sent() == 0);

    alice.do_market('B', 1); // nothing resting to hit; still an order sent
    run_all(s);
    CHECK(alice.acct().orders_sent() == 2 && alice.acct().cancels_sent() == 0);

    const uint64_t rep = alice.do_replace(lim, 9.5, 40);
    run_all(s);
    CHECK(alice.acct().orders_sent() == 3); // a replace is a new order...
    CHECK(alice.acct().cancels_sent() == 0); // ...and not a cancel

    // --- the two that count as cancels sent ---
    alice.do_reduce(rep, 10); // the order survives, but it counts as a cancel
    run_all(s);
    CHECK(alice.acct().orders_sent() == 3 && alice.acct().cancels_sent() == 1);

    alice.do_cancel(rep);
    run_all(s);
    CHECK(alice.acct().orders_sent() == 3 && alice.acct().cancels_sent() == 2);

    // --- Wake counts as neither ---
    s.schedule(s.now(), ALICE, Action::wake());
    run_all(s);
    CHECK(alice.acct().orders_sent() == 3 && alice.acct().cancels_sent() == 2);

    // --- counted when sent, not when the book accepts it ---
    // Cancelling an id that does not exist is rejected by the book, but the
    // participant still asked for it, so the counter moves and rejects() also
    // records the refusal.
    alice.do_cancel(999999);
    run_all(s);
    CHECK(alice.acct().cancels_sent() == 3 && alice.acct().rejects() == 1);

    // --- per participant, not global ---
    CHECK(bob.acct().orders_sent() == 0 && bob.acct().cancels_sent() == 0);
    bob.do_limit('S', 20.0, 5);
    run_all(s);
    CHECK(bob.acct().orders_sent() == 1 && alice.acct().orders_sent() == 3);
}

// Fees: the taker pays, the maker is paid.
void test_fees_applied() {
    Scheduler s;
    s.set_fees(FeeSchedule{0.003, 0.002});
    Recorder maker, taker;
    s.add_participant(ALICE, maker);
    s.add_participant(BOB, taker);

    maker.do_limit('S', 10.0, 100);
    run_all(s);
    taker.do_limit('B', 10.0, 100);
    run_all(s);

    CHECK(near(s.account(ALICE).fees_paid(), -0.20));
    CHECK(near(s.account(BOB).fees_paid(), 0.30));
    CHECK(s.account(ALICE).position() == -100 && s.account(BOB).position() == 100);
    CHECK(near(s.account(ALICE).net_pnl(10.0), 0.20));
    CHECK(near(s.account(BOB).net_pnl(10.0), -0.30));
}

// Timers fire after the requested delay, with no network leg.
void test_timer() {
    Scheduler s;
    Recorder rec;
    s.add_participant(ALICE, rec, LatencyProfile::uniform(999, 999, 999));
    s.schedule(100, FEED, Action::wake());
    s.step();
    rec.do_timer(250);
    run_all(s);
    CHECK(rec.timer_times.size() == 1 && rec.timer_times[0] == 350);
}

// A participant can ask where its resting order stands in line.
void test_queue_position_query() {
    Scheduler s;
    Recorder rec;
    s.add_participant(ALICE, rec);
    s.schedule(100, FEED, Action::add(make(1, 'B', 10.0, 70)));
    s.run();
    const uint64_t id = rec.do_limit('B', 10.0, 10); // joins behind the feed's 70
    s.run();
    CHECK(rec.where(id).has_value() && rec.where(id)->shares_ahead == 70);

    s.schedule(200, FEED, Action::add(make(2, 'S', 10.0, 50))); // 50 trades in front
    s.run();
    CHECK(rec.where(id)->shares_ahead == 20);
    CHECK(!rec.where(424242).has_value());
}

// A participant that is not registered cannot act.
void test_unregistered() {
    Recorder loose;
    CHECK(loose.do_limit('B', 10.0, 1) == 0);
    CHECK(loose.acct().position() == 0);
}
} // namespace

int main() {
    struct { const char* name; void (*fn)(); } tests[] = {
        {"callbacks_zero_latency", test_callbacks_zero_latency},
        {"latency_both_legs", test_latency_both_legs},
        {"fill_notification_delay", test_fill_notification_delay},
        {"faster_wins_the_race", test_faster_wins_the_race},
        {"latency_presets", test_latency_presets},
        {"market_order", test_market_order},
        {"order_management", test_order_management},
        {"sent_counters", test_sent_counters},
        {"fees_applied", test_fees_applied},
        {"timer", test_timer},
        {"queue_position_query", test_queue_position_query},
        {"unregistered", test_unregistered},
    };
    for (const auto& t : tests) {
        const int before = failures;
        t.fn();
        std::printf("%s  %s\n", failures == before ? "ok  " : "FAIL", t.name);
    }
    std::printf("%s (%d failed check%s)\n", failures ? "FAILED" : "PASSED",
                failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
