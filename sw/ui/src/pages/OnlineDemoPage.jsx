import { useCallback, useEffect, useState } from "react";
import Header from "../components/Header";
import ControlPanel from "../components/ControlPanel";
import ResultsSummary from "../components/ResultsSummary";
import PnLChart from "../components/PnLChart";
import TradeRecordsTable from "../components/TradeRecordsTable";
import TopOfBook from "../components/TopOfBook.jsx";
import ErrorBanner from "../components/ErrorBanner";
import { useDatasets } from "../hooks/useDatasets";
import { useSimulation } from "../hooks/useSimulation";
import { useEventSourceRun } from "../lib/useEventSourceRun.js";

export default function OnlineDemoPage() {
    const [mode, setMode] = useState("offline");
    const [selectedDataset, setSelectedDataset] = useState(null);
    const [topOfBook, setTopOfBook] = useState(null); // { bestBid, bestAsk } -- live, online mode only
    const [liveCurve, setLiveCurve] = useState([]); // pnl_curve built up live from "pnl" events
    const [streamResult, setStreamResult] = useState(null); // set from the SSE "complete" event
    const [onlineTarget, setOnlineTarget] = useState("loopback"); // "loopback" | "hardware"

    const { datasets, loading: datasetsLoading, error: datasetsError } = useDatasets();

    // Offline mode: blocking POST /simulate, waits for the full result.
    const blocking = useSimulation();

    // Online mode: live via SSE (/simulate/online/stream). Each "pnl" event
    // updates both the top-of-book card and the running PnL curve so the
    // chart actually animates during the run instead of sitting empty until
    // "complete" arrives. Trades don't stream per-fill today (the engine's
    // live callback only carries PnL samples, not fill events), so the Order
    // Blotter still only populates once the full result lands.
    const onStreamEvent = useCallback((evt) => {
        if (evt.type === "pnl") {
            setTopOfBook({ bestBid: evt.best_bid, bestAsk: evt.best_ask });
            setLiveCurve((prev) => [
                ...prev,
                {
                    timestamp_ns: evt.timestamp_ns,
                    realized_pnl: evt.realized_pnl,
                    unrealized_pnl: evt.unrealized_pnl,
                    position_size: evt.position_size,
                },
            ]);
        } else if (evt.type === "complete") {
            setStreamResult(evt);
        }
    }, []);
    const streaming = useEventSourceRun({
        startUrl: "/simulate/online/stream",
        onEvent: onStreamEvent,
    });

    const isOnline = mode === "online";
    const status = isOnline ? streaming.status : blocking.status;
    const error = isOnline ? streaming.error : blocking.error;
    const result = isOnline ? streamResult : blocking.result;

    // Default the toggle list to the first available dataset once it loads.
    useEffect(() => {
        if (!selectedDataset && datasets.length > 0) {
            setSelectedDataset(datasets[0]);
        }
    }, [datasets, selectedDataset]);

    const running = status === "running";
    const canRun = Boolean(selectedDataset) || datasets.length === 0; // fall back to server default

    const handleRun = () => {
        if (isOnline) {
            setTopOfBook(null);
            setLiveCurve([]);
            setStreamResult(null);
            streaming.start({ data_file: selectedDataset || undefined, online_target: onlineTarget });
        } else {
            blocking.run({ mode, dataFile: selectedDataset });
        }
    };

    // Clears both modes' state unconditionally, not just the active one --
    // guards against stale results lingering if the mode was switched after
    // a run (e.g. run offline, flip to online, click Reset: without this an
    // old offline result could still be sitting in `blocking`).
    const handleReset = () => {
        blocking.reset();
        streaming.reset();
        setTopOfBook(null);
        setLiveCurve([]);
        setStreamResult(null);
    };
    // Deliberately excludes "running": the blocking (offline) fetch has no
    // abort mechanism, so resetting mid-run would only clear the UI
    // optimistically -- the in-flight request would still resolve later and
    // overwrite the reset state with stale results. Stop already covers
    // interrupting an active online run; Reset is for clearing a finished
    // (complete/error) one.
    const canReset = status === "complete" || status === "error";

    // Once "complete" lands, its pnl_curve is authoritative (it's the same
    // data the DB got, and covers the rare edge case of a sample landing
    // between the last "pnl" event and the run actually finishing); until
    // then, show what's streamed in live.
    const pnlCurve = isOnline ? streamResult?.pnl_curve ?? liveCurve : blocking.result?.pnl_curve ?? [];

    return (
        <div>
            <Header status={status} />

            <ErrorBanner message={error} />

            <ControlPanel
                mode={mode}
                onModeChange={setMode}
                datasets={datasets}
                datasetsLoading={datasetsLoading}
                datasetsError={datasetsError}
                selectedDataset={selectedDataset}
                onDatasetChange={setSelectedDataset}
                running={running}
                onRun={handleRun}
                canRun={canRun}
                onStop={isOnline ? streaming.stop : undefined}
                onReset={handleReset}
                canReset={canReset}
                onlineTarget={onlineTarget}
                onOnlineTargetChange={isOnline ? setOnlineTarget : undefined}
            />

            {isOnline && (running || topOfBook) && (
                <TopOfBook bestBid={topOfBook?.bestBid} bestAsk={topOfBook?.bestAsk} />
            )}

            <ResultsSummary metrics={result?.metrics} />

            <div className="market-grid">
                <PnLChart pnlCurve={pnlCurve} />
                <TradeRecordsTable trades={result?.trades ?? []} />
            </div>
        </div>
    );
}
