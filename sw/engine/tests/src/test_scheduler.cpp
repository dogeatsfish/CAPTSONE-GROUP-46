// Unit tests for the discrete-event Scheduler (make test).
// Plain asserts, no framework: each CHECK prints the failing line and the
// process exits non-zero if any failed.

#include <cstdio>
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

using T = BookEventType;

constexpr ParticipantId FEED  = 0;
constexpr ParticipantId ALICE = 1;
constexpr ParticipantId BOB   = 2;

Order make(uint64_t id, char side, double price, double size) {
    return Order{id, price, size, side, false};
}

// Actions run in time order no matter what order they were scheduled in.
void test_time_order() {
    Scheduler s;
    s.schedule(300, FEED, Action::add(make(3, 'B', 8.0, 1)));
    s.schedule(100, FEED, Action::add(make(1, 'B', 10.0, 1)));
    s.schedule(200, FEED, Action::add(make(2, 'B', 9.0, 1)));

    CHECK(s.pending() == 3 && s.next_time() == 100);
    CHECK(s.step().action.order.order_id == 1);
    CHECK(s.now() == 100);
    CHECK(s.step().action.order.order_id == 2);
    CHECK(s.step().action.order.order_id == 3);
    CHECK(s.now() == 300 && s.empty());
}

// Same timestamp: first scheduled runs first, so it gets queue priority.
void test_same_time_tie_break() {
    Scheduler s;
    s.schedule(100, ALICE, Action::add(make(1, 'B', 10.0, 10)));
    s.schedule(100, BOB,   Action::add(make(2, 'B', 10.0, 10)));
    s.schedule(100, FEED,  Action::add(make(3, 'S', 10.0, 10)));

    const StepResult a = s.step();
    const StepResult b = s.step();
    const StepResult c = s.step();
    CHECK(a.participant == ALICE && b.participant == BOB && c.participant == FEED);
    CHECK(a.seq < b.seq && b.seq < c.seq);
    // The sell hits Alice (first in), not Bob.
    CHECK(c.events[1].type == T::Trade && c.events[1].contra_order_id == 1);
}

// Nothing can be scheduled into the past.
void test_no_time_travel() {
    Scheduler s;
    s.schedule(500, FEED, Action::wake());
    s.step();
    s.schedule(100, FEED, Action::add(make(1, 'B', 10.0, 1)));
    const StepResult r = s.step();
    CHECK(r.time_ns == 500 && s.now() == 500);
    CHECK(r.events[0].timestamp_ns == 500);
}

// Events reach the right inbox -- including a passive fill caused by someone else.
void test_inbox_routing() {
    Scheduler s;
    s.open_inbox(ALICE);
    s.open_inbox(BOB);

    s.schedule(100, ALICE, Action::add(make(1, 'S', 10.0, 50))); // Alice rests
    s.schedule(200, BOB,   Action::add(make(2, 'B', 10.0, 20))); // Bob lifts 20
    s.step();
    s.step();

    const BookEvents alice = s.drain_inbox(ALICE);
    CHECK(alice.size() == 2);
    CHECK(alice[0].type == T::Accepted && alice[0].order_id == 1);
    CHECK(alice[1].type == T::PartialFill && alice[1].order_id == 1);
    CHECK(alice[1].liquidity == 'M' && alice[1].size == 20 && alice[1].remaining == 30);
    CHECK(alice[1].timestamp_ns == 200);

    const BookEvents bob = s.drain_inbox(BOB);
    CHECK(bob.size() == 2);
    CHECK(bob[0].type == T::Accepted && bob[0].order_id == 2);
    CHECK(bob[1].type == T::Filled && bob[1].liquidity == 'T');

    CHECK(s.drain_inbox(ALICE).empty()); // draining clears it

    // Rejects go to whoever asked; cancels to the owner.
    s.schedule(300, BOB,   Action::cancel(999));
    s.schedule(300, ALICE, Action::reduce(1, 10));
    s.schedule(300, ALICE, Action::cancel(1));
    s.step(); s.step(); s.step();
    const BookEvents bob2 = s.drain_inbox(BOB);
    CHECK(bob2.size() == 1 && bob2[0].type == T::Rejected);
    const BookEvents alice2 = s.drain_inbox(ALICE);
    CHECK(alice2.size() == 2);
    CHECK(alice2[0].type == T::Reduced && alice2[0].remaining == 20);
    CHECK(alice2[1].type == T::Cancelled && alice2[1].size == 20);
}

// A participant without an inbox gets nothing kept on its behalf.
void test_closed_inbox() {
    Scheduler s;
    s.open_inbox(ALICE);
    s.schedule(100, FEED,  Action::add(make(1, 'S', 10.0, 10)));
    s.schedule(200, ALICE, Action::add(make(2, 'B', 10.0, 10)));
    s.step();
    s.step();
    CHECK(s.drain_inbox(FEED).empty());
    CHECK(s.drain_inbox(ALICE).size() == 2); // Accepted + Filled
}

// Replace goes through the scheduler; Wake touches nothing.
void test_replace_and_wake() {
    Scheduler s;
    s.schedule(100, FEED, Action::add(make(1, 'B', 10.0, 10)));
    s.schedule(200, FEED, Action::replace(1, make(2, 0, 11.0, 5)));
    s.schedule(300, FEED, Action::wake());
    s.step();
    const StepResult rep = s.step();
    CHECK(rep.events.size() == 2 && rep.events[0].type == T::Cancelled);
    CHECK(s.book().get_l1_state().best_bid == 11.0);
    const StepResult wake = s.step();
    CHECK(wake.events.empty() && wake.time_ns == 300);
}

// run_until stops at the given time; run drains the queue.
void test_run_until() {
    Scheduler s;
    for (uint64_t t = 100; t <= 500; t += 100) {
        s.schedule(t, FEED, Action::add(make(t, 'B', 10.0, 1)));
    }
    CHECK(s.run_until(300) == 3);
    CHECK(s.now() == 300 && s.pending() == 2);
    CHECK(s.run() == 2 && s.empty());
}

// Snapshots are taken on the interval and hold the book as of that instant.
void test_periodic_snapshots() {
    Scheduler s;
    s.set_snapshot_interval(1000);
    s.schedule(0,    FEED, Action::add(make(1, 'B', 10.0, 10)));
    s.schedule(500,  FEED, Action::add(make(2, 'B', 10.0, 20)));
    s.schedule(1000, FEED, Action::add(make(3, 'S', 11.0, 30))); // exactly on the boundary
    s.schedule(4500, FEED, Action::cancel(1));                   // after a long quiet gap
    s.schedule(5200, FEED, Action::wake());
    s.run();

    const std::vector<BookSnapshot>& snaps = s.snapshots();
    CHECK(snaps.size() == 3);
    // t=1000: orders 1 and 2 are in; order 3 (at the boundary) is not yet.
    CHECK(snaps[0].timestamp_ns == 1000);
    CHECK(snaps[0].bids.size() == 2 && snaps[0].asks.empty());
    CHECK(snaps[0].next_event_seq == 3); // two Accepted events so far
    // The gap 1000..4500 crosses 2000/3000/4000 but yields one snapshot.
    CHECK(snaps[1].timestamp_ns == 2000);
    CHECK(snaps[1].bids.size() == 2 && snaps[1].asks.size() == 1);
    // t=5000: order 1 has been cancelled.
    CHECK(snaps[2].timestamp_ns == 5000);
    CHECK(snaps[2].bids.size() == 1 && snaps[2].bids[0].order_id == 2);
}

// Seek: a fresh scheduler restored from a snapshot and fed the rest of the
// input ends up with the same book and the same later events.
void test_seek_from_snapshot() {
    auto feed = [](Scheduler& s, uint64_t from_ns) {
        struct Rec { uint64_t t; Action a; };
        const Rec recs[] = {
            {100,  Action::add(make(1, 'B', 10.0, 10))},
            {200,  Action::add(make(2, 'S', 11.0, 10))},
            {900,  Action::add(make(3, 'B', 10.0, 5))},
            {1500, Action::add(make(4, 'S', 10.0, 12))}, // trades with 1, then 3
            {1700, Action::cancel(2)},
        };
        for (const Rec& r : recs) {
            if (r.t >= from_ns) s.schedule(r.t, FEED, r.a);
        }
    };

    Scheduler full;
    full.record_events(true);
    full.set_snapshot_interval(1000);
    feed(full, 0);
    full.run();
    CHECK(full.snapshots().size() == 1);
    const BookSnapshot snap = full.snapshots()[0]; // book as of t=1100

    Scheduler resumed;
    resumed.record_events(true);
    resumed.restore(snap);
    CHECK(resumed.now() == snap.timestamp_ns);
    feed(resumed, snap.timestamp_ns);
    resumed.run();

    // The resumed log is exactly the tail of the full log.
    const BookEvents& a = full.event_log();
    const BookEvents& b = resumed.event_log();
    CHECK(!b.empty() && b.size() < a.size());
    const size_t offset = a.size() - b.size();
    for (size_t i = 0; i < b.size(); ++i) {
        CHECK(a[offset + i].seq == b[i].seq && a[offset + i].type == b[i].type);
        CHECK(a[offset + i].order_id == b[i].order_id && a[offset + i].size == b[i].size);
    }
    CHECK(b.front().seq == snap.next_event_seq);
    CHECK(full.book().get_l2_state(5).bids.size() == resumed.book().get_l2_state(5).bids.size());
}

// A small scenario driven by the scheduler's RNG.
BookEvents run_scenario(uint64_t seed) {
    Scheduler s(seed);
    s.record_events(true);
    uint64_t t = 0;
    for (uint64_t id = 1; id <= 500; ++id) {
        const uint64_t r = s.rng()();
        t += r % 1000;
        const char side = (r >> 10) & 1 ? 'B' : 'S';
        const double price = 100.0 + static_cast<double>((r >> 11) % 21) - 10.0;
        const double size = 1.0 + static_cast<double>((r >> 20) % 50);
        s.schedule(t, static_cast<ParticipantId>(r % 4), Action::add(make(id, side, price, size)));
        if ((r >> 30) % 5 == 0 && id > 1) {
            s.schedule(t + 500, FEED, Action::reduce(1 + (r >> 32) % (id - 1), 3));
        }
    }
    while (!s.empty()) s.step();
    return s.event_log();
}

bool same(const BookEvents& a, const BookEvents& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        const BookEvent& x = a[i];
        const BookEvent& y = b[i];
        if (x.seq != y.seq || x.timestamp_ns != y.timestamp_ns || x.type != y.type ||
            x.order_id != y.order_id || x.contra_order_id != y.contra_order_id ||
            x.side != y.side || x.liquidity != y.liquidity || x.price != y.price ||
            x.size != y.size || x.remaining != y.remaining || x.reason != y.reason) {
            return false;
        }
    }
    return true;
}

// Same seed -> identical event log; a different seed -> a different one.
void test_determinism() {
    const BookEvents a = run_scenario(42);
    const BookEvents b = run_scenario(42);
    const BookEvents c = run_scenario(43);
    CHECK(a.size() > 500); // the scenario really traded
    CHECK(same(a, b));
    CHECK(!same(a, c));
}
} // namespace

int main() {
    struct { const char* name; void (*fn)(); } tests[] = {
        {"time_order",          test_time_order},
        {"same_time_tie_break", test_same_time_tie_break},
        {"no_time_travel",      test_no_time_travel},
        {"inbox_routing",       test_inbox_routing},
        {"closed_inbox",        test_closed_inbox},
        {"replace_and_wake",    test_replace_and_wake},
        {"run_until",           test_run_until},
        {"periodic_snapshots",  test_periodic_snapshots},
        {"seek_from_snapshot",  test_seek_from_snapshot},
        {"determinism",         test_determinism},
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
