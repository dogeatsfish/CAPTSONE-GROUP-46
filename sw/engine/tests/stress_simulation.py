"""Stress + robustness harness for the C++ OfflineSimulation (engine_sim module).

Generates synthetic packed-binary MBO streams of increasing size (matching the
data_pipeline '<QcQcdd' layout) and runs them through the compiled engine,
measuring throughput and sanity-checking the telemetry.

Run with a Python that can import the built engine_sim*.so, e.g.:

    ../../service/.venv/bin/python tests/stress_simulation.py

(from the engine/ directory). Build the module first: `make pymodule`.
"""

import os
import random
import struct
import sys
import tempfile
import time

# Make the compiled engine_sim module importable (it's built in engine/).
_ENGINE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ENGINE_DIR not in sys.path:
    sys.path.insert(0, _ENGINE_DIR)

import engine_sim  # noqa: E402

# Must match data_pipeline/src/cmd_L1_to_L3.py
MBO_STRUCT = struct.Struct("<QcQcdd")


def generate_stream(path: str, num_records: int, seed: int = 42) -> None:
    """Write a synthetic, timestamp-ordered MBO stream to `path`.

    Models a two-sided book that drifts over time: each step cancels the
    previous quote on a side and adds a new one, producing realistic add/cancel
    churn and periodic price crossings that exercise the matching path.
    """
    rng = random.Random(seed)
    ts = 1_700_000_000_000_000_000  # arbitrary ns epoch
    ts_step = 50_000  # 50 microseconds between events
    mid = 100.0
    order_id = 1
    live_bid_id = None
    live_ask_id = None

    with open(path, "wb") as f:
        for _ in range(num_records):
            side_is_bid = rng.random() < 0.5
            mid += rng.uniform(-0.05, 0.05)  # random walk
            spread = rng.uniform(0.01, 0.30)

            if side_is_bid:
                if live_bid_id is not None:
                    f.write(MBO_STRUCT.pack(ts, b"C", live_bid_id, b"B", 0.0, 0.0))
                    ts += ts_step
                price = round(mid - spread / 2, 2)
                size = float(rng.randint(1, 500))
                f.write(MBO_STRUCT.pack(ts, b"A", order_id, b"B", price, size))
                live_bid_id = order_id
            else:
                if live_ask_id is not None:
                    f.write(MBO_STRUCT.pack(ts, b"C", live_ask_id, b"S", 0.0, 0.0))
                    ts += ts_step
                price = round(mid + spread / 2, 2)
                size = float(rng.randint(1, 500))
                f.write(MBO_STRUCT.pack(ts, b"A", order_id, b"S", price, size))
                live_ask_id = order_id

            order_id += 1
            ts += ts_step


def run_case(num_records: int, seed: int = 42) -> None:
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        path = tmp.name
    try:
        gen0 = time.perf_counter()
        generate_stream(path, num_records, seed)
        gen_ms = (time.perf_counter() - gen0) * 1000.0
        file_bytes = os.path.getsize(path)

        # Run in a fresh process would be ideal (see note on static strategy
        # state), but here we time the pure C++ run() call directly.
        wall0 = time.perf_counter()
        sim = engine_sim.OfflineSimulation(path)
        result = sim.run()
        wall_ms = (time.perf_counter() - wall0) * 1000.0

        # --- Sanity checks on the telemetry ---
        assert result.total_trades == len(result.trades), "total_trades mismatch"
        assert result.compute_time_us >= 0, "negative compute time"
        # PnL curve must be non-decreasing in timestamp (sampled forward in time).
        prev = 0
        for p in result.pnl_curve:
            assert p.timestamp_ns >= prev, "pnl_curve timestamps out of order"
            prev = p.timestamp_ns
        # Trades must carry a valid side and positive size/price.
        for t in result.trades[: min(len(result.trades), 1000)]:
            assert t.side in ("B", "S"), f"bad trade side {t.side!r}"
            assert t.size > 0.0 and t.price > 0.0, "non-positive trade size/price"

        cpp_ms = result.compute_time_us / 1000.0
        throughput = num_records / (cpp_ms / 1000.0) if cpp_ms > 0 else float("inf")
        print(
            f"  records={num_records:>9,}  file={file_bytes/1e6:6.2f} MB  "
            f"gen={gen_ms:8.1f} ms  cpp_run={cpp_ms:8.2f} ms  "
            f"py_wall={wall_ms:8.2f} ms  thru={throughput/1e6:6.2f} M rec/s  "
            f"trades={result.total_trades:>8,}  pnl_pts={len(result.pnl_curve):>6,}"
        )
    finally:
        os.remove(path)


def test_missing_file_is_graceful() -> None:
    """A missing file must not crash; the engine returns an empty result."""
    sim = engine_sim.OfflineSimulation("/nonexistent/path/does_not_exist.bin")
    result = sim.run()
    assert result.total_trades == 0, "missing file should yield 0 trades"
    assert len(result.trades) == 0
    print("  missing-file handling: OK (empty result, no crash)")


def test_repeated_runs_state_leak() -> None:
    """Probe whether strategy state leaks across runs in the same process.

    Strategy::on_market_update uses function-local `static` variables, so
    running two simulations in one process may NOT be independent. We flag it
    if the second identical run diverges from the first.
    """
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        path = tmp.name
    try:
        generate_stream(path, 20_000, seed=7)
        r1 = engine_sim.OfflineSimulation(path).run()
        r2 = engine_sim.OfflineSimulation(path).run()
        same = r1.total_trades == r2.total_trades
        if same:
            print(
                f"  repeated-run determinism: OK ({r1.total_trades} trades both runs)"
            )
        else:
            print(
                "  repeated-run determinism: WARNING - results differ across runs "
                f"({r1.total_trades} vs {r2.total_trades}). "
                "Likely caused by `static` locals in Strategy::on_market_update "
                "persisting across OfflineSimulation instances in the same process."
            )
    finally:
        os.remove(path)


if __name__ == "__main__":
    print("=== OfflineSimulation robustness ===")
    test_missing_file_is_graceful()
    test_repeated_runs_state_leak()

    print("\n=== OfflineSimulation throughput scaling ===")
    for n in (10_000, 100_000, 1_000_000, 5_000_000):
        run_case(n)

    print("\nDone.")
