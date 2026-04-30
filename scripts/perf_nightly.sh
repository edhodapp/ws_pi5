#!/usr/bin/env bash
# perf_nightly.sh — wait for a quiet host, then run the strict perf cycle.
#
# Cron entry (system local TZ — important; the deadline aligns with
# Ed's sleep, not UTC):
#   0 0 * * * /home/ed/ws_pi5/scripts/perf_nightly.sh \
#       >> /tmp/perf_nightly.log 2>&1
#
# Behaviour (D016: cron is data-gathering, not gating):
#   * Polls the 1-minute load average every POLL_SECS seconds.
#   * As soon as load is below LOAD_THRESHOLD, fires the perf cycle
#     in --data-only mode. Every phase runs, every per-phase run
#     records its telemetry, and the cron exits non-zero ONLY if a
#     phase hangs (exceeds PHASE_TIMEOUT_S wall-clock) or the
#     harness itself crashes. Pytest assertion failures and
#     perf_check regressions are recorded as data points but do
#     not fail the cron — single-point thresholds are noise; the
#     human-readable trend in perf_runs.log is the signal.
#   * Pre-push-integration.sh keeps the gated behaviour (different
#     role: catching regressions before they ship).
#   * Gives up at the local-time deadline (default 08:00 today).
#   * Exits 0 on either "ran perf, recorded data" (regardless of
#     individual run outcomes) OR "deadline hit, no run today".
#     Non-zero exit indicates a hang or harness crash — operator
#     should investigate.
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
        echo "[$(date -Iseconds)] perf_nightly: load=$load < $LOAD_THRESHOLD — running data-only perf cycle"
        # --data-only: the cron records data, not gates. Inherits
        # PERF_RUNS=3 from hw_tests.sh; PHASE_TIMEOUT_S defaults to 600 s
        # but can be overridden in the cron environment if needed.
        if bash "$SCRIPT_DIR/hw_tests.sh" --data-only perf; then
            echo "[$(date -Iseconds)] perf_nightly: data recorded; check perf_runs.log for trends"
            exit 0
        else
            rc=$?
            echo "[$(date -Iseconds)] perf_nightly: FAIL (exit=$rc) — phase hang or harness crash; check perf_runs.log for HANG markers"
            exit "$rc"
        fi
    fi
    sleep "$POLL_SECS"
done

echo "[$(date -Iseconds)] perf_nightly: deadline $DEADLINE_LOCAL local reached; host stayed busy — no run today"
exit 0
