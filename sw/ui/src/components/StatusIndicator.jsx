
// The colored dot + label pairing next to a run's controls, shared by
// the dashboard header and the compiler pages -- only the label text per
// status differs between them.
export default function StatusIndicator({ status, labels }) {
    return (
        <span className="status">
            <span className={`dot ${status}`} />
            {labels[status]}
        </span>
    );
}
