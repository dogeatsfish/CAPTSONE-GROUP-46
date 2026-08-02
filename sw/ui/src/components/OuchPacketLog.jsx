import { elapsedSeconds, fmtCurrency, fmtNumber } from "../utils/format";

const MSG_TYPE_LABEL = {
    O: "ENTER",
    X: "CANCEL",
};

// packets: [{ timestamp_ns, msg_type, order_id, side, price, size, raw_hex }, ...]
// -- every inbound OUCH packet the engine's OUCH thread has seen (see the
// "ouch" SSE event in stream_manager.py), independent of whether it produced
// a fill. Hardware bring-up aid: proves the board is actually sending
// something back even when the Order Blotter stays empty, so a stuck demo
// can be told apart from a genuinely silent board.
export default function OuchPacketLog({ packets }) {
    const rows = packets ?? [];
    const firstTs = rows.length ? rows[0].timestamp_ns : 0;

    return (
        <div className="panel">
            <h3>OUCH Packets ({rows.length.toLocaleString()})</h3>

            {rows.length === 0 ? (
                <div className="hint">
                    No OUCH packets received yet. If the board is running and this
                    stays empty for a while, that points at the link/config, not the UI.
                </div>
            ) : (
                <div className="table-scroll">
                    <table className="trade-table">
                        <thead>
                            <tr>
                                <th>Elapsed (s)</th>
                                <th>Type</th>
                                <th>Order ID</th>
                                <th>Side</th>
                                <th>Price</th>
                                <th>Size</th>
                                <th>Raw</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((p, i) => (
                                <tr key={`${p.timestamp_ns}-${i}`}>
                                    <td>{elapsedSeconds(p.timestamp_ns, firstTs).toFixed(2)}</td>
                                    <td>
                                        <span className={`side-badge ${p.msg_type === "O" ? "buy" : "sell"}`}>
                                            {MSG_TYPE_LABEL[p.msg_type] ?? "UNKNOWN"}
                                        </span>
                                    </td>
                                    <td>{p.order_id}</td>
                                    <td>{p.side === "B" || p.side === "S" ? p.side : "—"}</td>
                                    <td>{p.msg_type === "O" ? fmtCurrency(p.price) : "—"}</td>
                                    <td>{fmtNumber(p.size, 0)}</td>
                                    <td className="mono-cell">{p.raw_hex}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    );
}
