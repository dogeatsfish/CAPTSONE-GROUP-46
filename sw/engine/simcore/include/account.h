#pragma once

#include <cstdint>
#include <map>
#include <vector>

#include "common.h"

// One participant's books and records. The Scheduler keeps one per registered
// participant and feeds it every event about that participant's orders, so
// bots and the player are all scored by exactly the same arithmetic.
//
// Single-symbol for now: one position. (Multi-symbol arrives with ticket #21.)

// What an exchange charges per share traded.
struct FeeSchedule {
    double taker_fee    = 0.0; // paid by the order that removed liquidity
    double maker_rebate = 0.0; // paid TO the resting order that provided it
};

struct OpenOrder {
    char   side = 0;
    double price = 0.0;
    double remaining = 0.0;
};

struct FillRecord {
    uint64_t timestamp_ns = 0;
    uint64_t order_id = 0;
    char     side = 0;       // 'B' bought / 'S' sold
    char     liquidity = 0;  // 'T' taker / 'M' maker
    double   price = 0.0;
    double   size = 0.0;
    double   fee = 0.0;      // > 0 fee paid, < 0 rebate received
};

class Account {
public:
    explicit Account(double starting_cash = 0.0);

    // Applies one lifecycle event about one of this account's orders.
    void on_event(const BookEvent& event, const FeeSchedule& fees);

    // Books an execution directly (on_event calls this for fills; also used
    // where there is no event stream, e.g. the online simulation).
    void apply_fill(uint64_t timestamp_ns, uint64_t order_id, char side, char liquidity,
                    double price, double size, const FeeSchedule& fees);

    void note_order_sent()  { ++orders_sent_; }
    void note_cancel_sent() { ++cancels_sent_; }

    // --- Position and PnL ---
    double position() const { return position_; }            // signed: + long, - short
    double avg_entry_price() const { return avg_entry_price_; }
    double cash() const { return cash_; }
    double realized_pnl() const { return realized_pnl_; }    // gross: before fees
    double unrealized_pnl(double mark_price) const;          // open position at the mark
    double fees_paid() const { return fees_paid_; }          // net of rebates; < 0 = earned
    double net_pnl(double mark_price) const {                // what scoring uses
        return realized_pnl_ + unrealized_pnl(mark_price) - fees_paid_;
    }

    // --- Activity ---
    // Ordered by id so iterating it is deterministic.
    const std::map<uint64_t, OpenOrder>& open_orders() const { return open_orders_; }
    const std::vector<FillRecord>& fills() const { return fills_; }
    uint64_t orders_sent() const { return orders_sent_; }
    uint64_t cancels_sent() const { return cancels_sent_; }
    uint64_t rejects() const { return rejects_; }
    double   volume() const { return volume_; }              // total shares traded

private:
    double position_ = 0.0;
    double avg_entry_price_ = 0.0; // weighted-average cost of the open position
    double realized_pnl_ = 0.0;
    double fees_paid_ = 0.0;
    double cash_ = 0.0;
    double volume_ = 0.0;

    uint64_t orders_sent_ = 0;
    uint64_t cancels_sent_ = 0;
    uint64_t rejects_ = 0;

    std::map<uint64_t, OpenOrder> open_orders_;
    std::vector<FillRecord> fills_;
};
