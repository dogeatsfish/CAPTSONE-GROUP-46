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


class RunSummary(BaseModel):
    """One persisted run's headline fields (db.py's `runs` table)."""

    run_id: int
    data_file: str
    mode: str
    started_at_ns: int
    compute_time_us: int
    total_trades: int


class RunDetail(RunSummary):
    """A run summary plus its persisted fills and PnL curve."""

    fills: List[Trade]
    pnl_curve: List[PnLPoint]
