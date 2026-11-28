// Participant: thin forwarding to its scheduler.
//
// These bodies live here rather than in participant.h because they need the
// complete Scheduler type, and scheduler.h only forward-declares Participant
// -- the engine does not depend on its clients. Every one of them is a plain
// forward to a PUBLIC Scheduler member, so none needs friendship; only
// Scheduler::add_participant does, to set scheduler_ and id_.

#include "participant.h"
#include "scheduler.h"

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
