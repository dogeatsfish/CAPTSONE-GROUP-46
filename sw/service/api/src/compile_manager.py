"""Alpha Engine compile job runner.

Structured like ``stream_manager.py``: a job is created (workspace + source
file written to disk), then started on a background daemon thread that shells
out to Vivado in non-interactive batch mode. Log lines and the final
pass/fail result are pushed onto a thread-safe queue that an SSE generator
drains, using the same two-step "create, then attach" handshake as the online
simulation stream.

Vivado's own artifacts (util.rpt, timing.rpt, result.json) are the source of
truth for pass/fail; this module's job is to run the process, relay its
stdout live, and translate the finished report into API-shaped JSON.
"""

from __future__ import annotations

import asyncio
import json
import queue
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, AsyncIterator, Dict, Optional

from config import COMPILE_JOBS_DIR, COMPILE_TCL_SCRIPT, VIVADO_BIN

# Sentinel enqueued after the job ends so the consumer knows to stop.
_DONE = object()

# Bound on queued-but-undelivered log lines. Vivado batch runs are chatty but
# short-lived; if a client can't keep up we drop rather than grow memory.
_QUEUE_MAXSIZE = 4096

# Jobs created but never attached to a stream are reaped after this long.
_JOB_TTL_S = 300.0

# Poll cadence while the queue is momentarily empty (mirrors stream_manager).
_POLL_INTERVAL_S = 0.1

# Only the standard Vivado report_utilization rows we care about. Table format
# is pipe-delimited regardless of which numbered section a row falls under, so
# this doesn't need to track section headers.
_UTIL_FIELDS = {
    "Slice LUTs": "lut_count",
    "Slice Registers": "ff_count",
    "DSPs": "dsp_count",
    "Block RAM Tile": "bram_count",
}

# Cap on how much of timing.rpt we forward verbatim (it's informational only
# -- see the scoping note in compile_alpha_engine.tcl).
_TIMING_REPORT_MAX_CHARS = 4000


def _parse_utilization(report_text: str) -> Dict[str, int]:
    """Extract LUT/FF/DSP/BRAM used-counts from a Vivado report_utilization dump."""
    counts: Dict[str, int] = {}
    for line in report_text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        parts = [p.strip() for p in stripped.strip("|").split("|")]
        if len(parts) < 2:
            continue
        # Vivado appends a "*" footnote marker to some labels (e.g. "Slice
        # LUTs*" when LUT-as-distributed-RAM/SRL usage is folded in).
        label = parts[0].rstrip("*").strip()
        field_name = _UTIL_FIELDS.get(label)
        if field_name is None or field_name in counts:
            continue
        try:
            counts[field_name] = int(parts[1])
        except ValueError:
            continue
    return counts


@dataclass
class CompileJob:
    """One compile run: its workspace, process, and event queue."""

    job_id: str
    workspace: Path
    source_path: Path
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
        """Launch Vivado on a daemon thread (idempotent)."""
        if self._started:
            return
        self._started = True
        self._thread = threading.Thread(
            target=self._run, name=f"compile-{self.job_id[:8]}", daemon=True
        )
        self._thread.start()

    def join(self, timeout: Optional[float] = None) -> None:
        if self._thread is not None:
            self._thread.join(timeout)

    # --- runs on the compile job's daemon thread ---------------------------
    def _emit(self, event: Dict[str, Any]) -> None:
        try:
            self.events.put_nowait(event)
        except queue.Full:
            pass  # slow/absent client: drop rather than block Vivado's stdout pipe

    def _run(self) -> None:
        try:
            proc = subprocess.Popen(
                [
                    VIVADO_BIN,
                    "-mode",
                    "batch",
                    "-source",
                    str(COMPILE_TCL_SCRIPT),
                    "-tclargs",
                    str(self.workspace),
                    str(self.source_path),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            self._emit({"type": "error", "detail": f"Failed to launch Vivado: {exc}"})
            self.events.put(_DONE)
            return

        assert proc.stdout is not None
        for line in proc.stdout:
            self._emit({"type": "log", "line": line.rstrip("\n")})
        proc.wait()

        result_path = self.workspace / "result.json"
        if not result_path.is_file():
            self._emit(
                {
                    "type": "error",
                    "detail": (
                        f"Vivado exited (code {proc.returncode}) without writing "
                        "result.json; see the log lines above for details."
                    ),
                }
            )
            self.events.put(_DONE)
            return

        try:
            result = json.loads(result_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            self._emit({"type": "error", "detail": f"Could not read result.json: {exc}"})
            self.events.put(_DONE)
            return

        if result.get("status") != "passed":
            self._emit(
                {
                    "type": "error",
                    "detail": result.get("error") or "Compile failed (no error detail).",
                }
            )
            self.events.put(_DONE)
            return

        util_path = self.workspace / "util.rpt"
        counts = _parse_utilization(util_path.read_text()) if util_path.is_file() else {}

        timing_path = self.workspace / "timing.rpt"
        timing_summary = ""
        if timing_path.is_file():
            timing_summary = timing_path.read_text()[:_TIMING_REPORT_MAX_CHARS]

        self._emit(
            {
                "type": "complete",
                "job_id": self.job_id,
                "synth_time_s": result.get("synth_time_s"),
                "lut_count": counts.get("lut_count"),
                "ff_count": counts.get("ff_count"),
                "dsp_count": counts.get("dsp_count"),
                "bram_count": counts.get("bram_count"),
                "timing_summary": timing_summary,
            }
        )
        self.events.put(_DONE)


class CompileManager:
    """Registry of active/pending compile jobs."""

    def __init__(self) -> None:
        self._jobs: Dict[str, CompileJob] = {}
        self._lock = threading.Lock()

    def create(self, source: str, module_name: str) -> CompileJob:
        """Register a new (not-yet-started) job: write the workspace + source file."""
        self._reap_stale()

        job_id = uuid.uuid4().hex
        workspace = COMPILE_JOBS_DIR / job_id
        workspace.mkdir(parents=True, exist_ok=True)

        source_path = workspace / f"{module_name}.sv"
        source_path.write_text(source)

        job = CompileJob(job_id=job_id, workspace=workspace, source_path=source_path)
        with self._lock:
            self._jobs[job_id] = job
        return job

    def get(self, job_id: str) -> Optional[CompileJob]:
        with self._lock:
            return self._jobs.get(job_id)

    def remove(self, job_id: str) -> None:
        with self._lock:
            self._jobs.pop(job_id, None)

    def _reap_stale(self) -> None:
        """Drop jobs that were created but never attached to a stream."""
        now = time.monotonic()
        with self._lock:
            stale = [
                jid
                for jid, j in self._jobs.items()
                if not j.started and (now - j.created_at) > _JOB_TTL_S
            ]
            for jid in stale:
                self._jobs.pop(jid, None)

    async def event_stream(
        self, job: CompileJob, request: Any
    ) -> AsyncIterator[str]:
        """Async generator yielding SSE frames for a compile job.

        Starts Vivado on first attach, then drains events until the job
        completes or the client disconnects. Mirrors
        StreamManager.event_stream in stream_manager.py.
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
compile_manager = CompileManager()
