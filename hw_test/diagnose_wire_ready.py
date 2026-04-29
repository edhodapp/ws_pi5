#!/usr/bin/env python3
"""diagnose_wire_ready.py — characterize WireCapture readiness latency.

Exercises the WireCapture __enter__ path (tcpdump spawn + readiness
probe) in a tight open/close loop and reports the latency
distribution. On any timeout, dumps the full diagnostic from
wire.py's instrumented _wait_until_ready so we can tell *which*
stage failed (tcpdump never wrote, probe never appeared, send
errors, reader errors).

This script runs entirely on the laptop. It does NOT involve the Pi:
the readiness probe is a self-addressed L2 frame on the chosen iface
that tcpdump captures on egress. Pi state is irrelevant to the
question this answers.

Run baseline (idle host):
    .venv/bin/python hw_test/diagnose_wire_ready.py \\
        --iface enx00e04c0a2bed --iterations 200

Run under contention (simulate cron-time host load — the cron fires
at 00:00 local with load < 1.5 already, but reflashes between phases
can briefly spike CPU):
    yes > /dev/null &
    yes > /dev/null &
    yes > /dev/null &
    .venv/bin/python hw_test/diagnose_wire_ready.py --iface ... \\
        --iterations 200
    kill %1 %2 %3

Run with rapid open/close (simulate the inter-test pattern that
actually triggered the failure: 3 perf runs back-to-back, fixture
setup tearing down then re-spawning tcpdump on the same iface):
    .venv/bin/python hw_test/diagnose_wire_ready.py --iface ... \\
        --iterations 500 --inter-iter-sleep-ms 0

Exit status is 0 if all iterations succeeded, 1 if any timed out.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

# hw_test/ goes on sys.path so `import wire` resolves the same way
# the pytest harness does it (per hw_test/conftest.py).
sys.path.insert(0, str(Path(__file__).resolve().parent))

import wire  # noqa: E402  pylint: disable=wrong-import-position


def _summarize(samples_ms: list[float], timeouts: list[tuple[int, str]],
               ready_timeout_ms: int, total_s: float) -> None:
    print()
    print(f"=== Results: {len(samples_ms)} iters, {total_s:.1f}s wall ===")
    ok = [s for s in samples_ms if s <= ready_timeout_ms]
    edges_ms = [10, 25, 50, 100, 250, 500, 1000, ready_timeout_ms]
    counts = [0] * len(edges_ms)
    for s in ok:
        for j, edge in enumerate(edges_ms):
            if s <= edge:
                counts[j] += 1
                break
    prev = 0
    for edge, c in zip(edges_ms, counts):
        print(f"  {prev:>5}–{edge:>5} ms : {c:>4}")
        prev = edge
    print(f"  TIMEOUT (>{ready_timeout_ms} ms): {len(timeouts):>4}")
    if ok:
        ok_sorted = sorted(ok)
        n = len(ok_sorted)
        print(
            f"  ok latency: min={ok_sorted[0]:.1f}ms"
            f"  median={ok_sorted[n // 2]:.1f}ms"
            f"  p95={ok_sorted[int(0.95 * (n - 1))]:.1f}ms"
            f"  max={ok_sorted[-1]:.1f}ms"
        )
    if timeouts:
        print()
        print(f"=== Timeout diagnostics ({len(timeouts)}) ===")
        for idx, msg in timeouts:
            print(f"--- iter {idx} ---")
            print(msg)


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--iface", required=True,
                   help="Network interface (e.g. enx00e04c0a2bed)")
    p.add_argument("--iterations", type=int, default=100,
                   help="WireCapture open/close cycles to run (default 100)")
    p.add_argument("--ready-timeout-ms", type=int,
                   default=wire.READY_PROBE_TIMEOUT_DEFAULT_MS,
                   help=("Per-iteration readiness timeout. Defaults to "
                         "the WireCapture default."))
    p.add_argument("--inter-iter-sleep-ms", type=int, default=0,
                   help=("Sleep between iterations in ms (default 0). "
                         "Use 0 to hammer; use a higher value to mimic "
                         "real test pacing."))
    p.add_argument("--bpf", default="",
                   help="Optional BPF (default: empty / capture all)")
    args = p.parse_args()

    samples_ms: list[float] = []
    timeouts: list[tuple[int, str]] = []

    print(f"Iface: {args.iface}")
    print(f"Iterations: {args.iterations}")
    print(f"ready_timeout_ms: {args.ready_timeout_ms}")
    print(f"inter_iter_sleep_ms: {args.inter_iter_sleep_ms}")
    print()

    t_overall = time.monotonic()
    for i in range(args.iterations):
        t0 = time.monotonic()
        try:
            with wire.WireCapture(
                args.iface,
                bpf=args.bpf,
                ready_timeout_ms=args.ready_timeout_ms,
            ):
                # Empty body: we only care about __enter__ readiness.
                pass
            samples_ms.append((time.monotonic() - t0) * 1000.0)
        except wire.WireError as e:
            timeouts.append((i, str(e)))
            samples_ms.append(float(args.ready_timeout_ms) + 1.0)
        if (i + 1) % 25 == 0:
            print(f"  ... iter {i + 1}/{args.iterations}"
                  f" (timeouts so far: {len(timeouts)})", flush=True)
        if args.inter_iter_sleep_ms > 0:
            time.sleep(args.inter_iter_sleep_ms / 1000.0)

    _summarize(samples_ms, timeouts,
               args.ready_timeout_ms, time.monotonic() - t_overall)

    return 1 if timeouts else 0


if __name__ == "__main__":
    sys.exit(main())
