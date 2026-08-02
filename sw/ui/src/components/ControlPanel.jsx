import ModeToggle from "./ModeToggle";
import DatasetSelector from "./DatasetSelector";
import OnlineTargetToggle from "./OnlineTargetToggle";

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
    onStop, // optional -- only modes that can actually be interrupted wire this (online)
    onlineTarget, // optional -- only online mode wires this ("loopback" | "hardware")
    onOnlineTargetChange,
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
                {mode === "online" && onOnlineTargetChange && (
                    <OnlineTargetToggle
                        value={onlineTarget}
                        onChange={onOnlineTargetChange}
                        disabled={running}
                    />
                )}
            </div>
            <div className="controls-row controls-row-actions">
                <button onClick={onRun} disabled={running || !canRun}>
                    {running ? "Running…" : "Run Simulation"}
                </button>
                {onStop && (
                    <button type="button" className="danger" onClick={onStop} disabled={!running}>
                        Stop Simulation
                    </button>
                )}
            </div>
        </div>
    );
}
