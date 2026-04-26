#!/usr/bin/env bash
# perf_push.sh — looser perf gate for pre-push.
#
# 1 run per phase, 75% tolerance. Catches "we did something really
# horrible" before a push but doesn't fight single-run tail-jitter
# from the laptop's USB / tcpreplay scheduling. The rigorous
# best-of-3 / 50% gate runs nightly via perf_nightly.sh.
#
# Host-load guard: a busy host (high cc1/qemu/whatever load) makes
# tcpreplay miss timing windows and a single run lands deep below
# baseline even at 75% tolerance. This isn't a code regression, it's
# the laptop being asked to do too many things at once. Skip the
# perf gate cleanly (exit 0) when 1-min load is above LOAD_THRESHOLD
# — the nightly cron will catch real regressions when the host is
# actually quiet. Override threshold via env var for unusual cases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOAD_THRESHOLD="${LOAD_THRESHOLD:-1.5}"
load=$(awk '{print $1}' /proc/loadavg)
if awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN{exit !(l >= t)}'; then
    echo "perf_push: host 1-min load=$load >= $LOAD_THRESHOLD"
    echo "perf_push: skipping pre-push perf gate — busy host produces noise, not signal."
    echo "perf_push: nightly cron (perf_nightly.sh) will catch real regressions."
    exit 0
fi

echo "perf_push: load=$load < $LOAD_THRESHOLD, running loose perf gate"
PERF_RUNS=1 PERF_TOLERANCE=0.75 \
    bash "$SCRIPT_DIR/hw_tests.sh" perf
