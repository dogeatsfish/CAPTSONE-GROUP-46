# HW ↔ SW Transport & Wire-Format Gaps

**Audience:** software lead.
**Date:** 2026-07-28.
**Status:** findings only — **no code was changed** by this review.

This is the companion to `hw_sw_interface.md`. That document covers symbols,
message-type mapping and numeric scaling. It has **no transport or addressing
section at all** — and that gap is the root cause of everything below.

---

## What was compared

| Side | Files | Branch |
|---|---|---|
| Software | `sw/engine/simulation/src/online_simulation.cpp`, `simulation/src/protocol.cpp`, `simulation/include/protocol.h`, `simulation/include/online_simulation.h`, `simulation/src/main_online.cpp` | **`origin/minh`** (also on `origin/main`) |
| Hardware TX | `rtl/tx_gen/outbound_tx_generator.sv`, `rtl/ip/tx_mac/tx_mac_core.sv`, `rtl/top/commontrader_top.sv` | `victor/HW_integration` |
| Hardware RX | `rtl/rx_mac/rx_mac_core.sv`, `rtl/parser/cut_through_parser.sv` | `victor/HW_integration` |
| Reference encoder | `sim/csv_to_itch.py` | `victor/HW_integration` |

**The hardware and software branches have never been merged.** The online
simulation does not exist on the HW integration branch and the RTL does not exist
in a form the SW branch can see. That is how the mismatches below survived: there
has never been a tree where both halves were visible at once.

---

## Summary

| # | Gap | Severity |
|---|---|---|
| 1 | FPGA sends orders over **UDP**; SW order entry is a **TCP** listener | 🔴 blocker |
| 2 | Port numbers don't match (50001 vs 26001) | 🔴 blocker |
| 3 | The two `'O'` Enter Order messages are **different formats** sharing a type byte (47 B vs 26 B) | 🔴 blocker |
| 4 | SW replies with an OUCH response frame; **FPGA has no ingress path for it** | 🟠 |
| 5 | SW broadcasts ITCH to **127.0.0.1** — never reaches a NIC | 🔴 blocker |
| 6 | SW omits the **MoldUDP64 header** the RTL parser hard-strips | 🔴 blocker |
| 7 | The two `'A'` Add Order messages are **both 36 B with different layouts** | 🔴 blocker (silent) |
| 8 | SW `'C'` Cancel (20 B) is not a message the RTL parser knows | 🟠 |
| 9 | Three components use three different IP/port/MAC tuples | 🟠 |
| 10 | FPGA's `DST_MAC` is a placeholder — frames die in the host NIC | 🔴 blocker |
| 11 | Online sim is POSIX-only (won't build on Windows) | 🟡 |

---

## 1. UDP vs TCP

| | Transport | Address | Port |
|---|---|---|---|
| SW ITCH out (market data) | **UDP** `sendto` | `127.0.0.1` | 26000 |
| SW OUCH in (order entry) | **TCP** `listen`/`accept` | `0.0.0.0` | 26001 |
| RTL TX out (orders) | **UDP** (`IP_PROTO = 8'd17`) | 192.168.0.1 → 192.168.0.2 | 50000 → 50001 |

The FPGA emits UDP datagrams. `OnlineSimulation::open_ouch_listener()` creates a
`SOCK_STREAM` socket and calls `listen()`/`accept()`. A UDP datagram cannot be
delivered to a TCP socket — the host kernel answers ICMP port-unreachable, which
the FPGA (having no ICMP stack) ignores. `accept()` will never return.

**This must be fixed on the software side.** TCP is not implementable in the
current datapath: `outbound_tx_generator.sv` is a stateless byte-select
multiplexer with no handshake, no sequence numbers, no retransmission, and no
receive path for acknowledgements. Its own header comment states that inbound
OUCH ack processing is out of scope. Adding TCP to the FPGA is a project, not a
fix.

---

## 2. What the FPGA actually puts on the wire

One frame per approved trade. **95 bytes on the wire**, byte-for-byte:

```
offset  len  field
------  ---  --------------------------------------------------------------
   0     6   dst MAC     AA:BB:CC:DD:EE:FF   <- placeholder, see gap #10
   6     6   src MAC     00:0A:35:01:02:03   (Xilinx OUI)
  12     2   ethertype   0x0800 (IPv4)
------------ IPv4 header (20 B) ------------------------------------------
  14     1   0x45        version 4, IHL 5
  15     1   0x00        DSCP/ECN
  16     2   0x004D      total length = 77
  18     2   ident       increments per packet
  20     1   0x40        Don't Fragment
  21     1   0x00        fragment offset
  22     1   0x40        TTL 64
  23     1   0x11        protocol 17 = UDP
  24     2   checksum    computed over the header
  26     4   src IP      192.168.0.1
  30     4   dst IP      192.168.0.2
------------ UDP header (8 B) --------------------------------------------
  34     2   src port    50000
  36     2   dst port    50001
  38     2   length      57  (8 + 49 payload)
  40     2   checksum    0x0000  (legal for IPv4 UDP, RFC 768)
------------ OUCH 5.0 Enter Order (47 B) ---------------------------------
  42     1   'O'         0x4F
  43     4   UserRefNum  big-endian, starts at 1, +1 per order
  47     1   Side        'B' (0x42) or 'S' (0x53)
  48     4   Quantity    big-endian uint32
  52     8   Symbol      ASCII, space-padded, MSB char first
  60     8   Price       big-endian; upper 4 bytes ZERO, lower 4 = uint32
                         with 4 implied decimals
  68     1   TimeInForce 0x00
  69     1   Display     0x00
  70     1   Capacity    0x00
  71     1   ISO         0x00
  72     1   CrossType   0x00
  73    14   ClOrdID     14 × 0x20 (spaces)
  87     2   AppendageLen 0x0000
------------ latency telemetry (2 B, NOT part of OUCH) -------------------
  89     2   latency     big-endian uint16, ticks of 4 ns
------------ Ethernet FCS ------------------------------------------------
  91     4   CRC-32      IEEE 802.3 reflected, LSB first
```

**UDP payload = 49 bytes: a 47-byte OUCH message followed by a 2-byte latency
trailer.** The trailer is the FPGA's FS-12 telemetry (time from parser to TX
generator). It is inside the UDP length but outside the OUCH message. Anything
consuming this stream must know to split at 47.

---

## 3. The two `'O'` messages are different formats

| | RTL `outbound_tx_generator.sv` | SW `protocol.h` / `protocol.cpp` |
|---|---|---|
| Spec | OUCH 5.0 Enter Order | custom compact encoding |
| Length | **47 B** (+2 B telemetry) | **26 B** |
| Field 2 | UserRefNum, **4 B** | order_id, **8 B** |
| Then | Side(1) Quantity(4) Symbol(8) Price(8) | side(1) price(8) size(8) |
| Symbol | 8-byte ASCII ticker | *absent* |
| Price | integer, 4 implied decimals | **IEEE-754 double bit pattern** |
| Size | uint32 big-endian | IEEE-754 double |
| Trailer | ClOrdID(14) AppLen(2) + latency(2) | none |

`from_ouch()` enforces `len == ouch_frame_len(buf[0])`, i.e. exactly 26 for `'O'`.
The FPGA's payload is 49 — rejected outright.

If the length check were relaxed it would be worse, not better:

- SW would read the FPGA's `UserRefNum(4) + Side(1) + Quantity(4)[0:3]` as its
  own 8-byte `order_id`.
- SW would `memcpy` 8 bytes of OUCH integer price into a `double` and reinterpret
  the bit pattern — producing denormals or astronomically wrong prices, not a
  value that is merely off by a scale factor.
- Over TCP the stream reader would also **desync**: it consumes exactly 26 bytes,
  then treats byte 27 of the FPGA's frame as the next message-type byte.

There is a real decision here: **whose format wins.** The RTL's is the
standards-conformant OUCH 5.0 layout and is what the design report claims. The
SW's is a compact in-house encoding. Recommendation is that SW adopts the OUCH
5.0 layout, because changing the RTL means touching `ct_pkg` field widths and
re-running timing closure on a design that is already tight.

---

## 4. The response direction does not exist in hardware

`handle_ouch_client()` replies to every ENTER with a 25-byte
`OUCH_ACCEPTED` / `OUCH_EXECUTED` frame on the same connection.

The FPGA has **no ingress path for it**. `rx_mac_core` feeds the ITCH parser and
nothing else, and `cut_through_parser.sv` blindly strips 48 bytes and looks for
ITCH types `A`/`E`/`X`/`D`/`U`. A 25-byte OUCH response would be parsed as
garbage or dropped.

This is consistent with the RTL's stated scope — no fill correlation, no ack
processing — but it means **the FPGA is fire-and-forget.** Any design that
assumes the client acknowledges orders needs rethinking, and `UserRefNum` is
currently allocated but never reconciled against anything.

---

## 5–7. The market-data direction is equally disconnected

**Destination.** `broadcast_itch()` sends to `cfg.itch_address`, which defaults
to `127.0.0.1`. Loopback traffic never reaches a NIC, so it can never reach the
FPGA over the cable. The field is configurable, so this one is a one-line change
— but nothing today selects an interface.

**Missing encapsulation layer.** SW puts the raw ITCH message straight into the
UDP payload. `cut_through_parser.sv` hard-strips
`ENCAP_LEN = IP(20) + UDP(8) + MoldUDP64(20) = 48` bytes and expects the first
`MsgLen(2) | ITCH message` pair at offset 48. It does not search for the payload;
it counts bytes. Without the 20-byte MoldUDP64 header every field lands 20 bytes
early.

MoldUDP64 header the parser expects:

```
 0    10   Session        (10 bytes, e.g. spaces)
10     8   SequenceNumber (big-endian uint64)
18     2   MessageCount   (big-endian uint16)
20   ...   repeated MessageCount times:  MsgLen(2, BE) | ITCH message
```

**Add Order — same length, different layout.** This is the dangerous one,
because a length check passes while every field is misaligned:

| Offset | RTL ITCH 5.0 `'A'` (36 B) | SW `'A'` (36 B) |
|---|---|---|
| 0 | type `'A'` | type `'A'` |
| 1–2 | Stock Locate (2) | stock_locate (2) |
| 3–4 | Tracking Number (2) | — |
| 3–10 | — | timestamp_ns (8, BE) |
| 5–10 | Timestamp (6) | — |
| 11–18 | Order Reference (8) | order_id (8) |
| 19 | Side (1) | side (1) |
| 20–23 | Shares (4) | — |
| 20–27 | — | price (**IEEE-754 double**) |
| 24–31 | Stock (8 ASCII) | — |
| 28–35 | — | size (**IEEE-754 double**) |
| 32–35 | Price (4) | — |

**Cancel.** SW emits `'C'` (20 B). The RTL parser has no `'C'`; it has `'X'`
Order Cancel (23 B, partial — carries shares removed) and `'D'` Order Delete
(19 B, full removal). Per `hw_sw_interface.md` §2 the correct mapping is
**`C → D`**, because the SW `C` always removes the whole order.

**Good news: the correct encoder already exists.** `sim/csv_to_itch.py` produces
exactly the right framing — MoldUDP64 + UDP + IPv4 + Ethernet with the RTL's ITCH
field layout and a correct 802.3 FCS. It currently writes `.hex` files for the
testbench rather than live packets, but it is a working reference implementation
and should be ported rather than rewritten.

---

## 8. Addressing: three components, three different worlds

| | src IP | dst IP | src port | dst port | dst MAC |
|---|---|---|---|---|---|
| RTL TX | 192.168.0.1 | 192.168.0.2 | 50000 | 50001 | `AA:BB:CC:DD:EE:FF` |
| `csv_to_itch.py` | 10.0.0.1 | 10.0.0.2 | 1234 | 5678 | `AA:AA:AA:AA:AA:AA` |
| SW online sim | host stack | 127.0.0.1 | ephemeral | 26000 / 26001 | host stack |

Three subnets, three port pairs, two MACs. Nothing lines up with anything.

---

## 9. "How does the software know which socket the FPGA is on?"

**It doesn't, and as built it can't.** The FPGA never opens a connection. It has
no TCP, no ARP, no DHCP and no ICMP. It emits one hardcoded UDP datagram per
approved trade and never listens for a reply.

The mental model has to be inverted: **the FPGA dictates the tuple; the host
binds to receive it.**

### To receive orders from the FPGA

1. Configure the NIC the board is cabled to with **192.168.0.2** — the RTL's
   hardcoded `DST_IP`.
2. `bind()` a **UDP** socket to `0.0.0.0:50001` or `192.168.0.2:50001` and
   `recvfrom()`. No `connect`, no `accept`.
3. Identify the FPGA by the datagram's source address (`192.168.0.1:50000`), or
   simply by which socket it arrived on. There is no session, so there is nothing
   else to correlate against.

### The MAC address is the real blocker

`tx_mac_core`'s `DST_MAC` parameter defaults to `AA:BB:CC:DD:EE:FF`, and
`commontrader_top.sv` instantiates the module **without overriding it**. That
address belongs to no real device. A NIC drops frames whose destination MAC is
not its own, not broadcast, and not a joined multicast group — so the frames
arrive at the NIC and are discarded **in hardware, before the IP stack sees
them**. A `recvfrom()` on the right port would still return nothing.

Three ways out, in order of preference for bring-up:

- **Broadcast** — set `DST_MAC = FF:FF:FF:FF:FF:FF`. Works immediately on a
  direct cable, no per-machine configuration. Sloppy for production, ideal for
  first light.
- **Real MAC** — override `DST_MAC` with the host NIC's actual address. Correct,
  but bakes a machine-specific value into the bitstream.
- **Promiscuous capture** — put the NIC in promiscuous mode and read with
  AF_PACKET / libpcap instead of a UDP socket. Sees everything, costs you the
  kernel's IP/UDP parsing.

Note also that the FPGA will never answer ARP, so if the host ever needs to send
*to* `192.168.0.1` it needs a **static ARP entry**.

### To send market data to the FPGA — easier than it looks

`rx_mac_core` does **no MAC filtering** and the parser does **no IP or port
checking**. Any frame with a valid FCS is accepted, and 48 bytes are stripped
unconditionally.

So a plain UDP socket is sufficient: send a datagram whose payload is
`MoldUDP64(20) + [MsgLen(2)|ITCH]...`, and the kernel's own IP(20) + UDP(8)
headers land exactly where the parser expects them. Destination IP and port are
irrelevant to the FPGA — only the byte offsets matter.

One caveat: this relies on a **20-byte IP header (IHL = 5, no options)**, which
is the normal case but is not guaranteed if anything on the path inserts options.

---

## 10. Build portability

`online_simulation.cpp` includes `<sys/socket.h>`, `<netinet/in.h>`,
`<arpa/inet.h>`, `<unistd.h>`, `<sys/select.h>` — POSIX only. It will not build
on Windows without a Winsock port. The checked-in artifact is
`engine_sim.cpython-314-darwin.so`, so development is on macOS. Worth deciding
early which machine gets the Ethernet cable to the board, because that machine
has to run this binary.

---

## Recommended actions

| # | Action | Owner |
|---|---|---|
| 1 | Add an **OUCH-over-UDP** receive path: bind `:50001`, `recvfrom`, split payload at 47 B (OUCH) + 2 B (latency) | SW |
| 2 | Add an **OUCH 5.0 decoder** matching the byte table in §2 | SW |
| 3 | Point `itch_address` at the FPGA; **prepend MoldUDP64**; adopt the RTL's ITCH field layout — port `csv_to_itch.py`'s encoder rather than rewriting | SW |
| 4 | Map SW `'C'` → ITCH `'D'` Delete (not `'X'`) | SW |
| 5 | Override `DST_MAC` (broadcast for bring-up) | HW |
| 6 | Agree one addressing tuple — IPs, ports, MACs — and write it into `hw_sw_interface.md` as a **transport section** | Both |
| 7 | Decide whether order acknowledgement is in scope at all; if yes it is an RTL ingress feature, not a SW fix | Both |

---

## The question to settle first

**Was the online simulation ever intended to talk to the FPGA?**

If it was, items 1–5 are bug fixes and the two halves were built to assumptions
that were never reconciled.

If it wasn't — if the online sim is a pure-software demo whose "client" is a
software strategy connecting over TCP — then **none of the above is a defect**.
It just means the FPGA host program does not exist yet, and items 1–3 are new
work rather than repairs. In that case the TCP OUCH server is correct for its
actual purpose and should be left alone, with a separate UDP-based host program
written for the board.

Everything else in this document follows from that answer, so it is worth
settling before any code moves.
