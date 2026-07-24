import os
import sys

_SRC_DIR = os.path.dirname(os.path.abspath(__file__))  # service/api/src
_INCLUDE_DIR = os.path.normpath(
    os.path.join(_SRC_DIR, "..", "include")
)  # service/api/include
_SERVICE_ROOT = os.path.normpath(os.path.join(_SRC_DIR, "..", ".."))  # service
_REPO_ROOT = os.path.normpath(os.path.join(_SERVICE_ROOT, ".."))  # sw
_ENGINE_DIR = os.path.join(_REPO_ROOT, "engine")
_DATA_DIR = os.path.join(_REPO_ROOT, "data_pipeline", "data")

# Make the schema modules (common/request/response) importable.
if _INCLUDE_DIR not in sys.path:
    sys.path.insert(0, _INCLUDE_DIR)

from fastapi import APIRouter, HTTPException

from common import PnLPoint, Trade
from request import SimulationRequest
from response import SimulationResponse

if _ENGINE_DIR not in sys.path:
    sys.path.insert(0, _ENGINE_DIR)

try:
    import engine_sim  # type: ignore
except ImportError as exc:  # pragma: no cover - environment/build issue
    raise ImportError(
        "Could not import the compiled 'engine_sim' module. "
        f"Expected a built extension in {_ENGINE_DIR}. "
        "Run `make pymodule` inside the engine/ directory first."
    ) from exc


router = APIRouter()

# Default dataset shipped with the repo.
DEFAULT_DATA_FILE = os.path.join(_DATA_DIR, "synthetic_mbo_stream.bin")


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@router.post("/simulate", response_model=SimulationResponse, tags=["simulation"])
def run_simulation(req: SimulationRequest):
    """Run the C++ offline simulation over an MBO stream and return telemetry."""
    data_file = req.data_file or DEFAULT_DATA_FILE

    # Resolve relative paths against the service root for predictability.
    if not os.path.isabs(data_file):
        data_file = os.path.normpath(os.path.join(_SERVICE_ROOT, data_file))

    if not os.path.isfile(data_file):
        raise HTTPException(
            status_code=404,
            detail=f"Data file not found: {data_file}",
        )

    try:
        sim = engine_sim.OfflineSimulation(data_file)
        result = sim.run()
    except Exception as exc:  # noqa: BLE001 - surface engine errors as HTTP 500
        raise HTTPException(
            status_code=500,
            detail=f"Simulation failed: {exc}",
        ) from exc

    trades = result.trades
    pnl_curve = result.pnl_curve
    if req.trade_limit is not None:
        trades = trades[: req.trade_limit]
    if req.pnl_limit is not None:
        pnl_curve = pnl_curve[: req.pnl_limit]

    return SimulationResponse(
        data_file=data_file,
        total_trades=result.total_trades,
        compute_time_us=result.compute_time_us,
        trades=[
            Trade(
                timestamp_ns=t.timestamp_ns,
                side=t.side,
                price=t.price,
                size=t.size,
            )
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
    if not os.path.isdir(_DATA_DIR):
        return {"data_dir": _DATA_DIR, "datasets": []}
    datasets = sorted(f for f in os.listdir(_DATA_DIR) if f.endswith(".bin"))
    return {"data_dir": _DATA_DIR, "datasets": datasets}
