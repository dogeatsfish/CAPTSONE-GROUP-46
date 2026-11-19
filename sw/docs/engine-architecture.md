# Engine Architecture

How the simulation engine is put together: who holds what, what moves between
them, and why the timing works the way it does.

The engine lives in `sw/engine/`. Everything below is C++; the same objects are
exposed to Python through pybind11 (`bindings/src/bindings.cpp`) under the
module name `engine_sim`.

---

## The one-paragraph version

Participants don't run on their own. A **Scheduler** owns a priority queue of
timestamped work, pops the earliest item, and calls whoever that item belongs
to. A participant reacting to an event puts a new item on the queue stamped
*later* — by exactly its own latency. The **OrderBook** matches orders and
returns a list of **events**, which the scheduler routes back to participants,
again delayed by each one's latency. Nothing happens instantaneously and
nothing happens in parallel.

---

## Components

```mermaid
flowchart TB
    subgraph Participants["Participants (you write these)"]
        P1["Bot A<br/><i>Participant subclass</i>"]
        P2["Bot B"]
        P3["StrategyParticipant<br/><i>wraps the user's Strategy</i>"]
    end

    subgraph Sched["Scheduler — owns the clock"]
        Q[("Priority queue<br/>min-heap on (time_ns, seq)")]
        CLK["now_ns_ · monotonic<br/>never moves backwards"]
        RNG["rng_ · mt19937_64<br/>seeded once per run"]
        SLOTS["slots_ : id → Slot"]
    end

    subgraph SlotDetail["Slot — one per registered participant"]
        SP["Participant* participant<br/><i>a pointer, not a copy</i>"]
        SL["LatencyProfile latency<br/>in_ns · out_ns · compute_ns"]
        SA["Account account<br/>position · cash · PnL · fills"]
    end

    BOOK["OrderBook<br/>bids/asks : price → deque&lt;Order&gt;<br/>+ id → price index per side"]

    P1 & P2 & P3 -- "send_limit / cancel / set_timer<br/>(scheduled at now + compute + out_ns)" --> Q
    Q -- "pop earliest" --> CLK
    CLK -- "BookAction: apply it" --> BOOK
    BOOK -- "BookEvents<br/>Accepted · Trade · fills · Cancelled" --> SLOTS
    SLOTS -- "account updated NOW" --> SA
    SLOTS -- "delivery queued at now + in_ns" --> Q
    Q -- "DeliverEvent / DeliverBook / Timer<br/>→ on_fill, on_trade, on_book_update, on_timer" --> P1 & P2 & P3
    SLOTS -.-> SlotDetail
```

### What each box holds

| Component | Owns | Key properties |
|---|---|---|
| **Scheduler** | the queue, the clock, the book, every Slot, the RNG | `now_ns_` only moves forward; `next_order_id_` starts at `1 << 40` so engine-assigned ids can never collide with a data file's; `book_depth_` (default 5) sets how many L2 levels get broadcast |
| **Slot** | one participant's registration | `Participant*` (a pointer — the scheduler does **not** copy or own your bot), `LatencyProfile`, `Account`. Looked up by `ParticipantId` (a `uint32_t` alias) |
| **LatencyProfile** | where a participant sits | `per_exchange : id → LatencyLeg{in_ns, out_ns}`, a `fallback` leg, and `compute_ns`. Presets: Retail / Direct / Colo / Microwave |
| **Account** | the exchange's record of a participant | position, average entry, cash, realized + unrealized PnL, open orders, fill history, reject count. Updated by `on_event()` the instant a fill happens |
| **OrderBook** | the live book | `std::map<price, deque<Order>>` per side (sorted, so `begin()` is the best price; the deque preserves time priority), plus an `unordered_map<order_id, price>` index per side for O(1) lookup by id |
| **Participant** | your strategy's state | abstract base. Holds a `Scheduler*` back-pointer and its own `ParticipantId`, both set by `add_participant()` through a `friend` declaration |

> **Why the back-pointer:** `send_limit()` has to reach the scheduler to queue
> an order. The participant stores the scheduler's *address*, and the scheduler
> stores the participant's — two pointers crossing, nothing nested, no copies.

---

## The queue

A `std::priority_queue<Entry, std::vector<Entry>, Later>` — a binary heap in a
vector. `std::priority_queue` is a *max*-heap, so the `Later` comparator
deliberately reports a later time as "smaller", which turns it into a min-heap:

```cpp
struct Later {
    bool operator()(const Entry& a, const Entry& b) const {
        if (a.time_ns != b.time_ns) return a.time_ns > b.time_ns;
        return a.seq > b.seq;        // tie-break: push order
    }
};
```

That `seq` tie-break is what makes a run **reproducible**. Two things stamped
for the same nanosecond always come out in the order they were pushed, so the
same seed gives byte-identical results on every machine.

### Four kinds of Entry

| Kind | Created by | What popping it does |
|---|---|---|
| `BookAction` | a participant's `send_*` / `cancel` / `reduce` / `replace`, or the market feed | applies the action to the `OrderBook` and publishes the resulting events |
| `DeliverEvent` | `publish()`, one per recipient per event | calls `on_trade` / `on_fill` / `on_order_update` on that participant |
| `DeliverBook` | `publish()`, after every book action | calls `on_book_update` with a shared L2 snapshot |
| `Timer` | a participant's `set_timer(delay)` | calls `on_timer` |

They're separate kinds because they happen at **different times** and go to
**different people**. The book action lands at one instant; each participant
hears about it at its own instant. Collapsing them into one entry would make
latency impossible to express.

---

## Timing: one order, end to end

A bot with `in_ns = 1000`, `out_ns = 1000`, `compute_ns = 500` reacting to a
trade that happens at **t = 0**:

```mermaid
sequenceDiagram
    autonumber
    participant Q as Priority queue
    participant S as Scheduler
    participant B as OrderBook
    participant A as Account in Slot
    participant Bot as Bot

    Note over B: t=0 — a trade occurs
    B->>S: BookEvents (Trade, fills)
    S->>A: update immediately (t=0)
    S->>Q: push DeliverEvent @ t=1000 (now + in_ns)

    Note over Q,Bot: ...scheduler pops other work meanwhile...

    Q->>Bot: t=1000 — on_trade(event)
    Bot->>S: send_limit(...)
    S->>Q: push BookAction @ t=2500<br/>(1000 + compute 500 + out 1000)

    Q->>B: t=2500 — order reaches the book
    B->>S: BookEvents (Accepted, PartialFill, ...)
    S->>A: update immediately (t=2500)
    S->>Q: push DeliverEvent @ t=3500 (+ in_ns)
    Q->>Bot: t=3500 — on_fill(event)
```

Two things to take from that diagram:

1. **The bot's order lands 2500 ns after the trade it reacted to.** A colocated
   competitor with 5 µs legs and a retail bot with 25 ms legs run identical
   code and get completely different fills. That's the whole point of the
   latency model.
2. **The account is updated at t = 2500, but `on_fill` arrives at t = 3500.**
   `account()` is the *exchange's* live view, not a latency-delayed one. A bot
   reading it between those two moments sees a position its callbacks haven't
   told it about yet. This is a known simplification.

---

## Event routing

One match produces three events, and they do not all go to the same place:

```mermaid
flowchart LR
    M["A match occurs"] --> T["Trade"]
    M --> TF["taker fill ('T')"]
    M --> MF["maker fill ('M')"]

    T --> EV["every registered participant<br/><i>on_trade</i>"]
    TF --> AG["the aggressor only<br/><i>on_fill</i>"]
    MF --> RS["the resting order's owner only<br/><i>on_fill</i>"]

    M --> BK["L2 book update<br/><i>on_book_update</i>"]
    BK --> OTH["everyone EXCEPT the actor"]
```

| Event | Recipients |
|---|---|
| `Trade` | everyone — this is the public tape |
| `PartialFill` / `Filled` | the order's owner only (looked up in `order_owner_`) |
| `Accepted` / `Rejected` | the participant who sent it |
| `Reduced` / `Cancelled` | the order's owner |
| L2 book snapshot | everyone except the participant whose action caused it |

If the resting side belonged to the recorded market feed rather than a bot,
there is no maker fill to deliver — only the Trade and the taker fill go out.

---

## Where a run comes from

`OfflineSimulation` is a thin driver around the scheduler. It does **not**
touch the order book itself:

```mermaid
flowchart LR
    F[("MBO .bin file<br/>34-byte records")] --> L["OfflineSimulation::run()<br/>buffered reader"]
    L -- "holds next record back<br/>until the queue catches up" --> SCH["Scheduler"]
    SCH --> R["SimulationResult<br/>trades · pnl_curve · events · book_snapshots"]
```

The loop alternates:

- if the queue has something due **at or before** the next file record, step the
  scheduler;
- otherwise schedule that record as a `BookAction` from participant 0
  (`MARKET_FEED`) and read the next one.

The player's strategy is participant 1 (`PLAYER`), wrapped in a
`StrategyParticipant` adapter that builds an `L1State` from the L2 update,
calls `Strategy::sync_account(...)`, then `on_market_update(...)`.

`OnlineSimulation` is **not** on the scheduler. It is paced by the wall clock
and the board replies when it replies, so simulated-time jumps don't apply. It
drives the `OrderBook` directly and keeps its own `Account` so the PnL math is
shared.

---

## Determinism

A run is a pure function of its seed. Three things guarantee it:

1. **Single-threaded.** The scheduler calls one participant at a time, as a
   normal function call. Nothing pushes to the queue while it's being popped,
   so there are no locks and no OS-scheduling nondeterminism.
2. **Total ordering.** `(time_ns, seq)` has no ties.
3. **One RNG.** `Scheduler::rng()` is the run's only randomness source.

> **Caveat:** `std::mt19937_64` produces identical output everywhere for a given
> seed, but `std::uniform_real_distribution` and friends do **not** — each
> standard library implements them differently. Derive values from `rng()()`
> directly if you need cross-platform reproducibility.

---

## Known simplifications

These are deliberate, not bugs — but they shape what conclusions a run supports.

- **One symbol, one exchange.** `per_exchange` latency exists but is never
  exercised; adding symbols means a book per symbol and per-symbol positions in
  `Account`.
- **No duplicate-order-id rejection and no ownership check on cancels.** A
  participant can cancel an id it doesn't own.
- **Accounts and `queue_position()` are live views**, not latency-delayed.
- **Shorting is unrestricted** — no borrow, no margin, no buying-power check.
  Position limits exist only where a strategy imposes them on itself.
- **The actor gets no book update for its own action**; it has to infer the new
  book from its own fills.
- **Snapshots hold the book only** — not accounts, not order ownership — so
  `restore()` is a book-level seek, not a full run rewind.
