#include "orderbook.h"
#include <algorithm> // Required for std::min
#include <cmath>     // std::isfinite

namespace {

// Appends one event, stamping it with the book's next sequence number.
BookEvent& emit(BookEvents& events, uint64_t& next_seq, uint64_t timestamp_ns,
                BookEventType type, uint64_t order_id, char side) {
    BookEvent e;
    e.seq          = next_seq++;
    e.timestamp_ns = timestamp_ns;
    e.type         = type;
    e.order_id     = order_id;
    e.side         = side;
    events.push_back(e);
    return events.back();
}

template <class Book>
void match_impl(Order& aggressive_order,
                Book& passive_book,
                OrderBook::IdIndex& passive_index,
                std::vector<Trade>& trade_log,
                BookEvents& events,
                uint64_t& next_seq,
                bool is_bid,
                uint64_t timestamp_ns) {
    const char taker_side = aggressive_order.side;
    const char maker_side = is_bid ? 'S' : 'B';

    while (!passive_book.empty() && aggressive_order.size > 0) {
        auto level_it = passive_book.begin(); // best price level
        const double level_price = level_it->first;

        // Stop once the best remaining level no longer crosses.
        if (is_bid && aggressive_order.price < level_price) break;
        if (!is_bid && aggressive_order.price > level_price) break;

        auto& queue = level_it->second; // FIFO of resting orders at this price

        while (!queue.empty() && aggressive_order.size > 0) {
            Order& best_passive = queue.front();
            const uint64_t maker_id = best_passive.order_id;

            const double trade_size = std::min(aggressive_order.size, best_passive.size);
            aggressive_order.size -= trade_size;
            best_passive.size -= trade_size;

            trade_log.push_back(Trade{
                timestamp_ns,
                level_price,
                trade_size,
                maker_id,
                aggressive_order.order_id
            });

            // Public print of the match.
            BookEvent& trade = emit(events, next_seq, timestamp_ns, BookEventType::Trade,
                                    aggressive_order.order_id, taker_side);
            trade.contra_order_id = maker_id;
            trade.price           = level_price;
            trade.size            = trade_size;
            trade.remaining       = aggressive_order.size;

            // Private view for the taker...
            BookEvent& taker = emit(events, next_seq, timestamp_ns,
                                    aggressive_order.size > 0 ? BookEventType::PartialFill
                                                              : BookEventType::Filled,
                                    aggressive_order.order_id, taker_side);
            taker.contra_order_id = maker_id;
            taker.liquidity       = 'T';
            taker.price           = level_price;
            taker.size            = trade_size;
            taker.remaining       = aggressive_order.size;

            // ...and for the resting maker, which otherwise never hears it traded.
            BookEvent& maker = emit(events, next_seq, timestamp_ns,
                                    best_passive.size > 0 ? BookEventType::PartialFill
                                                          : BookEventType::Filled,
                                    maker_id, maker_side);
            maker.contra_order_id = aggressive_order.order_id;
            maker.liquidity       = 'M';
            maker.price           = level_price;
            maker.size            = trade_size;
            maker.remaining       = best_passive.size;

            if (best_passive.size == 0) {
                passive_index.erase(maker_id);
                queue.pop_front(); // time priority: oldest first
            }
        }

        if (queue.empty()) {
            passive_book.erase(level_it); // drop the emptied price level
        }
    }
}

template <class Book>
void rest_order(const Order& order, Book& book, OrderBook::IdIndex& index) {
    book[order.price].push_back(order);
    index[order.order_id] = order.price;
}

// Removes order_id from this side. Returns true and fills `removed` with the
// order as it rested (its remaining size) if it was found.
template <class Book>
bool cancel_from(uint64_t order_id, Book& book, OrderBook::IdIndex& index, Order& removed) {
    auto idx_it = index.find(order_id);
    if (idx_it == index.end()) return false;

    removed = Order{order_id, idx_it->second, 0.0, 0, false};
    auto level_it = book.find(idx_it->second);
    if (level_it != book.end()) {
        auto& queue = level_it->second;
        for (auto it = queue.begin(); it != queue.end(); ++it) {
            if (it->order_id == order_id) {
                removed = *it;
                queue.erase(it);
                break;
            }
        }
        if (queue.empty()) book.erase(level_it);
    }
    index.erase(idx_it);
    return true;
}

RejectReason validate(const Order& order) {
    if (order.side != 'B' && order.side != 'S') return RejectReason::InvalidSide;
    if (!std::isfinite(order.size) || order.size <= 0.0) return RejectReason::InvalidSize;
    if (!std::isfinite(order.price) || order.price <= 0.0) return RejectReason::InvalidPrice;
    return RejectReason::None;
}
}

OrderBook::OrderBook() {
    trade_log.reserve(10000);
}

// ---------------------------------------------------------
// Public Methods
// ---------------------------------------------------------
BookEvents OrderBook::process_add(Order& aggressive_order, uint64_t timestamp_ns) {
    BookEvents events;

    const RejectReason reason = validate(aggressive_order);
    if (reason != RejectReason::None) {
        BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Rejected,
                            aggressive_order.order_id, aggressive_order.side);
        e.price  = aggressive_order.price;
        e.size   = aggressive_order.size;
        e.reason = reason;
        return events;
    }

    BookEvent& accepted = emit(events, next_event_seq, timestamp_ns, BookEventType::Accepted,
                               aggressive_order.order_id, aggressive_order.side);
    accepted.price     = aggressive_order.price;
    accepted.size      = aggressive_order.size;
    accepted.remaining = aggressive_order.size;

    if (aggressive_order.side == 'B') {
        match_impl(aggressive_order, asks, ask_index, trade_log, events, next_event_seq,
                   true, timestamp_ns);
        if (aggressive_order.size > 0) {
            rest_order(aggressive_order, bids, bid_index);
        }
    } else {
        match_impl(aggressive_order, bids, bid_index, trade_log, events, next_event_seq,
                   false, timestamp_ns);
        if (aggressive_order.size > 0) {
            rest_order(aggressive_order, asks, ask_index);
        }
    }
    return events;
}

BookEvents OrderBook::process_cancel(uint64_t order_id, uint64_t timestamp_ns, char side) {
    BookEvents events;
    Order removed{};
    bool found = false;

    if (side == 'B') {
        found = cancel_from(order_id, bids, bid_index, removed);
    } else if (side == 'S') {
        found = cancel_from(order_id, asks, ask_index, removed);
    } else {
        // Side unknown: an id rests on at most one side, so try both.
        found = cancel_from(order_id, bids, bid_index, removed) ||
                cancel_from(order_id, asks, ask_index, removed);
    }

    if (!found) {
        BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Rejected,
                            order_id, side);
        e.reason = RejectReason::UnknownOrderId;
        return events;
    }

    BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Cancelled,
                        order_id, removed.side);
    e.price = removed.price;
    e.size  = removed.size; // unexecuted size taken out of the book
    return events;
}

L1State OrderBook::get_l1_state() const {
    L1State state;
    if (!bids.empty()) state.best_bid = bids.begin()->first; // highest bid
    if (!asks.empty()) state.best_ask = asks.begin()->first; // lowest ask
    return state;
}
