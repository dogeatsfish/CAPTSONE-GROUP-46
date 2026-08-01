import React, { useCallback, useMemo, useRef, useState } from "react";
import PnlCharts from "./components/PnlCharts.jsx";
import StatCards from "./components/StatCards.jsx";
import StatusIndicator from "./components/StatusIndicator.jsx";
import StrategyCompiler from "./components/StrategyCompiler.jsx";
import { fmt } from "./lib/format.js";
import { capPoints, snapshotToPoint } from "./lib/pnl.js";
import { useEventSourceRun } from "./lib/useEventSourceRun.js";

const STATUS_LABEL = {
    idle: "Idle",
    running: "Streaming live telemetry…",
    complete: "Run complete",
    error: "Error",
};

function OnlineDemo() {
    const [points, setPoints] = useState([]);
    const [summary, setSummary] = useState(null);
    const firstTsRef = useRef(null);

    const onEvent = useCallback((evt) => {
        if (evt.type === "pnl") {
            if (firstTsRef.current === null) firstTsRef.current = evt.timestamp_ns;
            setPoints((prev) => capPoints([...prev, snapshotToPoint(evt, firstTsRef.current)]));
        } else if (evt.type === "complete") {
            setSummary({ total_trades: evt.total_trades, compute_time_us: evt.compute_time_us });
        }
    }, []);

    const { status, error, start, stop } = useEventSourceRun({
        startUrl: "/simulate/online/stream",
        onEvent,
    });

    const runOnline = useCallback(() => {
        setPoints([]);
        setSummary(null);
        firstTsRef.current = null;
        start();
    }, [start]);

    const last = points.length ? points[points.length - 1] : null;
    const totalPnl = last ? last.total : 0;

    const elapsed = useMemo(() => (last ? `${fmt(last.t, 1)}s` : "—"), [last]);

    return (
        <div>
            <div className="header">
                <div>
                    <div className="title">HFT Online Simulation</div>
                    <div className="subtitle">
                        Real-time ITCH replay · OUCH order entry · live PnL telemetry via SSE
                    </div>
                </div>
                <div className="controls">
                    <StatusIndicator status={status} labels={STATUS_LABEL} />
                    {status === "running" ? (
                        <button className="secondary" onClick={stop}>
                            Stop
                        </button>
                    ) : (
                        <button onClick={runOnline}>Run Simulation</button>
                    )}
                </div>
            </div>

            {error && <div className="error-banner">{error}</div>}

            <StatCards
                items={[
                    { label: "Total PnL", display: fmt(totalPnl), raw: totalPnl },
                    {
                        label: "Position",
                        display: last ? fmt(last.position, 0) : "—",
                        raw: last?.position ?? 0,
                    },
                    { label: "Sim Elapsed", display: elapsed },
                    {
                        label: "Total Trades",
                        display: summary ? summary.total_trades.toLocaleString() : "—",
                    },
                ]}
            />

            <PnlCharts points={points} />

            <div className="hint">
                Data: server default MBO stream (data_pipeline/data/synthetic_mbo_stream.bin).
                Telemetry samples once per simulated second; pacing is set server-side
                (ONLINE_STREAM_TIME_SCALE). The engine's ITCH/UDP + OUCH/TCP sockets stay
                entirely on the server.
            </div>
        </div>
    );
}

export default function App() {
    return (
        <div className="app">
            <OnlineDemo />
            <hr className="section-divider" />
            <StrategyCompiler />
        </div>
    );
}
