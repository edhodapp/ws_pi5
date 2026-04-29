#!/usr/bin/env bash
# perf_nightly.sh — wait for a quiet host, then run the strict perf cycle.
#
# Cron entry (system local TZ — important; the deadline aligns with
# Ed's sleep, not UTC):
#   0 0 * * * /home/ed/ws_pi5/scripts/perf_nightly.sh \
#       >> /tmp/perf_nightly.log 2>&1
#
# Behaviour:
#   * Polls the 1-minute load average every POLL_SECS seconds.
#   * As soon as load is below LOAD_THRESHOLD, fires the strict perf
#     cycle (best-of-3, 50% tolerance) with --continue-on-fail — every
#     phase runs, every per-phase run records its telemetry, and the
#     wrapper exits non-zero at the end if anything failed. This is
#     intentionally different from the interactive `hw_tests.sh perf`
#     default (which still bails on first failure for fast feedback).
#     The cron wants regression-trend data; bailing early loses runs
#     2/3 of one phase and the entire next phase.
#   * Gives up at the local-time deadline (default 08:00 today).
#   * Exits 0 on either "ran perf cleanly" OR "deadline hit, no run
#     today". Non-zero exit means at least one phase or run failed —
#     check perf_runs.log and the cron log for which.
#
# Trigger uses local time (matches sleep schedule).
# Log timestamps inside perf_runs.log stay UTC (matches the rest of
# the project; the trigger and the data live in different time bases
# on purpose).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

LOAD_THRESHOLD="${LOAD_THRESHOLD:-1.5}"
POLL_SECS="${POLL_SECS:-300}"           # 5 min between polls
DEADLINE_LOCAL="${DEADLINE_LOCAL:-08:00}"

DEADLINE_TS=$(date -d "$DEADLINE_LOCAL today" +%s)
START_TS=$(date +%s)
if [ "$START_TS" -ge "$DEADLINE_TS" ]; then
    # Cron fired after deadline (e.g. catchup after a long suspend).
    # The interesting window is past — bail without running.
    echo "[$(date -Iseconds)] perf_nightly: started after $DEADLINE_LOCAL local; skipping"
    exit 0
fi

echo "[$(date -Iseconds)] perf_nightly: waiting for quiet host (load < $LOAD_THRESHOLD), deadline $DEADLINE_LOCAL local"

while [ "$(date +%s)" -lt "$DEADLINE_TS" ]; do
    load=$(awk '{print $1}' /proc/loadavg)
    if awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN{exit !(l < t)}'; then
        echo "[$(date -Iseconds)] perf_nightly: load=$load < $LOAD_THRESHOLD — running strict perf cycle"
        # Inherits PERF_RUNS=3 / PERF_TOLERANCE=0.50 defaults from hw_tests.sh.
        # --continue-on-fail keeps every phase running even if one fails so
        # the trend log gets a full night's data.
        if bash "$SCRIPT_DIR/hw_tests.sh" --continue-on-fail perf; then
            echo "[$(date -Iseconds)] perf_nightly: PASS"
            exit 0
        else
            rc=$?
            echo "[$(date -Iseconds)] perf_nightly: FAIL (exit=$rc) — one or more phases/runs failed; check perf_runs.log"
            exit "$rc"
        fi
    fi
    sleep "$POLL_SECS"
done

echo "[$(date -Iseconds)] perf_nightly: deadline $DEADLINE_LOCAL local reached; host stayed busy — no run today"
exit 0
