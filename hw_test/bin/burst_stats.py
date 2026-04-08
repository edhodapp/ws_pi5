#!/usr/bin/env python3
"""Run test_l2_ring burst test N times and report stats.

Computes mean, stddev, excess kurtosis, skewness, and Sarle's
bimodality coefficient on the reply counts. Flags likely bimodality.

Usage:
    hw_test/bin/burst_stats.py <burst_size> <runs>

Example:
    hw_test/bin/burst_stats.py 1024 10
"""
import math
import os
import re
import statistics
import subprocess
import sys


STATS_RE = re.compile(
    r"BURST_STATS: n=(\d+) replies=(\d+) send_ms=([\d.]+) "
    r"wire_pps=([\d.]+) total_ms=([\d.]+)"
)


def run_once(n: int) -> tuple[int, float]:
    """Run one pytest invocation, return (reply_count, send_time_ms)."""
    env = os.environ.copy()
    env["HW_TEST"] = "1"
    result = subprocess.run(
        [
            ".venv/bin/pytest",
            f"hw_test/test_l2_ring.py::TestRingWraparound::"
            f"test_burst_n_arp_replies_received[{n}]",
            "-s",  # don't capture -- BURST_STATS print must reach us
            "-q",
            "--tb=line",
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    m = STATS_RE.search(result.stdout + result.stderr)
    if not m:
        raise RuntimeError(
            f"Could not parse BURST_STATS line from pytest output:\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return int(m.group(2)), float(m.group(3))


def central_moment(xs: list[float], k: int) -> float:
    """k-th central moment = E[(X - mean)^k]."""
    mu = statistics.fmean(xs)
    return sum((x - mu) ** k for x in xs) / len(xs)


def skewness(xs: list[float]) -> float:
    """Sample skewness (3rd standardized moment)."""
    sd = statistics.pstdev(xs)
    if sd == 0:
        return 0.0
    return central_moment(xs, 3) / (sd**3)


def excess_kurtosis(xs: list[float]) -> float:
    """Excess kurtosis = 4th standardized moment - 3.

    Normal distribution has 0. Narrow peak / heavy tails: positive.
    Flat / bimodal: negative (typically < -1 for clear bimodality)."""
    sd = statistics.pstdev(xs)
    if sd == 0:
        return 0.0
    return central_moment(xs, 4) / (sd**4) - 3.0


def sarle_bimodality(xs: list[float]) -> float:
    """Sarle's bimodality coefficient.

    b = (g^2 + 1) / (k + 3*(n-1)^2 / ((n-2)*(n-3)))

    where g = skewness, k = excess kurtosis, n = sample size.
    b > 5/9 (~0.555) suggests bimodality. Uniform distribution
    has b = 5/9 exactly. Standard normal has b = 1/3."""
    n = len(xs)
    if n < 4:
        return float("nan")
    g = skewness(xs)
    k = excess_kurtosis(xs)
    correction = 3.0 * (n - 1) ** 2 / ((n - 2) * (n - 3))
    return (g * g + 1.0) / (k + correction)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    burst_size = int(sys.argv[1])
    runs = int(sys.argv[2])

    if runs < 4:
        print("Need at least 4 runs for kurtosis to be meaningful.", file=sys.stderr)
        return 2

    print(f"Running test_l2_ring[{burst_size}] {runs} times...", flush=True)
    counts: list[int] = []
    send_times: list[float] = []
    for i in range(runs):
        c, t = run_once(burst_size)
        counts.append(c)
        send_times.append(t)
        print(f"  run {i+1:>2}/{runs}: {c:>4} replies, send_time={t:.1f}ms", flush=True)

    print()
    print(f"=== Reply counts (target = {burst_size}) ===")
    print(f"  samples: {counts}")
    mean = statistics.fmean(counts)
    sd = statistics.stdev(counts) if runs > 1 else 0.0
    g = skewness(counts)
    k = excess_kurtosis(counts)
    b = sarle_bimodality(counts)
    print(f"  mean          : {mean:8.2f}")
    print(f"  stdev         : {sd:8.2f}")
    print(f"  min, max      : {min(counts)}, {max(counts)}")
    print(f"  skewness (g)  : {g:8.3f}")
    print(f"  ex. kurtosis  : {k:8.3f}  (normal=0; flat/bimodal<0; peaked>0)")
    print(f"  Sarle's b     : {b:8.3f}  (bimodal if > 0.555; uniform=0.555)")

    flags: list[str] = []
    if k < -1.0:
        flags.append(f"excess kurtosis {k:.2f} < -1 (flat distribution)")
    if b > 0.555:
        flags.append(f"Sarle's b {b:.3f} > 0.555 (likely bimodal)")
    if flags:
        print()
        print("  ==> BIMODALITY LIKELY:", "; ".join(flags))
    else:
        print()
        print("  ==> No bimodality detected (Sarle's b <= 0.555 and kurtosis >= -1)")

    print()
    print("=== Send time (ms) ===")
    print(f"  samples: {[round(t,1) for t in send_times]}")
    print(f"  mean          : {statistics.fmean(send_times):8.2f}")
    print(f"  stdev         : {statistics.stdev(send_times) if runs > 1 else 0.0:8.2f}")
    if runs >= 4:
        b_t = sarle_bimodality(send_times)
        k_t = excess_kurtosis(send_times)
        print(f"  ex. kurtosis  : {k_t:8.3f}")
        print(f"  Sarle's b     : {b_t:8.3f}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
