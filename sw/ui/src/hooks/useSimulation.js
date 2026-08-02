import { useCallback, useState } from "react";
import { runSimulation } from "../api/client";

// Owns the run lifecycle (idle -> running -> complete/error) for a single
// simulation, independent of which mode or dataset was chosen. Components
// only see status/result/error and a run()/reset() pair.
export function useSimulation() {
    const [status, setStatus] = useState("idle"); // idle | running | complete | error
    const [result, setResult] = useState(null);
    const [error, setError] = useState(null);

    const run = useCallback(async ({ mode, dataFile }) => {
        setStatus("running");
        setError(null);
        try {
            const data = await runSimulation({ mode, dataFile });
            setResult(data);
            setStatus("complete");
        } catch (e) {
            setError(String(e.message || e));
            setStatus("error");
        }
    }, []);

    const reset = useCallback(() => {
        setStatus("idle");
        setResult(null);
        setError(null);
    }, []);

    return { status, result, error, run, reset };
}
