"""Live telemetry streaming for the online simulation.

Keeps the SSE / threading machinery out of the route handlers. The design is a
two-step handshake so browsers can use the native ``EventSource`` (which is
GET-only):

    POST /simulate/online/stream            -> create a session, return its id
    GET  /simulate/online/stream/{id}       -> attach an SSE stream to it

Two independent planes are involved:
  * South-bound (engine <-> exchange/FPGA): ITCH/UDP + OUCH/TCP, handled inside
    the C++ engine and never exposed here.
  * North-bound (server -> browser): the SSE stream produced here, carrying a
    copy of each per-second PnL sample (plus the current top-of-book, L1:
    best_bid/best_ask) and a terminal event with the full run (same shape as
    the blocking endpoints' SimulationResponse).

The blocking ``engine.run(callback)`` executes on a dedicated daemon thread
(the C++ hot loop releases the GIL), so the asyncio event loop stays free. The
engine callback pushes snapshots into a thread-safe queue that the async
generator drains.
"""

from __future__ import annotations

import asyncio
import json
import logging
import queue
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Dict, Optional

import db
from config import (
    ONLINE_STREAM_ITCH_ADDRESS,
    ONLINE_STREAM_ITCH_PORT,
    ONLINE_STREAM_OUCH_PORT,
    ONLINE_STREAM_TIME_SCALE,
    engine_sim,
)
from metrics import compute_summary_metrics

# Sentinel enqueued after the run ends so the consumer knows to stop.
_DONE = object()

# Bound on queued-but-undelivered samples. Telemetry is ~1/sec, so this is
# ample headroom; if a client can't keep up we drop rather than grow memory.
_QUEUE_MAXSIZE = 1024

# Sessions created but never attached to a stream are reaped after this long.
_SESSION_TTL_S = 300.0

# Poll cadence while the queue is momentarily empty.
_POLL_INTERVAL_S = 0.1

# Emit an SSE keep-alive comment after this many idle poll cycles (~10s).
_KEEPALIVE_TICKS = 100


def build_online_config() -> Any:
    """Build the server-side engine transport/pacing config for a stream run.

    Loopback, not the FPGA hardware addressing -- this is a software-only
    live view for the browser (see the config.py comment on
    ONLINE_STREAM_ITCH_ADDRESS). None of these socket details are ever
    surfaced to the client.
    """
    cfg = engine_sim.OnlineConfig()
    cfg.itch_address = ONLINE_STREAM_ITCH_ADDRESS
    cfg.itch_port = ONLINE_STREAM_ITCH_PORT
    cfg.ouch_port = ONLINE_STREAM_OUCH_PORT
    cfg.time_scale = ONLINE_STREAM_TIME_SCALE
    return cfg


@dataclass
class StreamSession:
    """One online-simulation run and its telemetry queue."""

    session_id: str
    data_file: str
    cfg: Any
    created_at: float = field(default_factory=time.monotonic)
    events: "queue.Queue[Any]" = field(
        default_factory=lambda: queue.Queue(maxsize=_QUEUE_MAXSIZE)
    )
    _thread: Optional[threading.Thread] = None
    _started: bool = False
    _engine: Optional[Any] = None  # set once _run() constructs it

    @property
    def started(self) -> bool:
        return self._started

    def start(self) -> None:
        """Launch the engine on a daemon thread (idempotent)."""
        if self._started:
            return
        self._started = True
        self._thread = threading.Thread(
            target=self._run, name=f"online-sim-{self.session_id[:8]}", daemon=True
        )
        self._thread.start()

    def join(self, timeout: Optional[float] = None) -> None:
        if self._thread is not None:
            self._thread.join(timeout)

    def stop(self) -> bool:
        """Request an early stop (e.g. the UI's Stop Simulation button, or a
        disconnected client). Just an atomic store on the C++ side (see
        OnlineSimulation::stop()) -- safe to call from any thread, and a
        no-op if the engine hasn't been constructed yet (session created but
        never started) or has already finished. run() unwinds through its
        normal end-of-file path either way, so the client still gets a
        regular "complete" event with whatever was collected so far.
        Returns whether there was a live engine to stop.
        """
        if self._engine is None:
            return False
        self._engine.stop()
        return True

    # --- runs on the engine's daemon thread -------------------------------
    def _on_sample(
        self,
        ts_ns: int,
        realized: float,
        unrealized: float,
        position: float,
        best_bid: float,
        best_ask: float,
    ) -> None:
        try:
            self.events.put_nowait(
                {
                    "type": "pnl",
                    "timestamp_ns": ts_ns,
                    "realized_pnl": realized,
                    "unrealized_pnl": unrealized,
                    "position_size": position,
                    "best_bid": best_bid,
                    "best_ask": best_ask,
                }
            )
        except queue.Full:
            pass  # slow/absent client: drop this sample, never block the engine

    def _log_run(self, started_at_ns: int, result: Any) -> None:
        """Persist a completed streaming run to the database (FS-15).

        Best-effort, same as routes.py's _log_run: a logging failure must
        never take down an otherwise-successful stream.
        """
        try:
            db.log_run(
                data_file=self.data_file,
                mode="online",
                started_at_ns=started_at_ns,
                compute_time_us=result.compute_time_us,
                total_trades=result.total_trades,
                trades=result.trades,
                pnl_curve=result.pnl_curve,
            )
        except Exception:  # noqa: BLE001 - logging must never break the stream
            logging.getLogger(__name__).exception("Failed to persist run to database")

    def _run(self) -> None:
        started_at_ns = time.time_ns()
        try:
            self._engine = engine_sim.OnlineSimulation(self.data_file, self.cfg)
            result = self._engine.run(self._on_sample)
            self._log_run(started_at_ns, result)
            metrics = compute_summary_metrics(result.pnl_curve, result.compute_time_us)
            self.events.put(
                {
                    "type": "complete",
                    "data_file": self.data_file,
                    "total_trades": result.total_trades,
                    "compute_time_us": result.compute_time_us,
                    "trades": [
                        {
                            "timestamp_ns": t.timestamp_ns,
                            "side": t.side,
                            "price": t.price,
                            "size": t.size,
                        }
                        for t in result.trades
                    ],
                    "pnl_curve": [
                        {
                            "timestamp_ns": p.timestamp_ns,
                            "realized_pnl": p.realized_pnl,
                            "unrealized_pnl": p.unrealized_pnl,
                            "position_size": p.position_size,
                        }
                        for p in result.pnl_curve
                    ],
                    "metrics": metrics.model_dump(),
                }
            )
        except Exception as exc:  # noqa: BLE001 - forward engine errors to client
            self.events.put({"type": "error", "detail": str(exc)})
        finally:
            self.events.put(_DONE)


class StreamManager:
    """Registry of active streaming sessions."""

    def __init__(self) -> None:
        self._sessions: Dict[str, StreamSession] = {}
        self._lock = threading.Lock()

    def create(self, data_file: str, cfg: Any) -> StreamSession:
        """Register a new (not-yet-started) session and return it."""
        self._reap_stale()
        session = StreamSession(
            session_id=uuid.uuid4().hex, data_file=data_file, cfg=cfg
        )
        with self._lock:
            self._sessions[session.session_id] = session
        return session

    def get(self, session_id: str) -> Optional[StreamSession]:
        with self._lock:
            return self._sessions.get(session_id)

    def remove(self, session_id: str) -> None:
        with self._lock:
            self._sessions.pop(session_id, None)

    def _reap_stale(self) -> None:
        """Drop sessions that were created but never attached to a stream."""
        now = time.monotonic()
        with self._lock:
            stale = [
                sid
                for sid, s in self._sessions.items()
                if not s.started and (now - s.created_at) > _SESSION_TTL_S
            ]
            for sid in stale:
                self._sessions.pop(sid, None)

    async def event_stream(
        self, session: StreamSession, request: Any
    ) -> AsyncIterator[str]:
        """Async generator yielding SSE frames for a session.

        Starts the engine on first attach, then drains telemetry until the run
        completes or the client disconnects. The session is removed when done.
        """
        session.start()
        idle_ticks = 0
        try:
            while True:
                try:
                    evt = session.events.get_nowait()
                except queue.Empty:
                    if await request.is_disconnected():
                        break
                    idle_ticks += 1
                    if idle_ticks >= _KEEPALIVE_TICKS:
                        idle_ticks = 0
                        yield ": keep-alive\n\n"
                    await asyncio.sleep(_POLL_INTERVAL_S)
                    continue

                idle_ticks = 0
                if evt is _DONE:
                    break
                yield f"data: {json.dumps(evt)}\n\n"
        finally:
            # Whatever ended this loop -- a disconnected client, the run
            # finishing on its own, or an explicit stop request racing us
            # here -- ask the engine to stop. A no-op if it's already done;
            # otherwise this is what actually cuts a disconnected client's
            # run short instead of letting it keep going in the background
            # until the input file is exhausted.
            session.stop()
            session.join(timeout=1.0)
            self.remove(session.session_id)


# Module-level singleton shared by the route handlers.
stream_manager = StreamManager()
