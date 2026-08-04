// Client-side mirror of sw/service/api/include/metrics.py's
// compute_summary_metrics(). Exists so the Online-mode dashboard can show
// drawdown/Sharpe/volatility/Time-per-Trade updating live from the
// in-progress pnl_curve/trades arrays (liveCurve/liveTrades in
// OnlineDemoPage.jsx), the same way the PnL number/graph already do,
// instead of sitting on "--" until the server's "complete" event lands.
//
// Keep this in sync with metrics.py by hand -- there is deliberately no
// shared source between the Python and JS copies of this math.

// Matches TRADING_SECONDS_PER_YEAR in metrics.py exactly (252 trading days x
// 23,400s/day NYSE session length).
const TRADING_SECONDS_PER_YEAR = 252 * 23_400;

function avgDecisionLatencyNs(trades) {
    // Mirrors metrics.py's _avg_decision_latency_ns: ignore unmeasured (0)
    // trades rather than averaging them in, which would drag a real average
    // toward zero instead of reflecting only what was actually timed.
    const measured = (trades ?? [])
        .map((t) => t.decision_latency_ns)
        .filter((ns) => ns > 0);
    if (measured.length === 0) return 0;
    return measured.reduce((a, b) => a + b, 0) / measured.length;
}

// pnlCurve: [{ realized_pnl, unrealized_pnl, ... }, ...]
// trades: [{ decision_latency_ns, ... }, ...]
// Returns the same shape as the backend's SummaryMetrics (minus
// compute_time_us/trades_per_second, which aren't meaningful mid-run and
// aren't displayed by ResultsSummary).
export function computeLiveMetrics(pnlCurve, trades) {
    const avg_decision_latency_ns = avgDecisionLatencyNs(trades);

    if (!pnlCurve || pnlCurve.length === 0) {
        return {
            final_pnl: 0,
            final_realized_pnl: 0,
            max_drawdown: 0,
            max_drawdown_pct: 0,
            volatility: 0,
            sharpe_ratio: 0,
            avg_decision_latency_ns,
        };
    }

    // "Equity" = realized + unrealized PnL at each sampled instant.
    const equity = pnlCurve.map((p) => p.realized_pnl + p.unrealized_pnl);
    const final_pnl = equity[equity.length - 1];
    const final_realized_pnl = pnlCurve[pnlCurve.length - 1].realized_pnl;

    // --- Max drawdown: largest peak-to-trough decline of the equity curve ---
    let peak = equity[0];
    let maxDrawdown = 0;
    let maxDrawdownPct = 0;
    for (const e of equity) {
        if (e > peak) peak = e;
        const dd = peak - e;
        if (dd > maxDrawdown) {
            maxDrawdown = dd;
            maxDrawdownPct = peak > 0 ? (dd / peak) * 100 : 0;
        }
    }

    // --- Per-sample returns: deltas between consecutive equity snapshots ---
    const deltas = [];
    for (let i = 1; i < equity.length; i++) {
        deltas.push(equity[i] - equity[i - 1]);
    }

    let volatility = 0;
    let sharpeRatio = 0;
    if (deltas.length >= 2) {
        const meanDelta = deltas.reduce((a, b) => a + b, 0) / deltas.length;
        const variance =
            deltas.reduce((a, d) => a + (d - meanDelta) ** 2, 0) / deltas.length;
        volatility = Math.sqrt(variance);
        sharpeRatio =
            volatility > 0
                ? (meanDelta / volatility) * Math.sqrt(TRADING_SECONDS_PER_YEAR)
                : 0;
    }

    return {
        final_pnl,
        final_realized_pnl,
        max_drawdown: maxDrawdown,
        max_drawdown_pct: maxDrawdownPct,
        volatility,
        sharpe_ratio: sharpeRatio,
        avg_decision_latency_ns,
    };
}
