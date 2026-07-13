//==============================================================================
// CommonTrader - Shared Interface Definitions
// Group 2026.46
//
// Single source of truth for inter-block interfaces, packed structures, and
// system parameters. Every subsystem includes this file; no block should
// redefine a width or bit position locally.
//
// If you change anything in this file, it changes another team member's ports.
// Open a PR and tag the affected owners.
//==============================================================================

`ifndef COMMONTRADER_INTERFACES_SVH
`define COMMONTRADER_INTERFACES_SVH

//------------------------------------------------------------------------------
// System parameters
//------------------------------------------------------------------------------
package ct_pkg;

  // --- Clocking -------------------------------------------------------------
  parameter int CORE_CLK_HZ      = 250_000_000;  // 250 MHz core domain (MMCM)
  parameter int PHY_CLK_HZ       = 125_000_000;  // 125 MHz RGMII domain
  parameter int CORE_PERIOD_NS   = 4;            // 1 / 250 MHz

  // --- Market structure -----------------------------------------------------
  parameter int NUM_ASSETS       = 5;            // FS-6: minimum 5 assets
  parameter int NUM_LEVELS       = 16;           // price levels per side
  parameter int NUM_LIVE_ORDERS  = 1024;         // Order Reference Table depth

  // --- Field widths ---------------------------------------------------------
  parameter int SYMBOL_W         = 8;            // asset index (indexes NUM_ASSETS)
  parameter int PRICE_W          = 32;
  parameter int QTY_W            = 32;
  parameter int SIDE_W           = 1;            // 0 = bid, 1 = ask
  parameter int TYPE_W           = 2;            // add / modify / delete
  parameter int TIMESTAMP_W      = 16;           // latency delta, 4 ns/tick, 262 us range
  parameter int TICKER_W         = 64;           // 8 ASCII chars, space-padded (OUCH)
  parameter int USERREF_W        = 32;           // OUCH UserRefNum

  // --- Derived --------------------------------------------------------------
  parameter int LEVEL_W          = PRICE_W + QTY_W;               // 64
  parameter int ASSET_IDX_W      = $clog2(NUM_ASSETS);            // 3
  parameter int LEVEL_IDX_W      = $clog2(NUM_LEVELS);            // 4
  parameter int DEPTH_ADDR_W     = ASSET_IDX_W + SIDE_W + LEVEL_IDX_W; // 8

  // --- Side encoding --------------------------------------------------------
  parameter logic SIDE_BID = 1'b0;
  parameter logic SIDE_ASK = 1'b1;

  // --- Book update message type ---------------------------------------------
  typedef enum logic [TYPE_W-1:0] {
    MSG_ADD    = 2'b00,
    MSG_MODIFY = 2'b01,
    MSG_DELETE = 2'b10,
    MSG_RSVD   = 2'b11
  } msg_type_e;

  // --- OUCH outbound message type -------------------------------------------
  typedef enum logic [1:0] {
    OUCH_ENTER  = 2'b00,   // Type 'O', 47 bytes
    OUCH_CANCEL = 2'b01,   // Type 'X', 11 bytes
    OUCH_MODIFY = 2'b10    // Type 'M', 12 bytes
  } ouch_type_e;

  //----------------------------------------------------------------------------
  // Parser -> Order Book Array
  // 91-bit packed price-level update
  // {symbol_id [7:0], price [39:8], quantity [71:40], side [72],
  //  type [74:73], timestamp [90:75]}
  //----------------------------------------------------------------------------
  typedef struct packed {
    logic [TIMESTAMP_W-1:0] timestamp;   // [90:75]
    msg_type_e              msg_type;    // [74:73]
    logic                   side;        // [72]
    logic [QTY_W-1:0]       quantity;    // [71:40]
    logic [PRICE_W-1:0]     price;       // [39:8]
    logic [SYMBOL_W-1:0]    symbol_id;   // [7:0]
  } book_update_t;

  parameter int BOOK_UPDATE_W = $bits(book_update_t);   // 91

  //----------------------------------------------------------------------------
  // Order Reference Table entry (internal to Cut-through Stream Parser)
  // 74-bit packed entry, direct-indexed by Order Reference Number
  // {valid [73], symbol_id [72:65], side [64], price [63:32], shares [31:0]}
  //----------------------------------------------------------------------------
  typedef struct packed {
    logic                   valid;       // [73]
    logic [SYMBOL_W-1:0]    symbol_id;   // [72:65]
    logic                   side;        // [64]
    logic [PRICE_W-1:0]     price;       // [63:32]
    logic [QTY_W-1:0]       shares;      // [31:0]
  } ref_entry_t;

  parameter int REF_ENTRY_W = $bits(ref_entry_t);       // 74
  parameter int REF_ADDR_W  = $clog2(NUM_LIVE_ORDERS);  // 10

  //----------------------------------------------------------------------------
  // Order Book depth level (one BRAM word)
  //----------------------------------------------------------------------------
  typedef struct packed {
    logic [PRICE_W-1:0] price;
    logic [QTY_W-1:0]   quantity;
  } level_t;

  //----------------------------------------------------------------------------
  // Alpha Engine -> Risk Gateway -> TX Generator
  // 144-bit packed trade structure
  // {price [31:0], quantity [63:32], ticker [127:64], timestamp [143:128]}
  //----------------------------------------------------------------------------
  typedef struct packed {
    logic [TIMESTAMP_W-1:0] timestamp;   // [143:128]
    logic [TICKER_W-1:0]    ticker;      // [127:64]  ASCII, space-padded
    logic [QTY_W-1:0]       quantity;    // [63:32]
    logic [PRICE_W-1:0]     price;       // [31:0]
  } trade_t;

  parameter int TRADE_W = $bits(trade_t);   // 144

  // Trade direction rides on AXI tuser
  parameter logic DIR_SELL = 1'b0;
  parameter logic DIR_BUY  = 1'b1;

endpackage : ct_pkg

`endif // COMMONTRADER_INTERFACES_SVH
