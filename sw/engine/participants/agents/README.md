# Agents

Built-in participants that populate the simulated market. Empty for now — this
is where tickets 11–18 land:

| Ticket | Agent | What it does |
|---|---|---|
| 11 | `fair_value` | per-symbol correlated random walk; the price the others reference |
| 12 | `background_flow` | zero-intelligence flow, the bulk of the book |
| 13 | `market_maker` | quotes around fair value, skews on inventory |
| 14 | `noise_trader` | random small market orders |
| 15 | `momentum` | chases recent trades |
| 16 | `institutional` | VWAP/TWAP slicer working a large parent order |
| 17 | `news` | jumps fair value; slow makers get picked off |
| 18 | `arb` | cross-venue taker (needs ticket 21, multi-venue books) |

Each is a `Participant` subclass: override the callbacks you need, act through
`send_limit` / `send_market` / `cancel` / `set_timer`. Nothing here is known to
the engine — `simcore/` only ever sees a `Participant*`, so an agent is added
by registering it with the scheduler and nothing else.

Use `Scheduler::rng()` for any randomness, never a generator of your own, or
the run stops being reproducible from its seed. Derive values from `rng()()`
directly rather than through `std::*_distribution`, which differs between
standard libraries — see the note in `simcore/include/scheduler.h`.
