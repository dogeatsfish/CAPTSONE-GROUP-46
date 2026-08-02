"""Software strategy compile-and-run job runner.

Structured the same way as compile_manager.py's Vivado CompileJob: a job is
created (workspace + templated user_strategy.cpp written to disk), then
started on a background daemon thread, which here runs two subprocesses in
sequence -- compile (g++) then run (the freshly built binary) -- instead of
one. Log lines and the final result are pushed onto a thread-safe queue that
an SSE generator drains, using the same two-step "create, then attach"
handshake as the Vivado compile job and the online simulation stream.

ISOLATION AND ITS LIMITS. This is subprocess-level only (timeouts,
argument-list subprocess calls -- never a shell, confined per-job workspace
dir): no container, no resource caps, no restricted user. That is a lighter
tier than it might sound like next to the Vivado CompileJob, because the two
pipelines run fundamentally different things: Vivado *synthesizes*
SystemVerilog and never executes submitted source as a native process, while
this pipeline compiles submitted C++ into a real binary and *runs* it on the
host. "Just a function body" only holds if the body is actually confined to
that function -- see _validate_braces below, which rejects anything that
could close on_market_update early and splice arbitrary top-level C++ (e.g.
a static initializer that runs before main()) into the rest of the file. It
is a plain character count, not a real parser: braces inside a string
literal or comment are counted as if structural, which can reject some
legitimate submissions (fails safe) but is not proof against a determined
attacker who engineers matching stray braces inside a comment/string to
cancel out a real escape. This whole pipeline is scoped for a classroom demo
among trusted submitters, not a hardened multi-tenant sandbox; real isolation
would mean running the compile+run step in a container with resource limits.
"""

from __future__ import annotations

import asyncio
import json
import queue
import shutil
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, AsyncIterator, Dict, Optional

import db
from common import PnLPoint, Trade, apply_limit
from config import (
    COMPILE_JOBS_DIR,
    CXX_BIN,
    ENGINE_DIR,
    STRATEGY_COMPILE_TIMEOUT_S,
    STRATEGY_JOB_TEMPLATE,
    STRATEGY_MAIN_JOB_SRC,
    STRATEGY_RUN_TIMEOUT_S,
)
from metrics import compute_summary_metrics
from response import SimulationResponse

# Sentinel enqueued after the job ends so the consumer knows to stop.
_DONE = object()

# Bound on queued-but-undelivered log lines (mirrors compile_manager.py).
_QUEUE_MAXSIZE = 4096

# Jobs created but never attached to a stream are reaped after this long.
_JOB_TTL_S = 300.0

# Poll cadence while the queue is momentarily empty (mirrors stream_manager).
_POLL_INTERVAL_S = 0.1

# Marker in user_strategy.job_template.cpp that gets replaced with the
# submitted on_market_update body -- plain string substitution, never
# brace-matching/parsing into the real, live user_strategy.cpp.
_BODY_MARKER = "/*__ON_MARKET_UPDATE_BODY__*/"

# Read and validated once at import time: this is static repo source, not
# per-request data, so there's no reason to re-read it from disk on every
# "Compile & Run" click.
_JOB_TEMPLATE_TEXT = STRATEGY_JOB_TEMPLATE.read_text()
_marker_count = _JOB_TEMPLATE_TEXT.count(_BODY_MARKER)
if _marker_count != 1:
    raise RuntimeError(
        f"Job template {STRATEGY_JOB_TEMPLATE} has {_marker_count} occurrences of "
        f"{_BODY_MARKER!r}, expected exactly 1 -- str.replace() would splice the "
        "submitted body into the wrong spot (e.g. an incidental mention in a "
        "comment) instead of failing loudly."
    )

# Windows' g++ (MinGW) silently appends .exe to -o output with no extension;
# every other platform we target (Linux container, macOS) does not.
_EXE_SUFFIX = ".exe" if sys.platform == "win32" else ""

_INCLUDES = [
    f"-I{ENGINE_DIR / 'shared' / 'include'}",
    f"-I{ENGINE_DIR / 'match' / 'include'}",
    f"-I{ENGINE_DIR / 'simulation' / 'include'}",
]
# Fixed, non-user-controlled sources compiled straight from the tracked repo
# tree -- only user_strategy.cpp (written per-job below) is derived from
# submitted input. Mirrors engine/Makefile's OFFLINE_CORE_SRCS; keep in sync
# if that list changes.
_SHARED_SRCS = [
    str(ENGINE_DIR / "simulation" / "src" / "offline_simulation.cpp"),
    str(ENGINE_DIR / "simulation" / "src" / "protocol.cpp"),
    str(ENGINE_DIR / "simulation" / "src" / "strategy_base.cpp"),
    str(ENGINE_DIR / "match" / "src" / "orderbook.cpp"),
]


class InvalidStrategyBodyError(ValueError):
    """Raised when a submitted on_market_update_body fails validation."""


def _validate_braces(body: str) -> None:
    """Reject a body that isn't brace-balanced on its own.

    If the running brace count ever goes negative, an unmatched '}' would
    close on_market_update early and let whatever follows compile as
    top-level C++ instead of statements inside the function -- including
    something that executes before main() ever runs (a static/global
    initializer). Ending anywhere other than exactly 0 means an unmatched
    '{' is left open, which would instead swallow the template's own closing
    brace and everything g++ tries to parse after it. See the module
    docstring for what this check does and doesn't guarantee.

    Also counts the C++ digraphs '<%'/'%>', which GCC accepts by default
    (no flag exists to turn them off -- they're part of the ISO lexical
    grammar, unlike trigraphs, which C++17 did remove) as alternate
    spellings of '{'/'}'. Confirmed by direct test: g++ -std=c++17 with no
    extra flags compiles a '<% ... %>' function body identically to a
    brace-delimited one. Without this, '<%'/'%>' would be an unguarded
    bypass of the exact escape this function exists to close.
    """
    balance = 0
    i = 0
    n = len(body)
    while i < n:
        two = body[i : i + 2]
        if body[i] == "{" or two == "<%":
            balance += 1
            i += 2 if two == "<%" else 1
            continue
        if body[i] == "}" or two == "%>":
            balance -= 1
            i += 2 if two == "%>" else 1
            if balance < 0:
                raise InvalidStrategyBodyError(
                    "on_market_update_body has a '}' (or '%>' digraph) with no "
                    "matching '{'/'<%' before it -- this would close the function "
                    "early and let arbitrary code after it compile as top-level C++."
                )
            continue
        i += 1
    if balance != 0:
        raise InvalidStrategyBodyError(
            f"on_market_update_body has {balance} unmatched '{{'/'<%' -- every brace "
            "(or digraph) opened in the submitted body must also be closed in it."
        )


@dataclass
class StrategyCompileJob:
    """One compile-and-run: its workspace, process, and event queue."""

    job_id: str
    workspace: Path
    data_file: Path
    trade_limit: Optional[int]
    pnl_limit: Optional[int]
    created_at: float = field(default_factory=time.monotonic)
    events: "queue.Queue[Any]" = field(
        default_factory=lambda: queue.Queue(maxsize=_QUEUE_MAXSIZE)
    )
    _thread: Optional[threading.Thread] = None
    _started: bool = False
    _start_lock: threading.Lock = field(default_factory=threading.Lock)

    @property
    def started(self) -> bool:
        return self._started

    def start(self) -> None:
        """Launch compile+run on a daemon thread (idempotent, thread-safe).

        Two near-simultaneous SSE attaches to the same fresh job could both
        observe _started == False before either sets it -- the lock closes
        that window so the compile/run subprocess is never launched twice.
        """
        with self._start_lock:
            if self._started:
                return
            self._started = True
        self._thread = threading.Thread(
            target=self._run, name=f"strategy-compile-{self.job_id[:8]}", daemon=True
        )
        self._thread.start()

    def join(self, timeout: Optional[float] = None) -> None:
        if self._thread is not None:
            self._thread.join(timeout)

    # --- runs on the job's daemon thread ------------------------------------
    def _emit(self, event: Dict[str, Any]) -> None:
        try:
            self.events.put_nowait(event)
        except queue.Full:
            pass  # slow/absent client: drop rather than block

    def _emit_terminal(self, event: Dict[str, Any]) -> None:
        """Like _emit, but for an event the consumer MUST see (an error or
        completion payload, or _DONE itself). Dropping these -- unlike an
        intermediate log line -- would leave event_stream polling forever
        with nothing left to deliver, so if the queue is full this evicts
        the oldest buffered item instead of giving up. Bounded by
        _QUEUE_MAXSIZE, so this always terminates.
        """
        for _ in range(_QUEUE_MAXSIZE + 1):
            try:
                self.events.put_nowait(event)
                return
            except queue.Full:
                try:
                    self.events.get_nowait()
                except queue.Empty:
                    return

    def _log(self, line: str) -> None:
        self._emit({"type": "log", "line": line})

    def _fail(self, detail: str) -> None:
        self._emit_terminal({"type": "error", "detail": detail})
        self._emit_terminal(_DONE)

    def _run(self) -> None:
        try:
            self._run_unguarded()
        except Exception as exc:  # noqa: BLE001 - any bug here must still end the job
            self._fail(f"Internal error while processing the run: {exc}")

    def _run_unguarded(self) -> None:
        binary_path = self.workspace / f"strategy_run{_EXE_SUFFIX}"
        results_path = self.workspace / "result.json"

        # --- Phase 1: compile ------------------------------------------------
        compile_cmd = (
            [CXX_BIN, "-std=c++17", "-O2", "-Wall", "-Wextra"]
            + _INCLUDES
            + _SHARED_SRCS
            + [str(self.workspace / "user_strategy.cpp"), str(STRATEGY_MAIN_JOB_SRC)]
            + ["-o", str(binary_path)]
        )
        self._log(f"[compile] {' '.join(compile_cmd)}")
        try:
            proc = subprocess.run(
                compile_cmd, capture_output=True, text=True, timeout=STRATEGY_COMPILE_TIMEOUT_S
            )
        except subprocess.TimeoutExpired:
            self._fail(f"Compile timed out after {STRATEGY_COMPILE_TIMEOUT_S}s.")
            return
        except OSError as exc:
            self._fail(f"Failed to launch compiler: {exc}")
            return

        for line in (proc.stdout or "").splitlines():
            self._log(f"[compile] {line}")
        for line in (proc.stderr or "").splitlines():
            self._log(f"[compile] {line}")

        if proc.returncode != 0:
            self._fail(f"Compile failed (exit code {proc.returncode}); see log above.")
            return

        # --- Phase 2: run ------------------------------------------------------
        # Results go to a file (results_path), not stdout: the submitted
        # on_market_update body runs inside this process and is free to
        # std::cout/printf for debugging, which would otherwise corrupt a
        # stdout-encoded payload. See main_job.cpp's header comment. Both
        # stdout and stderr are still captured and shown as log lines.
        self._log(f"[run] {binary_path} {self.data_file} {results_path}")
        try:
            proc = subprocess.run(
                [str(binary_path), str(self.data_file), str(results_path)],
                capture_output=True,
                text=True,
                timeout=STRATEGY_RUN_TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            self._fail(f"Run timed out after {STRATEGY_RUN_TIMEOUT_S}s.")
            return
        except OSError as exc:
            self._fail(f"Failed to launch strategy_run: {exc}")
            return

        for line in (proc.stdout or "").splitlines():
            self._log(f"[run] {line}")
        for line in (proc.stderr or "").splitlines():
            self._log(f"[run] {line}")

        if proc.returncode != 0:
            self._fail(f"strategy_run exited with code {proc.returncode}; see log above.")
            return

        try:
            raw = json.loads(results_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            self._fail(f"Could not read/parse strategy_run's result file: {exc}")
            return

        trades = [Trade(**t) for t in raw.get("trades", [])]
        pnl_curve = [PnLPoint(**p) for p in raw.get("pnl_curve", [])]

        try:
            db.log_run(
                data_file=str(self.data_file),
                mode="software_compile",
                started_at_ns=time.time_ns(),
                compute_time_us=raw.get("compute_time_us", 0),
                total_trades=raw.get("total_trades", 0),
                trades=trades,
                pnl_curve=pnl_curve,
            )
        except Exception:  # noqa: BLE001 - logging must never break the job
            self._log("[run] warning: failed to persist run to database")

        compute_time_us = raw.get("compute_time_us", 0)
        metrics = compute_summary_metrics(pnl_curve, compute_time_us)

        response = SimulationResponse(
            data_file=str(self.data_file),
            total_trades=raw.get("total_trades", 0),
            compute_time_us=compute_time_us,
            trades=apply_limit(trades, self.trade_limit),
            pnl_curve=apply_limit(pnl_curve, self.pnl_limit),
            metrics=metrics,
        )
        self._emit_terminal(
            {"type": "complete", "job_id": self.job_id, "result": response.model_dump()}
        )
        self._emit_terminal(_DONE)


class StrategyCompileManager:
    """Registry of active/pending software compile jobs."""

    def __init__(self) -> None:
        self._jobs: Dict[str, StrategyCompileJob] = {}
        self._lock = threading.Lock()

    def create(
        self,
        on_market_update_body: str,
        data_file: Path,
        trade_limit: Optional[int] = None,
        pnl_limit: Optional[int] = None,
    ) -> StrategyCompileJob:
        """Register a new (not-yet-started) job: write the workspace + templated source.

        Raises InvalidStrategyBodyError if on_market_update_body isn't brace-
        balanced on its own -- see _validate_braces.
        """
        _validate_braces(on_market_update_body)
        self._reap_stale()

        job_id = uuid.uuid4().hex
        workspace = COMPILE_JOBS_DIR / job_id
        workspace.mkdir(parents=True, exist_ok=True)
        try:
            source = _JOB_TEMPLATE_TEXT.replace(_BODY_MARKER, on_market_update_body)
            (workspace / "user_strategy.cpp").write_text(source)
        except OSError:
            # Never register (or leave dangling) a workspace we couldn't
            # finish writing -- nothing would otherwise clean it up, since
            # it's not in self._jobs for remove()/_reap_stale() to find.
            shutil.rmtree(workspace, ignore_errors=True)
            raise

        job = StrategyCompileJob(
            job_id=job_id,
            workspace=workspace,
            data_file=data_file,
            trade_limit=trade_limit,
            pnl_limit=pnl_limit,
        )
        with self._lock:
            self._jobs[job_id] = job
        return job

    def get(self, job_id: str) -> Optional[StrategyCompileJob]:
        with self._lock:
            return self._jobs.get(job_id)

    def remove(self, job_id: str) -> None:
        """Drop a job from the registry and delete its on-disk workspace.

        Same real-join-before-rmtree reasoning as CompileManager.remove: an
        early client disconnect can leave the compile/run subprocess still
        running past event_stream's own short wait.
        """
        with self._lock:
            job = self._jobs.pop(job_id, None)
        if job is None:
            return
        threading.Thread(
            target=lambda: (job.join(), shutil.rmtree(job.workspace, ignore_errors=True)),
            daemon=True,
        ).start()

    def _reap_stale(self) -> None:
        now = time.monotonic()
        with self._lock:
            stale = [
                jid
                for jid, j in self._jobs.items()
                if not j.started and (now - j.created_at) > _JOB_TTL_S
            ]
            for jid in stale:
                self._jobs.pop(jid, None)
        for jid in stale:
            shutil.rmtree(COMPILE_JOBS_DIR / jid, ignore_errors=True)

    async def event_stream(
        self, job: StrategyCompileJob, request: Any
    ) -> AsyncIterator[str]:
        """Async generator yielding SSE frames for a strategy compile job.

        Starts the compile+run on first attach, then drains events until the
        job completes or the client disconnects. Mirrors
        CompileManager.event_stream / StreamManager.event_stream.
        """
        job.start()
        try:
            while True:
                try:
                    evt = job.events.get_nowait()
                except queue.Empty:
                    if await request.is_disconnected():
                        break
                    await asyncio.sleep(_POLL_INTERVAL_S)
                    continue

                if evt is _DONE:
                    break
                yield f"data: {json.dumps(evt)}\n\n"
        finally:
            job.join(timeout=1.0)
            self.remove(job.job_id)


# Module-level singleton shared by the route handlers.
strategy_compile_manager = StrategyCompileManager()
