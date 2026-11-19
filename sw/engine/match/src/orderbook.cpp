#include "orderbook.h"
#include <algorithm> // Required for std::min
#include <cmath>     // std::isfinite
#include <limits>

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

// Pointer to a resting order on this side, or nullptr.
template <class Book>
Order* find_resting(uint64_t order_id, Book& book, OrderBook::IdIndex& index) {
    auto idx_it = index.find(order_id);
    if (idx_it == index.end()) return nullptr;
    auto level_it = book.find(idx_it->second);
    if (level_it == book.end()) return nullptr;
    for (Order& o : level_it->second) {
        if (o.order_id == order_id) return &o;
    }
    return nullptr;
}

template <class Book>
void collect_levels(const Book& book, size_t n_levels, std::vector<L2Level>& out) {
    out.reserve(std::min(n_levels, book.size()));
    for (auto it = book.begin(); it != book.end() && out.size() < n_levels; ++it) {
        L2Level level;
        level.price = it->first;
        for (const Order& o : it->second) {
            level.size += o.size;
            ++level.order_count;
        }
        out.push_back(level);
    }
}

template <class Book>
std::optional<QueuePosition> position_in(uint64_t order_id, const Book& book,
                                         const OrderBook::IdIndex& index) {
    const auto idx_it = index.find(order_id);
    if (idx_it == index.end()) return std::nullopt;
    const auto level_it = book.find(idx_it->second);
    if (level_it == book.end()) return std::nullopt;

    QueuePosition pos;
    for (const Order& o : level_it->second) { // front of the queue first
        if (o.order_id == order_id) {
            pos.side      = o.side;
            pos.price     = o.price;
            pos.remaining = o.size;
            return pos;
        }
        pos.shares_ahead += o.size;
        ++pos.orders_ahead;
    }
    return std::nullopt;
}

template <class Book>
void copy_orders(const Book& book, std::vector<Order>& out) {
    for (const auto& level : book) {          // best price first
        for (const Order& o : level.second) { // oldest first
            out.push_back(o);
        }
    }
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

    add_validated(aggressive_order, timestamp_ns, events);
    return events;
}

BookEvents OrderBook::process_market(Order& order, uint64_t timestamp_ns) {
    BookEvents events;

    // A price that crosses every level: the highest possible for a buy, the
    // lowest positive one for a sell.
    order.price = (order.side == 'B') ? std::numeric_limits<double>::max()
                                      : std::numeric_limits<double>::min();
    const RejectReason reason = validate(order);
    if (reason != RejectReason::None) {
        BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Rejected,
                            order.order_id, order.side);
        e.size   = order.size;
        e.reason = reason;
        return events;
    }

    add_validated(order, timestamp_ns, events, false);
    events.front().price = 0.0; // Accepted: a market order has no limit price
    return events;
}

void OrderBook::add_validated(Order& order, uint64_t timestamp_ns, BookEvents& events,
                              bool rest_remainder) {
    BookEvent& accepted = emit(events, next_event_seq, timestamp_ns, BookEventType::Accepted,
                               order.order_id, order.side);
    accepted.price     = order.price;
    accepted.size      = order.size;
    accepted.remaining = order.size;

    if (order.side == 'B') {
        match_impl(order, asks, ask_index, trade_log, events, next_event_seq, true, timestamp_ns);
        if (order.size > 0 && rest_remainder) {
            rest_order(order, bids, bid_index);
        }
    } else {
        match_impl(order, bids, bid_index, trade_log, events, next_event_seq, false, timestamp_ns);
        if (order.size > 0 && rest_remainder) {
            rest_order(order, asks, ask_index);
        }
    }

    if (order.size > 0 && !rest_remainder) {
        // Ran out of liquidity: the rest of the order is dropped, not rested.
        BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Cancelled,
                            order.order_id, order.side);
        e.size = order.size;
    }
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

BookEvents OrderBook::process_reduce(uint64_t order_id, double qty, uint64_t timestamp_ns,
                                     char side) {
    BookEvents events;

    if (!std::isfinite(qty) || qty <= 0.0) {
        BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Rejected,
                            order_id, side);
        e.size   = qty;
        e.reason = RejectReason::InvalidSize;
        return events;
    }

    Order* resting = nullptr;
    if (side != 'S') resting = find_resting(order_id, bids, bid_index);
    if (resting == nullptr && side != 'B') resting = find_resting(order_id, asks, ask_index);

    if (resting == nullptr) {
        BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Rejected,
                            order_id, side);
        e.size   = qty;
        e.reason = RejectReason::UnknownOrderId;
        return events;
    }

    // Nothing would be left: this is a full cancel.
    if (qty >= resting->size) {
        return process_cancel(order_id, timestamp_ns, resting->side);
    }

    // Shrink in place -- the order is not moved, so it keeps its queue position.
    resting->size -= qty;
    BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Reduced,
                        order_id, resting->side);
    e.price     = resting->price;
    e.size      = qty;
    e.remaining = resting->size;
    return events;
}

BookEvents OrderBook::process_replace(uint64_t old_order_id, Order& new_order,
                                      uint64_t timestamp_ns) {
    BookEvents events;

    const Order* old_order = find_resting(old_order_id, bids, bid_index);
    if (old_order == nullptr) old_order = find_resting(old_order_id, asks, ask_index);

    if (old_order == nullptr) {
        BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Rejected,
                            old_order_id, 0);
        e.reason = RejectReason::UnknownOrderId;
        return events;
    }

    // A replace cannot change side; validate the new order before touching
    // the old one so a bad replace leaves the original resting.
    new_order.side = old_order->side;
    const RejectReason reason = validate(new_order);
    if (reason != RejectReason::None) {
        BookEvent& e = emit(events, next_event_seq, timestamp_ns, BookEventType::Rejected,
                            new_order.order_id, new_order.side);
        e.contra_order_id = old_order_id;
        e.price  = new_order.price;
        e.size   = new_order.size;
        e.reason = reason;
        return events;
    }

    events = process_cancel(old_order_id, timestamp_ns, new_order.side);
    events.back().contra_order_id = new_order.order_id; // links old -> new

    // Entered as a brand-new order: back of the queue, free to match.
    add_validated(new_order, timestamp_ns, events);
    return events;
}

L1State OrderBook::get_l1_state() const {
    L1State state;
    if (!bids.empty()) state.best_bid = bids.begin()->first; // highest bid
    if (!asks.empty()) state.best_ask = asks.begin()->first; // lowest ask
    return state;
}

L2State OrderBook::get_l2_state(size_t n_levels) const {
    L2State state;
    collect_levels(bids, n_levels, state.bids);
    collect_levels(asks, n_levels, state.asks);
    return state;
}

std::optional<QueuePosition> OrderBook::queue_position(uint64_t order_id) const {
    std::optional<QueuePosition> pos = position_in(order_id, bids, bid_index);
    if (!pos) pos = position_in(order_id, asks, ask_index);
    return pos;
}

BookSnapshot OrderBook::snapshot(uint64_t timestamp_ns) const {
    BookSnapshot snap;
    snap.timestamp_ns   = timestamp_ns;
    snap.next_event_seq = next_event_seq;
    copy_orders(bids, snap.bids);
    copy_orders(asks, snap.asks);
    return snap;
}

void OrderBook::restore(const BookSnapshot& snapshot) {
    bids.clear();
    asks.clear();
    bid_index.clear();
    ask_index.clear();
    // Re-resting in snapshot order rebuilds every queue in its original order.
    for (const Order& o : snapshot.bids) rest_order(o, bids, bid_index);
    for (const Order& o : snapshot.asks) rest_order(o, asks, ask_index);
    next_event_seq = snapshot.next_event_seq;
}
