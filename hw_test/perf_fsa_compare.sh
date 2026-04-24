#!/usr/bin/env bash
# hw_test/perf_fsa_compare.sh
#
# Legacy-vs-FSA perf comparison harness. Flashes both kernel flavors
# sequentially, runs wrk at three concurrency tiers against each, and
# writes a markdown comparison block to hw_test/perf_history.md.
#
# For the HTTP_OUTPUT_FSA=1 build we also curl /fsa_stats before AND
# after each wrk run so the delta captures the engine counters under
# load — events_posted, events_dropped, step_ok, step_no_trans, plus
# per-handler dispatch counts.
#
# Runs on the laptop. Pi 4 must be wired via GENET (10.0.0.2) and
# chainloader-reachable via /dev/ttyUSB0.
#
# Usage:
#   hw_test/perf_fsa_compare.sh [--duration N] [--output FILE] [--skip-flash]
#
#   --duration N    wrk run time per tier in seconds (default 10)
#   --output FILE   append markdown to FILE (default hw_test/perf_history.md)
#   --skip-flash    skip the legacy build + flash; useful when you've
#                   already compared a prior run and only want the FSA
#                   measurement
#   --legacy-only   skip the FSA half (sanity-check the harness without
#                   touching the FSA flag)
#
# Exit 0 on success (comparison written). Non-zero on setup / flash /
# wrk failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# --- config ---------------------------------------------------------------
PI_IP="${PI_IP:-10.0.0.2}"
PI_PORT="${PI_PORT:-80}"
DURATION=10
OUTPUT="$PROJECT_DIR/hw_test/perf_history.md"
SKIP_FLASH=0
LEGACY_ONLY=0
FSA_ONLY=0
VENV="$PROJECT_DIR/.venv/bin/python"
TIERS=(10 50 100)          # concurrent connection counts
THREADS=4                  # wrk thread count; same as historical runs

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DURATION="$2"; shift 2;;
        --output)   OUTPUT="$2";   shift 2;;
        --skip-flash) SKIP_FLASH=1; shift;;
        --legacy-only) LEGACY_ONLY=1; shift;;
        --fsa-only)    FSA_ONLY=1;    shift;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//; /^set/d'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

if [[ ! -x "$VENV" ]]; then
    echo "perf_fsa_compare: .venv not found at $VENV — create the project venv first" >&2
    exit 1
fi

if ! command -v wrk >/dev/null; then
    echo "perf_fsa_compare: wrk not installed" >&2
    exit 1
fi

COMMIT=$(git rev-parse --short HEAD)
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- helpers --------------------------------------------------------------

# Clean stale hw_send processes so the serial port isn't held hostage.
kill_stale() {
    "$VENV" -c "
import sys; sys.path.insert(0, 'scripts')
from hw_send import kill_stale_hw_send
kill_stale_hw_send()
" 2>/dev/null || true
}

# Build + flash a kernel flavor. Waits for the boot banner on the
# serial log before declaring the Pi ready.
#   $1 = human-readable flavor name ("legacy" / "FSA")
#   $2 = extra make args (e.g. HTTP_OUTPUT_FSA=1)
flash_build() {
    local flavor="$1"; shift
    echo "=== [$flavor] clean build ==="
    make clean >/dev/null 2>&1
    make PLATFORM=pi4 "$@" >/dev/null 2>&1

    echo "=== [$flavor] flashing ==="
    kill_stale
    local logfile; logfile=$(mktemp)
    "$VENV" scripts/hw_send.py kernel8.img > "$logfile" 2>&1 &
    local pid=$!
    for _ in $(seq 1 75); do
        if grep -q 'GENET Gigabit Ethernet' "$logfile" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    if ! grep -q 'GENET Gigabit Ethernet' "$logfile"; then
        kill "$pid" 2>/dev/null || true
        cat "$logfile" >&2
        rm -f "$logfile"
        echo "perf_fsa_compare: Pi did not boot after flash of $flavor" >&2
        exit 1
    fi
    rm -f "$logfile"

    # Quick reachability probe (3 retries — link takes a beat to come
    # up after GENET init prints).
    local tries=0
    until ping -c 1 -W 2 "$PI_IP" >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [[ $tries -ge 5 ]]; then
            echo "perf_fsa_compare: Pi $PI_IP not reachable after $flavor flash" >&2
            exit 1
        fi
        sleep 1
    done
}

# Grab /fsa_stats as a single string. Newlines replaced with spaces so
# the line can be appended to a log directly.
grab_fsa_stats() {
    curl -s --max-time 3 "http://${PI_IP}:${PI_PORT}/fsa_stats" \
        | tr '\n' ' ' | sed 's/ *$//' || true
}

# Run wrk at one concurrency tier and emit a markdown table row.
#   $1 = connection count
#   $2 = markdown table accumulator file
run_one_tier() {
    local conns="$1"
    local acc="$2"

    # Warm-up: short run to bring TCP conns / caches up.
    wrk -t1 -c"$conns" -d2s "http://${PI_IP}:${PI_PORT}/" >/dev/null 2>&1 || true

    local out; out=$(wrk -t"$THREADS" -c"$conns" -d"${DURATION}s" \
        --latency "http://${PI_IP}:${PI_PORT}/" 2>&1)

    # wrk output lines we care about:
    #   Requests/sec:  NNNN.NN
    #   Latency Distribution  [50] ... [99] ...
    # Scrape them.
    local rps
    rps=$(echo "$out" | awk '/Requests\/sec/ {print $2}')
    local p50 p99 p999
    p50=$(echo "$out" | awk '/^[[:space:]]*50%/ {print $2}' | tail -1)
    p99=$(echo "$out" | awk '/^[[:space:]]*99%/ {print $2}' | tail -1)
    p999=$(echo "$out" | awk '/^[[:space:]]*99\.999%/ {print $2}' | tail -1)
    local xfer
    xfer=$(echo "$out" | awk '/Transfer\/sec/ {print $2}')
    local errs
    errs=$(echo "$out" | awk '/Socket errors/ {print $0}')

    printf '| %3d | %s | %s | %s | %s | %s |\n' \
        "$conns" "${rps:-?}" "${p50:-?}" "${p99:-?}" "${xfer:-?}" "${errs:--}" \
        >> "$acc"
}

# Run all tiers against the currently-flashed kernel; emit a full
# markdown section to stdout.
run_flavor() {
    local flavor="$1"; local want_stats="$2"
    local table; table=$(mktemp)

    if [[ "$want_stats" == "yes" ]]; then
        echo
        echo "\`\`\` /fsa_stats BEFORE"
        grab_fsa_stats
        echo
        echo "\`\`\`"
    fi

    {
        echo "| Conns | Req/s | P50 lat | P99 lat | Transfer/s | Socket errors |"
        echo "|-------|-------|---------|---------|------------|---------------|"
    } > "$table"

    for c in "${TIERS[@]}"; do
        run_one_tier "$c" "$table"
    done

    cat "$table"
    rm -f "$table"

    if [[ "$want_stats" == "yes" ]]; then
        echo
        echo "\`\`\` /fsa_stats AFTER"
        grab_fsa_stats
        echo
        echo "\`\`\`"
    fi
}

# --- main -----------------------------------------------------------------

if [[ "$FSA_ONLY" -eq 1 && "$LEGACY_ONLY" -eq 1 ]]; then
    echo "perf_fsa_compare: --fsa-only and --legacy-only are mutually exclusive" >&2
    exit 2
fi

REPORT=$(mktemp)
{
    echo
    echo "## Legacy vs Output FSA — $COMMIT — $STAMP"
    echo
    echo "- Host: \`$(hostname)\`, wrk $(wrk --version 2>&1 | head -1 | awk '{print $2}')"
    echo "- Link: laptop → Pi 4 GENET ($PI_IP), $THREADS wrk threads, ${DURATION}s runs"
    echo "- Build: \`make PLATFORM=pi4\` (legacy) / \`make PLATFORM=pi4 HTTP_OUTPUT_FSA=1\` (FSA)"
    echo "- Commit: \`$COMMIT\`"
} > "$REPORT"

if [[ "$FSA_ONLY" -ne 1 ]]; then
    if [[ "$SKIP_FLASH" -ne 1 ]]; then
        flash_build legacy
    fi
    echo "=== [legacy] wrk runs ==="
    {
        echo
        echo "### Legacy build"
        run_flavor legacy no
    } >> "$REPORT"
fi

if [[ "$LEGACY_ONLY" -ne 1 ]]; then
    flash_build "FSA" HTTP_OUTPUT_FSA=1
    echo "=== [FSA] wrk runs ==="
    {
        echo
        echo "### HTTP_OUTPUT_FSA=1 build"
        run_flavor "FSA" yes
    } >> "$REPORT"
fi

# Dump the report to stdout and append to perf_history.md (or the
# caller's chosen target).
cat "$REPORT"
cat "$REPORT" >> "$OUTPUT"
rm -f "$REPORT"

echo "=== perf_fsa_compare complete — appended to $OUTPUT ==="
