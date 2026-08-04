import { useLayoutEffect, useRef, useState } from "react";

// Shrinks a value's font size just enough to keep it on one line within its
// own box. Multi-word values never need this -- white-space: normal (see
// .value in styles.css) already wraps them onto a second line, which keeps
// scrollWidth within clientWidth without any shrinking. This only kicks in
// for a single unbreakable token (e.g. a large formatted dollar figure) that
// has nowhere to wrap, so each card shrinks independently based on its own
// content and width instead of every card in the row sharing one size.
//
// The caller must not paint the value until `ready` is true, and `ready` is
// reset to false the instant `content` changes (not just on first mount).
// Two reasons both matter:
//
// 1. index.html loads Space Grotesk/JetBrains Mono from Google Fonts with
//    display=swap, async, and Chrome loads @font-face fonts lazily -- a
//    face doesn't actually start fetching until something first tries to
//    render with it. The placeholder "-" doesn't use any digit glyphs, so
//    the numeric font subset a real value needs can still be genuinely
//    loading well after the placeholder's own fit already completed and
//    marked this component "ready". Actively requesting the exact faces via
//    document.fonts.load(...) (rather than passively awaiting
//    document.fonts.ready, which only reflects loads already triggered by
//    someone else) closes that gap.
// 2. Without resetting `ready`, a content change from an old, already-fit
//    value to a new one would render the NEW text immediately visible at
//    the OLD, stale fontSize (since `ready` was already true from before)
//    -- correct only by coincidence, whenever the font promise happens to
//    resolve within the same microtask checkpoint. Resetting `ready` to
//    false synchronously, before any async work, means every new value is
//    hidden the instant it appears and only revealed once it's actually
//    been measured -- via useLayoutEffect's guarantee that state updates it
//    triggers are flushed before the browser paints.
const FONT_SPECS = ['600 16px "JetBrains Mono"', '700 16px "JetBrains Mono"'];

function waitForFonts() {
    if (!document.fonts) return Promise.resolve();
    return Promise.all(FONT_SPECS.map((spec) => document.fonts.load(spec).catch(() => {}))).then(
        () => document.fonts.ready
    );
}

export default function useFitFontSize(content, { max, min = 10 } = {}) {
    const ref = useRef(null);
    const [fontSize, setFontSize] = useState(max);
    const [ready, setReady] = useState(false);
    const [prevContent, setPrevContent] = useState(content);

    // Detects a genuine content change during render (not just "ready
    // happens to be true") and resets synchronously, in the same commit,
    // before paint -- so a new value is never shown at a size that was only
    // ever fit for different (e.g. shorter) text. Comparing against a
    // stored previous value (React's documented pattern for this) matters:
    // an unconditional `if (ready) setReady(false)` would also fire on
    // renders where content DIDN'T change, immediately undoing the effect's
    // own setReady(true) with no content change left to re-trigger the
    // effect and set it true again -- permanently stuck hidden.
    if (content !== prevContent) {
        setPrevContent(content);
        setReady(false);
    }

    useLayoutEffect(() => {
        const el = ref.current;
        if (!el) return;
        let cancelled = false;

        const fit = () => {
            let size = max;
            el.style.fontSize = `${size}px`;
            let width = el.scrollWidth;
            while (size > min && width > el.clientWidth + 1) {
                const nextSize = size - 1;
                el.style.fontSize = `${nextSize}px`;
                const nextWidth = el.scrollWidth;
                if (nextWidth >= width) {
                    // The browser didn't actually render the smaller size --
                    // e.g. a Chrome accessibility "minimum font size"
                    // setting clamps how small text can render, regardless
                    // of what CSS asks for. Without this check, scrollWidth
                    // stays frozen at the clamped width no matter how far
                    // `size` keeps dropping, and the loop spins all the way
                    // to `min` chasing a measurement that can never
                    // improve. Revert to the last size that had a real
                    // effect and stop instead of guessing further.
                    el.style.fontSize = `${size}px`;
                    break;
                }
                size = nextSize;
                width = nextWidth;
            }
            setFontSize(size);
        };

        const onResize = () => fit();

        waitForFonts().then(() => {
            if (cancelled) return;
            fit();
            setReady(true);
            window.addEventListener("resize", onResize);
        });

        return () => {
            cancelled = true;
            window.removeEventListener("resize", onResize);
        };
    }, [content, max, min]);

    return { ref, fontSize, ready };
}
