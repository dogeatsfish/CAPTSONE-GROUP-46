import { elapsedSeconds, fmtCurrency, fmtNumber } from "../utils/format";

// trades: SimulationResponse.trades, i.e. [{ timestamp_ns, side, price, size }, ...]
export default function TradeRecordsTable({ trades }) {
    const rows = trades ?? [];
    const firstTs = rows.length ? rows[0].timestamp_ns : 0;

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
                                <th>Sim Time (s)</th>
                                <th>Side</th>
                                <th>Price</th>
                                <th>Size</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((t, i) => (
                                <tr key={`${t.timestamp_ns}-${i}`}>
                                    <td>{elapsedSeconds(t.timestamp_ns, firstTs).toFixed(2)}</td>
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
