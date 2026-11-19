#pragma once

#include <cstdint>

// One record of recorded market data, exactly as it sits in a packed .bin
// file. This is the engine's input format, shared by everything that reads a
// feed file, serializes one to the wire, or replays one through the book.
//
// It lives here, on its own, deliberately. It used to be declared in
// offline_simulation.h, which meant protocol.h had to include that header just
// to name this struct -- dragging the scheduler, the participants and the
// player's strategy into every translation unit that only wanted to talk ITCH.

#pragma pack(push, 1)
struct MBORecord {
    uint64_t timestamp_ns;
    char     message_type; // ITCH: 'A' add, 'X' cancel/reduce
    uint64_t order_id;
    char     side;         // 'B' / 'S'
    double   price;
    double   size;
};
#pragma pack(pop)

// The on-disk record must be exactly 34 bytes to match the Python packer
// (struct format "<QcQcdd"). Keep this assertion next to the struct: it is the
// contract with data_pipeline, and it has to fire in every file that writes
// these bytes to disk or to the wire, not just in the one that reads them.
static_assert(sizeof(MBORecord) == 34, "MBORecord layout must match Python '<QcQcdd'");
