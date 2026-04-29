#!/usr/bin/env bash
# hw_tests.sh — Bucket C: Pi 4 hardware integration runner.
#
# Each layer / perf flavor needs its own fresh flash for state
# isolation. The script handles flashing between phases.
#
# Layers (functional, default kernel build):
#   L2  → -m l2   (Ethernet / data link)
#   L3  → -m l3   (IPv4 / ICMP / reassembly)
#   L4  → test_tcp_*.py
#   L5  → test_http_*.py
#
# Perf flavors (each its own PERF= build):
#   perf-l2       → PERF=recv     ( -m l2 -m perf )
#   perf-dispatch → PERF=dispatch ( -m perf, dispatch tests )
#   perf-l3       → PERF=l3       ( -m l3 -m perf )
#   perf-l4       → PERF=send     ( TCP TX perf )
#   perf  → shorthand for "all four perf phases"
#
# Usage:
#   scripts/hw_tests.sh L2 L3 L4 L5            # all functional
#   scripts/hw_tests.sh L2 L3 L4 L5 perf       # full functional + all perf
#   scripts/hw_tests.sh L3-L4                  # range (functional)
#   scripts/hw_tests.sh L2 L4                  # selective
#   scripts/hw_tests.sh perf-l2                # one perf flavor
#   scripts/hw_tests.sh --no-reflash L5        # skip flash (trust state)
#   scripts/hw_tests.sh --continue-on-fail perf  # run all phases, record
#                                                # all runs, exit non-zero
#                                                # at end if any failed
#                                                # (regression-trend cron)
#
# After perf phases run, scripts/perf_check.py validates wire_pps
# hasn't regressed > 10% versus the median of the last 10 runs.
#
# See TESTING.md for the bucket taxonomy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

VENV="$PROJECT_DIR/.venv/bin/python"
if [ ! -x "$VENV" ]; then
    echo "ERROR: .venv not found — install Python venv per project setup" >&2
    exit 1
fi

PERF_LOG="$PROJECT_DIR/hw_test/perf_runs.log"
DEV_CONTENT_MAX=65536
COMMIT=$(git rev-parse --short HEAD)
RESTORE_DEFAULT=true
NO_REFLASH=false
CONTINUE_ON_FAIL=false
ANY_FAIL=0
FAILED_LABELS=()
PHASES=()

# --- arg parse -------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --no-reflash) NO_REFLASH=true; shift ;;
        --no-restore) RESTORE_DEFAULT=false; shift ;;
        --continue-on-fail) CONTINUE_ON_FAIL=true; shift ;;
        L2|L3|L4|L5) PHASES+=("$1"); shift ;;
        L2-L3) PHASES+=(L2 L3); shift ;;
        L2-L4) PHASES+=(L2 L3 L4); shift ;;
        L2-L5) PHASES+=(L2 L3 L4 L5); shift ;;
        L3-L4) PHASES+=(L3 L4); shift ;;
        L3-L5) PHASES+=(L3 L4 L5); shift ;;
        L4-L5) PHASES+=(L4 L5); shift ;;
        perf) PHASES+=(perf-l2 perf-dispatch perf-l3 perf-l4); shift ;;
        perf-l2|perf-dispatch|perf-l3|perf-l4) PHASES+=("$1"); shift ;;
        -h|--help)
            sed -n '2,35p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown phase '$1'" >&2
            exit 1
            ;;
    esac
done

if [ "${#PHASES[@]}" -eq 0 ]; then
    echo "ERROR: no phases specified. Try: $0 L2 L3 L4 L5" >&2
    exit 1
fi

# --- helpers ---------------------------------------------------------
kill_stale() {
    "$VENV" -c "
import sys; sys.path.insert(0, 'scripts')
from hw_send import kill_stale_hw_send
kill_stale_hw_send()
" 2>/dev/null || true
}

# note_fail <label> <message...>
# Records a failure under the given label. In --continue-on-fail mode,
# returns 1 so the caller can skip the rest of its phase but the outer
# loop keeps going. Otherwise, exits 1 immediately (legacy behaviour).
note_fail() {
    local label="$1"; shift
    echo "FAIL [$label]: $*" >&2
    FAILED_LABELS+=("$label")
    ANY_FAIL=1
    if [ "$CONTINUE_ON_FAIL" = "true" ]; then
        return 1
    fi
    exit 1
}

flash_and_wait() {
    # flash_and_wait <logfile> [--label <name>] <make-args...>
    # --label distinguishes flash failures across phases in the
    # final summary (e.g. "flash-restore" vs the default "flash").
    local logfile="$1"; shift
    local label="flash"
    if [ "${1:-}" = "--label" ]; then
        shift
        label="$1"
        shift
    fi
    if [ "$NO_REFLASH" = "true" ]; then
        echo "  [skip flash: --no-reflash]"
        return 0
    fi
    kill_stale
    make clean > /dev/null 2>&1
    make "$@" > /dev/null 2>&1
    "$VENV" scripts/hw_send.py kernel8.img > "$logfile" 2>&1 &
    local hw_pid=$!
    # 9514 hex records takes ~66 s to UART-send, then GENET init adds
    # a variable few seconds. The previous 75 s budget left only ~9 s
    # for init and intermittently flagged healthy boots as "did not
    # boot". Bumped to 150 s so a slow genet_init still has headroom.
    for i in $(seq 1 150); do
        if grep -q 'GENET Gigabit Ethernet' "$logfile" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    if ! grep -q 'GENET Gigabit Ethernet' "$logfile"; then
        kill "$hw_pid" 2>/dev/null || true
        note_fail "$label" "Pi 4 did not boot (see $logfile)"
        return 1
    fi
    if ! ping -c 2 -W 2 10.0.0.2 > /dev/null 2>&1; then
        kill "$hw_pid" 2>/dev/null || true
        note_fail "$label" "Pi 4 not reachable after boot"
        return 1
    fi
}

run_pytest() {
    # run_pytest <selector_args...> ; returns nonzero on failure
    HW_TEST=1 "$VENV" -m pytest hw_test/ "$@" --tb=short -q
}

# --- per-phase runners ----------------------------------------------
run_layer_functional() {
    local layer="$1"
    local marker_or_path="$2"
    local flash_log="/tmp/hw_tests-${layer}-flash.log"
    echo "=== [$layer] flash default build ==="
    if ! flash_and_wait "$flash_log" PLATFORM=pi4 CONTENT_MAX=$DEV_CONTENT_MAX; then
        # In continue mode, note_fail already accounted for the flash
        # failure; skip pytest since the Pi isn't up.
        return 1
    fi
    echo "=== [$layer] running tests ==="
    if ! run_pytest $marker_or_path; then
        note_fail "$layer" "functional tests failed"
        return 1
    fi
}

run_perf_phase() {
    local label="$1"
    local perf_flavor="$2"
    # Marker EXPRESSION (e.g. "l2 and perf") — passed straight to pytest -m.
    # Single string, not a multi-token args list, so the bash word-split
    # bug from $pytest_selector expansion can't reappear.
    local marker_expr="$3"
    local flash_log="/tmp/hw_tests-${label}-flash.log"
    local out
    out=$(mktemp)
    echo "=== [$label] flash PERF=$perf_flavor build ==="
    if ! flash_and_wait "$flash_log" PLATFORM=pi4 PERF=$perf_flavor CONTENT_MAX=$DEV_CONTENT_MAX; then
        rm -f "$out"
        return 1
    fi
    # PERF_RUNS / PERF_TOLERANCE are knobs the calling driver script
    # can tune. Strict nightly runs use --runs 3 and --tolerance 0.50;
    # the looser pre-push gate uses --runs 1 and --tolerance 0.75
    # (catch only "really horrible" regressions, ignore single-run
    # tail jitter on a noisy host).
    : "${PERF_RUNS:=3}"
    : "${PERF_TOLERANCE:=0.50}"
    local phase_failed=0
    for i in $(seq 1 "$PERF_RUNS"); do
        echo "=== [$label] perf run $i/$PERF_RUNS (-m \"$marker_expr\") ==="
        # Pytest exit codes: 0 = pass, 1 = fail, 5 = no tests collected.
        # We tolerate 5 here because some PERF flavors (e.g.
        # perf-dispatch) have a build configuration but no associated
        # test suite yet — "no tests" is not a failure, it's a no-op.
        # Use a temp-file PIPESTATUS dance because `tee` clobbers $? .
        set +e
        HW_TEST=1 "$VENV" -m pytest hw_test/ -m "$marker_expr" \
            --tb=short -q -s 2>&1 | tee "$out"
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -eq 5 ]; then
            echo "  (no tests matched -m \"$marker_expr\" — phase is a build-only no-op, skipping)"
            rm -f "$out"
            return 0
        fi
        # Record this run's telemetry regardless of pass/fail. For a
        # regression-trend cron the failed-run BURST_STATS / PERF_STATS
        # numbers ARE the data — they tell us *how badly* something
        # regressed. Header annotates the run with its exit status so
        # perf_check.py and human readers can tell.
        {
            echo ""
            echo "--- $COMMIT $(date -u +%Y-%m-%dT%H:%M:%SZ) PERF=$perf_flavor ---"
            if [ "$rc" -ne 0 ]; then
                echo "    (pytest exit=$rc — test failed; stats below are from the failed run)"
            fi
            grep -E 'RTT baseline|BURST_STATS|PERF_STATS' "$out" || true
        } >> "$PERF_LOG"
        if [ "$rc" -ne 0 ]; then
            phase_failed=1
            # note_fail handles both modes: in continue-on-fail it
            # records the label and returns 1 so we `continue` to the
            # next run; in fail-fast it exits 1 immediately. Trailing
            # `|| true` is required only in continue mode.
            note_fail "${label}-run${i}" "pytest exit=$rc" || true
            continue
        fi
    done
    rm -f "$out"
    # Skip the regression check if any run in this phase failed —
    # perf_check.py reads the last PERF_RUNS entries from the log,
    # and a failed run's stats either are missing or come from a
    # broken-state DUT, so the median comparison would either
    # spuriously pass or spuriously fail. The trend log still has
    # the data; humans can eyeball it. Phase-level failure is
    # already recorded via per-run note_fail calls above.
    if [ "$phase_failed" -ne 0 ]; then
        echo "  [skip perf_check: $label had per-run failures; trend log retains the data]"
        return 1
    fi
    if ! "$VENV" "$SCRIPT_DIR/perf_check.py" --flavor "PERF=$perf_flavor" \
            --commit "$COMMIT" --runs "$PERF_RUNS" \
            --tolerance "$PERF_TOLERANCE"; then
        note_fail "$label" "perf regression vs baseline"
        return 1
    fi
}

# --- run each requested phase ----------------------------------------
# In --continue-on-fail mode, a phase returning 1 has already called
# note_fail. Trailing `|| true` keeps the loop alive under set -e.
# In default (fail-fast) mode, note_fail exits 1 itself; the trailing
# `|| true` is reached only when a phase succeeds, so behaviour is
# unchanged for interactive callers.
for phase in "${PHASES[@]}"; do
    case "$phase" in
        L2)            run_layer_functional "L2" "-m l2"               || true ;;
        L3)            run_layer_functional "L3" "-m l3"               || true ;;
        L4)            run_layer_functional "L4" "-m l4"               || true ;;
        L5)            run_layer_functional "L5" "-m l5"               || true ;;
        perf-l2)       run_perf_phase "perf-l2"       "recv"     "l2 and perf"      || true ;;
        perf-dispatch) run_perf_phase "perf-dispatch" "dispatch" "perf and dispatch" || true ;;
        perf-l3)       run_perf_phase "perf-l3"       "l3"       "l3 and perf"      || true ;;
        perf-l4)       run_perf_phase "perf-l4"       "send"     "l4 and perf"      || true ;;
        *) echo "BUG: unhandled phase $phase" >&2; exit 1 ;;
    esac
done

# --- restore default build at the end (matches old pre-push Phase 3) -
if [ "$RESTORE_DEFAULT" = "true" ]; then
    echo "=== restoring default build ==="
    flash_and_wait /tmp/hw_tests-restore-flash.log --label flash-restore \
        PLATFORM=pi4 CONTENT_MAX=$DEV_CONTENT_MAX || true
fi

if [ "$ANY_FAIL" -eq 0 ]; then
    echo "=== hw_tests.sh: all requested phases passed ==="
    exit 0
fi
echo "=== hw_tests.sh: ${#FAILED_LABELS[@]} failure(s): ${FAILED_LABELS[*]} ==="
exit 1
