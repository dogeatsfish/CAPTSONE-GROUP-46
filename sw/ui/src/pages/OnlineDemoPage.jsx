import { useCallback, useEffect, useMemo, useState } from "react";
import Header from "../components/Header";
import ControlPanel from "../components/ControlPanel";
import ResultsSummary from "../components/ResultsSummary";
import PnLChart from "../components/PnLChart";
import TradeRecordsTable from "../components/TradeRecordsTable";
import TopOfBook from "../components/TopOfBook.jsx";
import OuchPacketLog from "../components/OuchPacketLog.jsx";
import ErrorBanner from "../components/ErrorBanner";
import { useDatasets } from "../hooks/useDatasets";
import { useSimulation } from "../hooks/useSimulation";
import { useEventSourceRun } from "../lib/useEventSourceRun.js";
import { computeLiveMetrics } from "../utils/metrics.js";
import { elapsedSeconds, pickElapsedUnit } from "../utils/format";

// A chatty/misbehaving board could send a lot of packets; cap retained rows
// so a single run can't grow the log unbounded (mirrors the compiler pages'
// MAX_LOG_LINES).
const MAX_OUCH_PACKETS = 500;

export default function OnlineDemoPage() {
    const [mode, setMode] = useState("offline");
    const [selectedDataset, setSelectedDataset] = useState(null);
    const [topOfBook, setTopOfBook] = useState(null); // { bestBid, bestAsk } -- live, online mode only
    const [liveCurve, setLiveCurve] = useState([]); // pnl_curve built up live from "pnl" events
    const [liveTrades, setLiveTrades] = useState([]); // trades built up live from "trade" events
    const [ouchPackets, setOuchPackets] = useState([]); // every inbound OUCH packet, live
    const [streamResult, setStreamResult] = useState(null); // set from the SSE "complete" event
    const [onlineTarget, setOnlineTarget] = useState("loopback"); // "loopback" | "hardware"

    const { datasets, loading: datasetsLoading, error: datasetsError } = useDatasets();

    // Offline mode: blocking POST /simulate, waits for the full result.
    const blocking = useSimulation();

    // Online mode: live via SSE (/simulate/online/stream). Each "pnl" event
    // updates both the top-of-book card and the running PnL curve so the
    // chart actually animates during the run instead of sitting empty until
    // "complete" arrives. Each "trade" event (one per fill, loopback local
    // strategy or a real inbound OUCH order -- see set_trade_observer in
    // online_simulation.h) does the same for the Order Blotter.
    const onStreamEvent = useCallback((evt) => {
        if (evt.type === "pnl") {
            // Hold each side's last known value instead of overwriting both
            // on every sample: this dataset's book is thin and routinely
            // one-sided at any given instant (best_bid/best_ask legitimately
            // read 0 when nothing rests on that side right then), so blindly
            // replacing both fields every time made a real, still-resting
            // quote flash briefly then blank out the moment the *other*
            // side's momentary zero came through.
            setTopOfBook((prev) => ({
                bestBid: evt.best_bid > 0 ? evt.best_bid : prev?.bestBid,
                bestAsk: evt.best_ask > 0 ? evt.best_ask : prev?.bestAsk,
            }));
            setLiveCurve((prev) => [
                ...prev,
                {
                    timestamp_ns: evt.timestamp_ns,
                    realized_pnl: evt.realized_pnl,
                    unrealized_pnl: evt.unrealized_pnl,
                    position_size: evt.position_size,
                },
            ]);
        } else if (evt.type === "trade") {
            setLiveTrades((prev) => [
                ...prev,
                {
                    timestamp_ns: evt.timestamp_ns,
                    side: evt.side,
                    price: evt.price,
                    size: evt.size,
                    decision_latency_ns: evt.decision_latency_ns,
                },
            ]);
        } else if (evt.type === "ouch") {
            setOuchPackets((prev) => {
                const next = [...prev, evt];
                return next.length > MAX_OUCH_PACKETS ? next.slice(next.length - MAX_OUCH_PACKETS) : next;
            });
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
            setLiveTrades([]);
            setOuchPackets([]);
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
        setLiveTrades([]);
        setOuchPackets([]);
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

    // Same idea as pnlCurve above: once "complete" lands, its trades array
    // is authoritative; until then, show what's streamed in live.
    const trades = isOnline ? streamResult?.trades ?? liveTrades : blocking.result?.trades ?? [];

    // Shared elapsed-time origin/unit for both PnLChart and TradeRecordsTable
    // -- computed once, here, from pnlCurve alone (never from `trades`), so a
    // fill's "Sim Time" in the blotter always lines up with the same instant
    // on the graph's x-axis. Previously each component computed its own
    // origin from its own first row (first trade vs. first PnL sample), which
    // don't land at the same instant, so the two "elapsed" numbers disagreed.
    const firstTimestampNs = pnlCurve.length > 0 ? pnlCurve[0].timestamp_ns : 0;
    const totalElapsedSeconds =
        pnlCurve.length > 0
            ? elapsedSeconds(pnlCurve[pnlCurve.length - 1].timestamp_ns, firstTimestampNs)
            : 0;
    const elapsedUnit = pickElapsedUnit(totalElapsedSeconds);

    // A hardware run can go for minutes (or, at real-time pacing, hours)
    // before "complete" ever arrives, so Final Results would otherwise sit
    // on "--" the whole time even though real PnL is accruing. Recompute the
    // full metrics set (drawdown/Sharpe/volatility/Time-per-Trade, not just
    // final_pnl) from whatever's streamed in so far -- same math as
    // metrics.py, ported to utils/metrics.js -- the same tradeoff the PnL
    // number/graph already accept: early in a run this is naturally noisy
    // (e.g. Sharpe off 2-3 samples), but that's more useful than "--" for a
    // run that might not finish for hours. useMemo since liveCurve can grow
    // into the thousands over a long real-time-paced run, and this would
    // otherwise recompute on every unrelated re-render (e.g. top-of-book
    // ticks). Deliberately gated on liveCurve.length > 0, not `running`:
    // Stop moves status to "idle" without ever delivering a "complete"
    // event, so a `running` check here would blank Final Results back to
    // "--" the instant you stopped a run, discarding the last-known figures
    // instead of holding them (liveCurve/liveTrades aren't cleared by stop
    // -- only by Reset/a new run).
    const liveMetrics = useMemo(
        () => (isOnline && liveCurve.length > 0 ? computeLiveMetrics(liveCurve, liveTrades) : null),
        [isOnline, liveCurve, liveTrades]
    );
    const metrics = result?.metrics ?? liveMetrics;

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

            {isOnline && (running || ouchPackets.length > 0) && (
                <OuchPacketLog packets={ouchPackets} />
            )}

            <ResultsSummary metrics={metrics} />

            <div className="market-grid">
                <PnLChart pnlCurve={pnlCurve} firstTimestampNs={firstTimestampNs} unit={elapsedUnit} />
                <TradeRecordsTable trades={trades} firstTimestampNs={firstTimestampNs} unit={elapsedUnit} />
            </div>
        </div>
    );
}
