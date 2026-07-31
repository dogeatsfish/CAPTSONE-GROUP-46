import { useEffect, useState } from "react";
import Header from "./components/Header";
import ControlPanel from "./components/ControlPanel";
import ResultsSummary from "./components/ResultsSummary";
import PnLChart from "./components/PnLChart";
import TradeRecordsTable from "./components/TradeRecordsTable";
import ErrorBanner from "./components/ErrorBanner";
import { useDatasets } from "./hooks/useDatasets";
import { useSimulation } from "./hooks/useSimulation";

export default function App() {
    const [mode, setMode] = useState("offline");
    const [selectedDataset, setSelectedDataset] = useState(null);

    const { datasets, loading: datasetsLoading, error: datasetsError } = useDatasets();
    const { status, result, error, run } = useSimulation();

    // Default the toggle list to the first available dataset once it loads.
    useEffect(() => {
        if (!selectedDataset && datasets.length > 0) {
            setSelectedDataset(datasets[0]);
        }
    }, [datasets, selectedDataset]);

    const running = status === "running";
    const canRun = Boolean(selectedDataset) || datasets.length === 0; // fall back to server default

    const handleRun = () => {
        run({ mode, dataFile: selectedDataset });
    };

    return (
        <div className="app">
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
            />

            <ResultsSummary metrics={result?.metrics} />

            <div className="market-grid">
                <PnLChart pnlCurve={result?.pnl_curve ?? []} />
                <TradeRecordsTable trades={result?.trades ?? []} />
            </div>
        </div>
    );
}
