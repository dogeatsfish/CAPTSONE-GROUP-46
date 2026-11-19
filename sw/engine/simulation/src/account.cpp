#include "account.h"

#include <cmath>

Account::Account(double starting_cash) : cash_(starting_cash) {}

void Account::on_event(const BookEvent& event, const FeeSchedule& fees) {
    switch (event.type) {
        case BookEventType::Accepted:
            open_orders_[event.order_id] = OpenOrder{event.side, event.price, event.remaining};
            break;

        case BookEventType::PartialFill:
        case BookEventType::Filled: {
            apply_fill(event.timestamp_ns, event.order_id, event.side, event.liquidity,
                       event.price, event.size, fees);
            auto it = open_orders_.find(event.order_id);
            if (it != open_orders_.end()) {
                if (event.type == BookEventType::Filled) {
                    open_orders_.erase(it);
                } else {
                    it->second.remaining = event.remaining;
                }
            }
            break;
        }

        case BookEventType::Reduced: {
            auto it = open_orders_.find(event.order_id);
            if (it != open_orders_.end()) it->second.remaining = event.remaining;
            break;
        }

        case BookEventType::Cancelled:
            open_orders_.erase(event.order_id);
            break;

        case BookEventType::Rejected:
            ++rejects_;
            break;

        case BookEventType::Trade:
            break; // public print; the fill events carry this account's side of it
    }
}

void Account::apply_fill(uint64_t timestamp_ns, uint64_t order_id, char side, char liquidity,
                         double price, double size, const FeeSchedule& fees) {
    const double qty = (side == 'B') ? size : -size; // signed incoming quantity

    const bool opposite = position_ != 0.0 && ((position_ > 0.0) != (qty > 0.0));

    if (opposite) {
        // Trading against the open position: the part that closes it realizes PnL.
        const double closing = std::fmin(size, std::fabs(position_));
        const double dir     = (position_ > 0.0) ? 1.0 : -1.0;
        realized_pnl_ += dir * (price - avg_entry_price_) * closing;

        const double remaining = std::fabs(position_) - closing; // left in old direction
        const double leftover  = size - closing;                 // portion that flips

        if (remaining > 0.0) {
            position_ = dir * remaining;
        } else if (leftover > 0.0) {
            position_        = (qty > 0.0 ? 1.0 : -1.0) * leftover;
            avg_entry_price_ = price;
        } else {
            position_        = 0.0;
            avg_entry_price_ = 0.0;
        }
    } else {
        // Adding to the position: blend the entry price.
        const double new_pos = position_ + qty;
        avg_entry_price_ =
            (std::fabs(position_) * avg_entry_price_ + size * price) / std::fabs(new_pos);
        position_ = new_pos;
    }

    // Takers pay the fee; makers are paid the rebate (a negative fee).
    const double fee = (liquidity == 'M') ? -fees.maker_rebate * size : fees.taker_fee * size;
    fees_paid_ += fee;
    cash_      -= qty * price + fee; // buying spends cash, selling brings it in
    volume_    += size;

    fills_.push_back(FillRecord{timestamp_ns, order_id, side, liquidity, price, size, fee});
}

double Account::unrealized_pnl(double mark_price) const {
    if (position_ == 0.0 || mark_price == 0.0) {
        return 0.0;
    }
    return position_ * (mark_price - avg_entry_price_);
}
