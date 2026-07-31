// Toggle list over the fixed set of pre-generated .bin MBO files returned by
// GET /datasets (sw/data_pipeline/data). Prices are not generated on the fly
// here -- this only picks which pre-built file the run reads from.
export default function DatasetSelector({ datasets, loading, error, value, onChange, disabled }) {
    return (
        <div className="field">
            <div className="field-label">Data file</div>

            {loading && <div className="hint">Loading datasets…</div>}
            {error && <div className="hint error-text">{error}</div>}

            {!loading && !error && datasets.length === 0 && (
                <div className="hint">No .bin datasets found in data_pipeline/data.</div>
            )}

            {!loading && datasets.length > 0 && (
                <div className="toggle-list" role="radiogroup" aria-label="Dataset file">
                    {datasets.map((name) => (
                        <button
                            key={name}
                            type="button"
                            role="radio"
                            aria-checked={value === name}
                            className={`toggle-option ${value === name ? "active" : ""}`}
                            disabled={disabled}
                            onClick={() => onChange(name)}
                        >
                            {name}
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
}
