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
    const [streamResult, setStreamResult] = useState(null); // set from the SSE "complete" event

    const { datasets, loading: datasetsLoading, error: datasetsError } = useDatasets();

    // Offline mode: blocking POST /simulate, waits for the full result.
    const blocking = useSimulation();

    // Online mode: live via SSE (/simulate/online/stream) -- best_bid/best_ask
    // update per "pnl" event, the full result (same shape as the blocking
    // SimulationResponse) arrives on "complete".
    const onStreamEvent = useCallback((evt) => {
        if (evt.type === "pnl") {
            setTopOfBook({ bestBid: evt.best_bid, bestAsk: evt.best_ask });
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
            setStreamResult(null);
            streaming.start({ data_file: selectedDataset || undefined });
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
        setStreamResult(null);
    };
    // Deliberately excludes "running": the blocking (offline) fetch has no
    // abort mechanism, so resetting mid-run would only clear the UI
    // optimistically -- the in-flight request would still resolve later and
    // overwrite the reset state with stale results. Stop already covers
    // interrupting an active online run; Reset is for clearing a finished
    // (complete/error) one.
    const canReset = status === "complete" || status === "error";

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
            />

            {isOnline && (running || topOfBook) && (
                <TopOfBook bestBid={topOfBook?.bestBid} bestAsk={topOfBook?.bestAsk} />
            )}

            <ResultsSummary metrics={result?.metrics} />

            <div className="market-grid">
                <PnLChart pnlCurve={result?.pnl_curve ?? []} />
                <TradeRecordsTable trades={result?.trades ?? []} />
            </div>
        </div>
    );
}
