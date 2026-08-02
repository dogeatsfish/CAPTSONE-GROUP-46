import logging
import time
from pathlib import Path
from typing import List

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse

from config import (
    DATA_DIR,
    DEFAULT_DATA_FILE,
    SERVICE_ROOT,
    ONLINE_ITCH_ADDRESS,
    ONLINE_ITCH_PORT,
    ONLINE_OUCH_PORT,
    ONLINE_DEFAULT_TIME_SCALE,
    engine_sim,
)
import db
from common import PnLPoint, Trade, apply_limit
from compile import CompileRequest, CompileStartResponse
from compile_manager import compile_manager
from metrics import compute_summary_metrics
from request import SimulationRequest
from response import RunDetail, RunSummary, SimulationResponse, StreamStartResponse
from stream_manager import stream_manager, build_online_config
from strategy_compile import StrategyCompileRequest, StrategyCompileStartResponse
from strategy_compile_manager import InvalidStrategyBodyError, strategy_compile_manager

router = APIRouter()

# SSE responses should not be buffered or cached by clients/proxies.
_SSE_HEADERS = {
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no",  # disable proxy buffering (e.g. nginx)
}


def _resolve_data_file(data_file: str | None) -> Path:
    """Resolve a requested data file to an existing .bin, or raise HTTP 404."""
    path = Path(data_file) if data_file else DEFAULT_DATA_FILE
    if not path.is_absolute():
        path = (SERVICE_ROOT / path).resolve()
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"Data file not found: {path}")
    return path


def _log_run(data_file: Path, mode: str, started_at_ns: int, result) -> None:
    """Persist a completed run to the database (FS-15, partial scope -- see db.py).

    Best-effort: a logging failure shouldn't take down a successful simulation
    response, so it's caught and reported via the FastAPI logger rather than
    raised.
    """
    try:
        db.log_run(
            data_file=str(data_file),
            mode=mode,
            started_at_ns=started_at_ns,
            compute_time_us=result.compute_time_us,
            total_trades=result.total_trades,
            trades=result.trades,
            pnl_curve=result.pnl_curve,
        )
    except Exception:  # noqa: BLE001 - logging must never break the response
        logging.getLogger(__name__).exception("Failed to persist run to database")


def _to_response(data_file: Path, result, req) -> SimulationResponse:
    """Map an engine SimulationResult into the API response schema."""
    # Metrics are derived from the FULL pnl_curve, before trade_limit/pnl_limit
    # truncation below -- otherwise capping the payload for display would
    # silently skew drawdown/volatility/Sharpe.
    full_pnl_curve = [
        PnLPoint(
            timestamp_ns=p.timestamp_ns,
            realized_pnl=p.realized_pnl,
            unrealized_pnl=p.unrealized_pnl,
            position_size=p.position_size,
        )
        for p in result.pnl_curve
    ]
    metrics = compute_summary_metrics(full_pnl_curve, result.compute_time_us)

    trades = apply_limit(result.trades, req.trade_limit)
    pnl_curve = apply_limit(full_pnl_curve, req.pnl_limit)

    return SimulationResponse(
        data_file=str(data_file),
        total_trades=result.total_trades,
        compute_time_us=result.compute_time_us,
        trades=[
            Trade(timestamp_ns=t.timestamp_ns, side=t.side, price=t.price, size=t.size)
            for t in trades
        ],
        pnl_curve=pnl_curve,
        metrics=metrics,
    )


@router.post("/simulate", response_model=SimulationResponse, tags=["simulation"])
def run_simulation(req: SimulationRequest):
    """Run the C++ offline simulation over an MBO stream and return telemetry."""
    data_file = _resolve_data_file(req.data_file)
    started_at_ns = time.time_ns()

    try:
        result = engine_sim.OfflineSimulation(str(data_file)).run()
    except Exception as exc:  # noqa: BLE001 - surface engine errors as HTTP 500
        raise HTTPException(
            status_code=500, detail=f"Simulation failed: {exc}"
        ) from exc

    _log_run(data_file, "offline", started_at_ns, result)
    return _to_response(data_file, result, req)


@router.post("/simulate/online", response_model=SimulationResponse, tags=["simulation"])
def run_online_simulation(req: SimulationRequest):
    """Run the C++ *online* (real-time) simulation and return telemetry.

    Uses the same request/response contract as /simulate. The engine replays
    the MBO stream as an ITCH market-data broadcast while serving OUCH order
    entry; those UDP/TCP sockets are handled entirely inside the engine using
    server-side configuration, so clients simply trigger the run and receive
    the resulting trade / PnL telemetry.
    """
    data_file = _resolve_data_file(req.data_file)
    started_at_ns = time.time_ns()

    # Build the engine networking/pacing config on the server side only. None
    # of these socket details are part of the request or response schema.
    cfg = engine_sim.OnlineConfig()
    cfg.itch_address = ONLINE_ITCH_ADDRESS
    cfg.itch_port = ONLINE_ITCH_PORT
    cfg.ouch_port = ONLINE_OUCH_PORT
    cfg.ouch_transport = engine_sim.OuchTransport.UDP  # matches the FPGA
    cfg.time_scale = ONLINE_DEFAULT_TIME_SCALE

    try:
        result = engine_sim.OnlineSimulation(str(data_file), cfg).run()
    except Exception as exc:  # noqa: BLE001 - surface engine errors as HTTP 500
        raise HTTPException(
            status_code=500, detail=f"Online simulation failed: {exc}"
        ) from exc

    _log_run(data_file, "online", started_at_ns, result)
    return _to_response(data_file, result, req)


@router.post(
    "/simulate/online/stream",
    response_model=StreamStartResponse,
    tags=["simulation"],
)
def start_online_stream(req: SimulationRequest):
    """Create a live online-simulation run and return its stream URL.

    The run starts when a client attaches to the returned ``stream_url`` via
    Server-Sent Events (so the client never misses the opening telemetry). The
    engine's ITCH/OUCH sockets stay entirely server-side.
    """
    data_file = _resolve_data_file(req.data_file)
    session = stream_manager.create(str(data_file), build_online_config())
    return StreamStartResponse(
        session_id=session.session_id,
        data_file=str(data_file),
        stream_url=f"/simulate/online/stream/{session.session_id}",
    )


@router.get("/simulate/online/stream/{session_id}", tags=["simulation"])
async def online_stream(session_id: str, request: Request):
    """Attach a Server-Sent Events stream to a previously created run.

    Emits one JSON object per `data:` frame:
      {"type": "pnl", "timestamp_ns", "realized_pnl", "unrealized_pnl", "position_size"}
      {"type": "complete", "data_file", "total_trades", "compute_time_us"}
      {"type": "error", "detail"}
    """
    session = stream_manager.get(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="Unknown or expired stream session")
    if session.started:
        raise HTTPException(
            status_code=409, detail="Stream session is already being consumed"
        )
    return StreamingResponse(
        stream_manager.event_stream(session, request),
        media_type="text/event-stream",
        headers=_SSE_HEADERS,
    )


@router.get("/datasets", tags=["simulation"])
def list_datasets():
    """List the .bin MBO streams available in the bundled data directory."""
    datasets = (
        sorted(p.name for p in DATA_DIR.glob("*.bin")) if DATA_DIR.is_dir() else []
    )
    return {"data_dir": str(DATA_DIR), "datasets": datasets}


@router.get("/runs", response_model=List[RunSummary], tags=["runs"])
def list_runs(limit: int = Query(20, ge=1, le=200)):
    """List the most recently persisted simulation runs, newest first."""
    return db.get_recent_runs(limit=limit)


@router.get("/runs/{run_id}", response_model=RunDetail, tags=["runs"])
def get_run(run_id: int):
    """One persisted run's summary plus its fills and PnL curve."""
    run = db.get_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail=f"Unknown run_id: {run_id}")
    return run


@router.post("/compile", response_model=CompileStartResponse, tags=["compile"])
def start_compile(req: CompileRequest):
    """Create an Alpha Engine Core compile job and return its stream URL.

    Runs an out-of-context synthesis check (FS-16 first slice) against the
    fixed FS-8 sandbox port list -- not a full bitstream/board-flash flow, see
    vivado/scripts/compile_alpha_engine.tcl for scope notes. The job starts
    when a client attaches to the returned ``stream_url`` via Server-Sent
    Events, mirroring the online-simulation stream handshake above.
    """
    job = compile_manager.create(req.source, req.module_name)
    return CompileStartResponse(
        job_id=job.job_id,
        stream_url=f"/compile/{job.job_id}/stream",
    )


@router.get("/compile/{job_id}/stream", tags=["compile"])
async def compile_stream(job_id: str, request: Request):
    """Attach a Server-Sent Events stream to a previously created compile job.

    Emits one JSON object per `data:` frame:
      {"type": "log", "line": "<one line of Vivado stdout>"}
      {"type": "complete", "job_id", "synth_time_s", "lut_count", "ff_count",
       "dsp_count", "bram_count", "timing_summary"}
      {"type": "error", "detail"}
    """
    job = compile_manager.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Unknown or expired compile job")
    if job.started:
        raise HTTPException(
            status_code=409, detail="Compile job is already being consumed"
        )
    return StreamingResponse(
        compile_manager.event_stream(job, request),
        media_type="text/event-stream",
        headers=_SSE_HEADERS,
    )


@router.post(
    "/compile/software",
    response_model=StrategyCompileStartResponse,
    tags=["compile"],
)
def start_strategy_compile(req: StrategyCompileRequest):
    """Create a software strategy compile-and-run job and return its stream URL.

    Builds a native offline-simulation binary from the submitted
    on_market_update body (spliced into user_strategy.job_template.cpp),
    then runs it against a dataset -- no Vivado/hardware involved. The job
    starts when a client attaches to the returned ``stream_url`` via
    Server-Sent Events, mirroring the Vivado compile job's handshake above.
    """
    data_file = _resolve_data_file(req.data_file)
    try:
        job = strategy_compile_manager.create(
            req.on_market_update_body, data_file, req.trade_limit, req.pnl_limit
        )
    except InvalidStrategyBodyError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return StrategyCompileStartResponse(
        job_id=job.job_id,
        stream_url=f"/compile/software/{job.job_id}/stream",
    )


@router.get("/compile/software/{job_id}/stream", tags=["compile"])
async def strategy_compile_stream(job_id: str, request: Request):
    """Attach a Server-Sent Events stream to a previously created software compile job.

    Emits one JSON object per `data:` frame:
      {"type": "log", "line": "<one line of compiler/run output>"}
      {"type": "complete", "job_id", "result": <SimulationResponse-shaped object>}
      {"type": "error", "detail"}
    """
    job = strategy_compile_manager.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Unknown or expired compile job")
    if job.started:
        raise HTTPException(
            status_code=409, detail="Compile job is already being consumed"
        )
    return StreamingResponse(
        strategy_compile_manager.event_stream(job, request),
        media_type="text/event-stream",
        headers=_SSE_HEADERS,
    )
