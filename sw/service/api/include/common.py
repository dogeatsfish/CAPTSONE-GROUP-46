"""Shared API schemas used across requests and responses."""

from typing import List, Optional, TypeVar

from pydantic import BaseModel

T = TypeVar("T")


def apply_limit(items: List[T], limit: Optional[int]) -> List[T]:
    """Cap a list to its first `limit` items, or return it unchanged if
    `limit` is None. Shared by every endpoint that trims trades/pnl_curve
    for the response while persisting the untrimmed data to the DB.

    Note for pnl_curve callers: a stoppage/halt in the underlying MBO stream
    now backfills a real (held-PnL) sample at every second boundary of the
    gap (see OfflineSimulation::run), instead of contributing zero samples
    the way it used to. A caller that sets pnl_limit on a run with an early
    stoppage will have more of that budget spent on the gap, so the
    truncated response can end mid-stoppage rather than reaching later,
    possibly more interesting, data. No shipped UI path sets pnl_limit today
    (always None/unlimited), but this is worth knowing before that changes.
    """
    return items[:limit] if limit is not None else items


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
    engine's own wall-clock measurement of the run. trades_per_second is
    total_trades divided by compute_time_us (converted to seconds) -- engine
    throughput, not a market-timing or latency figure.
    """

    final_pnl: float
    max_drawdown: float
    max_drawdown_pct: float
    volatility: float
    sharpe_ratio: float
    compute_time_us: int
    trades_per_second: float
