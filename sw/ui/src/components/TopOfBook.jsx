import { fmtCurrency } from "../utils/format";

// Live L1 (best bid/ask) readout for Online mode, driven by the "pnl" SSE
// event's best_bid/best_ask fields (see stream_manager.py). Bid/ask always
// keep their own color regardless of sign -- unlike PnL, these are prices,
// not signed values.
export default function TopOfBook({ bestBid, bestAsk }) {
    // Thin/single-instrument books routinely have only one side resting at a
    // given instant (see OrderBook::get_l1_state) -- show whichever side(s)
    // are actually present rather than gating the whole card on both.
    const hasBid = bestBid > 0;
    const hasAsk = bestAsk > 0;
    const spread = hasBid && hasAsk ? bestAsk - bestBid : null;

    return (
        <div className="panel">
            <h3>Top of Book</h3>
            <div className="cards">
                <div className="card">
                    <div className="label">Best Bid</div>
                    <div className="value pos">{hasBid ? fmtCurrency(bestBid) : "—"}</div>
                </div>
                <div className="card">
                    <div className="label">Best Ask</div>
                    <div className="value neg">{hasAsk ? fmtCurrency(bestAsk) : "—"}</div>
                </div>
                <div className="card">
                    <div className="label">Spread</div>
                    <div className="value">{spread !== null ? fmtCurrency(spread) : "—"}</div>
                </div>
            </div>
        </div>
    );
}
