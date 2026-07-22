# Verification Flow

Everything needed to run and extend the CommonTrader testbenches.

```
./sim/run_all_tb.sh                        # everything (~0.7 s warm, ~78 s cold)
./sim/run_all_tb.sh order_book_crv         # just one bench
./sim/run_all_tb.sh +SEED=42               # every bench, specific seed
./sim/run_all_tb.sh --sim xsim             # everything under Vivado (xsim)
./sim/regression_crv.sh                    # both CRV benches across seeds 1..20 (xsim)
./sim/clean.sh                             # reclaim build artifacts
```

Running under Vivado xsim (command line **and** GUI): **[`vivado/README.md`](../vivado/README.md)**.

Full plusarg reference and multi-seed soak recipes: **[section 2](#2-running-tests-and-soaking-seeds)**.

---

## 1. How the pieces fit together

The design goal is that **Verilator and xsim run the identical bench list from the
identical source lists**. If a bench passes in one and fails in the other, that is
a real RTL or testbench portability bug — never a difference in what got compiled.

```
        sim/benches.sh            sim/filelists/<bench>.f
     (what benches exist,          (which sources build
      what their top module         each bench, in order)
      is called)
              \                         /
               \                       /
                +---------+-----------+
                          |
         both runners read the same two inputs
                          |
          +---------------+---------------+
          |                               |
  sim/run_verilator.sh            sim/run_xsim.sh
  (verilator --binary)            (xvlog -> xelab -> xsim)
          |                               |
          +---------------+---------------+
                          |
                  sim/run_all_tb.sh
              (loops the manifest, parses
               each bench's summary line,
               exits non-zero on any failure)
                          |
                  sim/run_<bench>_tb.sh
              (one-line convenience wrappers)
```

### `sim/benches.sh`

Pure data, sourced not executed. Two things:

- `BENCH_TOP[<name>]` — maps a bench name to its **top module**. The runners need
  this because Verilator wants `--top-module` and xelab wants `-top`, and the
  module name rarely matches the file name (`rx_mac` → `tb_rx_mac_core`).
- `BENCH_ORDER` — the regression order. Unit benches first, full-chip last, so a
  broken block is reported by its own bench rather than by the integration run.

### `sim/filelists/<bench>.f`

One source path per line, **in compile order** (packages before the modules that
import them). Plain text with no comments, because that is the intersection of
what `verilator -f` and `xvlog -f` both accept.

### `sim/run_verilator.sh <bench> [+PLUSARGS]`

Builds into `sim/obj_<bench>_tb/` and runs the binary. Notably it does **not**
define `SYNTHESIS`, so `rx_mac_core`'s IDDR stage, `tx_mac_core`'s ODDR stage and
`clk_rst_gen`'s MMCM all fall back to behavioural equivalents — no vendor
libraries needed.

### `sim/run_xsim.sh <bench> [+PLUSARGS] [--gui]`

Same inputs, `xvlog` → `xelab` → `xsim`. `--gui` builds the bench and opens the
xsim waveform viewer instead of running headless; `SYNTH=1` defines `SYNTHESIS`
and elaborates against the real `unisims_ver` primitives — useful for checking
the DDR stages before board bring-up.

> **Verified on Vivado 2025.2** — all 12 benches pass under xsim (173,400 checks,
> 0 failures in the default-seed run). Full xsim + Vivado-GUI setup, and the
> 2025.2 quirks the flow works around, are in
> **[`vivado/README.md`](../vivado/README.md)**.

### `sim/run_all_tb.sh`

Runs every bench in `BENCH_ORDER`, writing per-bench logs to `sim/logs/<sim>/`.
It also accepts plusargs and a bench subset — see
[section 2](#2-running-tests-and-soaking-seeds).

It keys off a single line every bench prints:

```
  <bench_name> : <N> checks, <M> failures
```

**A bench that builds and runs but prints no summary line is treated as a
FAILURE.** That is deliberate — otherwise a bench that silently stopped checking
anything would show up green.

### `sim/clean.sh [--all]`

Removes build dirs, logs and waveforms. Nothing it deletes is source. You do
**not** need it to pick up edits — Verilator emits `-MMD` dependency files, so
`make` already rebuilds exactly what changed. Clean for disk space (173 MB → 1 MB)
or before archiving, not out of habit.

---

## 2. Running tests and soaking seeds

### `run_all_tb.sh` arguments

```
./sim/run_all_tb.sh [--sim verilator|xsim] [-q] [+PLUSARG=value ...] [bench ...]
```

| Argument | Effect |
|---|---|
| *(none)* | every bench, Verilator |
| `--sim xsim` | every bench, Vivado xsim |
| `-q` | summary table only, no failure excerpts |
| `+NAME=value` | forwarded **verbatim to every bench that runs** |
| `<bench>` | run only the named bench(es); a typo fails immediately with the valid list |

Plusargs a bench does not read are simply ignored, so a global `+SEED=42` is safe
even though only the two constrained-random benches act on it.

### Plusargs by bench

| Bench | Plusarg | Default | Meaning |
|---|---|---|---|
| `order_book_crv` | `+SEED` | `0xC0FFEE01` | RNG seed |
| | `+NTXN` | `2000` | book transactions to generate |
| `integration_crv` | `+SEED` | `0xBEEF0001` | RNG seed |
| | `+NPKT_A` | `60` | phase A packets (mixed random traffic) |
| | `+NPKT_B` | `20` | phase B packets (minimum inter-frame gap) |
| | `+NPKT_C` | `30` | phase C packets (order-rate burst) |
| `replay` | `+FRAMES` | `sim/replay_frames.hex` | frame byte stream |
| | `+LENS` | `sim/replay_lens.hex` | per-frame lengths |
| | `+TOB` | `sim/replay_tob.hex` | expected top of book |

Every randomised bench **prints its seed on the first line of output and again in
the failure summary**, so a failing log always tells you how to reproduce it.

### Soak recipes

Both runners exit non-zero on failure, so `|| break` stops at the first bad seed
and leaves its log in place.

```bash
# One bench across several seeds -- the usual quick soak
for s in 1 42 777 31337; do
  ./sim/run_all_tb.sh -q order_book_crv +SEED=$s || break
done

# Whole regression across 20 seeds, stopping at the first failure
for s in $(seq 1 20); do
  echo "=== seed $s ==="
  ./sim/run_all_tb.sh -q +SEED=$s || { echo "FAILED at seed $s"; break; }
done

# Deep soak of one bench (minutes, not seconds)
./sim/run_order_book_crv_tb.sh +SEED=7 +NTXN=200000

# Both constrained-random benches, one seed
./sim/run_all_tb.sh order_book_crv integration_crv +SEED=777

# Reproduce a specific reported failure
./sim/run_order_book_crv_tb.sh +SEED=3237998081
```

### `regression_crv.sh` — the CRV seed regression (xsim)

For the two constrained-random benches specifically, `sim/regression_crv.sh` runs
the multi-seed sweep for you. Unlike the `|| break` recipes above it **does not
stop on the first failure** — it runs the whole range and reports which seeds
failed. Each bench is elaborated once and re-run per seed, so it is far quicker
than a rebuild-per-seed loop.

```bash
./sim/regression_crv.sh                 # both CRV benches, seeds 1..20
./sim/regression_crv.sh --seeds 1 100   # seeds 1..100
./sim/regression_crv.sh +NPKT_C=400     # forward extra plusargs to every run
```

xsim-only. Per-seed logs land in `sim/xsim_regression_<bench>/run_seed<N>.log`,
and the summary ends with a compact `failing seeds:` line. (`+SEED=1` and
`+SEED=3` were the standing repros of the TX CDC FIFO overflow before it was
fixed — L1 in `docs/known_limitations.md`; both pass now.)

### Reading the result

```
BENCH                            CHECKS    FAILS   STATUS
order_book_crv                   177988        0   PASS
```

Per-bench logs land in `sim/logs/<simulator>/<bench>.log`. A bench that builds
and runs but prints **no summary line** is reported as a failure, not a pass --
otherwise a bench that silently stopped checking anything would look green.

Some checks are labelled `KNOWN GAP` — a defect that is understood, documented in
`docs/known_limitations.md`, and deliberately not fixed. Those report loudly but
do not fail the regression, and they invert into real failures once the
underlying defect is fixed. (The TX CDC FIFO overflow, L1, was made a hard check
and then fixed — its invariant `C1` now passes and guards against regression.)

---

## 3. The benches

| Bench | Testbench | What it proves |
|---|---|---|
| `cdc_fifo` | `tb/ip/cdc_fifo/axis_cdc_fifo_tb.sv` | Gray-pointer CDC FIFO, full/empty corners |
| `rx_mac` | `tb/rx_mac/rx_mac_tb.sv` | RGMII ingress, preamble/L2/FCS stripping, CRC error flag |
| `tx_mac` | `tb/ip/tx_mac/tx_mac_core_tb.sv` | Ethernet framing, padding, FCS generation |
| `parser` | `tb/parser/cut_through_parser_tb.sv` | ITCH decode, order-reference table, UDP checksum |
| `order_book` | `tb/order_book/order_book_array_tb.sv` | Directed book transactions, top-of-book strobes |
| `order_book_crv` | `tb/order_book/order_book_crv_tb.sv` | **Constrained random** book torture vs a reference model |
| `alpha_engine` | `tb/alpha_engine/alpha_engine_core_tb.sv` | EMA mean-reversion strategy, FS-7 cycle budget |
| `risk_gateway` | `tb/risk_gateway/risk_gateway_tb.sv` | Quantity/value/rate/kill-switch checks |
| `tx_gen` | `tb/tx_gen/outbound_tx_generator_tb.sv` | OUCH Enter Order encoding, IP/UDP wrapping |
| `integration` | `tb/top/commontrader_top_tb.sv` | **Full chip**, RGMII in → RGMII out, hand-built packets |
| `replay` | `tb/top/commontrader_replay_tb.sv` | **Full chip** with real recorded market data |
| `integration_crv` | `tb/top/commontrader_crv_tb.sv` | **Full chip, constrained random** — randomised traffic shape and timing, invariant checks |

The three that matter most, and why they are not redundant:

- **`integration`** proves one hand-built packet produces one correct OUCH order,
  field by field, through every block including both CDC FIFOs and both MACs.
- **`order_book_crv`** explores state space the directed benches cannot: 16-level
  sorted insert / tail eviction / shift-up-on-delete under randomised pressure,
  checked against a behavioural reference after **every** transaction.
- **`replay`** streams an actual recorded feed and cross-checks the book against
  an independent software model. Real data, real price distribution, real
  erroneous ticks.
- **`integration_crv`** randomises traffic shape and timing and checks invariants
  that need no golden model. This is what found the TX CDC FIFO overflow recorded
  as L1 in `docs/known_limitations.md` — **since fixed** (a write-side start gate
  on the TX FIFO); its invariant `C1` now passes and stands as a regression guard.

Benches pin known defects rather than hiding them: a check labelled `KNOWN GAP`
reports loudly, does not fail the regression, and inverts into a real failure the
moment the underlying defect is fixed. The TX CDC FIFO overflow (L1) went the full
route — `KNOWN GAP` → hard failure → fixed — and its check `C1` now passes, failing
again only if the defect returns. See `docs/known_limitations.md`.

---

## 4. The replay stimulus: `csv_to_itch.py` and the `.hex` files

The `.hex` files in `sim/` are **generated stimulus, not source.** They are
gitignored and rebuilt on demand.

### What the script does

The software team's pipeline emits an MBO (market-by-order) CSV. The hardware
expects ITCH messages inside MoldUDP64 inside UDP inside IPv4 inside Ethernet.
`csv_to_itch.py` bridges the two, and simultaneously runs a **reference order
book** so the testbench has something to check against.

```
sw/data_pipeline/data/synthetic_mbo_stream.csv
   |  timestamp, message_type, order_id, side, price, size
   |
   |  per row:
   |    'A' -> ITCH Add Order    (36 B)      'C' -> ITCH Order Delete (19 B)
   |    price * 10^4 -> uint32 (OUCH 5.0 has 4 implied decimals)
   |    order_id % N -> ITCH Stock Locate  (the CSV has NO symbol column)
   v
   batch --per-frame messages (default 8)
   |
   +--> MoldUDP64 header ---> UDP (+ checksum) ---> IPv4 ---> Ethernet (+ FCS)
   |                                                              |
   |                                                              v
   |                                                    replay_frames.hex
   |                                                    replay_lens.hex
   |
   +--> reference price-level book (mirrors order_book_array.sv,
        NOT a matching engine -- it never crosses trades)
                                                              |
                                                              v
                                                     replay_tob.hex
```

### The output files

| File | Format | Loaded into |
|---|---|---|
| `replay_frames.hex` | one byte per line, hex; all frames concatenated | `logic [7:0] fr_bytes[]` |
| `replay_lens.hex` | one frame length per line (4 hex digits) | `logic [15:0] fr_lens[]` |
| `replay_tob.hex` | one 128-bit word per line, `{bid_px, bid_qty, ask_px, ask_qty}`, **`NUM_ASSETS` lines per frame** | `logic [127:0] exp_tob[]` |
| `replay_meta.txt` | human-readable summary | — |

All three are read with `$readmemh`, which behaves identically in Verilator and
xsim. That is why the stimulus is a flat hex file rather than, say, a DPI call or
a CSV parsed in SystemVerilog.

**The frames do not contain the preamble.** `build_frame()` starts at the
destination MAC. The testbench prepends `7 x 0x55` + `0xD5` itself, because
preamble length is a property of the transmitter, not of the frame.

### Running it

```bash
python3 sim/csv_to_itch.py --events 4000 --out sim/replay
./sim/run_replay_tb.sh                    # uses whatever is in sim/
./sim/run_replay_tb.sh --events 4000      # regenerate, then run
```

Two flags exist because the corresponding decisions are **not settled** — see
`docs/hw_sw_interface.md`:

- `--symbols N` — how many Stock Locates to spread events across. The CSV has no
  symbol column at all, so any assignment is a test-harness choice.
- `--price-scale` — fixed-point multiplier, default `10^4`. At that scale the
  feed's maximum price leaves only 1.43x of uint32 headroom.

---

## 5. Writing a new bench

1. Write `tb/<block>/<name>_tb.sv`. It **must** print, once, at the end:

   ```systemverilog
   $display("  <name>_tb : %0d checks, %0d failures", checks, errors);
   ```

2. Add `sim/filelists/<bench>.f` listing its sources in compile order.
3. Add one line to `BENCH_TOP` and one to `BENCH_ORDER` in `sim/benches.sh`.
4. Optionally add a `sim/run_<bench>_tb.sh` wrapper (copy any existing one).

Both simulators pick it up. Nothing else to touch.

---

## 6. Portability rules — learned the hard way

Every one of these came from a bug that made a bench pass in one configuration
and fail in another. Follow them or the xsim migration will hurt.

**Never drive stimulus with a non-blocking assignment on a clock edge.**

```systemverilog
// WRONG -- races the DUT's capture flops
@(posedge clk); data <= value;

// RIGHT -- change the bus mid-phase, blocking
@(negedge clk); #2; data = value;
```

Whether the DUT flop sees the old or new value depends on the simulator's NBA
ordering, and Verilator's `--timing` scheduler resolves it opposite to xsim. On
the DDR RGMII bus this landed nibbles half a byte out of phase and every frame
decoded to garbage.

**Never sample combinational DUT outputs exactly on the active edge.** Sample on
the opposite edge (mid-cycle, everything settled, no `#delay` needed). Single
cycle pulses like `tlast` and `rx_error` read as 0 otherwise.

**Monitors must be `always` blocks, not `initial ... forever`.** Under `--timing`
the latter becomes a coroutine whose scoreboard writes were not reliably observed
by the test process. A bench whose result depends on `--trace` is a race.

**Monitors must only WRITE scoreboard state, never read what the test owns.**
A value written by a test task and read back inside a monitor process silently
optimises to a stale copy. Record in the monitor, compare in the test.

**Use `int` counters, not sticky `logic` flags, for cross-process state.** A
`logic` flag written by a monitor and read by the test can read as its reset
value — and the failure mode is a check that passes *vacuously*. A counter also
tells you how many times the condition fired.

**Mask signed types before widening.** `byte` is signed; `crc ^ frame_data[i]`
sign-extends anything `>= 0x80`. Write `crc ^ {24'h0, (frame_data[i] & 8'hFF)}`.

**Do not start a comment line with the word "verilator".** It is parsed as a
lint directive and fails the build.

---

## 7. Constrained random

`order_book_crv` uses `$urandom_range` with explicit constraint logic rather than
SystemVerilog `rand` / `constraint` classes. Verilator implements class
randomisation by shelling out to the **z3** SAT solver, which is not installed
and would become a hard dependency for everyone cloning this repo. `$urandom_range`
needs nothing, behaves identically under xsim, and is reproducible from a seed.

Seeds and transaction counts are plusargs; see
[section 2](#2-running-tests-and-soaking-seeds) for the full table and soak
recipes.

The bench prints what the stimulus actually **reached** (new-level inserts,
aggregations, tail evictions, full-book drops) as well as pass/fail, so a green
run that never exercised the interesting paths is visible rather than reassuring.
If you are running it under xsim only, the constraint blocks documented in the
bench header translate directly to real `constraint` syntax.
