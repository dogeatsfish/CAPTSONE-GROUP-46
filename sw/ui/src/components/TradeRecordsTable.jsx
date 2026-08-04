import { elapsedSeconds, fmtCurrency, fmtNumber, pickElapsedUnit } from "../utils/format";

// trades: SimulationResponse.trades, i.e. [{ timestamp_ns, side, price, size }, ...]
// firstTimestampNs/unit: same shared elapsed-time origin/unit PnLChart uses
// (see its doc comment) -- keeps a trade's "Sim Time" directly comparable to
// where it lands on the PnL graph's x-axis, instead of this table computing
// its own origin from its own first row.
export default function TradeRecordsTable({ trades, firstTimestampNs = 0, unit = pickElapsedUnit(0) }) {
    const rows = trades ?? [];

    return (
        <div className="panel">
            <h3>Order Blotter ({rows.length.toLocaleString()})</h3>

            {rows.length === 0 ? (
                <div className="hint">No fills yet. Run a simulation to populate the blotter.</div>
            ) : (
                <div className="table-scroll">
                    <table className="trade-table">
                        <thead>
                            <tr>
                                <th>Sim Time ({unit.suffix})</th>
                                <th>Side</th>
                                <th>Price ($)</th>
                                <th>Size (shares)</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((t, i) => (
                                <tr key={`${t.timestamp_ns}-${i}`}>
                                    <td>{(elapsedSeconds(t.timestamp_ns, firstTimestampNs) / unit.divisor).toFixed(2)}</td>
                                    <td>
                                        <span className={`side-badge ${t.side === "B" ? "buy" : "sell"}`}>
                                            {t.side === "B" ? "BUY" : "SELL"}
                                        </span>
                                    </td>
                                    <td>{fmtCurrency(t.price)}</td>
                                    <td>{fmtNumber(t.size, 0)}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    );
}
