"""API routes for the HFT engine service.

Defines the FastAPI endpoints and bridges HTTP requests to the compiled C++
``engine_sim`` module. All filesystem/path wiring lives in ``config.py``.

The main endpoint is ``POST /simulate`` which runs an ``OfflineSimulation``
over a packed binary MBO stream and returns the resulting telemetry.
"""

from pathlib import Path

from fastapi import APIRouter, HTTPException

from config import DATA_DIR, DEFAULT_DATA_FILE, SERVICE_ROOT, engine_sim
from common import PnLPoint, Trade
from request import SimulationRequest
from response import SimulationResponse

router = APIRouter()


@router.post("/simulate", response_model=SimulationResponse, tags=["simulation"])
def run_simulation(req: SimulationRequest):
    """Run the C++ offline simulation over an MBO stream and return telemetry."""
    data_file = Path(req.data_file) if req.data_file else DEFAULT_DATA_FILE

    # Resolve relative paths against the service root for predictability.
    if not data_file.is_absolute():
        data_file = (SERVICE_ROOT / data_file).resolve()

    if not data_file.is_file():
        raise HTTPException(status_code=404, detail=f"Data file not found: {data_file}")

    try:
        result = engine_sim.OfflineSimulation(str(data_file)).run()
    except Exception as exc:  # noqa: BLE001 - surface engine errors as HTTP 500
        raise HTTPException(
            status_code=500, detail=f"Simulation failed: {exc}"
        ) from exc

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


@router.get("/datasets", tags=["simulation"])
def list_datasets():
    """List the .bin MBO streams available in the bundled data directory."""
    datasets = (
        sorted(p.name for p in DATA_DIR.glob("*.bin")) if DATA_DIR.is_dir() else []
    )
    return {"data_dir": str(DATA_DIR), "datasets": datasets}
