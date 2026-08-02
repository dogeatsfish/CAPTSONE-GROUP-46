import { SIMULATION_MODES } from "../api/client";

const MODE_LABEL = {
    offline: "Offline",
    online: "Online",
};

const MODE_DESCRIPTION = {
    offline: "Backtest engine_sim.OfflineSimulation against the file end-to-end.",
    online: "Replay via engine_sim.OnlineSimulation over the ITCH/OUCH sockets.",
};

export default function ModeToggle({ value, onChange, disabled }) {
    return (
        <div className="field">
            <div className="field-label">Mode</div>
            <div className="segmented" role="radiogroup" aria-label="Simulation mode">
                {SIMULATION_MODES.map((mode) => (
                    <button
                        key={mode}
                        type="button"
                        role="radio"
                        aria-checked={value === mode}
                        className={`segmented-option ${value === mode ? "active" : ""}`}
                        disabled={disabled}
                        onClick={() => onChange(mode)}
                        title={MODE_DESCRIPTION[mode]}
                    >
                        {MODE_LABEL[mode] ?? mode}
                    </button>
                ))}
            </div>
        </div>
    );
}
