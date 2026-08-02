import ModeToggle from "./ModeToggle";
import DatasetSelector from "./DatasetSelector";

// Layout-only: composes the mode toggle, dataset picker, and run/stop button.
// Holds no state of its own -- everything is passed down from App.
export default function ControlPanel({
    mode,
    onModeChange,
    datasets,
    datasetsLoading,
    datasetsError,
    selectedDataset,
    onDatasetChange,
    running,
    onRun,
    canRun,
}) {
    return (
        <div className="panel controls-panel">
            <div className="controls-row">
                <ModeToggle value={mode} onChange={onModeChange} disabled={running} />
                <DatasetSelector
                    datasets={datasets}
                    loading={datasetsLoading}
                    error={datasetsError}
                    value={selectedDataset}
                    onChange={onDatasetChange}
                    disabled={running}
                />
            </div>
            <div className="controls-row controls-row-actions">
                <button onClick={onRun} disabled={running || !canRun}>
                    {running ? "Running…" : "Run Simulation"}
                </button>
            </div>
        </div>
    );
}
