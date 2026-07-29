# Known Limitations

Defects and design gaps that are **understood and measured**. Each entry records
what it is, how it was found, what it costs, and what fixing it would take — or,
for a resolved entry, how it was fixed.

Anything in this file is pinned by a testbench check so it cannot be forgotten. A
resolved entry keeps its check as a permanent regression guard (e.g. L1's `C1`,
which now passes and fails again if the defect ever returns).

---

## L1 — TX CDC FIFO overflow (RESOLVED)

**Status: FIXED.** Was **high severity** — silently truncated Ethernet frames on
the wire. The write-side start gate described below eliminates it; the pinning
check `commontrader_crv_tb` **C1** now passes and stands as a regression guard.

### What it was

Found by `tb/top/commontrader_crv_tb.sv` (constrained-random integration bench),
reproducible on 3 of 4 seeds:

```
TX FIFO OVERFLOW  byte_idx=51  wbin=78  rbin=206  occ=128  macstate=2
[FAIL] egress frame 7 length 78, expected 103
```

The FIFO went genuinely full (128/128) while the TX Generator was at byte 51 of a
77-byte packet; the bytes written during the overflow were lost and the TX MAC
emitted a truncated frame. Seen with two approved orders only **444 ns apart** —
ordinary Phase A traffic, not an artificial burst.

### Root cause

The backpressure boundary was in the wrong place — the TX Generator's ready
reflected only its own serialiser state, not whether the FIFO could absorb another
frame:

```systemverilog
assign s_axis_trade_tready = (state == IDLE);   // says nothing about FIFO room
```

| | Duration |
|---|---|
| TX Gen serialises one packet | 308 ns (77 B @ 250 MHz) |
| A full Ethernet frame occupies the wire | 920 ns (115 byte-times @ 125 MHz) |

The generator produces frames roughly **3× faster** than the wire carries them, so
two approved orders spaced anywhere in the **308–920 ns** window were both
accepted, both serialised, and the second overran the FIFO. A bigger FIFO cannot
fix this: at a 3× production/drain ratio any finite depth overflows and depth only
widens the window. (The original "peak ≈ 61 B → 128 is ample" sizing was correct
for *one frame in isolation*, not for two overlapping orders.)

### The fix (applied)

Move the backpressure boundary to the FIFO and make the crossing lossless with a
**start gate**: the generator refuses to *begin* a frame it cannot fully fit,
instead of overrunning mid-frame.

1. `rtl/ip/cdc_fifo/cdc_fifo.sv` + `axis_cdc_fifo.sv` — new `ALMOST_FULL_THRESH`
   parameter and `s_axis_almost_full` output. Write-domain occupancy is derived by
   converting the synchronised Gray read pointer back to binary
   (`wbin − gray2bin(wq2_rgray)`); because that pointer lags, occupancy is
   over-estimated and the flag is conservative (asserts early, never optimistic).
2. `rtl/tx_gen/outbound_tx_generator.sv` — new `fifo_has_room` input; the FSM
   accepts a trade only while it is high, and
   `assign s_axis_trade_tready = (state == IDLE) && fifo_has_room;`.
3. `rtl/top/commontrader_top.sv` — the TX FIFO is instanced with
   `ALMOST_FULL_THRESH = TX_FRAME_BYTES (77)`, and its `s_axis_almost_full` drives
   the generator's `fifo_has_room` (inverted). The 128-deep FIFO is kept: the gate
   needs depth ≥ one frame, and 128 is the smallest power of two ≥ 77.

The generator now paces itself to the wire; orders it cannot send are dropped
**cleanly** at the gateway and counted by `order_drop_count` (the ceiling in L4) —
never truncated mid-frame. Because the drop stays at that lossy boundary, no
back-pressure propagates into the cut-through ingress path.

### Verification

- `axis_cdc_fifo_tb` **T7** — `almost_full` asserts exactly below the free-entry
  threshold and clears on drain.
- `outbound_tx_generator_tb` **T3** — the generator stalls while there is no room
  (no bytes emitted) and resumes the instant room appears.
- `commontrader_crv_tb` **C1** — no overflow across seeds 1–20 (previously failed
  on seeds 1 and 3); **C2** still confirms the clean drop path fires. Reproduce
  with `./sim/regression_crv.sh`.

### Pinned by

`commontrader_crv_tb`, check **C1** — now a hard invariant that passes, and fails
again the moment an overflow reappears.

---

## L2 — Sustained order rate is ~1000/s, not the wire ceiling

**Severity: documentation.** No malfunction; the throughput figure quoted in the
design report would be wrong by three orders of magnitude.

### Evidence

`rtl/risk_gateway/pre_trade_risk_gateway.sv` adds **one** token per
`RATE_PERIOD`:

```systemverilog
parameter int RATE_TOKENS = 16,          // bucket depth
parameter int RATE_PERIOD = 250_000      // 1 ms @ 250 MHz
...
tokens_to_add = refill_pulse + refund_pulse;   // refill_pulse is 1 cycle in 250_000
```

| Limit | Rate |
|---|---|
| Token bucket, sustained | **1,000 orders/s** |
| Token bucket, burst | 16 |
| 1 Gbps Ethernet wire ceiling | 1,090,000 orders/s |
| TX Generator serialiser | 3,250,000 orders/s |

Confirmed empirically: the CRV bench produces only 12–16 orders in a 323 µs run
before the bucket empties, and no amount of additional stimulus raises it.

### Consequence

**The Risk Gateway, not the network, is the throughput bottleneck** — by a factor
of about 1,090. Any claim that the platform sustains ~1 M orders/s is describing
the wire, not the system.

It also means L1's drop path cannot be provoked by sustained load: the rate
limiter throttles long before the TX Generator becomes the constraint. The drops
that *are* observed come from ordinary traffic where two orders happen to land
inside one serialisation window.

### Resolved: 1 token/ms is intended

The Detailed Design Report confirms it: the FastAPI/logging subsystem is sized
for **exactly 1000 orders/s** (4000 audit records/s), so the token bucket (1
token per 1 ms = 1000/s sustained) is a deliberate design point, not an
oversight. No change needed. Anyone quoting the ~1.09 M/s wire ceiling as the
system's order rate is still wrong — the binding limit is this rate limiter.

---

## L3 — Two of the six risk checks are not implemented

`pre_trade_risk_gateway.sv` declares `viol_crc` and `viol_blacklist` but drives
neither; both bits are hardwired to `1'b0` in the violations vector. Four of the
six required checks are live (quantity, order value, rate limit, kill switch).

The parser's `r_valid` checksum output is correspondingly left unconnected at the
top level, and `rx_error` is wired through a proper CDC synchroniser but has no
effect.

**Pinned by** `commontrader_top_tb`, check **T9** — which proves `rx_error`
reaches the core domain and then asserts the order is *still emitted*. When
`viol_crc` is enabled, T9 fails and its expectation is what needs flipping.

Note that even once implemented, cut-through forwarding means a trade derived
from an early message in a packet can leave before the end-of-packet CRC is
known. Closing that hole entirely would require holding trades until packet end,
costing ~5.9 µs and contradicting FS-1.

---

## L4 — Approved orders can be dropped without backpressure

The Risk Gateway has no `tready` input and the Alpha Engine fires on every
qualifying `tob_updated`, so an approved trade arriving while `trade_tready` is
low is lost. Since the L1 fix, `trade_tready` is low both while the TX Generator
is serialising a frame **and** while the TX CDC FIFO cannot hold another one, so
the generator paces itself to the wire and the excess is dropped here.

This is a real ceiling rather than a bug to paper over — see L2 for why the
binding constraint is actually the rate limiter. Losses are counted by
`order_drop_count` at the top level so they are observable rather than silent.
This is exactly the clean drop L1's fix relies on: pressure stops at this lossy
boundary and never reaches the cut-through ingress path.

**Pinned by** `commontrader_crv_tb`, check **C2**, which asserts the drop path is
actually exercised (3–6 drops per run).
