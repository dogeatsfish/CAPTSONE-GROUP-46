#!/usr/bin/env python3
"""
csv_to_itch.py -- turn the software team's MBO stream into wire-format Ethernet
frames the hardware can parse, plus a reference top-of-book to check against.

    python3 sim/csv_to_itch.py --events 500 --out sim/replay

Reads  : sw/data_pipeline/data/synthetic_mbo_stream.csv
Writes : <out>_frames.hex   one byte per line, all frames concatenated
         <out>_lens.hex     one frame length per line
         <out>_tob.hex      expected {bid_px, bid_qty, ask_px, ask_qty} after
                            each frame, as one 128-bit word per line
         <out>_meta.txt     human-readable summary

The .hex files are consumed by $readmemh in tb/top/commontrader_replay_tb.sv,
which works identically under Verilator and xsim.

The mapping decisions encoded here are documented in docs/hw_sw_interface.md.
The two that are NOT settled are surfaced as command-line options rather than
buried, so changing them is a flag and not an edit:

  --symbols N     how many ITCH Stock Locates to spread events across.
                  The CSV has no symbol column at all (open item 1).
  --price-scale   fixed-point multiplier, default 10^4 to match OUCH 5.0's
                  four implied decimal places (open item 3).

The reference book below is deliberately a PRICE-LEVEL book, matching
rtl/order_book/order_book_array.sv -- not a matching engine. It never crosses
trades. See interface doc item 5.
"""

import argparse
import csv
import os
import sys

# ---------------------------------------------------------------------------
# Encapsulation constants. These must match what cut_through_parser.sv expects
# and what the integration testbench already uses.
# ---------------------------------------------------------------------------
SRC_IP   = 0x0A000001          # 10.0.0.1
DST_IP   = 0x0A000002          # 10.0.0.2
SRC_PORT = 1234
DST_PORT = 5678

DST_MAC = bytes([0xAA] * 6)
SRC_MAC = bytes([0xBB] * 6)
ETHERTYPE = bytes([0x08, 0x00])

NUM_LEVELS = 16                # must match ct_pkg::NUM_LEVELS


# ---------------------------------------------------------------------------
# CRC-32 (IEEE 802.3, reflected) -- the same polynomial the RX/TX MACs use.
# ---------------------------------------------------------------------------
def crc32_8023(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if (crc & 1) else (crc >> 1)
    return (~crc) & 0xFFFFFFFF


def udp_checksum(src_ip, dst_ip, udp_datagram: bytes) -> int:
    """One's-complement sum over the IPv4 pseudo-header plus the datagram."""
    s = 0
    s += (src_ip >> 16) & 0xFFFF
    s += src_ip & 0xFFFF
    s += (dst_ip >> 16) & 0xFFFF
    s += dst_ip & 0xFFFF
    s += 17                                     # protocol = UDP
    s += len(udp_datagram)
    for i in range(0, len(udp_datagram), 2):
        hi = udp_datagram[i]
        lo = udp_datagram[i + 1] if i + 1 < len(udp_datagram) else 0
        s += (hi << 8) | lo
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    c = (~s) & 0xFFFF
    return c if c != 0 else 0xFFFF               # RFC 768: 0 means "none"


# ---------------------------------------------------------------------------
# ITCH message builders. Field layouts are the ones cut_through_parser.sv
# decodes -- offsets are relative to the type byte.
# ---------------------------------------------------------------------------
def itch_add(locate, ref, side_char, shares, stock, price) -> bytes:
    m = bytearray()
    m += b"A"
    m += locate.to_bytes(2, "big")
    m += (0).to_bytes(2, "big")                  # tracking number
    m += (0).to_bytes(6, "big")                  # timestamp
    m += ref.to_bytes(8, "big")
    m += side_char.encode()
    m += shares.to_bytes(4, "big")
    m += stock.ljust(8).encode()[:8]             # alpha: left-justified, space pad
    m += price.to_bytes(4, "big")
    assert len(m) == 36, len(m)
    return bytes(m)


def itch_delete(locate, ref) -> bytes:
    m = bytearray()
    m += b"D"
    m += locate.to_bytes(2, "big")
    m += (0).to_bytes(2, "big")
    m += (0).to_bytes(6, "big")
    m += ref.to_bytes(8, "big")
    assert len(m) == 19, len(m)
    return bytes(m)


def build_frame(messages) -> bytes:
    """MoldUDP64 + UDP + IPv4 + Ethernet around a list of ITCH messages."""
    mold = bytearray()
    mold += b" " * 10                            # session
    mold += (1).to_bytes(8, "big")               # sequence number
    mold += len(messages).to_bytes(2, "big")     # message count
    for m in messages:
        mold += len(m).to_bytes(2, "big")        # MoldUDP64 per-message length
        mold += m

    udp_len = 8 + len(mold)
    udp = bytearray()
    udp += SRC_PORT.to_bytes(2, "big")
    udp += DST_PORT.to_bytes(2, "big")
    udp += udp_len.to_bytes(2, "big")
    udp += (0).to_bytes(2, "big")                # checksum placeholder
    udp += mold
    ck = udp_checksum(SRC_IP, DST_IP, bytes(udp))
    udp[6:8] = ck.to_bytes(2, "big")

    total_len = 20 + len(udp)
    ip = bytearray()
    ip += bytes([0x45, 0x00])
    ip += total_len.to_bytes(2, "big")
    ip += (0).to_bytes(2, "big")                 # identification
    ip += (0x4000).to_bytes(2, "big")            # don't fragment
    ip += bytes([64, 17])                        # TTL, protocol
    ip += (0).to_bytes(2, "big")                 # header checksum (DUT ignores)
    ip += SRC_IP.to_bytes(4, "big")
    ip += DST_IP.to_bytes(4, "big")
    ip += udp

    body = DST_MAC + SRC_MAC + ETHERTYPE + bytes(ip)
    fcs = crc32_8023(body)
    return body + fcs.to_bytes(4, "little")      # FCS is transmitted LSB first


# ---------------------------------------------------------------------------
# Reference price-level book -- mirrors order_book_array.sv, not a matcher.
# ---------------------------------------------------------------------------
class RefBook:
    """One asset. levels[side] is a price-ordered list of [price, qty]."""

    def __init__(self):
        self.levels = {0: [], 1: []}             # 0 = bid, 1 = ask

    @staticmethod
    def _better(side, a, b):
        return a > b if side == 0 else a < b

    def add(self, side, price, qty):
        lv = self.levels[side]
        for e in lv:
            if e[0] == price:
                e[1] += qty
                return
        pos = len(lv)
        for i, e in enumerate(lv):
            if self._better(side, price, e[0]):
                pos = i
                break
        lv.insert(pos, [price, qty])
        del lv[NUM_LEVELS:]                      # tail eviction

    def delete(self, side, price):
        lv = self.levels[side]
        for i, e in enumerate(lv):
            if e[0] == price:
                lv.pop(i)
                return

    def l1(self, side):
        lv = self.levels[side]
        return (lv[0][0], lv[0][1]) if lv else (0, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csv", default="sw/data_pipeline/data/synthetic_mbo_stream.csv")
    ap.add_argument("--out", default="sim/replay")
    ap.add_argument("--events", type=int, default=500,
                    help="MBO events to convert (0 = all)")
    ap.add_argument("--per-frame", type=int, default=8,
                    help="ITCH messages per Ethernet frame")
    ap.add_argument("--symbols", type=int, default=5,
                    help="ITCH Stock Locates to spread events across "
                         "(the CSV has no symbol column -- see interface doc)")
    ap.add_argument("--price-scale", type=int, default=10000,
                    help="fixed-point multiplier (OUCH 5.0 uses 4 decimals)")
    args = ap.parse_args()

    tickers = ["AAPL", "MSFT", "AMZN", "GOOG", "TSLA"]

    if not os.path.exists(args.csv):
        sys.exit(f"ERROR: cannot find {args.csv}")

    # order_id -> (locate, side, price_hw, qty_hw) so a 'C' can be resolved.
    live = {}
    books = {i: RefBook() for i in range(args.symbols)}

    frames, lens, tobs = [], [], []
    pending = []
    n_add = n_del = n_skipped = n_overflow = 0
    next_ref = 1

    def flush():
        nonlocal pending
        if not pending:
            return
        f = build_frame(pending)
        frames.append(f)
        lens.append(len(f))
        # Expected top of book after this frame, for EVERY asset: one 128-bit
        # word each, emitted in asset order. The testbench walks
        # exp_tob[frame*NUM_ASSETS + asset], so all five books are checked
        # rather than just the one the last message happened to touch.
        for a in range(args.symbols):
            bp, bq = books[a].l1(0)
            ap_, aq = books[a].l1(1)
            tobs.append((bp, bq, ap_, aq))
        pending = []

    with open(args.csv) as fh:
        rdr = csv.DictReader(fh)
        for i, row in enumerate(rdr):
            if args.events and i >= args.events:
                break

            mtype = row["message_type"]
            oid   = int(row["order_id"])
            side  = 0 if row["side"] == "B" else 1
            price = int(round(float(row["price"]) * args.price_scale))
            size  = int(round(float(row["size"])))

            if price >= (1 << 32) or price < 0:
                n_overflow += 1
                continue
            if size >= (1 << 32) or size <= 0:
                n_skipped += 1
                continue

            if mtype == "A":
                locate = oid % args.symbols
                ref = next_ref
                next_ref += 1
                live[oid] = (locate, side, price, size, ref)
                books[locate].add(side, price, size)
                pending.append(itch_add(locate, ref, row["side"], size,
                                        tickers[locate % len(tickers)], price))
                n_add += 1
            elif mtype == "C":
                if oid not in live:
                    n_skipped += 1
                    continue
                locate, lside, lprice, lsize, ref = live.pop(oid)
                books[locate].delete(lside, lprice)
                # 'C' removes the whole order -> ITCH Delete, never Cancel.
                pending.append(itch_delete(locate, ref))
                n_del += 1
            else:
                n_skipped += 1
                continue

            if len(pending) >= args.per_frame:
                flush()

    flush()

    # ---- emit -------------------------------------------------------------
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    with open(f"{args.out}_frames.hex", "w") as fh:
        for f in frames:
            for b in f:
                fh.write(f"{b:02x}\n")

    with open(f"{args.out}_lens.hex", "w") as fh:
        for n in lens:
            fh.write(f"{n:04x}\n")

    with open(f"{args.out}_tob.hex", "w") as fh:
        for bp, bq, ap_, aq in tobs:
            fh.write(f"{bp:08x}{bq:08x}{ap_:08x}{aq:08x}\n")

    meta = (
        f"source          : {args.csv}\n"
        f"events consumed : {n_add + n_del}\n"
        f"  ITCH Add      : {n_add}\n"
        f"  ITCH Delete   : {n_del}\n"
        f"skipped         : {n_skipped}\n"
        f"price overflow  : {n_overflow}\n"
        f"frames          : {len(frames)}\n"
        f"total bytes     : {sum(lens)}\n"
        f"symbols         : {args.symbols}\n"
        f"price scale     : {args.price_scale}\n"
    )
    with open(f"{args.out}_meta.txt", "w") as fh:
        fh.write(meta)

    print(meta, end="")


if __name__ == "__main__":
    main()
