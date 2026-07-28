#include "protocol.h"

#include <cstring> // std::memcpy

namespace protocol {
namespace {

// ---------------------------------------------------------
// Portable big-endian (network byte order) serialisation helpers.
// Implemented with explicit shifts so they behave identically on
// little- and big-endian hosts without relying on platform headers.
// ---------------------------------------------------------
void put_u64(std::vector<uint8_t>& out, uint64_t v) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        out.push_back(static_cast<uint8_t>((v >> shift) & 0xFF));
    }
}

void put_double(std::vector<uint8_t>& out, double v) {
    uint64_t bits;
    std::memcpy(&bits, &v, sizeof(bits)); // reinterpret IEEE-754 payload
    put_u64(out, bits);
}

uint64_t get_u64(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) {
        v = (v << 8) | p[i];
    }
    return v;
}

double get_double(const uint8_t* p) {
    const uint64_t bits = get_u64(p);
    double v;
    std::memcpy(&v, &bits, sizeof(v));
    return v;
}

} // namespace

// ---------------------------------------------------------
// ITCH encoding
// ---------------------------------------------------------
std::vector<uint8_t> to_itch(const MBORecord& rec) {
    std::vector<uint8_t> packet;

    if (rec.message_type == ITCH_ADD) {
        packet.reserve(ITCH_ADD_LEN);
        packet.push_back(static_cast<uint8_t>(ITCH_ADD));
        put_u64(packet, rec.timestamp_ns);
        put_u64(packet, rec.order_id);
        packet.push_back(static_cast<uint8_t>(rec.side));
        put_double(packet, rec.price);
        put_double(packet, rec.size);
    } else if (rec.message_type == ITCH_CANCEL) {
        packet.reserve(ITCH_CANCEL_LEN);
        packet.push_back(static_cast<uint8_t>(ITCH_CANCEL));
        put_u64(packet, rec.timestamp_ns);
        put_u64(packet, rec.order_id);
        packet.push_back(static_cast<uint8_t>(rec.side));
    }
    // Unknown message types fall through and return an empty buffer.

    return packet;
}

// ---------------------------------------------------------
// OUCH encoding (client -> server)
// ---------------------------------------------------------
std::vector<uint8_t> to_ouch_enter(uint64_t order_id, char side,
                                   double price, double size) {
    std::vector<uint8_t> packet;
    packet.reserve(OUCH_ENTER_LEN);
    packet.push_back(static_cast<uint8_t>(OUCH_ENTER));
    put_u64(packet, order_id);
    packet.push_back(static_cast<uint8_t>(side));
    put_double(packet, price);
    put_double(packet, size);
    return packet;
}

std::vector<uint8_t> to_ouch_cancel(uint64_t order_id, char side) {
    std::vector<uint8_t> packet;
    packet.reserve(OUCH_CANCEL_LEN);
    packet.push_back(static_cast<uint8_t>(OUCH_CANCEL));
    put_u64(packet, order_id);
    packet.push_back(static_cast<uint8_t>(side));
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
        out.order_id = get_u64(buf + 1);
        out.side     = static_cast<char>(buf[9]);
        out.price    = get_double(buf + 10);
        out.size     = get_double(buf + 18);
        return true;
    }
    if (type == OUCH_CANCEL) {
        out.msg_type = OUCH_CANCEL;
        out.order_id = get_u64(buf + 1);
        out.side     = static_cast<char>(buf[9]);
        out.price    = 0.0;
        out.size     = 0.0;
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
