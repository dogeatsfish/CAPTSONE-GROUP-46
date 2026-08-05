#pragma once
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

#include "common.h"             // Order
#include "offline_simulation.h" // MBORecord

namespace protocol {

// ---- Fixed on-the-wire sizes (bytes) -------------------------------------
constexpr size_t ITCH_ADD_LEN    = 36;
constexpr size_t ITCH_CANCEL_LEN = 23;
constexpr size_t OUCH_ENTER_LEN  = 47;
constexpr size_t OUCH_CANCEL_LEN = 11;
    
// ---- ITCH 5.0 wire message tags (must match cut_through_parser.sv) -------
constexpr char ITCH_ADD    = 'A'; // Add Order,    36 bytes
constexpr char ITCH_CANCEL = 'X'; // Order Cancel, 23 bytes

// ---- OUCH 5.0 wire message tags (must match outbound_tx_generator.sv) ----
constexpr char OUCH_ENTER  = 'O'; // client -> server: enter order (47 bytes)
constexpr char OUCH_CANCEL = 'X'; // client -> server: cancel order (11 bytes).
constexpr char OUCH_ACCEPTED = 'A'; // order accepted and resting (no fill yet)
constexpr char OUCH_EXECUTED = 'E'; // order (partially) executed

constexpr size_t OUCH_RESPONSE_LEN = 25;
constexpr size_t OUCH_MAX_LEN = OUCH_ENTER_LEN;


// Default 
constexpr uint16_t DEFAULT_STOCK_LOCATE = 1;
constexpr double PRICE_SCALE = 10000.0;

// ---- MoldUDP64 framing ---------------------------------------------------

constexpr size_t MOLD_SESSION_LEN = 10;
constexpr size_t MOLD_HEADER_LEN  = MOLD_SESSION_LEN + 8 + 2; // 20 bytes
constexpr size_t MOLD_MSGLEN_LEN  = 2; 




std::vector<uint8_t> to_itch(const MBORecord& rec,
                             uint16_t stock_locate = DEFAULT_STOCK_LOCATE);

std::vector<uint8_t> to_moldudp64(
    const std::vector<std::vector<uint8_t>>& messages,
    uint64_t seq_num,
    const std::string& session = "");

// ---------------------------------------------------------
// OUCH decoding (inbound order entry)
// ---------------------------------------------------------
struct OuchMessage {
    char        msg_type = 0; 
    uint64_t    order_id = 0;  
    char        side     = 0;  
    double      price    = 0.0; 
    double      size     = 0.0; 
    std::string ticker;         
};


std::vector<uint8_t> to_ouch_enter(uint64_t order_id, char side,
                                   double price, double size);

std::vector<uint8_t> to_ouch_cancel(uint64_t order_id, double size);

size_t ouch_frame_len(uint8_t msg_type);
bool from_ouch(const uint8_t* buf, size_t len, OuchMessage& out);
Order ouch_to_order(const OuchMessage& msg);

// ---------------------------------------------------------
// OUCH responses (server -> client)
// ---------------------------------------------------------
struct OuchResponse {
    char     type     = 0;   // OUCH_EXECUTED / OUCH_ACCEPTED
    uint64_t order_id = 0;
    double   size     = 0.0; // executed or resting volume (see type)
    double   price    = 0.0; // avg fill price or order price (see type)
};

std::vector<uint8_t> to_ouch_response(char type, uint64_t order_id,
                                      double size, double price);

bool from_ouch_response(const uint8_t* buf, size_t len, OuchResponse& out);

}
