import { signClass } from "../utils/format";
import AutoFitValue from "./AutoFitValue";

// Summary card grid shared by the two compiler pages.
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
                    <AutoFitValue max={24} className={`value ${raw !== undefined ? signClass(raw) : ""}`} text={display} />
                </div>
            ))}
        </div>
    );
}
