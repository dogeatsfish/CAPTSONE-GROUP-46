import useFitFontSize from "../lib/useFitFontSize";

// Stat-card value that shrinks to fit its own box when it's a single
// unbreakable token; multi-word values wrap underneath instead (see
// useFitFontSize). Used by ResultsSummary and StatCards so every card sizes
// off its own content/width rather than a size shared across the row.
export default function AutoFitValue({ text, className, max }) {
    const { ref, fontSize, ready } = useFitFontSize(text, { max });
    return (
        <div ref={ref} className={className} style={{ fontSize, visibility: ready ? "visible" : "hidden" }}>
            {text}
        </div>
    );
}
