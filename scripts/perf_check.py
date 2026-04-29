#!/usr/bin/env python3
# pylint: disable=inconsistent-quotes
"""perf_check.py — fail if perf regressed > tolerance from the all-time best.

The regression gate runs ONLY on Pi-reported metrics from
PERF_STATS lines (recv_ns, dispatch_ns, send_ns). Laptop-reported
metrics from BURST_STATS lines (wire_pps, send_ms, total_ms,
replies) are parsed and printed in the delta table for observation
but cannot fail the gate — they conflate Pi drain rate with
laptop USB scheduling under backpressure (laptop blocks once the
GENET RX ring depth, 256, is reached), so a bad-luck laptop run
trips a wire_pps "regression" that has nothing to do with the
Pi. Pi-side counters use the Pi's own clock and are immune to
that. See "test at the right layer" / "isolate what you test"
in CLAUDE.md.

Ratchet semantics (applied to gated metrics):
  * For each (flavor, burst_size, metric), the "standard" is the
    best ever observed across all prior runs in perf_runs.log.
  * Higher-is-better metrics: standard = max-so-far.
    Fail if current < (1 - tolerance) * standard.
  * Lower-is-better metrics (recv_ns, etc.): standard = min-so-far.
    Fail if current > (1 + tolerance) * standard.
  * A run that beats the standard sets the new bar automatically.
  * No manual standards file — perf_runs.log is the source of truth.
    To "reset" a standard (remove an anomalous outlier), edit the log.

`--runs N` (default 1) lets the caller aggregate across the last N
runs of the matching (commit, flavor). The "current" measurement for
each (burst_size, metric) becomes the best across those N. History
excludes those same N runs so we're not comparing the aggregate
against itself.

Always prints a delta table for human inspection regardless of
pass/fail. Observe-only rows show status `obs` and never appear in
the failures list.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass

LOG_PATH = "hw_test/perf_runs.log"
DEFAULT_TOLERANCE = 0.50  # see docstring; overridable via --tolerance


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
# Both stat lines have the same shape:  WORD_STATS:  n=N  k=v  k=v  ...
# Each contributes its own metrics to the same (burst_size) bucket.
STATS_RE = re.compile(r"(?:BURST|PERF)_STATS:\s+n=(\d+)\s+(.+?)\s*$")
KV_RE = re.compile(r"(\w+)=([0-9.]+)")

# Direction: True = higher is better; False = lower is better.
# All metrics here are parsed and printed in the delta table.
METRIC_DIRECTION: dict[str, bool] = {
    # Laptop-observed (BURST_STATS) — observe-only, see GATED_METRICS.
    "wire_pps": True,
    "replies": True,
    "send_ms": False,
    "total_ms": False,
    # Pi-observed (PERF_STATS) — gated.
    "recv_ns": False,
    "dispatch_ns": False,
    "send_ns": False,
}

# Subset of METRIC_DIRECTION that gates the regression check. A run
# can only FAIL on these metrics. Everything else is logged in the
# table for human inspection but cannot trip the gate. Only Pi-side
# counters belong here — they're measured by the Pi's own clock and
# are immune to laptop-side scheduling jitter that dominates
# wire_pps / send_ms in the backpressured (N >= 256) regime.
GATED_METRICS: set[str] = {"recv_ns", "dispatch_ns", "send_ns"}

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
            mb = STATS_RE.search(line)
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
                key = (size, name)
                if key in current.metrics:
                    # BURST_STATS and PERF_STATS contribute different
                    # metric names today, so no (size, name) tuple should
                    # appear twice in one run. If a future field is added
                    # to both lines (or duplicated within one line), a
                    # silent overwrite would lose data and bias the
                    # ratchet. Fail loudly so the log gets fixed.
                    raise ValueError(
                        f"perf_check: metric collision in {path}: "
                        f"({size}, {name}) appears more than once in run "
                        f"{current.commit}/{current.timestamp}"
                    )
                current.metrics[key] = val
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
    current: float, standard: float, higher_better: bool, tolerance: float,
) -> bool:
    if higher_better:
        return current < (1.0 - tolerance) * standard
    return current > (1.0 + tolerance) * standard


def delta_pct(current: float, standard: float, higher_better: bool) -> float:
    if standard == 0:
        return 0.0
    if higher_better:
        return (current / standard - 1.0) * 100
    return (1.0 - current / standard) * 100  # positive = improved (lower)


def aggregate_best(
    runs: list[Run],
) -> dict[tuple[int, str], float]:
    """Return per-(burst, metric) best across the given runs."""
    aggregated: dict[tuple[int, str], float] = {}
    for run in runs:
        for key, val in run.metrics.items():
            higher_better = METRIC_DIRECTION.get(key[1], True)
            existing = aggregated.get(key)
            if existing is None:
                aggregated[key] = val
            elif higher_better and val > existing:
                aggregated[key] = val
            elif not higher_better and val < existing:
                aggregated[key] = val
    return aggregated


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
    ap.add_argument(
        "--runs", type=int, default=1,
        help=(
            "aggregate the last N runs of (commit, flavor) into a "
            "best-of-N current measurement. Default 1 = single run, "
            "back-compat. Use 3+ to absorb single-run tail-jitter "
            "outliers from a noisy rig."
        ),
    )
    ap.add_argument(
        "--tolerance", type=float, default=DEFAULT_TOLERANCE,
        help=(
            "fail threshold as a fraction (0.50 = fail at 50%% drop "
            "from best). Default 0.50 — strict run for best-of-N. "
            "Use 0.75 for the looser pre-push gate."
        ),
    )
    ap.add_argument("--log", default=LOG_PATH)
    args = ap.parse_args()

    if not 0.0 < args.tolerance < 1.0:
        print(
            f"perf_check: --tolerance must be in (0, 1) "
            f"(got {args.tolerance})",
            file=sys.stderr,
        )
        return 2

    if args.runs < 1:
        print(
            f"perf_check: --runs must be >= 1 (got {args.runs})",
            file=sys.stderr,
        )
        return 2

    runs, reset_after = parse_log(args.log)
    reset_idx = reset_after.get(args.flavor, 0)
    same_flavor = [r for r in runs[reset_idx:] if r.flavor == args.flavor]
    if not same_flavor:
        print(
            f"perf_check: no runs found for flavor "
            f"{args.flavor!r}; nothing to check."
        )
        return 0

    # Pick the "current window": last args.runs entries matching
    # (commit, flavor) if --commit was given, else the last args.runs
    # of the flavor.
    if args.commit:
        matching = [r for r in same_flavor if r.commit == args.commit]
        if not matching:
            print(
                f"perf_check: no run for commit {args.commit} "
                f"flavor {args.flavor!r}; nothing to check."
            )
            return 0
        current_runs = matching[-args.runs:]
    else:
        current_runs = same_flavor[-args.runs:]

    # History = same-flavor runs strictly BEFORE the current window.
    # Aggregating the current window against itself would always pass
    # (current is included in history → best == current). Filter out
    # the runs we're using as the current window.
    current_set = {(r.commit, r.timestamp) for r in current_runs}
    history = [
        r for r in same_flavor
        if (r.commit, r.timestamp) not in current_set
    ]

    aggregated_metrics = aggregate_best(current_runs)
    representative = current_runs[-1]

    if args.runs > 1:
        print(
            f"perf_check: flavor={args.flavor} commit={representative.commit}"
            f" timestamp={representative.timestamp}"
            f" (best-of-{len(current_runs)} window;"
            f" earliest run {current_runs[0].timestamp})"
        )
    else:
        print(
            f"perf_check: flavor={args.flavor} commit={representative.commit}"
            f" timestamp={representative.timestamp}"
        )
    print(f"  history: {len(history)} prior runs of this flavor "
          f"(after most recent BASELINE_RESET, if any)")
    print(f"  threshold: {args.tolerance*100:.0f}% from all-time best")
    print()

    if not aggregated_metrics:
        print("  (no metrics in current run window)")
        return 0

    # Synthesize a single Run with the aggregated metrics so the
    # downstream printing / comparison code stays the same shape.
    current = Run(
        commit=representative.commit,
        timestamp=representative.timestamp,
        flavor=representative.flavor,
        metrics=aggregated_metrics,
    )

    print(f"  {'burst':>6}  {'metric':<13}  {'current':>10}  "
          f"{'best':>10}  {'delta':>8}  status")
    print(f"  {'-'*6}  {'-'*13}  {'-'*10}  {'-'*10}  {'-'*8}  ------")

    failures: list[str] = []
    new_bars_gated: list[str] = []
    new_bars_obs: list[str] = []

    for key in sorted(current.metrics.keys()):
        size, name = key
        current_val = current.metrics[key]
        higher_better = METRIC_DIRECTION.get(name, True)
        gated = name in GATED_METRICS
        standard = best_so_far(history, key)

        if standard is None:
            status = "first" if gated else "obs (first)"
            print(f"  {size:>6}  {name:<13}  {current_val:>10.1f}  "
                  f"{'(none)':>10}  {'-':>8}  {status}")
            continue

        d = delta_pct(current_val, standard, higher_better)

        new_best = (
            (higher_better and current_val > standard)
            or (not higher_better and current_val < standard)
        )

        if new_best:
            # Track new bests for gated and observe-only metrics in
            # separate buckets — only gated bests tighten the gate.
            # Observe-only bests are reported for humans to spot
            # secular trends but don't move any threshold.
            entry = f"{name}@n={size}: {standard:.1f} → {current_val:.1f}"
            if gated:
                new_bars_gated.append(entry)
                status = "NEW BEST"
            else:
                new_bars_obs.append(entry)
                status = "obs (NEW BEST)"
        elif is_regression(
            current_val, standard, higher_better, args.tolerance,
        ):
            if gated:
                status = "FAIL"
                failures.append(
                    f"{name}@n={size}: current={current_val:.1f} "
                    f"best={standard:.1f} delta={d:+.1f}%"
                )
            else:
                # Observe-only metric drifted past tolerance. Surface it
                # in the table so a human notices, but don't fail the
                # gate — laptop-side variance is expected here.
                status = "obs (over)"
        else:
            status = "ok" if gated else "obs"

        print(f"  {size:>6}  {name:<13}  {current_val:>10.1f}  "
              f"{standard:>10.1f}  {d:>+7.1f}%  {status}")

    print()
    if new_bars_gated:
        print(
            f"perf_check: {len(new_bars_gated)} gated new best(s) — "
            f"these tighten the regression gate:"
        )
        for nb in new_bars_gated:
            print(f"  + {nb}")
        print()
    if new_bars_obs:
        print(
            f"perf_check: {len(new_bars_obs)} observe-only new best(s) — "
            f"informational, do not affect the gate:"
        )
        for nb in new_bars_obs:
            print(f"  + {nb}")
        print()

    if failures:
        print(
            f"perf_check: REGRESSION "
            f"(>{args.tolerance*100:.0f}% from best)"
        )
        for f in failures:
            print(f"  - {f}")
        return 1

    print("perf_check: OK — no regressions; perf is monotonic")
    return 0


if __name__ == "__main__":
    sys.exit(main())
