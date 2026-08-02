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
    // The start response's session_id, if the endpoint returns one -- lets a
    // caller request a server-side stop (POST `${startUrl}/${sessionId}/stop`)
    // instead of just closing the local EventSource, which only stops this
    // browser tab from listening; the engine keeps running server-side.
    const [sessionId, setSessionId] = useState(null);
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
            setSessionId(null);
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
                const data = await res.json();
                streamUrl = data.stream_url;
                if (callId === callIdRef.current) setSessionId(data.session_id ?? null);
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
        // Tell the server to actually stop the run, not just stop listening --
        // best-effort; the local cleanup below happens regardless. Endpoints
        // that don't hand back a session_id (e.g. the compile pages) never
        // set one, so this is a no-op for them.
        if (sessionId) {
            fetch(`${startUrl}/${sessionId}/stop`, { method: "POST" }).catch(() => {});
        }
        cleanup();
        setStatus((s) => (s === "running" ? "idle" : s));
    }, [cleanup, startUrl, sessionId]);

    return { status, error, sessionId, start, stop };
}
