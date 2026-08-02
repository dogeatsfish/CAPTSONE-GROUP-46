"""Persistent database logging for simulation runs (FS-15, partial scope).

Scope note: the design doc (docs, Compiler/FastAPI Subsystem section) describes
a six-table schema -- runs, book_snapshots, orders, order_events, fills,
metrics -- built around a full order-lifecycle blotter and periodic L2 book
snapshots. The engine's pybind11 surface (``engine_sim.SimulationResult``)
currently only returns ``trades`` and ``pnl_curve``, with no order-event
lifecycle (submit/ack/cancel/reject) or book-depth data exposed. Extending
that would mean changing the C++ matching engine / bindings, which is out of
scope here. This module persists what's actually available today -- one row
per completed run, its executed trades, and its PnL samples -- and leaves
book_snapshots/orders/order_events as a follow-up tracked in TODO.md.

Wired into the blocking /simulate and /simulate/online endpoints in
routes.py, and into the SSE streaming path (stream_manager.py) -- a run is
logged once the engine thread finishes, same best-effort pattern in both
places.
"""

from __future__ import annotations

import sqlite3
import threading
from typing import Any, Iterable

from config import DB_PATH

_SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    run_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    data_file       TEXT NOT NULL,
    mode            TEXT NOT NULL,      -- 'offline' | 'online'
    started_at_ns   INTEGER NOT NULL,   -- host wall-clock, ns since Unix epoch
    compute_time_us INTEGER NOT NULL,
    total_trades    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS fills (
    run_id       INTEGER NOT NULL REFERENCES runs(run_id),
    timestamp_ns INTEGER NOT NULL,
    side         TEXT NOT NULL,
    price        REAL NOT NULL,
    size         REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_fills_run ON fills(run_id);

CREATE TABLE IF NOT EXISTS metrics (
    run_id         INTEGER NOT NULL REFERENCES runs(run_id),
    timestamp_ns   INTEGER NOT NULL,
    realized_pnl   REAL NOT NULL,
    unrealized_pnl REAL NOT NULL,
    position_size  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_metrics_run ON metrics(run_id);
"""

# One process-wide lock serializes writes. FastAPI runs sync `def` route
# handlers in a thread pool, so concurrent /simulate requests are a real
# possibility; SQLite connections aren't safe to share across threads, and a
# fresh short-lived connection per call is simple and cheap enough for the
# end-of-run bulk-write pattern here (this is not the high-frequency
# streaming-write case the design doc's batching policy was written for).
_lock = threading.Lock()


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(_SCHEMA)
    return conn


def log_run(
    data_file: str,
    mode: str,
    started_at_ns: int,
    compute_time_us: int,
    total_trades: int,
    trades: Iterable[Any],
    pnl_curve: Iterable[Any],
) -> int:
    """Persist one completed run plus its trades/PnL samples.

    ``trades``/``pnl_curve`` are the engine's TradeRecord/PnLSnapshot objects
    (or anything duck-typing the same attributes). Returns the new run_id.
    """
    with _lock:
        conn = _connect()
        try:
            cur = conn.execute(
                "INSERT INTO runs "
                "(data_file, mode, started_at_ns, compute_time_us, total_trades) "
                "VALUES (?, ?, ?, ?, ?)",
                (data_file, mode, started_at_ns, compute_time_us, total_trades),
            )
            run_id = cur.lastrowid

            conn.executemany(
                "INSERT INTO fills (run_id, timestamp_ns, side, price, size) "
                "VALUES (?, ?, ?, ?, ?)",
                [(run_id, t.timestamp_ns, t.side, t.price, t.size) for t in trades],
            )
            conn.executemany(
                "INSERT INTO metrics "
                "(run_id, timestamp_ns, realized_pnl, unrealized_pnl, position_size) "
                "VALUES (?, ?, ?, ?, ?)",
                [
                    (run_id, p.timestamp_ns, p.realized_pnl, p.unrealized_pnl, p.position_size)
                    for p in pnl_curve
                ],
            )
            conn.commit()
            return run_id
        finally:
            conn.close()


def get_recent_runs(limit: int = 20) -> list[dict]:
    """Return the most recently persisted runs, newest first. No lock needed
    here -- WAL mode handles concurrent reads fine, unlike log_run's write."""
    conn = _connect()
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT run_id, data_file, mode, started_at_ns, compute_time_us, total_trades "
            "FROM runs ORDER BY run_id DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


def get_run(run_id: int) -> dict | None:
    """Return one run's summary plus its fills and PnL samples, or None if
    run_id doesn't exist."""
    conn = _connect()
    conn.row_factory = sqlite3.Row
    try:
        run_row = conn.execute(
            "SELECT run_id, data_file, mode, started_at_ns, compute_time_us, total_trades "
            "FROM runs WHERE run_id = ?",
            (run_id,),
        ).fetchone()
        if run_row is None:
            return None

        fills = conn.execute(
            "SELECT timestamp_ns, side, price, size FROM fills "
            "WHERE run_id = ? ORDER BY timestamp_ns",
            (run_id,),
        ).fetchall()
        metrics = conn.execute(
            "SELECT timestamp_ns, realized_pnl, unrealized_pnl, position_size "
            "FROM metrics WHERE run_id = ? ORDER BY timestamp_ns",
            (run_id,),
        ).fetchall()

        run = dict(run_row)
        run["fills"] = [dict(row) for row in fills]
        run["pnl_curve"] = [dict(row) for row in metrics]
        return run
    finally:
        conn.close()
