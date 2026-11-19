#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <queue>
#include <random>
#include <unordered_map>
#include <vector>

#include "account.h"
#include "latency.h"
#include "orderbook.h"
#include "participant.h"

// Deterministic discrete-event scheduler: the simulated exchange's clock.
//
// Nobody touches the OrderBook directly. Everything that happens is an entry
// on one time-ordered queue, and step() processes the earliest:
//
//   * a book Action (add / cancel / ...) sent by a participant or the data feed
//   * the delivery of an event or a book snapshot to a participant
//   * a participant's timer
//
// When an action changes the book, the scheduler updates the accounts of the
// participants involved and queues the news for delivery L_in later. When a
// participant reacts by sending an order, it is queued compute + L_out later.
// That is the whole latency model (see latency.h).
//
// Determinism: entries are ordered by (time_ns, seq). seq is a counter stamped
// when the entry is queued, so two entries at the same nanosecond always run
// in the order they were queued -- never in an order that depends on memory
// layout or hashing. Same inputs + same seed = identical event log.

enum class ActionType : uint8_t {
    Add,      // enter limit `order`
    Market,   // trade `order` against the book now; never rests
    Cancel,   // remove `target_order_id`
    Reduce,   // take `qty` off `target_order_id` (keeps queue position)
    Replace,  // swap `target_order_id` for `order` (loses queue position)
    Wake      // no book change; a tick with nothing to apply
};

struct Action {
    ActionType type = ActionType::Wake;
    Order      order{};              // Add / Market / Replace: the (new) order
    uint64_t   target_order_id = 0;  // Cancel / Reduce / Replace: the resting order
    double     qty = 0.0;            // Reduce: size to take off
    char       side = 0;             // Cancel / Reduce: side to look on, 0 = either

    static Action add(const Order& order);
    static Action market(const Order& order);
    static Action cancel(uint64_t order_id, char side = 0);
    static Action reduce(uint64_t order_id, double qty, char side = 0);
    static Action replace(uint64_t old_order_id, const Order& new_order);
    static Action wake();
};

enum class StepKind : uint8_t {
    BookAction,  // an Action was applied to the book
    Delivery,    // a participant callback ran (event, book update or timer)
};

// What one step() did.
struct StepResult {
    StepKind      kind = StepKind::BookAction;
    uint64_t      time_ns = 0;      // sim time it happened
    uint64_t      seq = 0;          // its queue sequence number
    ParticipantId participant = 0;  // who sent the action / received the delivery
    Action        action{};         // BookAction: as applied; for Add / Market /
                                    // Replace, order.size is the unfilled remainder
    BookEvents    events;           // BookAction: everything the book emitted
};

class Scheduler {
public:
    explicit Scheduler(uint64_t seed = 0);

    Scheduler(const Scheduler&) = delete; // participants hold a pointer to it
    Scheduler& operator=(const Scheduler&) = delete;

    // ---------------- Participants ----------------

    // Registers a participant under `id`: it gets an Account, its callbacks
    // are invoked L_in after each event, and its orders land compute + L_out
    // after it sends them. The scheduler does not own it; it must outlive the
    // run. Ids are chosen by the caller and must be unique.
    void add_participant(ParticipantId id, Participant& participant,
                         const LatencyProfile& latency = {});
    void set_latency(ParticipantId id, const LatencyProfile& latency);
    bool is_registered(ParticipantId id) const { return participants_.count(id) != 0; }
    const Account& account(ParticipantId id) const; // id must be registered

    // Fees this exchange charges on every fill (default: none).
    void set_fees(const FeeSchedule& fees) { fees_ = fees; }
    // Price levels per side in the snapshots sent to on_book_update (default 5).
    void set_book_depth(size_t levels) { book_depth_ = levels; }
    ExchangeId exchange() const { return exchange_; }

    // Queues `action` on behalf of a registered participant, after its
    // outbound latency. For Add / Market / Replace a fresh order id is
    // assigned and returned (0 otherwise). Participant::send_* call this.
    uint64_t submit(ParticipantId id, Action action);
    void     set_timer(ParticipantId id, uint64_t delay_ns);

    // ---------------- Raw scheduling ----------------

    // Queues an action to hit the book at exactly time_ns, with no latency and
    // no account -- for sources that are not participants, like the recorded
    // market-data feed. A time earlier than now() is moved up to now().
    // Returns the entry's sequence number.
    uint64_t schedule(uint64_t time_ns, ParticipantId source, const Action& action);

    bool     empty() const { return queue_.empty(); }
    size_t   pending() const { return queue_.size(); }
    uint64_t now() const { return now_ns_; }
    uint64_t next_time() const; // time of the earliest pending entry; now() if empty

    // Processes the earliest entry and advances now() to its time.
    // Must not be called when empty().
    StepResult step();

    // Convenience loops: process everything due at or before time_ns / until
    // the queue is empty. Return how many entries were processed.
    size_t run_until(uint64_t time_ns);
    size_t run();

    // ---------------- Book snapshots ----------------

    // Every interval_ns of simulated time, keep a full L3 snapshot of the
    // book (0 = off, the default). A snapshot stamped T holds the book as it
    // stood at T: everything scheduled before T applied, nothing at or after.
    // The first is taken one interval after the first entry processed.
    void set_snapshot_interval(uint64_t interval_ns) { snapshot_interval_ns_ = interval_ns; }
    const std::vector<BookSnapshot>& snapshots() const { return snapshots_; }

    // Seek: load a snapshot's book and jump the clock to its time, so a run
    // can continue from there instead of from the start. Pending entries,
    // accounts and order ownership are NOT part of a snapshot -- call this on
    // a fresh scheduler, then feed it the data from that time onward.
    void restore(const BookSnapshot& snapshot);

    // ---------------- Inboxes (polling alternative to callbacks) ----------------

    // For a source that is not a Participant object but still wants the events
    // about its orders: open an inbox, then drain it whenever convenient.
    // Events land in it immediately (no latency).
    void open_inbox(ParticipantId id);
    BookEvents drain_inbox(ParticipantId id); // returns and clears it

    // ---------------- Everything else ----------------

    // Optional full event log (off by default; it grows with every event).
    void record_events(bool on) { recording_ = on; }
    const BookEvents& event_log() const { return event_log_; }

    OrderBook&       book() { return book_; }
    const OrderBook& book() const { return book_; }

    // The run's only source of randomness. The engine's raw output is the
    // same on every platform for a given seed; std::*_distribution is NOT
    // (each standard library implements them differently), so derive values
    // from rng()() directly when cross-platform reproducibility matters.
    std::mt19937_64& rng() { return rng_; }

private:
    enum class EntryKind : uint8_t { BookAction, DeliverEvent, DeliverBook, Timer };

    struct Entry {
        uint64_t      time_ns = 0;
        uint64_t      seq = 0;
        ParticipantId participant = 0;
        EntryKind     kind = EntryKind::BookAction;
        Action        action{};                    // BookAction
        BookEvent     event{};                     // DeliverEvent
        std::shared_ptr<const L2State> book;       // DeliverBook (shared by all recipients)
    };
    // priority_queue is a max-heap, so "later" must compare as "lower".
    struct Later {
        bool operator()(const Entry& a, const Entry& b) const {
            if (a.time_ns != b.time_ns) return a.time_ns > b.time_ns;
            return a.seq > b.seq;
        }
    };

    struct Slot {
        Participant*   participant = nullptr;
        LatencyProfile latency;
        Account        account;
    };

    void push(Entry entry); // stamps seq, clamps the time to now()
    void publish(ParticipantId actor, const BookEvents& events);
    void notify_owner(ParticipantId owner, const BookEvent& event);

    OrderBook book_;
    std::priority_queue<Entry, std::vector<Entry>, Later> queue_;
    uint64_t now_ns_   = 0;
    uint64_t next_seq_ = 0;

    // Ordered by id so fan-out to "everyone" is in a fixed order.
    std::map<ParticipantId, Slot> participants_;
    std::unordered_map<ParticipantId, BookEvents> inboxes_;
    // Live orders of registered participants and inbox holders.
    std::unordered_map<uint64_t, ParticipantId> order_owner_;

    // Ids handed to participants' orders; far above anything a data file uses.
    uint64_t    next_order_id_ = 1ULL << 40;
    FeeSchedule fees_;
    size_t      book_depth_ = 5;
    ExchangeId  exchange_ = 0; // single venue until ticket #21

    uint64_t snapshot_interval_ns_ = 0;
    uint64_t next_snapshot_ns_ = 0;
    bool     snapshot_clock_started_ = false;
    std::vector<BookSnapshot> snapshots_;

    bool       recording_ = false;
    BookEvents event_log_;

    std::mt19937_64 rng_;
};
