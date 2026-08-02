const TARGETS = ["loopback", "hardware"];

const TARGET_LABEL = {
    loopback: "Loopback",
    hardware: "Real Board",
};

const TARGET_DESCRIPTION = {
    loopback: "Software-only live view, fast pacing -- no board needed (default).",
    hardware: "Streams to the real FPGA at the configured board address, real-time pacing. Requires the host <-> board link to already be up.",
};

// Only relevant to Online mode -- picks which OnlineConfig build_online_config()
// (stream_manager.py) hands the engine for this run.
export default function OnlineTargetToggle({ value, onChange, disabled }) {
    return (
        <div className="field">
            <div className="field-label">Target</div>
            <div className="segmented" role="radiogroup" aria-label="Online simulation target">
                {TARGETS.map((target) => (
                    <button
                        key={target}
                        type="button"
                        role="radio"
                        aria-checked={value === target}
                        className={`segmented-option ${value === target ? "active" : ""}`}
                        disabled={disabled}
                        onClick={() => onChange(target)}
                        title={TARGET_DESCRIPTION[target]}
                    >
                        {TARGET_LABEL[target] ?? target}
                    </button>
                ))}
            </div>
        </div>
    );
}
