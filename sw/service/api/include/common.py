"""Shared API schemas used across requests and responses."""

from pydantic import BaseModel


class Trade(BaseModel):
    timestamp_ns: int
    side: str
    price: float
    size: float


class PnLPoint(BaseModel):
    timestamp_ns: int
    realized_pnl: float
    unrealized_pnl: float
    position_size: float


class SummaryMetrics(BaseModel):
    """Derived performance stats computed from a run's PnL curve.

    final_pnl / max_drawdown / volatility are in the same $ units as the
    engine's realized/unrealized PnL. sharpe_ratio is annualized assuming a
    252-day, 23,400-second-per-day trading year (the NYSE session length
    used elsewhere in the project) since the engine samples the PnL curve
    once per simulated second. compute_time_us is passed through from the
    engine's own wall-clock measurement of the run.
    """

    final_pnl: float
    max_drawdown: float
    max_drawdown_pct: float
    volatility: float
    sharpe_ratio: float
    compute_time_us: int
