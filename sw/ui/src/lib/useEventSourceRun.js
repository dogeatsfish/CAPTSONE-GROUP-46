import { useCallback, useEffect, useRef, useState } from "react";

// Shared "POST to start a job, then consume its SSE stream" lifecycle used
// by both the online-simulation demo (App.jsx) and the strategy compiler
// (StrategyCompiler.jsx): open/cleanup, the start POST, EventSource
// wiring, and the idle/running/complete/error status state machine were
// previously hand-duplicated between the two. Callers only supply what's
// actually different -- the start URL/body and what to do with each event.
export function useEventSourceRun({ startUrl, onEvent }) {
    const [status, setStatus] = useState("idle");
    const [error, setError] = useState(null);
    const esRef = useRef(null);

    // Identifies the most recent start() call. Bumped on every new start()
    // and on unmount, so an in-flight call's async continuation (the code
    // after `await fetch`) can tell it's been superseded -- by a newer
    // start() or by the component going away -- and bail out instead of
    // opening an EventSource nobody wants (a leaked connection/backend job)
    // or racing a newer call's state updates.
    const callIdRef = useRef(0);

    const cleanup = useCallback(() => {
        if (esRef.current) {
            esRef.current.close();
            esRef.current = null;
        }
    }, []);

    useEffect(() => {
        return () => {
            callIdRef.current += 1;
            cleanup();
        };
    }, [cleanup]);

    const start = useCallback(
        async (body) => {
            cleanup();
            setError(null);
            setStatus("running");
            const callId = ++callIdRef.current;

            let streamUrl;
            try {
                const res = await fetch(startUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify(body ?? {}),
                });
                if (!res.ok) {
                    const detail = await res.json().catch(() => null);
                    throw new Error(detail?.detail || `start failed: HTTP ${res.status}`);
                }
                ({ stream_url: streamUrl } = await res.json());
            } catch (e) {
                if (callId !== callIdRef.current) return; // superseded/unmounted meanwhile
                setError(String(e.message || e));
                setStatus("error");
                return;
            }

            if (callId !== callIdRef.current) return; // superseded/unmounted meanwhile

            const es = new EventSource(streamUrl);
            esRef.current = es;

            es.onmessage = (ev) => {
                let evt;
                try {
                    evt = JSON.parse(ev.data);
                } catch {
                    return;
                }

                if (evt.type === "complete") {
                    setStatus("complete");
                    cleanup();
                } else if (evt.type === "error") {
                    setError(evt.detail || "engine error");
                    setStatus("error");
                    cleanup();
                }
                onEvent(evt);
            };

            es.onerror = () => {
                // Fires on network close. If we didn't already finish, surface it.
                setStatus((s) => (s === "running" ? "error" : s));
                setError((e) => e || "stream connection lost");
                cleanup();
            };
        },
        [startUrl, onEvent, cleanup]
    );

    const stop = useCallback(() => {
        callIdRef.current += 1; // invalidate an in-flight start() too, not just close the socket
        cleanup();
        setStatus((s) => (s === "running" ? "idle" : s));
    }, [cleanup]);

    return { status, error, start, stop };
}
