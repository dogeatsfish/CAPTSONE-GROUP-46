#include "scheduler.h"

#include "participant.h" // complete type: virtual dispatch + add_participant

#include <algorithm>
#include <utility>

// ---------------------------------------------------------
// Action builders
// ---------------------------------------------------------
Action Action::add(const Order& order) {
    Action a;
    a.type  = ActionType::Add;
    a.order = order;
    return a;
}

Action Action::market(const Order& order) {
    Action a;
    a.type  = ActionType::Market;
    a.order = order;
    return a;
}

Action Action::cancel(uint64_t order_id, char side) {
    Action a;
    a.type            = ActionType::Cancel;
    a.target_order_id = order_id;
    a.side            = side;
    return a;
}

Action Action::reduce(uint64_t order_id, double qty, char side) {
    Action a;
    a.type            = ActionType::Reduce;
    a.target_order_id = order_id;
    a.qty             = qty;
    a.side            = side;
    return a;
}

Action Action::replace(uint64_t old_order_id, const Order& new_order) {
    Action a;
    a.type            = ActionType::Replace;
    a.target_order_id = old_order_id;
    a.order           = new_order;
    return a;
}

Action Action::wake() {
    return Action{};
}

// ---------------------------------------------------------
// Participant: thin forwarding to its scheduler
// ---------------------------------------------------------
uint64_t Participant::send_limit(char side, double price, double size) {
    if (scheduler_ == nullptr) return 0;
    return scheduler_->submit(id_, Action::add(Order{0, price, size, side, true}));
}

uint64_t Participant::send_market(char side, double size) {
    if (scheduler_ == nullptr) return 0;
    return scheduler_->submit(id_, Action::market(Order{0, 0.0, size, side, true}));
}

void Participant::cancel(uint64_t order_id) {
    if (scheduler_ != nullptr) scheduler_->submit(id_, Action::cancel(order_id));
}

void Participant::reduce(uint64_t order_id, double qty) {
    if (scheduler_ != nullptr) scheduler_->submit(id_, Action::reduce(order_id, qty));
}

uint64_t Participant::replace(uint64_t order_id, double price, double size) {
    if (scheduler_ == nullptr) return 0;
    // Side is taken from the order being replaced.
    return scheduler_->submit(id_, Action::replace(order_id, Order{0, price, size, 0, true}));
}

void Participant::set_timer(uint64_t delay_ns) {
    if (scheduler_ != nullptr) scheduler_->set_timer(id_, delay_ns);
}

uint64_t Participant::now() const {
    return scheduler_ != nullptr ? scheduler_->now() : 0;
}

std::optional<QueuePosition> Participant::queue_position(uint64_t order_id) const {
    if (scheduler_ == nullptr) return std::nullopt;
    return scheduler_->book().queue_position(order_id);
}

const Account& Participant::account() const {
    static const Account unregistered;
    return scheduler_ != nullptr ? scheduler_->account(id_) : unregistered;
}

// ---------------------------------------------------------
// Scheduler
// ---------------------------------------------------------
Scheduler::Scheduler(uint64_t seed) : rng_(seed) {}

void Scheduler::add_participant(ParticipantId id, Participant& participant,
                                const LatencyProfile& latency) {
    Slot& slot = participants_[id];
    slot.participant = &participant;
    slot.latency     = latency;
    participant.scheduler_ = this;
    participant.id_        = id;
}

void Scheduler::set_latency(ParticipantId id, const LatencyProfile& latency) {
    participants_.at(id).latency = latency;
}

const Account& Scheduler::account(ParticipantId id) const {
    return participants_.at(id).account;
}

void Scheduler::push(Entry entry) {
    entry.seq     = next_seq_++;
    entry.time_ns = std::max(entry.time_ns, now_ns_); // nothing goes into the past
    queue_.push(std::move(entry));
}

uint64_t Scheduler::schedule(uint64_t time_ns, ParticipantId source, const Action& action) {
    Entry entry;
    entry.time_ns     = time_ns;
    entry.participant = source;
    entry.kind        = EntryKind::BookAction;
    entry.action      = action;
    const uint64_t seq = next_seq_;
    push(std::move(entry));
    return seq;
}

uint64_t Scheduler::submit(ParticipantId id, Action action) {
    Slot& slot = participants_.at(id);

    uint64_t order_id = 0;
    switch (action.type) {
        case ActionType::Add:
        case ActionType::Market:
        case ActionType::Replace:
            order_id = next_order_id_++;
            action.order.order_id = order_id;
            slot.account.note_order_sent();
            break;
        case ActionType::Cancel:
        case ActionType::Reduce:
            slot.account.note_cancel_sent();
            break;
        case ActionType::Wake:
            break;
    }

    // The decision takes compute time, then the message travels to the exchange.
    const LatencyLeg& leg = slot.latency.leg(exchange_);
    Entry entry;
    entry.time_ns     = now_ns_ + slot.latency.compute_ns + leg.out_ns;
    entry.participant = id;
    entry.kind        = EntryKind::BookAction;
    entry.action      = action;
    push(std::move(entry));
    return order_id;
}

void Scheduler::set_timer(ParticipantId id, uint64_t delay_ns) {
    Entry entry;
    entry.time_ns     = now_ns_ + delay_ns; // local to the participant: no network leg
    entry.participant = id;
    entry.kind        = EntryKind::Timer;
    push(std::move(entry));
}

uint64_t Scheduler::next_time() const {
    return queue_.empty() ? now_ns_ : queue_.top().time_ns;
}

StepResult Scheduler::step() {
    const Entry next = queue_.top();
    queue_.pop();

    // Crossing a snapshot boundary: capture the book before anything at or
    // after that boundary is applied.
    if (snapshot_interval_ns_ != 0) {
        if (!snapshot_clock_started_) {
            snapshot_clock_started_ = true;
            next_snapshot_ns_ = next.time_ns + snapshot_interval_ns_;
        } else if (next.time_ns >= next_snapshot_ns_) {
            snapshots_.push_back(book_.snapshot(next_snapshot_ns_));
            // A quiet stretch can span several boundaries; the book was the
            // same at all of them, so one snapshot covers the gap.
            const uint64_t missed = (next.time_ns - next_snapshot_ns_) / snapshot_interval_ns_;
            next_snapshot_ns_ += (missed + 1) * snapshot_interval_ns_;
        }
    }

    now_ns_ = next.time_ns;

    StepResult result;
    result.time_ns     = next.time_ns;
    result.seq         = next.seq;
    result.participant = next.participant;

    // --- A callback into a participant ---
    if (next.kind != EntryKind::BookAction) {
        result.kind = StepKind::Delivery;
        const auto it = participants_.find(next.participant);
        if (it == participants_.end()) return result;
        Participant& p = *it->second.participant;

        if (next.kind == EntryKind::Timer) {
            p.on_timer(now_ns_);
        } else if (next.kind == EntryKind::DeliverBook) {
            p.on_book_update(*next.book);
        } else if (next.event.type == BookEventType::Trade) {
            p.on_trade(next.event);
        } else if (next.event.type == BookEventType::PartialFill ||
                   next.event.type == BookEventType::Filled) {
            p.on_fill(next.event);
        } else {
            p.on_order_update(next.event);
        }
        return result;
    }

    // --- An action against the book ---
    result.kind   = StepKind::BookAction;
    result.action = next.action;

    Action& a = result.action;
    switch (a.type) {
        case ActionType::Add:
            result.events = book_.process_add(a.order, now_ns_);
            break;
        case ActionType::Market:
            result.events = book_.process_market(a.order, now_ns_);
            break;
        case ActionType::Cancel:
            result.events = book_.process_cancel(a.target_order_id, now_ns_, a.side);
            break;
        case ActionType::Reduce:
            result.events = book_.process_reduce(a.target_order_id, a.qty, now_ns_, a.side);
            break;
        case ActionType::Replace:
            result.events = book_.process_replace(a.target_order_id, a.order, now_ns_);
            break;
        case ActionType::Wake:
            break;
    }

    if (!participants_.empty() || !inboxes_.empty()) publish(next.participant, result.events);
    if (recording_) {
        event_log_.insert(event_log_.end(), result.events.begin(), result.events.end());
    }
    return result;
}

size_t Scheduler::run_until(uint64_t time_ns) {
    size_t steps = 0;
    while (!queue_.empty() && queue_.top().time_ns <= time_ns) {
        step();
        ++steps;
    }
    return steps;
}

size_t Scheduler::run() {
    size_t steps = 0;
    while (!queue_.empty()) {
        step();
        ++steps;
    }
    return steps;
}

void Scheduler::restore(const BookSnapshot& snapshot) {
    book_.restore(snapshot);
    now_ns_ = snapshot.timestamp_ns;
    order_owner_.clear();
    snapshot_clock_started_ = false;
}

void Scheduler::open_inbox(ParticipantId id) {
    inboxes_[id]; // creates it if missing
}

BookEvents Scheduler::drain_inbox(ParticipantId id) {
    auto it = inboxes_.find(id);
    if (it == inboxes_.end()) return {};
    BookEvents out;
    out.swap(it->second);
    return out;
}

// One event about an order `owner` holds: book it, then tell them.
void Scheduler::notify_owner(ParticipantId owner, const BookEvent& event) {
    const auto slot = participants_.find(owner);
    if (slot != participants_.end()) {
        // The account is the exchange's record: it changes now. The owner
        // only hears about it after the inbound leg.
        slot->second.account.on_event(event, fees_);

        Entry entry;
        entry.time_ns     = now_ns_ + slot->second.latency.leg(exchange_).in_ns;
        entry.participant = owner;
        entry.kind        = EntryKind::DeliverEvent;
        entry.event       = event;
        push(std::move(entry));
    }

    const auto inbox = inboxes_.find(owner);
    if (inbox != inboxes_.end()) inbox->second.push_back(event);
}

void Scheduler::publish(ParticipantId actor, const BookEvents& events) {
    const bool actor_tracked = participants_.count(actor) != 0 || inboxes_.count(actor) != 0;

    for (const BookEvent& e : events) {
        switch (e.type) {
            case BookEventType::Trade:
                // Public print: every participant hears it, each after its own delay.
                for (const auto& [id, slot] : participants_) {
                    Entry entry;
                    entry.time_ns     = now_ns_ + slot.latency.leg(exchange_).in_ns;
                    entry.participant = id;
                    entry.kind        = EntryKind::DeliverEvent;
                    entry.event       = e;
                    push(std::move(entry));
                }
                break;

            case BookEventType::Accepted:
                // The actor now owns this order; remember that so fills and
                // cancels of it find their way back later.
                if (actor_tracked) {
                    order_owner_[e.order_id] = actor;
                    notify_owner(actor, e);
                }
                break;

            case BookEventType::Rejected:
                // Nothing entered the book, so only the requester cares.
                if (actor_tracked) notify_owner(actor, e);
                break;

            case BookEventType::PartialFill:
            case BookEventType::Reduced:
            case BookEventType::Filled:
            case BookEventType::Cancelled: {
                // Goes to whoever owns the order -- for a maker fill that is
                // not the actor.
                const auto owner = order_owner_.find(e.order_id);
                if (owner == order_owner_.end()) break;
                const ParticipantId owner_id = owner->second;
                // Filled / Cancelled end the order's life.
                if (e.type == BookEventType::Filled || e.type == BookEventType::Cancelled) {
                    order_owner_.erase(owner);
                }
                notify_owner(owner_id, e);
                break;
            }
        }
    }

    // Market data: after every action the exchange processes, each participant
    // gets the book as it stands now -- one snapshot, shared, delivered after
    // each one's own inbound delay. The actor is skipped: it learns the result
    // of its own action from the order events above, and echoing the book back
    // would make a strategy react to its own order.
    std::shared_ptr<const L2State> snapshot;
    for (const auto& [id, slot] : participants_) {
        if (id == actor) continue;
        if (!snapshot) {
            snapshot = std::make_shared<const L2State>(book_.get_l2_state(book_depth_));
        }
        Entry entry;
        entry.time_ns     = now_ns_ + slot.latency.leg(exchange_).in_ns;
        entry.participant = id;
        entry.kind        = EntryKind::DeliverBook;
        entry.book        = snapshot;
        push(std::move(entry));
    }
}
