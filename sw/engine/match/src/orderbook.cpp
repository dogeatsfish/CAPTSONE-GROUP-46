#include "orderbook.h"
#include <algorithm> // Required for std::min

namespace {

// ---------------------------------------------------------
// Templated matching core, shared by both book sides.
//
// Walks the passive book from its best price level outward, filling the
// aggressive order against resting orders in strict price-then-time priority
// until it is exhausted or no more levels cross. Emptied orders and price
// levels are popped as we go, so the hot path never re-sorts.
// ---------------------------------------------------------
template <class Book>
FillReport match_impl(Order& aggressive_order,
                      Book& passive_book,
                      OrderBook::IdIndex& passive_index,
                      std::vector<Trade>& trade_log,
                      bool is_bid,
                      uint64_t timestamp_ns) {
    FillReport report;
    double notional = 0.0; // sum of price * size across all fills

    while (!passive_book.empty() && aggressive_order.size > 0) {
        auto level_it = passive_book.begin(); // best price level
        const double level_price = level_it->first;

        // Stop once the best remaining level no longer crosses.
        if (is_bid && aggressive_order.price < level_price) break;
        if (!is_bid && aggressive_order.price > level_price) break;

        auto& queue = level_it->second; // FIFO of resting orders at this price

        while (!queue.empty() && aggressive_order.size > 0) {
            Order& best_passive = queue.front();

            const double trade_size = std::min(aggressive_order.size, best_passive.size);
            aggressive_order.size -= trade_size;
            best_passive.size -= trade_size;

            trade_log.push_back(Trade{
                timestamp_ns,
                level_price,
                trade_size,
                best_passive.order_id,
                aggressive_order.order_id
            });

            report.filled_size += trade_size;
            notional += trade_size * level_price;

            if (best_passive.size == 0) {
                passive_index.erase(best_passive.order_id);
                queue.pop_front(); // time priority: oldest first
            }
        }

        if (queue.empty()) {
            passive_book.erase(level_it); // drop the emptied price level
        }
    }

    // Volume-weighted average execution price for this aggressive order.
    if (report.filled_size > 0.0) {
        report.avg_fill_price = notional / report.filled_size;
    }
    return report;
}

// Rest an order at its price level and register it in the id index.
template <class Book>
void rest_order(const Order& order, Book& book, OrderBook::IdIndex& index) {
    book[order.price].push_back(order);
    index[order.order_id] = order.price;
}

// Cancel order_id out of one side's book + index. Returns false (a no-op)
// if order_id isn't in this side's index at all -- the caller decides
// whether that means "unknown id" or "try the other side."
template <class Book>
bool cancel_from(uint64_t order_id, Book& book, OrderBook::IdIndex& index) {
    auto idx_it = index.find(order_id);
    if (idx_it == index.end()) return false;

    auto level_it = book.find(idx_it->second);
    if (level_it != book.end()) {
        auto& queue = level_it->second;
        for (auto it = queue.begin(); it != queue.end(); ++it) {
            if (it->order_id == order_id) {
                queue.erase(it);
                break;
            }
        }
        if (queue.empty()) book.erase(level_it);
    }
    index.erase(idx_it);
    return true;
}

} // namespace

// ---------------------------------------------------------
// Constructor
// ---------------------------------------------------------
OrderBook::OrderBook() {
    // Trades are the only append-heavy structure left on the hot path.
    trade_log.reserve(10000);
}

// ---------------------------------------------------------
// Public Methods
// ---------------------------------------------------------
FillReport OrderBook::process_add(Order& aggressive_order, uint64_t timestamp_ns) {
    FillReport report;
    if (aggressive_order.side == 'B') {
        report = match_impl(aggressive_order, asks, ask_index, trade_log, true, timestamp_ns);
        if (aggressive_order.size > 0) {
            rest_order(aggressive_order, bids, bid_index);
        }
    } else {
        report = match_impl(aggressive_order, bids, bid_index, trade_log, false, timestamp_ns);
        if (aggressive_order.size > 0) {
            rest_order(aggressive_order, asks, ask_index);
        }
    }
    return report;
}

void OrderBook::process_cancel(uint64_t order_id, char side) {
    if (side == 'B') {
        cancel_from(order_id, bids, bid_index);
    } else {
        cancel_from(order_id, asks, ask_index);
    }
}

void OrderBook::process_cancel(uint64_t order_id) {
    // Side unknown: try bids first, then asks. A no-op (both misses) just
    // means an unrecognized id, same as the side-known overload.
    if (!cancel_from(order_id, bids, bid_index)) {
        cancel_from(order_id, asks, ask_index);
    }
}

L1State OrderBook::get_l1_state() const {
    L1State state;
    if (!bids.empty()) state.best_bid = bids.begin()->first; // highest bid
    if (!asks.empty()) state.best_ask = asks.begin()->first; // lowest ask
    return state;
}
