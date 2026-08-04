import React from "react";
import { sign } from "../lib/format.js";
import AutoFitValue from "./AutoFitValue";

// The 4-card summary grid (Total PnL / Position / one run-specific stat /
// Total Trades), shared between the online demo and the strategy compiler.
// `items` is [{ label, display, raw }] -- `display` is the already-formatted
// string to render, `raw` is the underlying number used only to decide
// pos/neg coloring (omit `raw` for cards that aren't signed values, e.g.
// elapsed time or trade count).
export default function StatCards({ items }) {
    return (
        <div className="cards">
            {items.map(({ label, display, raw }) => (
                <div className="card" key={label}>
                    <div className="label">{label}</div>
                    <AutoFitValue max={24} className={`value ${raw !== undefined ? sign(raw) : ""}`} text={display} />
                </div>
            ))}
        </div>
    );
}
