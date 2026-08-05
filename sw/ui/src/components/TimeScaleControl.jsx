// Pacing presets for the online stream. Value is OnlineConfig::time_scale:
// 1.0 = real time, smaller replays faster, 0 = no pacing (as fast as possible).
const OPTIONS = [
    { value: 1, label: "Real time (1x)" },
    { value: 0.1, label: "10x faster" },
    { value: 0.01, label: "100x faster" },
    { value: 0.001, label: "1000x faster" },
    { value: 0, label: "Max (no pacing)" },
];

// Only relevant to Online mode -- sets SimulationRequest.time_scale, which the
// server applies to the run's OnlineConfig (see build_online_config). Chosen
// before pressing Run; disabled while a run is in flight.
export default function TimeScaleControl({ value, onChange, disabled }) {
    return (
        <div className="field">
            <div className="field-label">Pacing</div>
            <select
                aria-label="Replay pacing (time scale)"
                value={value}
                disabled={disabled}
                onChange={(e) => onChange(Number(e.target.value))}
                title="How fast to replay market data: real time, a speed-up factor, or as fast as possible."
            >
                {OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>
                        {o.label}
                    </option>
                ))}
            </select>
        </div>
    );
}
