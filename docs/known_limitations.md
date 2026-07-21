# Known Limitations

Defects and design gaps that are **understood, measured, and deliberately not
fixed** at the time of writing. Each entry records what it is, how it was found,
what it costs, and what fixing it would take.

Anything in this file is pinned by a testbench check so it cannot be forgotten.
When a limitation is fixed, the corresponding check **fails** and points at the
expectation that needs updating.

---

## L1 — TX CDC FIFO overflows and corrupts outbound frames

**Severity: high.** Reachable in ordinary traffic. Silently truncates Ethernet
frames on the wire.

### Evidence

Found by `tb/top/commontrader_crv_tb.sv` (constrained-random integration bench),
reproducible on 3 of 4 seeds:

```
TX FIFO OVERFLOW  byte_idx=51  wbin=78  rbin=206  occ=128  macstate=2
[FAIL] egress frame 7 length 78, expected 103
```

The FIFO is genuinely full (128/128) while the TX Generator is at byte 51 of a
77-byte packet. The bytes it writes during the overflow are lost, and the TX MAC
emits a truncated frame.

Observed with two approved orders **444 ns apart** — normal Phase A traffic, not
an artificial burst.

### Root cause

The backpressure boundary is in the wrong place.
`rtl/tx_gen/outbound_tx_generator.sv`:

```systemverilog
assign s_axis_trade_tready = (state == IDLE);
```

That reflects only the TX Generator's own serialiser state. It says nothing
about whether the downstream TX CDC FIFO can absorb another 77 bytes.

| | Duration |
|---|---|
| TX Gen serialises one packet | 308 ns (77 B @ 250 MHz) |
| A full Ethernet frame occupies the wire | 920 ns (115 byte-times @ 125 MHz) |

Two approved orders spaced anywhere in the **308–920 ns** window are therefore
both accepted, both serialised, and the second overruns the FIFO.

### Why a bigger FIFO does not fix it

TX Gen produces frames roughly **3× faster** than the wire can carry them. Any
finite depth overflows under sustained load; increasing `ADDR_W` only widens the
window before it happens. The earlier depth calculation (peak ≈ 61 bytes → 128 is
ample) was correct for *one frame in isolation* and does not hold once two orders
overlap.

### Fix, when someone takes it

1. Expose write-domain free space from `axis_cdc_fifo` — an `almost_full` flag
   with a threshold of ≥ 77 entries is enough. The occupancy is already computed
   internally from `wbin` and the synchronised read pointer.
2. Gate the TX Generator's ready on it:
   ```systemverilog
   assign s_axis_trade_tready = (state == IDLE) && fifo_has_room;
   ```

This converts silent frame corruption into a clean drop, already counted by
`order_drop_count`. It touches `axis_cdc_fifo` and `outbound_tx_generator` plus
their unit benches.

### Pinned by

`commontrader_crv_tb`, check **C1**. The bench reports `KNOWN GAP L1` when the
overflow occurs and does not count the resulting frame defects as failures.
Frame defects **without** an overflow are still hard failures. Once the fix
lands, C1 stops reporting and the frame checks tighten automatically.

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

### Open question for the Risk Gateway's owner

Whether 1 token/ms is intended. If the intent was "16 orders per millisecond",
the refill needs to add `RATE_TOKENS` per period, or `RATE_PERIOD` should be
`250_000/16`. Not changed here — this is a policy decision, not a bug fix.

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
qualifying `tob_updated`, so an approved trade arriving while the TX Generator is
serialising is lost.

This is a real ceiling rather than a bug to paper over — see L2 for why the
binding constraint is actually the rate limiter. Losses are counted by
`order_drop_count` at the top level so they are observable rather than silent.

**Pinned by** `commontrader_crv_tb`, check **C2**, which asserts the drop path is
actually exercised (3–6 drops per run).
