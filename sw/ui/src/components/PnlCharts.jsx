import React from "react";
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

// Colors here reuse styles.css's :root custom properties -- SVG/Recharts
// props accept var(...) directly, so there's no need to hardcode hex that
// could silently drift from the theme.
const GRID = "var(--rule)";
const AXIS = "var(--dim)";
const TOOLTIP_BG = "var(--panel)";
const ZERO_LINE = "var(--faint)";

// Shared PnL/position chart pair. `points` is an array of
// { t, realized, unrealized, total, position } -- see pnl.js's
// pnlCurveToPoints for how callers (StrategyCompilerPage,
// AlphaEngineCompilerPage) produce this shape from a returned pnl_curve.
export default function PnlCharts({ points }) {
    return (
        <>
            <div className="panel">
                <h3>Realized vs Unrealized PnL</h3>
                <ResponsiveContainer width="100%" height={280}>
                    <LineChart data={points} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
                        <CartesianGrid stroke={GRID} strokeDasharray="3 3" />
                        <XAxis
                            dataKey="t"
                            stroke={AXIS}
                            tick={{ fontSize: 11 }}
                            label={{ value: "sim seconds", position: "insideBottom", offset: -2, fill: AXIS, fontSize: 11 }}
                        />
                        <YAxis stroke={AXIS} tick={{ fontSize: 11 }} width={64} />
                        <Tooltip
                            contentStyle={{ background: TOOLTIP_BG, border: `1px solid ${GRID}`, borderRadius: 8 }}
                            labelStyle={{ color: AXIS }}
                        />
                        <Legend wrapperStyle={{ fontSize: 12 }} />
                        <ReferenceLine y={0} stroke={ZERO_LINE} />
                        <Line type="monotone" dataKey="realized" name="Realized" stroke="var(--trace)" dot={false} isAnimationActive={false} strokeWidth={2} />
                        <Line type="monotone" dataKey="unrealized" name="Unrealized" stroke="var(--amber)" dot={false} isAnimationActive={false} strokeWidth={2} />
                    </LineChart>
                </ResponsiveContainer>
            </div>

            <div className="panel">
                <h3>Position Size</h3>
                <ResponsiveContainer width="100%" height={200}>
                    <LineChart data={points} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
                        <CartesianGrid stroke={GRID} strokeDasharray="3 3" />
                        <XAxis dataKey="t" stroke={AXIS} tick={{ fontSize: 11 }} />
                        <YAxis stroke={AXIS} tick={{ fontSize: 11 }} width={64} />
                        <Tooltip
                            contentStyle={{ background: TOOLTIP_BG, border: `1px solid ${GRID}`, borderRadius: 8 }}
                            labelStyle={{ color: AXIS }}
                        />
                        <ReferenceLine y={0} stroke={ZERO_LINE} />
                        <Line type="stepAfter" dataKey="position" name="Position" stroke="var(--bid)" dot={false} isAnimationActive={false} strokeWidth={2} />
                    </LineChart>
                </ResponsiveContainer>
            </div>
        </>
    );
}
