import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
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

const STATUS_LABEL = {
    idle: "Idle",
    running: "Streaming live telemetry…",
    complete: "Run complete",
    error: "Error",
};

function fmt(n, digits = 2) {
    if (n === null || n === undefined || Number.isNaN(n)) return "—";
    return Number(n).toLocaleString(undefined, {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits,
    });
}

export default function App() {
    const [status, setStatus] = useState("idle");
    const [points, setPoints] = useState([]);
    const [summary, setSummary] = useState(null);
    const [error, setError] = useState(null);

    const esRef = useRef(null);
    const firstTsRef = useRef(null);

    const cleanup = useCallback(() => {
        if (esRef.current) {
            esRef.current.close();
            esRef.current = null;
        }
    }, []);

    useEffect(() => cleanup, [cleanup]);

    const runOnline = useCallback(async () => {
        cleanup();
        setPoints([]);
        setSummary(null);
        setError(null);
        setStatus("running");
        firstTsRef.current = null;

        let streamUrl;
        try {
            // POST starts the run (empty body -> server default = the main data
            // pipeline file, synthetic_mbo_stream.bin) and returns a stream URL.
            const res = await fetch("/simulate/online/stream", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: "{}",
            });
            if (!res.ok) throw new Error(`start failed: HTTP ${res.status}`);
            ({ stream_url: streamUrl } = await res.json());
        } catch (e) {
            setError(String(e));
            setStatus("error");
            return;
        }

        // GET the SSE stream via native EventSource.
        const es = new EventSource(streamUrl);
        esRef.current = es;

        es.onmessage = (ev) => {
            let evt;
            try {
                evt = JSON.parse(ev.data);
            } catch {
                return;
            }

            if (evt.type === "pnl") {
                if (firstTsRef.current === null) firstTsRef.current = evt.timestamp_ns;
                const t = Number(evt.timestamp_ns - firstTsRef.current) / 1e9; // seconds
                setPoints((prev) => [
                    ...prev,
                    {
                        t: Number(t.toFixed(2)),
                        realized: evt.realized_pnl,
                        unrealized: evt.unrealized_pnl,
                        total: evt.realized_pnl + evt.unrealized_pnl,
                        position: evt.position_size,
                    },
                ]);
            } else if (evt.type === "complete") {
                setSummary({
                    total_trades: evt.total_trades,
                    compute_time_us: evt.compute_time_us,
                });
                setStatus("complete");
                cleanup();
            } else if (evt.type === "error") {
                setError(evt.detail || "engine error");
                setStatus("error");
                cleanup();
            }
        };

        es.onerror = () => {
            // Fires on network close. If we didn't already finish, surface it.
            setStatus((s) => (s === "running" ? "error" : s));
            setError((e) => e || "stream connection lost");
            cleanup();
        };
    }, [cleanup]);

    const stop = useCallback(() => {
        cleanup();
        setStatus((s) => (s === "running" ? "idle" : s));
    }, [cleanup]);

    const last = points.length ? points[points.length - 1] : null;
    const totalPnl = last ? last.total : 0;

    const sign = (v) => (v > 0 ? "pos" : v < 0 ? "neg" : "");

    const elapsed = useMemo(
        () => (last ? `${fmt(last.t, 1)}s` : "—"),
        [last]
    );

    return (
        <div className="app">
            <div className="header">
                <div>
                    <div className="title">HFT Online Simulation</div>
                    <div className="subtitle">
                        Real-time ITCH replay · OUCH order entry · live PnL telemetry via SSE
                    </div>
                </div>
                <div className="controls">
                    <span className="status">
                        <span className={`dot ${status}`} />
                        {STATUS_LABEL[status]}
                    </span>
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

            <div className="cards">
                <div className="card">
                    <div className="label">Total PnL</div>
                    <div className={`value ${sign(totalPnl)}`}>{fmt(totalPnl)}</div>
                </div>
                <div className="card">
                    <div className="label">Position</div>
                    <div className={`value ${sign(last?.position ?? 0)}`}>
                        {last ? fmt(last.position, 0) : "—"}
                    </div>
                </div>
                <div className="card">
                    <div className="label">Sim Elapsed</div>
                    <div className="value">{elapsed}</div>
                </div>
                <div className="card">
                    <div className="label">Total Trades</div>
                    <div className="value">{summary ? summary.total_trades.toLocaleString() : "—"}</div>
                </div>
            </div>

            <div className="panel">
                <h3>Realized vs Unrealized PnL</h3>
                <ResponsiveContainer width="100%" height={280}>
                    <LineChart data={points} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
                        <CartesianGrid stroke="#232c3d" strokeDasharray="3 3" />
                        <XAxis
                            dataKey="t"
                            stroke="#8a97ad"
                            tick={{ fontSize: 11 }}
                            label={{ value: "sim seconds", position: "insideBottom", offset: -2, fill: "#8a97ad", fontSize: 11 }}
                        />
                        <YAxis stroke="#8a97ad" tick={{ fontSize: 11 }} width={64} />
                        <Tooltip
                            contentStyle={{ background: "#121722", border: "1px solid #232c3d", borderRadius: 8 }}
                            labelStyle={{ color: "#8a97ad" }}
                        />
                        <Legend wrapperStyle={{ fontSize: 12 }} />
                        <ReferenceLine y={0} stroke="#3a4459" />
                        <Line type="monotone" dataKey="realized" name="Realized" stroke="#4dd0e1" dot={false} isAnimationActive={false} strokeWidth={2} />
                        <Line type="monotone" dataKey="unrealized" name="Unrealized" stroke="#ffb454" dot={false} isAnimationActive={false} strokeWidth={2} />
                    </LineChart>
                </ResponsiveContainer>
            </div>

            <div className="panel">
                <h3>Position Size</h3>
                <ResponsiveContainer width="100%" height={200}>
                    <LineChart data={points} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
                        <CartesianGrid stroke="#232c3d" strokeDasharray="3 3" />
                        <XAxis dataKey="t" stroke="#8a97ad" tick={{ fontSize: 11 }} />
                        <YAxis stroke="#8a97ad" tick={{ fontSize: 11 }} width={64} />
                        <Tooltip
                            contentStyle={{ background: "#121722", border: "1px solid #232c3d", borderRadius: 8 }}
                            labelStyle={{ color: "#8a97ad" }}
                        />
                        <ReferenceLine y={0} stroke="#3a4459" />
                        <Line type="stepAfter" dataKey="position" name="Position" stroke="#35d07f" dot={false} isAnimationActive={false} strokeWidth={2} />
                    </LineChart>
                </ResponsiveContainer>
            </div>

            <div className="hint">
                Data: server default MBO stream (data_pipeline/data/synthetic_mbo_stream.bin).
                Telemetry samples once per simulated second; pacing is set server-side
                (ONLINE_STREAM_TIME_SCALE). The engine's ITCH/UDP + OUCH/TCP sockets stay
                entirely on the server.
            </div>
        </div>
    );
}
