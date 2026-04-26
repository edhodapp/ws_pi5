#!/usr/bin/env python3
# pylint: disable=inconsistent-quotes
"""perf_check.py — fail if perf regressed > 50% from the all-time best.

Ratchet semantics:
  * For each (flavor, burst_size, metric), the "standard" is the
    best ever observed across all prior runs in perf_runs.log.
  * Higher-is-better metrics (e.g. wire_pps): standard = max-so-far.
    Fail if current < 0.5 * standard.
  * Lower-is-better metrics (e.g. send_ms, recv_ns): standard = min-so-far.
    Fail if current > 1.5 * standard.
  * A run that beats the standard sets the new bar automatically,
    because the standard is recomputed from history (which now includes
    this run) on the next check.
  * No manual standards file — perf_runs.log is the source of truth.
    To "reset" a standard (remove an anomalous outlier), edit the log.

The first run of a (flavor, burst_size, metric) tuple has no history
to compare against — it sets the initial standard. Subsequent runs
must stay within 50% of the best seen so far.

The 50% tolerance is wide on purpose: this rig has heavy
session-to-session host-side noise (USB scheduling, CPU governor
state, tcpreplay process timing) that easily moves wire_pps and
send_ms by 30%. The ratchet's job here is to catch order-of-magnitude
regressions and tail collapses, not to police 10% drift.

Always prints a delta table for human inspection regardless of pass/fail.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass

LOG_PATH = "hw_test/perf_runs.log"
TOLERANCE = 0.50  # 50% drop from best is a fail (see docstring)


@dataclass
class Run:
    commit: str
    timestamp: str
    flavor: str
    metrics: dict[tuple[int, str], float]  # (burst_size, metric_name) -> value


HEADER_RE = re.compile(r"^---\s+(\S+)\s+(\S+)\s+(.+?)\s+---\s*$")
BASELINE_RE = re.compile(
    r"^---\s+BASELINE_RESET\s+(\S+)\s+(\S+)\s+(.+?)\s+---\s*$"
)
BURST_RE = re.compile(r"BURST_STATS:\s+n=(\d+)\s+(.+?)\s*$")
KV_RE = re.compile(r"(\w+)=([0-9.]+)")

# Direction: True = higher is better; False = lower is better.
METRIC_DIRECTION: dict[str, bool] = {
    "wire_pps": True,
    "replies": True,
    "send_ms": False,
    "total_ms": False,
    "recv_ns": False,
    "dispatch_ns": False,
    "send_ns": False,
}

# Metrics that aren't useful to track (counts that are inputs, not outputs).
SKIP_METRICS = {"n"}


def parse_log(path: str) -> tuple[list[Run], dict[str, int]]:
    """Returns (runs, baseline_reset_index_by_flavor).

    `baseline_reset_index_by_flavor` maps a flavor string to the
    index in `runs` AT WHICH that flavor's history is considered to
    start. Runs of that flavor before this index are ignored when
    computing best-so-far. If a flavor has no reset, its key is absent
    (start from index 0).
    """
    runs: list[Run] = []
    current: Run | None = None
    reset_after: dict[str, int] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            mr = BASELINE_RE.match(line)
            if mr:
                # Close out any in-progress run first so the index
                # below points at "next run after the reset."
                if current is not None:
                    runs.append(current)
                    current = None
                reset_flavor = mr.group(1)
                # All runs of reset_flavor at index < len(runs) are now
                # invalidated. The next run of reset_flavor we append
                # will be the new floor.
                reset_after[reset_flavor] = len(runs)
                continue
            m = HEADER_RE.match(line)
            if m:
                if current is not None:
                    runs.append(current)
                current = Run(
                    commit=m.group(1),
                    timestamp=m.group(2),
                    flavor=m.group(3),
                    metrics={},
                )
                continue
            if current is None:
                continue
            mb = BURST_RE.search(line)
            if not mb:
                continue
            try:
                size = int(mb.group(1))
            except ValueError:
                continue
            for kv in KV_RE.finditer(mb.group(2)):
                name = kv.group(1)
                if name in SKIP_METRICS or name not in METRIC_DIRECTION:
                    continue
                try:
                    val = float(kv.group(2))
                except ValueError:
                    continue
                current.metrics[(size, name)] = val
    if current is not None:
        runs.append(current)
    return runs, reset_after


def best_so_far(history: list[Run], key: tuple[int, str]) -> float | None:
    _, name = key
    higher_better = METRIC_DIRECTION.get(name, True)
    values = [r.metrics[key] for r in history if key in r.metrics]
    if not values:
        return None
    return max(values) if higher_better else min(values)


def is_regression(
    current: float, standard: float, higher_better: bool,
) -> bool:
    if higher_better:
        return current < (1.0 - TOLERANCE) * standard
    return current > (1.0 + TOLERANCE) * standard


def delta_pct(current: float, standard: float, higher_better: bool) -> float:
    if standard == 0:
        return 0.0
    if higher_better:
        return (current / standard - 1.0) * 100
    return (1.0 - current / standard) * 100  # positive = improved (lower)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--flavor", required=True,
        help="flavor string to match (e.g. 'PERF=recv', 'default')",
    )
    ap.add_argument(
        "--commit", default=None,
        help="commit hash of the run to check (defaults to latest)",
    )
    ap.add_argument("--log", default=LOG_PATH)
    args = ap.parse_args()

    runs, reset_after = parse_log(args.log)
    reset_idx = reset_after.get(args.flavor, 0)
    same_flavor = [r for r in runs[reset_idx:] if r.flavor == args.flavor]
    if not same_flavor:
        print(
            f"perf_check: no runs found for flavor "
            f"{args.flavor!r}; nothing to check."
        )
        return 0

    if args.commit:
        current_idx = max(
            (i for i, r in enumerate(same_flavor) if r.commit == args.commit),
            default=None,
        )
    else:
        current_idx = len(same_flavor) - 1

    if current_idx is None:
        print(
            f"perf_check: no run for commit {args.commit} "
            f"flavor {args.flavor!r}; nothing to check."
        )
        return 0

    current = same_flavor[current_idx]
    history = same_flavor[:current_idx]  # all prior runs of same flavor

    print(f"perf_check: flavor={args.flavor} commit={current.commit} "
          f"timestamp={current.timestamp}")
    print(f"  history: {len(history)} prior runs of this flavor "
          f"(after most recent BASELINE_RESET, if any)")
    print(f"  threshold: {TOLERANCE*100:.0f}% from all-time best")
    print()

    if not current.metrics:
        print("  (no metrics in current run)")
        return 0

    print(f"  {'burst':>6}  {'metric':<13}  {'current':>10}  "
          f"{'best':>10}  {'delta':>8}  status")
    print(f"  {'-'*6}  {'-'*13}  {'-'*10}  {'-'*10}  {'-'*8}  ------")

    failures: list[str] = []
    new_bars: list[str] = []

    for key in sorted(current.metrics.keys()):
        size, name = key
        current_val = current.metrics[key]
        higher_better = METRIC_DIRECTION.get(name, True)
        standard = best_so_far(history, key)

        if standard is None:
            status = "first"
            print(f"  {size:>6}  {name:<13}  {current_val:>10.1f}  "
                  f"{'(none)':>10}  {'-':>8}  {status}")
            continue

        d = delta_pct(current_val, standard, higher_better)

        if higher_better and current_val > standard:
            status = "NEW BEST"
            new_bars.append(
                f"{name}@n={size}: {standard:.1f} → {current_val:.1f}"
            )
        elif not higher_better and current_val < standard:
            status = "NEW BEST"
            new_bars.append(
                f"{name}@n={size}: {standard:.1f} → {current_val:.1f}"
            )
        elif is_regression(current_val, standard, higher_better):
            status = "FAIL"
            failures.append(
                f"{name}@n={size}: current={current_val:.1f} "
                f"best={standard:.1f} delta={d:+.1f}%"
            )
        else:
            status = "ok"

        print(f"  {size:>6}  {name:<13}  {current_val:>10.1f}  "
              f"{standard:>10.1f}  {d:>+7.1f}%  {status}")

    print()
    if new_bars:
        print(
            f"perf_check: {len(new_bars)} new best(s) — "
            f"these now define the bar:"
        )
        for nb in new_bars:
            print(f"  + {nb}")
        print()

    if failures:
        print(f"perf_check: REGRESSION (>{TOLERANCE*100:.0f}% from best)")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("perf_check: OK — no regressions; perf is monotonic")
    return 0


if __name__ == "__main__":
    sys.exit(main())
