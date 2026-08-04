import React, { useCallback, useEffect, useRef, useState } from "react";
import PnlCharts from "../components/PnlCharts.jsx";
import StatCards from "../components/StatCards.jsx";
import StatusIndicator from "../components/StatusIndicator.jsx";
import { fmt } from "../lib/format.js";
import { pnlCurveToPoints } from "../lib/pnl.js";
import { useEventSourceRun } from "../lib/useEventSourceRun.js";

const STATUS_LABEL = {
    idle: "Idle",
    running: "Compiling…",
    complete: "Run complete",
    error: "Error",
};

// A noisy compile (-Wall -Wextra plus run stderr) can emit many lines;
// cap retained lines so a single run can't grow the log panel unbounded.
const MAX_LOG_LINES = 500;

// Pre-filled with the same spread-reversion body shipped in
// sw/engine/simulation/src/user_strategy.cpp today, so the box demonstrates
// working logic instead of starting empty. Just the function body -- the
// surrounding class (state fields, on_fill, constructor) is fixed; editing
// those is a future stretch goal, not this first pass.
const DEFAULT_BODY = `// 1. Ensure the order book has liquidity before making decisions
if (current_l1.best_ask == 0.0 || current_l1.best_bid == 0.0) {
    return std::nullopt;
}

double current_spread = current_l1.best_ask - current_l1.best_bid;
std::optional<Order> order_to_send = std::nullopt;

// On the very first two-sided quote we have no prior tick to compare
// against, so just seed the trackers and wait for the next update.
if (!have_last_l1) {
    last_bid = current_l1.best_bid;
    last_ask = current_l1.best_ask;
    last_spread = current_spread;
    have_last_l1 = true;
    return std::nullopt;
}

// 2. Spread-Reversion Logic:
// If the spread widened compared to the last tick, we push back.
if (current_spread > last_spread && last_spread > 0.0) {
    // Did the ask move up, widening the spread?
    if (current_l1.best_ask > last_ask) {
        Order aggressive_sell;
        aggressive_sell.order_id = next_strategy_order_id++;
        aggressive_sell.price    = current_l1.best_bid;
        aggressive_sell.size     = 100.0;
        aggressive_sell.side     = 'S';
        aggressive_sell.is_synthetic = true;
        order_to_send = aggressive_sell;
    }
    // Did the bid move down, widening the spread?
    else if (current_l1.best_bid < last_bid) {
        Order aggressive_buy;
        aggressive_buy.order_id = next_strategy_order_id++;
        aggressive_buy.price    = current_l1.best_ask;
        aggressive_buy.size     = 100.0;
        aggressive_buy.side     = 'B';
        aggressive_buy.is_synthetic = true;
        order_to_send = aggressive_buy;
    }
}

// 3. Update the state trackers for the next tick
last_bid = current_l1.best_bid;
last_ask = current_l1.best_ask;
last_spread = current_spread;

return order_to_send;`;

export default function StrategyCompilerPage() {
    const [body, setBody] = useState(DEFAULT_BODY);
    const [datasets, setDatasets] = useState([]);
    const [dataset, setDataset] = useState("");
    const [logs, setLogs] = useState([]);
    const [points, setPoints] = useState([]);
    const [summary, setSummary] = useState(null);

    const logEndRef = useRef(null);

    useEffect(() => {
        fetch("/datasets")
            .then((r) => r.json())
            .then((d) => setDatasets(d.datasets || []))
            .catch(() => {
                /* dataset picker just stays empty -> server default is used */
            });
    }, []);

    useEffect(() => {
        logEndRef.current?.scrollIntoView({ block: "nearest" });
    }, [logs]);

    const onEvent = useCallback((evt) => {
        if (evt.type === "log") {
            setLogs((prev) => {
                const next = [...prev, evt.line];
                return next.length > MAX_LOG_LINES ? next.slice(next.length - MAX_LOG_LINES) : next;
            });
        } else if (evt.type === "complete") {
            const result = evt.result;
            setPoints(pnlCurveToPoints(result.pnl_curve));
            setSummary({
                total_trades: result.total_trades,
                compute_time_us: result.compute_time_us,
                ...result.metrics,
            });
        }
    }, []);

    const { status, error, start } = useEventSourceRun({
        startUrl: "/compile/software",
        onEvent,
    });

    const compileAndRun = useCallback(() => {
        setLogs([]);
        setPoints([]);
        setSummary(null);
        start({ on_market_update_body: body, data_file: dataset || undefined });
    }, [start, body, dataset]);

    const last = points.length ? points[points.length - 1] : null;
    const totalPnl = last ? last.total : 0;
    const running = status === "running";

    return (
        <div>
            <div className="header">
                <div>
                    <div className="title">Strategy Compiler</div>
                    <div className="subtitle">
                        Edit Strategy::on_market_update, compile it to a native binary, run it
                        against a dataset -- no Vivado/hardware involved.
                    </div>
                </div>
                <div className="controls">
                    <StatusIndicator status={status} labels={STATUS_LABEL} />
                    <button onClick={compileAndRun} disabled={running}>
                        {running ? "Running…" : "Compile & Run"}
                    </button>
                </div>
            </div>

            {error && <div className="error-banner">{error}</div>}

            <div className="panel">
                <h3>on_market_update body</h3>
                <div className="hint" style={{ marginBottom: 8 }}>
                    Just the function body -- it's spliced into the fixed Strategy class
                    (state fields, constructor, on_fill stay as shipped). Signature:{" "}
                    <code>std::optional&lt;Order&gt; on_market_update(const L1State&amp; current_l1)</code>.
                    Braces must balance within the body you submit.
                </div>
                <textarea
                    className="code-editor"
                    value={body}
                    onChange={(e) => setBody(e.target.value)}
                    spellCheck={false}
                    disabled={running}
                    rows={20}
                />
            </div>

            <div className="panel">
                <h3>Dataset</h3>
                <select
                    value={dataset}
                    onChange={(e) => setDataset(e.target.value)}
                    disabled={running}
                >
                    <option value="">Server default (synthetic_mbo_stream.bin)</option>
                    {datasets.map((d) => (
                        <option key={d} value={d}>
                            {d}
                        </option>
                    ))}
                </select>
            </div>

            {logs.length > 0 && (
                <div className="panel">
                    <h3>Compiler / run log</h3>
                    <pre className="log-panel">
                        {logs.join("\n")}
                        <div ref={logEndRef} />
                    </pre>
                </div>
            )}

            {status === "complete" && (
                <>
                    <StatCards
                        items={[
                            { label: "Total PnL", display: fmt(totalPnl), raw: totalPnl },
                            {
                                label: "Position",
                                display: last ? fmt(last.position, 0) : "—",
                                raw: last?.position ?? 0,
                            },
                            {
                                label: "Compute Time",
                                display: summary ? `${fmt(summary.compute_time_us / 1000, 1)} ms` : "—",
                            },
                            {
                                label: "Total Trades",
                                display: summary ? summary.total_trades.toLocaleString() : "—",
                            },
                            {
                                label: "Max Drawdown",
                                display: summary
                                    ? `$${fmt(summary.max_drawdown)} (${fmt(summary.max_drawdown_pct, 1)}%)`
                                    : "—",
                                raw: summary ? -Math.abs(summary.max_drawdown) : undefined,
                            },
                            {
                                label: "Sharpe Ratio (ann.)",
                                display: summary ? fmt(summary.sharpe_ratio) : "—",
                                raw: summary?.sharpe_ratio,
                            },
                            {
                                label: "Volatility ($/s)",
                                display: summary ? `$${fmt(summary.volatility)}` : "—",
                            },
                            {
                                label: "Trade Throughput",
                                display: summary ? `${fmt(summary.trades_per_second, 1)} trades/s` : "—",
                            },
                        ]}
                    />
                    <PnlCharts points={points} />
                </>
            )}
        </div>
    );
}
