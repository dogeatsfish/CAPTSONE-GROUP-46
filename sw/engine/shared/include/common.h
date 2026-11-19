#pragma once // This prevents the file from being included multiple times in the same compilation
#include <cstdint>
#include <vector>

struct Order {
    uint64_t order_id;
    double price;
    double size;
    char side;        // 'B' for Bid, 'S' for Ask
    bool is_synthetic;
};

struct Trade {
    uint64_t timestamp_ns;
    double price;
    double size;
    uint64_t maker_id;
    uint64_t taker_id;
};

struct L1State {
    double best_bid = 0.0;
    double best_ask = 0.0;
};

// One aggregated price level of the book (see OrderBook::get_l2_state).
struct L2Level {
    double   price = 0.0;
    double   size = 0.0;        // total resting size at this price
    uint32_t order_count = 0;   // number of orders making up that size
};

// Top-N depth per side, best price first.
struct L2State {
    std::vector<L2Level> bids;  // highest price first
    std::vector<L2Level> asks;  // lowest price first
};

// Where one resting order stands in line at its price (OrderBook::queue_position).
// Orders at a price fill strictly first-in-first-out, so shares_ahead is how
// much must trade (or cancel) at that price before this order is next.
struct QueuePosition {
    char     side = 0;
    double   price = 0.0;
    double   remaining = 0.0;     // this order's own open size
    double   shares_ahead = 0.0;  // total size queued in front of it at this price
    uint32_t orders_ahead = 0;    // number of orders making up that size
};

// Every resting order, in priority order (OrderBook::snapshot). Enough to
// rebuild the book exactly with OrderBook::restore -- so a run can be resumed
// from the snapshot's time instead of replayed from the start.
struct BookSnapshot {
    uint64_t timestamp_ns = 0;
    uint64_t next_event_seq = 0;  // seq the next BookEvent will get: every event
                                  // with a lower seq is already reflected here
    std::vector<Order> bids;      // best price first; oldest first within a price
    std::vector<Order> asks;
};

struct FillReport {
    double filled_size = 0.0;     // total volume that executed against the book
    double avg_fill_price = 0.0;  // volume-weighted average execution price
};


enum class BookEventType : uint8_t {
    Accepted,     // order passed validation and entered matching
    Trade,        // one match between a taker and a resting maker
    PartialFill,  // order_id executed `size`, and still has `remaining` open
    Filled,       // order_id executed `size`, and is now complete
    Reduced,      // order_id gave up `size`, keeps its queue spot, `remaining` still open
    Cancelled,    // order_id left the book with `size` unexecuted
    Rejected      // request refused; the book is unchanged (see `reason`)
};

enum class RejectReason : uint8_t {
    None,
    InvalidSide,     // side is not 'B' or 'S'
    InvalidSize,     // size is not a positive finite number
    InvalidPrice,    // price is not a positive finite number
    UnknownOrderId   // cancel for an order that is not resting in the book
};

struct BookEvent {
    uint64_t      seq = 0;           // per-book counter: total order of events
    uint64_t      timestamp_ns = 0;  // sim time of the call that caused it
    BookEventType type = BookEventType::Accepted;
    uint64_t      order_id = 0;      // the order this event is about (Trade: the taker)
    uint64_t      contra_order_id = 0; // other side of a match (Trade: the maker);
                                     // on a replace's Cancelled: the new order id; else 0
    char          side = 0;          // side of order_id; 0 if unknown (rejected cancel)
    char          liquidity = 0;     // fills only: 'T' taker (aggressor), 'M' maker (resting)
    double        price = 0.0;       // execution price for Trade/fills; limit price otherwise
    double        size = 0.0;        // executed size for Trade/fills; Accepted: order size;
                                     // Cancelled: size removed; Rejected: requested size
    double        remaining = 0.0;   // open size left on order_id after this event
    RejectReason  reason = RejectReason::None;
};

using BookEvents = std::vector<BookEvent>;

inline const char* to_string(BookEventType t) {
    switch (t) {
        case BookEventType::Accepted:    return "Accepted";
        case BookEventType::Trade:       return "Trade";
        case BookEventType::PartialFill: return "PartialFill";
        case BookEventType::Filled:      return "Filled";
        case BookEventType::Reduced:     return "Reduced";
        case BookEventType::Cancelled:   return "Cancelled";
        case BookEventType::Rejected:    return "Rejected";
    }
    return "?";
}

inline const char* to_string(RejectReason r) {
    switch (r) {
        case RejectReason::None:           return "None";
        case RejectReason::InvalidSide:    return "InvalidSide";
        case RejectReason::InvalidSize:    return "InvalidSize";
        case RejectReason::InvalidPrice:   return "InvalidPrice";
        case RejectReason::UnknownOrderId: return "UnknownOrderId";
    }
    return "?";
}

// Collapses the events of one process_add() call into the aggressor's total
// executed size and volume-weighted average price.
inline FillReport fill_report(const BookEvents& events) {
    FillReport report;
    double notional = 0.0; // sum of price * size across all matches
    for (const BookEvent& e : events) {
        if (e.type != BookEventType::Trade) continue;
        report.filled_size += e.size;
        notional += e.size * e.price;
    }
    if (report.filled_size > 0.0) {
        report.avg_fill_price = notional / report.filled_size;
    }
    return report;
}
