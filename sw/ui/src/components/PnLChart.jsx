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
import { elapsedSeconds } from "../utils/format";

// pnlCurve: SimulationResponse.pnl_curve, i.e.
// [{ timestamp_ns, realized_pnl, unrealized_pnl, position_size }, ...]
export default function PnLChart({ pnlCurve }) {
    const points = toChartPoints(pnlCurve);

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
                            label={{
                                value: "sim seconds",
                                position: "insideBottom",
                                offset: -4,
                                fill: "#4b5468",
                                fontSize: 10,
                            }}
                        />
                        <YAxis
                            stroke="#4b5468"
                            tick={{ fontSize: 11, fontFamily: "JetBrains Mono, monospace" }}
                            width={76}
                            tickFormatter={(v) => v.toLocaleString()}
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

function toChartPoints(pnlCurve) {
    if (!pnlCurve || pnlCurve.length === 0) return [];
    const firstTs = pnlCurve[0].timestamp_ns;
    return pnlCurve.map((p) => ({
        t: Number(elapsedSeconds(p.timestamp_ns, firstTs).toFixed(2)),
        realized: p.realized_pnl,
        unrealized: p.unrealized_pnl,
        total: p.realized_pnl + p.unrealized_pnl,
    }));
}
