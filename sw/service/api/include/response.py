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
