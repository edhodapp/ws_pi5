#!/usr/bin/env bash
# perf_push.sh — looser perf gate for pre-push.
#
# 1 run per phase, 75% tolerance. Catches "we did something really
# horrible" before a push but doesn't fight single-run tail-jitter
# from the laptop's USB / tcpreplay scheduling. The rigorous
# best-of-3 / 50% gate runs nightly via perf_nightly.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PERF_RUNS=1 PERF_TOLERANCE=0.75 \
    bash "$SCRIPT_DIR/hw_tests.sh" perf
