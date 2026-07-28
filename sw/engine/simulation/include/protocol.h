#pragma once

// ---------------------------------------------------------
// Exchange wire protocols: ITCH (outbound market data) and
// OUCH (inbound order entry).
//
// These encodings mirror the byte layouts implemented by the FPGA RTL so the
// software simulation and the hardware speak exactly the same wire format:
//   - ITCH  : rtl/parser/cut_through_parser.sv      (HW decodes what SW emits)
//   - OUCH  : rtl/tx_gen/outbound_tx_generator.sv   (HW emits what SW decodes)
//
// Every multi-byte field is serialised in network byte order (big-endian),
// matching the RTL which assembles multi-byte fields MSB-first. Prices and
// quantities are BIG-ENDIAN INTEGERS on the wire (the RTL carries them as
// PRICE_W/QTY_W integer buses), NOT IEEE-754 doubles. Prices use 4 implied
// decimal places (the convention documented in the tx_gen), so a wire price of
// 1000000 represents 100.0000.
//
//   ITCH 5.0 (market data, broadcast by the simulation over UDP). Offsets are
//   relative to the message type byte and match cut_through_parser.sv:
//     'A' Add Order  36 B: type(1) locate(2) track(2) time(6) ref(8) side(1)
//                          shares(4) stock(8) price(4)
//     'X' Cancel     23 B: type(1) locate(2) track(2) time(6) ref(8) shares(4)
//
//   OUCH 5.0 (order entry, received by the simulation over TCP). Offsets match
//   outbound_tx_generator.sv (the OUCH message body, i.e. after the FPGA's
//   IP/UDP encapsulation has been stripped by the transport layer):
//     'O' Enter Order 47 B: type(1) userref(4) side(1) qty(4) symbol(8)
//                           price(8) tif(1) display(1) capacity(1) iso(1)
//                           crosstype(1) clordid(14) applen(2)
//     'X' Cancel      11 B: type(1) userref(4) qty(4) applen(2)
// ---------------------------------------------------------

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

#include "common.h"             // Order
#include "offline_simulation.h" // MBORecord

namespace protocol {

// ---- Source MBO record tags (as packed by the Python data pipeline) ------
// These identify the message type stored in MBORecord::message_type; they are
// NOT the ITCH wire tags. See sw/data_pipeline/src/cmd_L1_to_L3.py.
constexpr char MBO_ADD    = 'A';
constexpr char MBO_CANCEL = 'C';

// ---- ITCH 5.0 wire message tags (must match cut_through_parser.sv) -------
constexpr char ITCH_ADD    = 'A'; // Add Order,    36 bytes
constexpr char ITCH_CANCEL = 'X'; // Order Cancel, 23 bytes

// ---- OUCH 5.0 wire message tags (must match outbound_tx_generator.sv) ----
constexpr char OUCH_ENTER  = 'O'; // client -> server: enter order (47 bytes)
constexpr char OUCH_CANCEL = 'X'; // client -> server: cancel order (11 bytes)

// Server -> client responses. These acks are software-internal (the FPGA does
// not process inbound OUCH acks in the current scope), so their layout is not
// dictated by the RTL.
constexpr char OUCH_ACCEPTED = 'A'; // order accepted and resting (no fill yet)
constexpr char OUCH_EXECUTED = 'E'; // order (partially) executed

// Default numeric security id ("stock locate") stamped on ITCH messages when
// no explicit ticker is supplied. The parser derives symbol_id from the low
// byte of this field.
constexpr uint16_t DEFAULT_STOCK_LOCATE = 1;

// Fixed-point scale for prices on the wire: 4 implied decimal places, matching
// the "4 implied decimals" convention documented in the tx_gen. A double price
// of 100.0 is transported as the integer 1000000.
constexpr double PRICE_SCALE = 10000.0;

// ---- MoldUDP64 framing ---------------------------------------------------
// The parser expects each ITCH-carrying UDP datagram to open with a MoldUDP64
// header, followed by MessageCount blocks of {length(2), message(length)}:
//   Session (10 bytes ASCII) | SequenceNumber (8 BE) | MessageCount (2 BE)
// See the encapsulation note in rtl/parser/cut_through_parser.sv.
constexpr size_t MOLD_SESSION_LEN = 10;
constexpr size_t MOLD_HEADER_LEN  = MOLD_SESSION_LEN + 8 + 2; // 20 bytes
constexpr size_t MOLD_MSGLEN_LEN  = 2; // per-message big-endian length prefix

// ---- Fixed on-the-wire sizes (bytes) -------------------------------------
constexpr size_t ITCH_ADD_LEN    = 36;
constexpr size_t ITCH_CANCEL_LEN = 23;
constexpr size_t OUCH_ENTER_LEN  = 47;
constexpr size_t OUCH_CANCEL_LEN = 11;

// Server -> client response frame: type(1) order_id(8) size(8) price(8).
//   OUCH_EXECUTED: size = executed volume,  price = avg fill price
//   OUCH_ACCEPTED: size = resting volume,   price = order price
constexpr size_t OUCH_RESPONSE_LEN = 25;

// Largest OUCH frame; used to size read buffers.
constexpr size_t OUCH_MAX_LEN = OUCH_ENTER_LEN;

// ---------------------------------------------------------
// ITCH encoding (outbound market data)
// ---------------------------------------------------------
// Encode a single MBO record into an ITCH 5.0 packet in the exact byte layout
// decoded by cut_through_parser.sv. The 2-byte stock_locate defaults to
// DEFAULT_STOCK_LOCATE (1). Add records ('A') carry full price/size; cancel
// records ('C') are emitted as ITCH Order Cancel ('X') carrying the cancelled
// share count. Unknown message types produce an empty buffer.
std::vector<uint8_t> to_itch(const MBORecord& rec,
                             uint16_t stock_locate = DEFAULT_STOCK_LOCATE);

// Wrap one or more already-encoded ITCH messages into a MoldUDP64 packet ready
// to be placed in a UDP datagram. `seq_num` is the sequence number of the FIRST
// message in the packet; `session` identifies the market-data session (ASCII,
// truncated or zero-padded to MOLD_SESSION_LEN bytes). Empty messages are
// skipped. Returns the full MoldUDP64 payload (header + length-prefixed msgs).
std::vector<uint8_t> to_moldudp64(
    const std::vector<std::vector<uint8_t>>& messages,
    uint64_t seq_num,
    const std::string& session = "");

// ---------------------------------------------------------
// OUCH decoding (inbound order entry)
// ---------------------------------------------------------
// A decoded OUCH order-entry message.
struct OuchMessage {
    char     msg_type = 0;    // OUCH_ENTER / OUCH_CANCEL
    uint64_t order_id = 0;    // from the 4-byte UserRefNum
    char     side     = 0;    // 'B' / 'S' (OUCH_ENTER only; not on the wire for
                              //            OUCH_CANCEL -- see from_ouch note)
    double   price    = 0.0;  // valid for OUCH_ENTER
    double   size     = 0.0;  // OUCH_ENTER: order qty, OUCH_CANCEL: cancel qty
};

// Encode a client -> server OUCH ENTER order (OUCH_ENTER_LEN bytes) in the
// tx_gen's byte layout. Used by the test harness to emulate the FPGA.
std::vector<uint8_t> to_ouch_enter(uint64_t order_id, char side,
                                   double price, double size);

// Encode a client -> server OUCH CANCEL request (OUCH_CANCEL_LEN bytes) in the
// tx_gen's byte layout. Note the wire format carries no side.
std::vector<uint8_t> to_ouch_cancel(uint64_t order_id, double size);

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
