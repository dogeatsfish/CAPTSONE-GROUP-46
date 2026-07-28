#pragma once

// ---------------------------------------------------------
// Exchange wire protocols: ITCH (outbound market data) and
// OUCH (inbound order entry).
//
// These are compact, self-describing binary encodings inspired by the
// NASDAQ ITCH/OUCH families. Every multi-byte field is serialised in
// network byte order (big-endian) so the framing is portable across
// machines regardless of host endianness. Doubles are transported as
// their raw IEEE-754 bit pattern packed big-endian.
//
//   ITCH (market data, broadcast by the simulation over UDP):
//     'A' Add Order  : type(1) ts(8) order_id(8) side(1) price(8) size(8) = 34
//     'C' Cancel     : type(1) ts(8) order_id(8) side(1)                  = 18
//
//   OUCH (order entry, received by the simulation over TCP):
//     'O' Enter Order: type(1) order_id(8) side(1) price(8) size(8)       = 26
//     'X' Cancel     : type(1) order_id(8) side(1)                        = 10
// ---------------------------------------------------------

#include <cstdint>
#include <cstddef>
#include <vector>

#include "common.h"             // Order
#include "offline_simulation.h" // MBORecord

namespace protocol {

// ---- Message type tags ---------------------------------------------------
constexpr char ITCH_ADD    = 'A';
constexpr char ITCH_CANCEL = 'C';

constexpr char OUCH_ENTER  = 'O'; // client -> server: enter order
constexpr char OUCH_CANCEL = 'X'; // client -> server: cancel order

// Server -> client responses.
constexpr char OUCH_ACCEPTED = 'A'; // order accepted and resting (no fill yet)
constexpr char OUCH_EXECUTED = 'E'; // order (partially) executed

// ---- Fixed on-the-wire sizes (bytes) -------------------------------------
constexpr size_t ITCH_ADD_LEN    = 34;
constexpr size_t ITCH_CANCEL_LEN = 18;
constexpr size_t OUCH_ENTER_LEN  = 26;
constexpr size_t OUCH_CANCEL_LEN = 10;

// Server -> client response frame: type(1) order_id(8) size(8) price(8).
//   OUCH_EXECUTED: size = executed volume,  price = avg fill price
//   OUCH_ACCEPTED: size = resting volume,   price = order price
constexpr size_t OUCH_RESPONSE_LEN = 25;

// Largest OUCH frame; used to size read buffers.
constexpr size_t OUCH_MAX_LEN = OUCH_ENTER_LEN;

// ---------------------------------------------------------
// ITCH encoding (outbound market data)
// ---------------------------------------------------------
// Encode a single MBO record into an ITCH packet. Add records ('A') carry
// full price/size; cancel records ('C') carry only identity. Unknown message
// types produce an empty buffer.
std::vector<uint8_t> to_itch(const MBORecord& rec);

// ---------------------------------------------------------
// OUCH decoding (inbound order entry)
// ---------------------------------------------------------
// A decoded OUCH order-entry message.
struct OuchMessage {
    char     msg_type = 0;    // OUCH_ENTER / OUCH_CANCEL
    uint64_t order_id = 0;
    char     side     = 0;    // 'B' / 'S'
    double   price    = 0.0;  // valid for OUCH_ENTER
    double   size     = 0.0;  // valid for OUCH_ENTER
};

// Encode a client -> server OUCH ENTER order (OUCH_ENTER_LEN bytes).
std::vector<uint8_t> to_ouch_enter(uint64_t order_id, char side,
                                   double price, double size);

// Encode a client -> server OUCH CANCEL request (OUCH_CANCEL_LEN bytes).
std::vector<uint8_t> to_ouch_cancel(uint64_t order_id, char side);

// Given the first byte of a frame, report the total frame length so a stream
// reader knows how many more bytes to pull. Returns 0 for an unknown type.
size_t ouch_frame_len(uint8_t msg_type);

// Decode a complete OUCH frame. `len` must equal the frame length reported by
// ouch_frame_len(buf[0]). Returns false on a malformed / short buffer.
bool from_ouch(const uint8_t* buf, size_t len, OuchMessage& out);

// Convert a decoded OUCH ENTER message into an aggressive engine Order that
// can be handed straight to OrderBook::process_add. Orders arriving over OUCH
// are flagged synthetic (they originate from a connected trading client).
Order ouch_to_order(const OuchMessage& msg);

// ---------------------------------------------------------
// OUCH responses (server -> client)
// ---------------------------------------------------------
// A decoded OUCH response frame.
struct OuchResponse {
    char     type     = 0;   // OUCH_EXECUTED / OUCH_ACCEPTED
    uint64_t order_id = 0;
    double   size     = 0.0; // executed or resting volume (see type)
    double   price    = 0.0; // avg fill price or order price (see type)
};

// Encode an OUCH response frame (OUCH_RESPONSE_LEN bytes).
std::vector<uint8_t> to_ouch_response(char type, uint64_t order_id,
                                      double size, double price);

// Decode an OUCH response frame. `len` must equal OUCH_RESPONSE_LEN.
bool from_ouch_response(const uint8_t* buf, size_t len, OuchResponse& out);

} // namespace protocol
