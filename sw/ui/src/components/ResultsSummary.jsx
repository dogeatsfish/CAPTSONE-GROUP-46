import { fmtCurrency, fmtDuration, fmtNumber, signClass } from "../utils/format";

// metrics: SimulationResponse.metrics, i.e.
// { final_pnl, max_drawdown, max_drawdown_pct, volatility, sharpe_ratio, compute_time_us }
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
                    <div className="label">Current PnL</div>
                    <div className={`value ${signClass(m?.final_pnl ?? 0)}`}>
                        {m ? fmtCurrency(m.final_pnl) : "—"}
                    </div>
                </div>
                <div className="card">
                    <div className="label">Compute Time</div>
                    <div className="value">{m ? fmtDuration(m.compute_time_us) : "—"}</div>
                </div>
                <div className="card">
                    <div className="label">Max Drawdown</div>
                    <div className="value neg">
                        {m ? `${fmtCurrency(m.max_drawdown)} (${fmtNumber(m.max_drawdown_pct, 1)}%)` : "—"}
                    </div>
                </div>
                <div className="card">
                    <div className="label">Sharpe Ratio</div>
                    <div className={`value ${signClass(m?.sharpe_ratio ?? 0)}`}>
                        {m ? fmtNumber(m.sharpe_ratio, 2) : "—"}
                    </div>
                </div>
                <div className="card">
                    <div className="label">Volatility</div>
                    <div className="value">{m ? fmtCurrency(m.volatility) : "—"}</div>
                </div>
            </div>
            {m && (
                <div className="hint" style={{ marginTop: 14 }}>
                    Sharpe is annualized from per-second PnL samples (252 trading days ×
                    23,400s/day). Volatility is the standard deviation of second-over-second PnL
                    change, in the same $ units as PnL.
                </div>
            )}
        </div>
    );
}
