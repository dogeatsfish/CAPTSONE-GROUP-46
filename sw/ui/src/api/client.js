// Thin fetch wrappers around the FastAPI service. Nothing in here holds
// React state -- that lives in the hooks/ layer -- so this module can be
// reused or swapped independently of any component.

const MODE_ENDPOINTS = {
    offline: "/simulate",
    online: "/simulate/online",
};

export const SIMULATION_MODES = Object.keys(MODE_ENDPOINTS);

async function parseErrorDetail(res) {
    try {
        const body = await res.json();
        return body?.detail || `HTTP ${res.status}`;
    } catch {
        return `HTTP ${res.status}`;
    }
}

// GET /datasets -> { data_dir, datasets: string[] }
export async function listDatasets() {
    const res = await fetch("/datasets");
    if (!res.ok) throw new Error(`Failed to list datasets: ${await parseErrorDetail(res)}`);
    return res.json();
}

// POST /simulate or /simulate/online -> SimulationResponse
// { data_file, total_trades, compute_time_us, trades[], pnl_curve[], metrics }
export async function runSimulation({ mode, dataFile, tradeLimit, pnlLimit } = {}) {
    const endpoint = MODE_ENDPOINTS[mode];
    if (!endpoint) {
        throw new Error(`Unknown simulation mode: ${mode}`);
    }

    const res = await fetch(endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            data_file: dataFile ?? null,
            trade_limit: tradeLimit ?? null,
            pnl_limit: pnlLimit ?? null,
        }),
    });

    if (!res.ok) {
        throw new Error(`Simulation failed: ${await parseErrorDetail(res)}`);
    }
    return res.json();
}
