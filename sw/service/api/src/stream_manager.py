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
    copy of each per-second PnL sample plus a terminal event.

The blocking ``engine.run(callback)`` executes on a dedicated daemon thread
(the C++ hot loop releases the GIL), so the asyncio event loop stays free. The
engine callback pushes snapshots into a thread-safe queue that the async
generator drains.
"""

from __future__ import annotations

import asyncio
import json
import queue
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Dict, Optional

from config import (
    ONLINE_ITCH_ADDRESS,
    ONLINE_ITCH_PORT,
    ONLINE_OUCH_PORT,
    ONLINE_STREAM_TIME_SCALE,
    engine_sim,
)

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

    None of these socket details are ever surfaced to the client.
    """
    cfg = engine_sim.OnlineConfig()
    cfg.itch_address = ONLINE_ITCH_ADDRESS
    cfg.itch_port = ONLINE_ITCH_PORT
    cfg.ouch_port = ONLINE_OUCH_PORT
    cfg.ouch_transport = engine_sim.OuchTransport.UDP  # matches the FPGA
    cfg.time_scale = ONLINE_STREAM_TIME_SCALE  # ~1 telemetry event / wall-clock sec
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

    # --- runs on the engine's daemon thread -------------------------------
    def _on_sample(
        self, ts_ns: int, realized: float, unrealized: float, position: float
    ) -> None:
        try:
            self.events.put_nowait(
                {
                    "type": "pnl",
                    "timestamp_ns": ts_ns,
                    "realized_pnl": realized,
                    "unrealized_pnl": unrealized,
                    "position_size": position,
                }
            )
        except queue.Full:
            pass  # slow/absent client: drop this sample, never block the engine

    def _run(self) -> None:
        try:
            result = engine_sim.OnlineSimulation(self.data_file, self.cfg).run(
                self._on_sample
            )
            self.events.put(
                {
                    "type": "complete",
                    "data_file": self.data_file,
                    "total_trades": result.total_trades,
                    "compute_time_us": result.compute_time_us,
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
            # Reap the engine thread if it's already finishing; it's a daemon
            # thread either way, so a disconnected client can't leak it past
            # process exit.
            session.join(timeout=1.0)
            self.remove(session.session_id)


# Module-level singleton shared by the route handlers.
stream_manager = StreamManager()
