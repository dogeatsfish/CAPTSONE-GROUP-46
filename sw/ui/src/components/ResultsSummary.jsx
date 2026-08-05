import {
    fmtCompactCurrency,
    fmtCompactPercent,
    fmtCurrency,
    fmtNumber,
    signClass,
} from "../utils/format";
import AutoFitValue from "./AutoFitValue";

// metrics: SimulationResponse.metrics, i.e.
// { final_pnl, final_realized_pnl, max_drawdown, max_drawdown_pct,
//   volatility, sharpe_ratio, compute_time_us, trades_per_second,
//   avg_decision_latency_ns }
//
// Current PnL shows final_pnl -- realized plus the open position's unrealized
// mark-to-market -- so the headline reflects total account value including
// open exposure, not just closed trades. (final_realized_pnl is still
// available in metrics if a realized-only view is ever wanted; Realized/
// Unrealized/Total also show as separate lines on the PnL Curve chart.)
export default function ResultsSummary({ metrics }) {
    const m = metrics ?? null;

    return (
        <div className="panel">
            <h3>Final Results</h3>
            <div className="results-grid">
                <div className="card card-hero">
                    <span className="corner corner-tl" />
                    <span className="corner corner-tr" />
                    <span className="corner corner-bl" />
                    <span className="corner corner-br" />
                    <div className="label">Current PnL ($)</div>
                    <AutoFitValue
                        max={30}
                        className={`value ${signClass(m?.final_pnl ?? 0)}`}
                        text={m ? fmtCurrency(m.final_pnl) : "—"}
                    />
                </div>
                <div className="card">
                    <div className="label">Max Drawdown ($)</div>
                    <AutoFitValue
                        max={24}
                        className="value neg"
                        text={m ? `${fmtCompactCurrency(m.max_drawdown)} (${fmtCompactPercent(m.max_drawdown_pct)})` : "—"}
                    />
                </div>
                <div className="card">
                    <div className="label">Sharpe Ratio (ann.)</div>
                    <AutoFitValue
                        max={24}
                        className={`value ${signClass(m?.sharpe_ratio ?? 0)}`}
                        text={m ? fmtNumber(m.sharpe_ratio, 2) : "—"}
                    />
                </div>
                <div className="card">
                    <div className="label">Volatility ($/s)</div>
                    <AutoFitValue max={24} className="value" text={m ? fmtCompactCurrency(m.volatility) : "—"} />
                </div>
            </div>
            {m && (
                <div className="hint" style={{ marginTop: 14 }}>
                    Sharpe is annualized from per-second PnL samples (252 trading days ×
                    23,400s/day). Volatility is the standard deviation of second-over-second PnL
                    change.
                </div>
            )}
        </div>
    );
}
