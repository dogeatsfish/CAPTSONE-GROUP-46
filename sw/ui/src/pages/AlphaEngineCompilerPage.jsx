import React, { useCallback, useEffect, useRef, useState } from "react";
import StatCards from "../components/StatCards.jsx";
import StatusIndicator from "../components/StatusIndicator.jsx";
import { fmt } from "../lib/format.js";
import { useEventSourceRun } from "../lib/useEventSourceRun.js";
import { DEFAULT_SOURCE } from "../lib/defaultAlphaEngineSource.js";

const STATUS_LABEL = {
    idle: "Idle",
    running: "Synthesizing…",
    complete: "Synthesis complete",
    error: "Error",
};

// Vivado batch runs are chatty; cap retained lines so a single run can't
// grow the log panel unbounded (mirrors StrategyCompilerPage).
const MAX_LOG_LINES = 500;

export default function AlphaEngineCompilerPage() {
    const [source, setSource] = useState(DEFAULT_SOURCE);
    const [logs, setLogs] = useState([]);
    const [report, setReport] = useState(null);

    const logEndRef = useRef(null);

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
            setReport(evt);
        }
    }, []);

    const { status, error, start } = useEventSourceRun({
        startUrl: "/compile",
        onEvent,
    });

    const running = status === "running";

    const compile = useCallback(() => {
        setLogs([]);
        setReport(null);
        start({ source });
    }, [start, source]);

    return (
        <div>
            <div className="header">
                <div>
                    <div className="title">Alpha Engine Compiler</div>
                    <div className="subtitle">
                        Edit alpha_engine_core (the FS-8 sandbox module), run it through an
                        out-of-context Vivado synthesis, and see utilization + timing --
                        no bitstream generation or board flash, synthesis/report only.
                    </div>
                </div>
                <div className="controls">
                    <StatusIndicator status={status} labels={STATUS_LABEL} />
                    <button onClick={compile} disabled={running}>
                        {running ? "Synthesizing…" : "Compile"}
                    </button>
                </div>
            </div>

            {error && <div className="error-banner">{error}</div>}

            <div className="panel">
                <h3>alpha_engine_core.sv</h3>
                <div className="hint" style={{ marginBottom: 8 }}>
                    Pre-filled with the shipped prototype (mean-reversion over an EMA of
                    mid-price). The port list is the fixed FS-8 sandbox interface -- any
                    module conforming to it drops in. Compiles as{" "}
                    <code>module alpha_engine_core</code>.
                </div>
                <textarea
                    className="code-editor"
                    value={source}
                    onChange={(e) => setSource(e.target.value)}
                    spellCheck={false}
                    disabled={running}
                    rows={24}
                />
            </div>

            {logs.length > 0 && (
                <div className="panel">
                    <h3>Vivado log</h3>
                    <pre className="log-panel">
                        {logs.join("\n")}
                        <div ref={logEndRef} />
                    </pre>
                </div>
            )}

            {status === "complete" && report && (
                <>
                    <StatCards
                        items={[
                            {
                                label: "Synth Time",
                                display: report.synth_time_s != null ? `${fmt(report.synth_time_s, 1)} s` : "—",
                            },
                            { label: "LUTs", display: report.lut_count?.toLocaleString() ?? "—" },
                            { label: "FFs", display: report.ff_count?.toLocaleString() ?? "—" },
                            { label: "DSPs", display: report.dsp_count?.toLocaleString() ?? "—" },
                            { label: "Block RAM Tiles", display: report.bram_count?.toLocaleString() ?? "—" },
                        ]}
                    />
                    {report.timing_summary && (
                        <div className="panel">
                            <h3>Timing summary</h3>
                            <pre className="log-panel">{report.timing_summary}</pre>
                        </div>
                    )}
                </>
            )}
        </div>
    );
}
