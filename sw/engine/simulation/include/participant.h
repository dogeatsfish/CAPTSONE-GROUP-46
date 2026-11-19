#pragma once

#include <cstdint>
#include <optional>

#include "account.h"
#include "common.h"

class Scheduler;
using ParticipantId = uint32_t;

// Anything that trades in the simulation: built-in bots and the player's
// strategy alike. Subclass it, override the callbacks you care about, and act
// by calling the send_* / cancel helpers from inside them.
//
// Register an instance with Scheduler::add_participant(). Everything it hears
// arrives L_in late and everything it sends lands compute + L_out later (see
// latency.h), so two participants running identical code get different
// results purely from where they sit.
class Participant {
public:
    virtual ~Participant() = default;

    // --- What the exchange tells you (override what you need) ---

    // The book changed because of someone else's action. Top levels per side.
    virtual void on_book_update(const L2State&) {}
    // Public print: some trade happened (yours included).
    virtual void on_trade(const BookEvent&) {}
    // One of YOUR orders executed (PartialFill / Filled). event.liquidity says
    // whether you were the taker or the resting maker.
    virtual void on_fill(const BookEvent&) {}
    // Any other news about your orders: Accepted, Rejected, Reduced, Cancelled.
    virtual void on_order_update(const BookEvent&) {}
    // A timer you set with set_timer() went off.
    virtual void on_timer(uint64_t /*now_ns*/) {}

    ParticipantId id() const { return id_; }

protected:
    // --- What you can tell the exchange ---
    // Each returns immediately; the request reaches the book after your
    // outbound latency. Order ids are assigned for you and returned (0 if
    // this participant is not registered with a scheduler).

    uint64_t send_limit(char side, double price, double size);
    // Trades against whatever is resting; any unfilled remainder is cancelled.
    uint64_t send_market(char side, double size);
    void     cancel(uint64_t order_id);
    void     reduce(uint64_t order_id, double qty);                    // keeps queue position
    uint64_t replace(uint64_t order_id, double price, double size);    // loses it; returns new id
    void     set_timer(uint64_t delay_ns);                             // -> on_timer()

    uint64_t now() const; // current simulated time

    // Where one of your resting orders stands in line at its price; empty if
    // it is not resting. Like account(), this is the exchange's live view.
    std::optional<QueuePosition> queue_position(uint64_t order_id) const;

    // Your position, cash, PnL, open orders and fill history. This is the
    // exchange's record, updated the instant a fill happens -- your on_fill
    // callback for the same fill still arrives L_in later.
    const Account& account() const;

private:
    friend class Scheduler;
    Scheduler*    scheduler_ = nullptr; // set by Scheduler::add_participant
    ParticipantId id_ = 0;
};
