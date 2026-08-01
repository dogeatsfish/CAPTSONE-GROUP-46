// Converts one PnL snapshot -- either a streamed "pnl" SSE event or one
// entry of a SimulationResponse-shaped pnl_curve -- into the shape
// PnlCharts/StatCards expect: { t, realized, unrealized, total, position },
// with `t` = seconds since `firstTs`. Shared by both the incremental
// (App.jsx's streaming onEvent) and batch (pnlCurveToPoints below) paths so
// the two can't silently diverge on this math.
export function snapshotToPoint(snapshot, firstTs) {
    const t = Number(snapshot.timestamp_ns - firstTs) / 1e9;
    return {
        t: Number(t.toFixed(2)),
        realized: snapshot.realized_pnl,
        unrealized: snapshot.unrealized_pnl,
        total: snapshot.realized_pnl + snapshot.unrealized_pnl,
        position: snapshot.position_size,
    };
}

// Converts a full SimulationResponse-shaped pnl_curve (returned all at once
// by /compile/software's "complete" event) into an array of points.
export function pnlCurveToPoints(pnlCurve) {
    if (!pnlCurve || pnlCurve.length === 0) return [];
    const firstTs = pnlCurve[0].timestamp_ns;
    return pnlCurve.map((p) => snapshotToPoint(p, firstTs));
}

// A long/real-time online run streams one point per simulated second with
// no upper bound -- cap retained points so the chart data and each state
// update don't grow unbounded over a multi-minute run.
const MAX_POINTS = 2000;

export function capPoints(points) {
    return points.length > MAX_POINTS ? points.slice(points.length - MAX_POINTS) : points;
}
