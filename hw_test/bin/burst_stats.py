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


BURST_RE = re.compile(
    r"BURST_STATS: n=(\d+) replies=(\d+) send_ms=([\d.]+) "
    r"wire_pps=([\d.]+) total_ms=([\d.]+)"
)

# PERF_STATS line is OPTIONAL — only present when the Pi is running
# a PERF build that responds to the 0x88B6 perf_query. Default
# kernels skip it. We parse what we can; missing fields are None.
PERF_RE = re.compile(
    r"PERF_STATS: n=(\d+) "
    r"recv_count=(\d+) recv_none=(\d+) "
    r"dispatch_count=(\d+) "
    r"send_count=(\d+) send_fail=(\d+) "
    r"max_burst=(\d+) rx_discards=(\d+) "
    r"recv_ns=(\d+) dispatch_ns=(\d+) send_ns=(\d+)"
)


def run_once(n: int) -> dict:
    """Run one pytest invocation, return a dict with all parsed stats.

    Always populates: replies, send_ms.
    Populated only when the Pi has perf instrumentation:
    recv_count, recv_none, dispatch_count, send_count, send_fail,
    max_burst, rx_discards, recv_ns, dispatch_ns, send_ns.
    """
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
    output = result.stdout + result.stderr

    burst_m = BURST_RE.search(output)
    if not burst_m:
        raise RuntimeError(
            f"Could not parse BURST_STATS line from pytest output:\n"
            f"{output}"
        )
    out = {
        "replies": int(burst_m.group(2)),
        "send_ms": float(burst_m.group(3)),
        "wire_pps": float(burst_m.group(4)),
    }

    perf_m = PERF_RE.search(output)
    if perf_m:
        out.update({
            "recv_count":     int(perf_m.group(2)),
            "recv_none":      int(perf_m.group(3)),
            "dispatch_count": int(perf_m.group(4)),
            "send_count":     int(perf_m.group(5)),
            "send_fail":      int(perf_m.group(6)),
            "max_burst":      int(perf_m.group(7)),
            "rx_discards":    int(perf_m.group(8)),
            "recv_ns":        int(perf_m.group(9)),
            "dispatch_ns":    int(perf_m.group(10)),
            "send_ns":        int(perf_m.group(11)),
        })

    return out


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


def _summarize(name: str, xs: list[float], unit: str = "") -> None:
    """Print mean / stdev / range for a list of measurements."""
    if not xs:
        return
    mean = statistics.fmean(xs)
    sd = statistics.stdev(xs) if len(xs) > 1 else 0.0
    suffix = f" {unit}" if unit else ""
    print(
        f"  {name:<18} mean={mean:8.2f}{suffix}  "
        f"stdev={sd:7.2f}{suffix}  "
        f"min={min(xs):.0f} max={max(xs):.0f}"
    )


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
    trials: list[dict] = []
    for i in range(runs):
        t = run_once(burst_size)
        trials.append(t)
        perf_tag = ""
        if "recv_ns" in t:
            perf_tag = (
                f"  perf: recv={t['recv_ns']}ns "
                f"disp={t['dispatch_ns']}ns send={t['send_ns']}ns"
            )
        print(
            f"  run {i+1:>2}/{runs}: {t['replies']:>4} replies, "
            f"send_time={t['send_ms']:.1f}ms{perf_tag}",
            flush=True,
        )

    counts = [t["replies"] for t in trials]
    send_times = [t["send_ms"] for t in trials]

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

    # Per-stage perf stats are only present when the Pi has a PERF
    # build. Skip the section entirely if no trial returned them.
    perf_trials = [t for t in trials if "recv_ns" in t]
    if perf_trials:
        print()
        print(f"=== Per-stage cycle counts (PERF build, {len(perf_trials)}/{runs} trials) ===")
        print(f"  Pi 4 CNTVCT_EL0 = 54 MHz; ns = ticks * 18.52")
        print()
        _summarize("recv_ns",      [t["recv_ns"]      for t in perf_trials], "ns/frame")
        _summarize("dispatch_ns",  [t["dispatch_ns"]  for t in perf_trials], "ns/frame")
        _summarize("send_ns",      [t["send_ns"]      for t in perf_trials], "ns/frame")
        print()
        _summarize("recv_count",   [t["recv_count"]   for t in perf_trials])
        _summarize("recv_none",    [t["recv_none"]    for t in perf_trials])
        _summarize("dispatch_count",[t["dispatch_count"] for t in perf_trials])
        _summarize("send_count",   [t["send_count"]   for t in perf_trials])
        _summarize("send_fail",    [t["send_fail"]    for t in perf_trials])
        _summarize("rx_discards",  [t["rx_discards"]  for t in perf_trials])

        # Quick sanity: per-stage sum should be close to the
        # observed per-frame cost. If not, something's mis-probed.
        recv_mean = statistics.fmean(t["recv_ns"] for t in perf_trials)
        disp_mean = statistics.fmean(t["dispatch_ns"] for t in perf_trials)
        send_mean = statistics.fmean(t["send_ns"] for t in perf_trials)
        total = recv_mean + disp_mean + send_mean
        print()
        print(
            f"  per-frame total : {total:8.0f} ns "
            f"(recv {recv_mean/total*100:.0f}% / "
            f"disp {disp_mean/total*100:.0f}% / "
            f"send {send_mean/total*100:.0f}%)"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
