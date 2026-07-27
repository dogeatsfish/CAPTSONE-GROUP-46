from pathlib import Path

from fastapi import APIRouter, HTTPException

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
from common import PnLPoint, Trade
from request import SimulationRequest, OnlineSimulationRequest
from response import SimulationResponse

router = APIRouter()


def _resolve_data_file(data_file: str | None) -> Path:
    """Resolve a requested data file to an existing .bin, or raise HTTP 404."""
    path = Path(data_file) if data_file else DEFAULT_DATA_FILE
    if not path.is_absolute():
        path = (SERVICE_ROOT / path).resolve()
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"Data file not found: {path}")
    return path


def _to_response(data_file: Path, result, req) -> SimulationResponse:
    """Map an engine SimulationResult into the API response schema."""
    trades = result.trades
    pnl_curve = result.pnl_curve
    if req.trade_limit is not None:
        trades = trades[: req.trade_limit]
    if req.pnl_limit is not None:
        pnl_curve = pnl_curve[: req.pnl_limit]

    return SimulationResponse(
        data_file=str(data_file),
        total_trades=result.total_trades,
        compute_time_us=result.compute_time_us,
        trades=[
            Trade(timestamp_ns=t.timestamp_ns, side=t.side, price=t.price, size=t.size)
            for t in trades
        ],
        pnl_curve=[
            PnLPoint(
                timestamp_ns=p.timestamp_ns,
                realized_pnl=p.realized_pnl,
                unrealized_pnl=p.unrealized_pnl,
                position_size=p.position_size,
            )
            for p in pnl_curve
        ],
    )


@router.post("/simulate", response_model=SimulationResponse, tags=["simulation"])
def run_simulation(req: SimulationRequest):
    """Run the C++ offline simulation over an MBO stream and return telemetry."""
    data_file = _resolve_data_file(req.data_file)

    try:
        result = engine_sim.OfflineSimulation(str(data_file)).run()
    except Exception as exc:  # noqa: BLE001 - surface engine errors as HTTP 500
        raise HTTPException(
            status_code=500, detail=f"Simulation failed: {exc}"
        ) from exc

    return _to_response(data_file, result, req)


@router.post("/simulate/online", response_model=SimulationResponse, tags=["simulation"])
def run_online_simulation(req: OnlineSimulationRequest):
    """Run the C++ *online* (real-time) simulation and return telemetry.

    The engine replays the MBO stream as an ITCH market-data broadcast while
    serving OUCH order entry. Those UDP/TCP sockets are handled entirely inside
    the engine using server-side configuration; clients simply trigger the run
    and receive the resulting trade / PnL telemetry, exactly like /simulate.
    """
    data_file = _resolve_data_file(req.data_file)

    time_scale = (
        req.time_scale if req.time_scale is not None else ONLINE_DEFAULT_TIME_SCALE
    )

    # Build the engine networking/pacing config on the server side only. None
    # of these socket details are part of the request or response schema.
    cfg = engine_sim.OnlineConfig()
    cfg.itch_address = ONLINE_ITCH_ADDRESS
    cfg.itch_port = ONLINE_ITCH_PORT
    cfg.ouch_port = ONLINE_OUCH_PORT
    cfg.time_scale = time_scale

    try:
        result = engine_sim.OnlineSimulation(str(data_file), cfg).run()
    except Exception as exc:  # noqa: BLE001 - surface engine errors as HTTP 500
        raise HTTPException(
            status_code=500, detail=f"Online simulation failed: {exc}"
        ) from exc

    return _to_response(data_file, result, req)


@router.get("/datasets", tags=["simulation"])
def list_datasets():
    """List the .bin MBO streams available in the bundled data directory."""
    datasets = (
        sorted(p.name for p in DATA_DIR.glob("*.bin")) if DATA_DIR.is_dir() else []
    )
    return {"data_dir": str(DATA_DIR), "datasets": datasets}
