const STATUS_LABEL = {
    idle: "Idle",
    running: "Running simulation…",
    complete: "Run complete",
    error: "Error",
};

export default function Header({ status }) {
    return (
        <div className="header">
            <div>
                <div className="eyebrow">CommonTrader · Simulation Terminal</div>
                <div className="title">Matching Engine Run</div>
                <div className="subtitle">
                    Offline backtest or online replay against a fixed market-data file
                </div>
            </div>
            <span className="status">
                <span className={`dot ${status}`} />
                {STATUS_LABEL[status] ?? status}
            </span>
        </div>
    );
}
