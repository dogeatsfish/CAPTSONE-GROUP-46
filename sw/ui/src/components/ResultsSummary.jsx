import {
    fmtCompactCurrency,
    fmtCompactPercent,
    fmtCurrency,
    fmtDurationPerTrade,
    fmtNumber,
    signClass,
} from "../utils/format";
import AutoFitValue from "./AutoFitValue";

// metrics: SimulationResponse.metrics, i.e.
// { final_pnl, max_drawdown, max_drawdown_pct, volatility, sharpe_ratio,
//   compute_time_us, trades_per_second, avg_decision_latency_ns }
//
// Time / Trade shows the real measured decision-to-fill latency
// (avg_decision_latency_ns -- see metrics.py) when a run has it: today only
// online-loopback local-strategy trades are instrumented (0 = not
// measured). There's deliberately no fallback to compute_time_us /
// total_trades here anymore -- that's total batch-processing time
// (parsing/replaying every record, not just trade-triggering ones) diluted
// across only the trade count, not a per-trade timing figure, and showing
// it under this label was misleading (looked like a real, comparable
// latency when it wasn't). Offline runs and hardware-target runs render
// "--" until they're instrumented the same way loopback is.
export default function ResultsSummary({ metrics }) {
    const m = metrics ?? null;
    const hasRealLatency = m?.avg_decision_latency_ns > 0;
    const usPerTrade = hasRealLatency ? m.avg_decision_latency_ns / 1_000 : undefined;

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
                    <div className="label">Time / Trade</div>
                    <AutoFitValue
                        max={24}
                        className="value"
                        text={hasRealLatency ? fmtDurationPerTrade(usPerTrade) : "—"}
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
                    {hasRealLatency ? (
                        <>Time / Trade is the average real wall-clock decision-to-fill latency
                        across every trade this run made -- actual software execution speed, not a
                        benchmark.{" "}</>
                    ) : (
                        <>Time / Trade isn't measured for this run (only online-loopback
                        local-strategy trades are instrumented today).{" "}</>
                    )}
                    Sharpe is annualized from per-second PnL samples (252 trading days ×
                    23,400s/day). Volatility is the standard deviation of second-over-second PnL
                    change.
                </div>
            )}
        </div>
    );
}
