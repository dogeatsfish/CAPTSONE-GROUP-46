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

// Average time per trade, derived by inverting a trades/s rate (whichever
// kind -- see ResultsSummary's liveThroughput doc: compute-time-based post
// -run, or simulated-time-based live). Needs its own ns tier that
// fmtDuration doesn't have: the post-run figure is routinely sub-microsecond
// (the engine processes way faster than 1 trade/µs), where fmtDuration's
// whole-microsecond rounding would just show "1 µs" or "0 µs" for
// everything.
export function fmtDurationPerTrade(us) {
    if (us === null || us === undefined || Number.isNaN(us)) return "—";
    if (us < 1) return `${fmtNumber(us * 1000, 0)} ns`;
    if (us < 1_000) return `${fmtNumber(us, 2)} µs`;
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
    // Sub-$1000 PnL is common early in a run or for small size -- rounding to
    // a whole dollar collapses every tick on a small-magnitude axis to "$0".
    if (abs >= 1) return `${sign}$${abs.toFixed(2)}`;
    if (abs === 0) return "$0";
    return `${sign}$${abs.toFixed(4)}`;
}

// Same idea as fmtCompactCurrency, for percentages -- a sane drawdown pct
// (e.g. -72.3%) is untouched, this only kicks in for values large enough
// that something upstream is almost certainly wrong (e.g. a mis-scaled
// denominator), so the UI doesn't have to force-fit a 10+ digit number.
export function fmtCompactPercent(n) {
    if (n === null || n === undefined || Number.isNaN(n)) return "—";
    const sign = n < 0 ? "-" : "";
    const abs = Math.abs(n);
    if (abs >= 1_000_000) return `${sign}${(abs / 1_000_000).toFixed(2)}M%`;
    if (abs >= 1_000) return `${sign}${(abs / 1_000).toFixed(1)}k%`;
    return `${sign}${abs.toFixed(1)}%`;
}
