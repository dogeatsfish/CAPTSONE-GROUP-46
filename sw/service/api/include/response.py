"""Response schemas for the HFT engine service."""

from typing import List

from pydantic import BaseModel

from common import PnLPoint, Trade


class SimulationResponse(BaseModel):
    data_file: str
    total_trades: int
    compute_time_us: int
    trades: List[Trade]
    pnl_curve: List[PnLPoint]


class StreamStartResponse(BaseModel):
    """Returned by the POST that starts an online streaming run.

    The client then opens an EventSource (SSE) against ``stream_url`` to
    receive live PnL telemetry.
    """

    session_id: str
    data_file: str
    stream_url: str
