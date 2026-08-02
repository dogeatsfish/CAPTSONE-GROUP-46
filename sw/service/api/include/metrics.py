"""Derived performance-metric calculations for a completed simulation run.

The C++ engine (see ``offline_simulation.cpp`` / ``online_simulation.cpp``)
only returns the raw per-second PnL curve, trade list, and total compute
time -- it does not compute drawdown, volatility, or Sharpe ratio. These are
derived here, in pure Python, from that curve so the math is easy to read,
test, and adjust without touching (or rebuilding) the C++ engine.

Kept free of FastAPI/pydantic-request concerns so it can be unit tested with
plain lists of PnLPoint.
"""

import math
from typing import Sequence

from common import PnLPoint, SummaryMetrics

# The engine samples the PnL curve once per *simulated* second (see
# SAMPLE_INTERVAL_NS in offline_simulation.cpp / online_simulation.cpp), so
# each successive pair of points approximates a one-second return. We
# annualize using the same 252-trading-day, 23,400-second NYSE session
# figure already used in this project's own logging-volume analysis
# (sw/docs design report, FastAPI Subsystem section) for consistency.
TRADING_SECONDS_PER_YEAR = 252 * 23_400

_ZERO_METRICS_KWARGS = dict(
    final_pnl=0.0,
    max_drawdown=0.0,
    max_drawdown_pct=0.0,
    volatility=0.0,
    sharpe_ratio=0.0,
)


def compute_summary_metrics(
    pnl_curve: Sequence[PnLPoint], compute_time_us: int
) -> SummaryMetrics:
    """Derive final PnL, max drawdown, volatility, and Sharpe ratio.

    Pass the *full* pnl_curve (before any trade_limit/pnl_limit truncation
    applied for the response payload) so the metrics reflect the whole run.
    """
    if not pnl_curve:
        return SummaryMetrics(compute_time_us=compute_time_us, **_ZERO_METRICS_KWARGS)

    # "Equity" = realized + unrealized PnL at each sampled instant.
    equity = [p.realized_pnl + p.unrealized_pnl for p in pnl_curve]
    final_pnl = equity[-1]

    # --- Max drawdown: largest peak-to-trough decline of the equity curve ---
    peak = equity[0]
    max_dd = 0.0
    max_dd_pct = 0.0
    for e in equity:
        if e > peak:
            peak = e
        dd = peak - e
        if dd > max_dd:
            max_dd = dd
            max_dd_pct = (dd / peak * 100.0) if peak > 0 else 0.0

    # --- Per-sample returns: deltas between consecutive equity snapshots ---
    deltas = [equity[i] - equity[i - 1] for i in range(1, len(equity))]

    if len(deltas) >= 2:
        mean_d = sum(deltas) / len(deltas)
        variance = sum((d - mean_d) ** 2 for d in deltas) / len(deltas)
        volatility = math.sqrt(variance)
        sharpe_ratio = (
            (mean_d / volatility) * math.sqrt(TRADING_SECONDS_PER_YEAR)
            if volatility > 0
            else 0.0
        )
    else:
        volatility = 0.0
        sharpe_ratio = 0.0

    return SummaryMetrics(
        final_pnl=final_pnl,
        max_drawdown=max_dd,
        max_drawdown_pct=max_dd_pct,
        volatility=volatility,
        sharpe_ratio=sharpe_ratio,
        compute_time_us=compute_time_us,
    )
