import {
    ResponsiveContainer,
    LineChart,
    Line,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    ReferenceLine,
    Legend,
} from "recharts";
import { elapsedSeconds, fmtCompactCurrency, fmtCurrency } from "../utils/format";

// pnlCurve: SimulationResponse.pnl_curve, i.e.
// [{ timestamp_ns, realized_pnl, unrealized_pnl, position_size }, ...]
// firstTimestampNs/unit: shared elapsed-time origin and display unit, computed
// once by the parent (OnlineDemoPage) from this same pnlCurve and also handed
// to TradeRecordsTable -- so a trade plotted at "3.92 min" here shows the same
// "3.92" in the Order Blotter, instead of each component picking its own
// origin from its own first row (a trade's first row and the curve's first
// sample don't land at the same instant, so those independently-zeroed clocks
// used to disagree).
export default function PnLChart({ pnlCurve, firstTimestampNs, unit }) {
    const points = toChartPoints(pnlCurve, firstTimestampNs, unit);

    return (
        <div className="panel">
            <h3>PnL Curve</h3>
            {points.length === 0 ? (
                <div className="hint">No PnL samples yet. Run a simulation to populate this chart.</div>
            ) : (
                <ResponsiveContainer width="100%" height={340}>
                    <LineChart data={points} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
                        <CartesianGrid stroke="#1b212f" strokeDasharray="2 4" />
                        <XAxis
                            dataKey="t"
                            stroke="#4b5468"
                            tick={{ fontSize: 11, fontFamily: "JetBrains Mono, monospace" }}
                            tickFormatter={(v) => v.toLocaleString()}
                            label={{
                                value: unit.label,
                                position: "insideBottom",
                                offset: -4,
                                fill: "#4b5468",
                                fontSize: 10,
                            }}
                        />
                        <YAxis
                            stroke="#4b5468"
                            tick={{ fontSize: 11, fontFamily: "JetBrains Mono, monospace" }}
                            width={64}
                            tickFormatter={fmtCompactCurrency}
                            label={{
                                value: "PnL ($)",
                                angle: -90,
                                position: "insideLeft",
                                fill: "#4b5468",
                                fontSize: 10,
                            }}
                        />
                        <Tooltip
                            contentStyle={{
                                background: "#161b26",
                                border: "1px solid #232a3a",
                                borderRadius: 3,
                                fontFamily: "JetBrains Mono, monospace",
                                fontSize: 12,
                            }}
                            labelStyle={{ color: "#8792a6" }}
                            formatter={(value) => fmtCurrency(value)}
                            labelFormatter={(t) => `${t.toLocaleString()} ${unit.suffix} elapsed`}
                        />
                        <Legend wrapperStyle={{ fontSize: 11, fontFamily: "Space Grotesk, sans-serif" }} />
                        <ReferenceLine y={0} stroke="#4b5468" />
                        <Line
                            type="monotone"
                            dataKey="realized"
                            name="Realized"
                            stroke="#5eead4"
                            dot={false}
                            isAnimationActive={false}
                            strokeWidth={2}
                        />
                        <Line
                            type="monotone"
                            dataKey="unrealized"
                            name="Unrealized"
                            stroke="#f0b429"
                            dot={false}
                            isAnimationActive={false}
                            strokeWidth={2}
                        />
                        <Line
                            type="monotone"
                            dataKey="total"
                            name="Total"
                            stroke="#e8ecf3"
                            strokeDasharray="4 3"
                            dot={false}
                            isAnimationActive={false}
                            strokeWidth={1.5}
                        />
                    </LineChart>
                </ResponsiveContainer>
            )}
        </div>
    );
}

function toChartPoints(pnlCurve, firstTimestampNs, unit) {
    if (!pnlCurve || pnlCurve.length === 0) return [];
    return pnlCurve.map((p) => ({
        t: Number((elapsedSeconds(p.timestamp_ns, firstTimestampNs) / unit.divisor).toFixed(2)),
        realized: p.realized_pnl,
        unrealized: p.unrealized_pnl,
        total: p.realized_pnl + p.unrealized_pnl,
    }));
}
