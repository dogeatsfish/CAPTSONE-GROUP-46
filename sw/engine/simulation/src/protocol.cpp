#include "protocol.h"

#include <cmath>   // std::llround
#include <cstring> // std::memcpy

namespace protocol {
namespace {

// ---------------------------------------------------------
// Portable big-endian (network byte order) serialisation helpers.
// Implemented with explicit shifts so they behave identically on
// little- and big-endian hosts without relying on platform headers.
// These mirror the RTL, which shifts multi-byte fields in MSB-first.
// ---------------------------------------------------------
void put_u16(std::vector<uint8_t>& out, uint16_t v) {
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(v & 0xFF));
}

void put_u32(std::vector<uint8_t>& out, uint32_t v) {
    for (int shift = 24; shift >= 0; shift -= 8) {
        out.push_back(static_cast<uint8_t>((v >> shift) & 0xFF));
    }
}

// 48-bit big-endian field (ITCH timestamp is 6 bytes).
void put_u48(std::vector<uint8_t>& out, uint64_t v) {
    for (int shift = 40; shift >= 0; shift -= 8) {
        out.push_back(static_cast<uint8_t>((v >> shift) & 0xFF));
    }
}

void put_u64(std::vector<uint8_t>& out, uint64_t v) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        out.push_back(static_cast<uint8_t>((v >> shift) & 0xFF));
    }
}

// IEEE-754 double transported as its raw big-endian bit pattern. Used only by
// the software-internal OUCH response frames.
void put_double(std::vector<uint8_t>& out, double v) {
    uint64_t bits;
    std::memcpy(&bits, &v, sizeof(bits));
    put_u64(out, bits);
}

// Fixed-point wire price: double -> 32-bit integer with PRICE_SCALE implied
// decimals (matches the parser's 32-bit price bus).
uint32_t price_to_wire(double price) {
    return static_cast<uint32_t>(std::llround(price * PRICE_SCALE));
}

uint32_t qty_to_wire(double size) {
    return static_cast<uint32_t>(std::llround(size));
}

uint32_t get_u32(const uint8_t* p) {
    uint32_t v = 0;
    for (int i = 0; i < 4; ++i) v = (v << 8) | p[i];
    return v;
}

uint64_t get_u64(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | p[i];
    return v;
}

double get_double(const uint8_t* p) {
    const uint64_t bits = get_u64(p);
    double v;
    std::memcpy(&v, &bits, sizeof(v));
    return v;
}

// OUCH's ticker field is fixed-width, space-padded ASCII (matches
// alpha_engine_core's ticker_of()); trim the padding for display rather than
// carrying "AAPL    " around everywhere a decoded message is shown.
std::string trim_ticker(const uint8_t* p, size_t len) {
    size_t end = len;
    while (end > 0 && (p[end - 1] == ' ' || p[end - 1] == '\0')) --end;
    return std::string(reinterpret_cast<const char*>(p), end);
}

} // namespace

// ---------------------------------------------------------
// ITCH encoding
//
// Byte layout matches cut_through_parser.sv exactly. The parser ignores the
// Tracking Number and the 8-byte Stock ASCII field (symbol is taken from the
// low byte of Stock Locate), so those are emitted as zero / spaces.
// ---------------------------------------------------------
std::vector<uint8_t> to_itch(const MBORecord& rec, uint16_t stock_locate) {
    std::vector<uint8_t> packet;

    if (rec.message_type == MBO_ADD) {
        packet.reserve(ITCH_ADD_LEN);
        packet.push_back(static_cast<uint8_t>(ITCH_ADD));   // [0]  type 'A'
        put_u16(packet, stock_locate);                      // [1-2]  locate
        put_u16(packet, 0);                                 // [3-4]  tracking
        put_u48(packet, rec.timestamp_ns & 0xFFFFFFFFFFFFULL); // [5-10] time(6)
        put_u64(packet, rec.order_id);                      // [11-18] ref
        packet.push_back(static_cast<uint8_t>(rec.side));   // [19]   side
        put_u32(packet, qty_to_wire(rec.size));             // [20-23] shares
        for (int i = 0; i < 8; ++i) packet.push_back(' ');  // [24-31] stock
        put_u32(packet, price_to_wire(rec.price));          // [32-35] price
    } else if (rec.message_type == MBO_CANCEL) {
        packet.reserve(ITCH_CANCEL_LEN);
        packet.push_back(static_cast<uint8_t>(ITCH_CANCEL)); // [0]  type 'X'
        put_u16(packet, stock_locate);                       // [1-2]  locate
        put_u16(packet, 0);                                  // [3-4]  tracking
        put_u48(packet, rec.timestamp_ns & 0xFFFFFFFFFFFFULL); // [5-10] time(6)
        put_u64(packet, rec.order_id);                       // [11-18] ref
        put_u32(packet, qty_to_wire(rec.size));              // [19-22] shares
    }
    // Unknown message types fall through and return an empty buffer.

    return packet;
}

// ---------------------------------------------------------
// MoldUDP64 framing
//
// Layout (matches the encapsulation stripped by cut_through_parser.sv):
//   Session(10) | SequenceNumber(8, BE) | MessageCount(2, BE)
//   then, MessageCount times: MsgLen(2, BE) | ITCH message bytes
// ---------------------------------------------------------
std::vector<uint8_t> to_moldudp64(
    const std::vector<std::vector<uint8_t>>& messages,
    uint64_t seq_num,
    const std::string& session) {

    std::vector<uint8_t> packet;

    // Session: 10 ASCII bytes, left-justified and zero-padded (truncated if the
    // caller supplies more than MOLD_SESSION_LEN characters).
    for (size_t i = 0; i < MOLD_SESSION_LEN; ++i) {
        packet.push_back(i < session.size()
                             ? static_cast<uint8_t>(session[i])
                             : 0x00);
    }

    put_u64(packet, seq_num); // sequence number of the first message

    // Count only non-empty messages (an empty buffer means "unknown type").
    uint16_t count = 0;
    for (const auto& m : messages) if (!m.empty()) ++count;
    put_u16(packet, count);

    for (const auto& m : messages) {
        if (m.empty()) continue;
        put_u16(packet, static_cast<uint16_t>(m.size())); // MoldUDP64 MsgLen
        packet.insert(packet.end(), m.begin(), m.end());
    }

    return packet;
}

// ---------------------------------------------------------
// OUCH encoding (client -> server)
//
// Byte layout matches outbound_tx_generator.sv. UserRefNum is 32-bit, so only
// the low 32 bits of order_id ride the wire; quantities are 32-bit integers
// and prices are 64-bit fixed-point (4 implied decimals, upper bytes zero).
// ---------------------------------------------------------
std::vector<uint8_t> to_ouch_enter(uint64_t order_id, char side,
                                   double price, double size) {
    std::vector<uint8_t> packet;
    packet.reserve(OUCH_ENTER_LEN);
    packet.push_back(static_cast<uint8_t>(OUCH_ENTER));          // [0]  'O'
    put_u32(packet, static_cast<uint32_t>(order_id));           // [1-4]  userref
    packet.push_back(static_cast<uint8_t>(side));               // [5]   side
    put_u32(packet, qty_to_wire(size));                         // [6-9]  qty
    for (int i = 0; i < 8; ++i) packet.push_back(' ');          // [10-17] symbol
    put_u64(packet, static_cast<uint64_t>(price_to_wire(price)));// [18-25] price
    packet.push_back(0);                                        // [26]  TIF
    packet.push_back(0);                                        // [27]  Display
    packet.push_back(0);                                        // [28]  Capacity
    packet.push_back(0);                                        // [29]  ISO
    packet.push_back(0);                                        // [30]  CrossType
    for (int i = 0; i < 14; ++i) packet.push_back(' ');         // [31-44] ClOrdID
    put_u16(packet, 0);                                         // [45-46] AppLen
    return packet;
}

std::vector<uint8_t> to_ouch_cancel(uint64_t order_id, double size) {
    std::vector<uint8_t> packet;
    packet.reserve(OUCH_CANCEL_LEN);
    packet.push_back(static_cast<uint8_t>(OUCH_CANCEL)); // [0]  'X'
    put_u32(packet, static_cast<uint32_t>(order_id));    // [1-4]  userref
    put_u32(packet, qty_to_wire(size));                  // [5-8]  qty
    put_u16(packet, 0);                                  // [9-10] AppLen
    return packet;
}

// ---------------------------------------------------------
// OUCH decoding
// ---------------------------------------------------------
size_t ouch_frame_len(uint8_t msg_type) {
    switch (static_cast<char>(msg_type)) {
        case OUCH_ENTER:  return OUCH_ENTER_LEN;
        case OUCH_CANCEL: return OUCH_CANCEL_LEN;
        default:          return 0;
    }
}

bool from_ouch(const uint8_t* buf, size_t len, OuchMessage& out) {
    if (buf == nullptr || len == 0) return false;

    const char type = static_cast<char>(buf[0]);
    if (len != ouch_frame_len(buf[0])) return false; // wrong/unknown framing

    if (type == OUCH_ENTER) {
        out.msg_type = OUCH_ENTER;
        out.order_id = get_u32(buf + 1);                       // userref
        out.side     = static_cast<char>(buf[5]);              // side
        out.size     = static_cast<double>(get_u32(buf + 6));  // qty
        // symbol at [10..17] -- not used for matching (the engine is keyed
        // by order id), but decoded for display/telemetry.
        out.ticker   = trim_ticker(buf + 10, 8);
        out.price    = static_cast<double>(get_u64(buf + 18)) / PRICE_SCALE;
        return true;
    }
    if (type == OUCH_CANCEL) {
        out.msg_type = OUCH_CANCEL;
        out.order_id = get_u32(buf + 1);                       // userref
        out.size     = static_cast<double>(get_u32(buf + 5));  // cancel qty
        // The OUCH Cancel wire format carries no side or symbol (see tx_gen);
        // the matching engine must resolve the resting side from the order id.
        out.side     = 0;
        out.ticker.clear();
        out.price    = 0.0;
        return true;
    }

    return false;
}

Order ouch_to_order(const OuchMessage& msg) {
    Order order;
    order.order_id     = msg.order_id;
    order.price        = msg.price;
    order.size         = msg.size;
    order.side         = msg.side;
    order.is_synthetic = true; // arrived from a connected OUCH client
    return order;
}

// ---------------------------------------------------------
// OUCH responses (server -> client)
//
// Software-internal ack framing; not consumed by the FPGA in the current
// scope, so this layout is independent of the RTL.
// ---------------------------------------------------------
std::vector<uint8_t> to_ouch_response(char type, uint64_t order_id,
                                      double size, double price) {
    std::vector<uint8_t> packet;
    packet.reserve(OUCH_RESPONSE_LEN);
    packet.push_back(static_cast<uint8_t>(type));
    put_u64(packet, order_id);
    put_double(packet, size);
    put_double(packet, price);
    return packet;
}

bool from_ouch_response(const uint8_t* buf, size_t len, OuchResponse& out) {
    if (buf == nullptr || len != OUCH_RESPONSE_LEN) return false;
    const char type = static_cast<char>(buf[0]);
    if (type != OUCH_EXECUTED && type != OUCH_ACCEPTED) return false;

    out.type     = type;
    out.order_id = get_u64(buf + 1);
    out.size     = get_double(buf + 9);
    out.price    = get_double(buf + 17);
    return true;
}

} // namespace protocol
