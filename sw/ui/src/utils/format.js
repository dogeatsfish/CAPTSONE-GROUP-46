// Shared display-formatting helpers. Kept dependency-free so any component
// can import just what it needs.

export function fmtNumber(n, digits = 2) {
    if (n === null || n === undefined || Number.isNaN(n)) return "—";
    return Number(n).toLocaleString(undefined, {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits,
    });
}

export function fmtCurrency(n, digits = 2) {
    if (n === null || n === undefined || Number.isNaN(n)) return "—";
    const sign = n < 0 ? "-" : "";
    return `${sign}$${Math.abs(n).toLocaleString(undefined, {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits,
    })}`;
}

// Engine timing is reported in microseconds; pick a readable unit.
export function fmtDuration(us) {
    if (us === null || us === undefined || Number.isNaN(us)) return "—";
    if (us < 1_000) return `${fmtNumber(us, 0)} µs`;
    if (us < 1_000_000) return `${fmtNumber(us / 1_000, 2)} ms`;
    return `${fmtNumber(us / 1_000_000, 2)} s`;
}

// Nanosecond engine timestamp -> elapsed seconds since the first sample.
export function elapsedSeconds(timestampNs, firstTimestampNs) {
    return Number((timestampNs - firstTimestampNs) / 1e9);
}

export function signClass(v) {
    if (v > 0) return "pos";
    if (v < 0) return "neg";
    return "";
}

// Picks the coarsest unit (s / min / hr) that keeps an elapsed-time span
// readable, so a chart covering a full trading session doesn't force the
// viewer to read raw seconds in the thousands. `totalSeconds` is the full
// span being plotted, not any individual point.
export function pickElapsedUnit(totalSeconds) {
    if (totalSeconds < 120) {
        return { divisor: 1, suffix: "s", label: "elapsed (s)" };
    }
    if (totalSeconds < 7_200) {
        return { divisor: 60, suffix: "min", label: "elapsed (min)" };
    }
    return { divisor: 3_600, suffix: "hr", label: "elapsed (hr)" };
}

// Compact $ formatter for chart axis ticks -- full-precision numbers belong
// in the tooltip (fmtCurrency), axis ticks just need to be scannable at a
// glance: "$1.9k" instead of "$1,939.72".
export function fmtCompactCurrency(n) {
    if (n === null || n === undefined || Number.isNaN(n)) return "—";
    const sign = n < 0 ? "-" : "";
    const abs = Math.abs(n);
    if (abs >= 1_000_000) return `${sign}$${(abs / 1_000_000).toFixed(2)}M`;
    if (abs >= 1_000) return `${sign}$${(abs / 1_000).toFixed(1)}k`;
    return `${sign}$${abs.toFixed(0)}`;
}
