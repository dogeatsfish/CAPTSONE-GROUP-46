import { useCallback, useEffect, useRef, useState } from "react";

// How long stop() waits for the server's final "complete" event before giving
// up and closing the stream anyway.
const STOP_GRACE_MS = 5000;

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

    // True between a Stop click and the stream ending. The ref is read by the
    // EventSource handlers; the state drives the UI.
    const [stopping, setStopping] = useState(false);
    const stoppingRef = useRef(false);
    const stopTimerRef = useRef(null);

    const cleanup = useCallback(() => {
        if (esRef.current) {
            esRef.current.close();
            esRef.current = null;
        }
        clearTimeout(stopTimerRef.current);
        stoppingRef.current = false;
        setStopping(false);
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
                // The stream closing after a Stop click isn't a failure.
                if (stoppingRef.current) {
                    setStatus((s) => (s === "running" ? "idle" : s));
                    cleanup();
                    return;
                }
                // Fires on network close. If we didn't already finish, surface it.
                setStatus((s) => (s === "running" ? "error" : s));
                setError((e) => e || "stream connection lost");
                cleanup();
            };
        },
        [startUrl, onEvent, cleanup]
    );

    const stop = useCallback(() => {
        // A stopped run still ends with a regular "complete" event holding
        // everything collected so far, so keep listening for it rather than
        // closing the stream now. The timer covers that event never arriving.
        if (sessionId && esRef.current) {
            stoppingRef.current = true;
            setStopping(true);
            fetch(`${startUrl}/${sessionId}/stop`, { method: "POST" }).catch(() => {});
            stopTimerRef.current = setTimeout(() => {
                setStatus((s) => (s === "running" ? "idle" : s));
                cleanup();
            }, STOP_GRACE_MS);
            return;
        }
        // Nothing to wait for: the start POST is still in flight, or this
        // endpoint has no session to stop (e.g. the compile pages).
        callIdRef.current += 1;
        cleanup();
        setStatus((s) => (s === "running" ? "idle" : s));
    }, [cleanup, startUrl, sessionId]);

    // Unlike stop() (only transitions running -> idle), reset() unconditionally
    // clears back to idle from any state (complete/error/running) -- it's what
    // backs a Reset button that should always leave a blank slate, not just
    // interrupt an active run.
    const reset = useCallback(() => {
        callIdRef.current += 1;
        if (sessionId) {
            fetch(`${startUrl}/${sessionId}/stop`, { method: "POST" }).catch(() => {});
        }
        cleanup();
        setStatus("idle");
        setError(null);
        setSessionId(null);
    }, [cleanup, startUrl, sessionId]);

    return { status, error, sessionId, stopping, start, stop, reset };
}
