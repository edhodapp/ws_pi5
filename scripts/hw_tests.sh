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
#   scripts/hw_tests.sh --data-only perf         # cron mode: record data,
#                                                # only fail on hang or
#                                                # harness crash (D016)
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
DATA_ONLY=false
ANY_FAIL=0
FAILED_LABELS=()
PHASES=()

# Per-phase wall-clock budget in seconds (overridable via env).
# 600 s is generous: a quiet host typically finishes a perf phase in
# ~3 min. Hangs blow past 600 s; legitimate slow runs do not.
: "${PHASE_TIMEOUT_S:=600}"

# PI4_IP resolution. Same precedence as hw_test/run_hw_tests.sh's 912c569:
#   1. Explicit PI4_IP env var (caller knows the address — honor it)
#   2. mDNS resolve of ${PI4_HOSTNAME:-wspi5}.local
#   3. Static fallback 10.0.0.2 (chainloader rig with --testrig SD)
#
# Encapsulated as a function so we can re-call after every per-bucket
# reflash: in DHCP-mode test passes the kernel re-issues DISCOVER on
# each fresh boot, and although dnsmasq usually hands back the same
# lease, we don't want the test runner to assume that. A re-resolve
# costs one mDNS round-trip (~5 ms) and removes the assumption.
PI4_HOSTNAME="${PI4_HOSTNAME:-wspi5}"
PI4_FQDN="${PI4_HOSTNAME}.local"

resolve_pi4_ip() {
    # First positional: --strict-dhcp-pool requires the resolved IP to
    # be within dnsmasq's pool (10.0.0.100-110) when NETWORK_MODE=dhcp.
    # The post-flash call uses this so we don't latch onto a stale
    # avahi cache entry from a prior static pass (e.g. wspi5.local ->
    # 10.0.0.2 lingers in the laptop's mDNS cache across the Pi's
    # reboot into DHCP mode and resolves before the fresh announce).
    # The pre-flash sanity call doesn't pass the flag because the Pi
    # is still on whatever kernel it was previously running and the
    # check exists to prove the laptop side (avahi/NIC) is alive, not
    # that the Pi is already in the new mode.
    local strict_dhcp_pool=false
    if [ "${1:-}" = "--strict-dhcp-pool" ]; then
        strict_dhcp_pool=true
    fi
    # If caller pinned PI4_IP at script entry, keep honoring it.
    if [ -n "${PI4_IP_PIN:-}" ]; then
        export PI4_IP="$PI4_IP_PIN"
        echo "  PI4_IP source: pinned env (${PI4_IP})"
        return 0
    fi
    # In strict DHCP mode (post-flash), prefer dnsmasq.leases as the
    # authoritative source. The kernel's mDNS announces don't fire
    # reliably in DHCP mode — mdns_start arms PROBE_1 before
    # dhcp_start completes, so the probe goes out with net_our_ip = 0
    # and the announce phase ends up sending nothing useful (separate
    # kernel bug to file). avahi-resolve therefore returns whatever
    # is left in the laptop's mDNS cache, often a prior static pass's
    # 10.0.0.2 entry. The lease file is written by dnsmasq the moment
    # ACK is sent and is world-readable, so it sidesteps the kernel
    # bug entirely. Pick the lease with the latest expire-epoch in
    # case multiple pool entries coexist.
    # Lease file path. Defaults to /tmp/dnsmasq-wspi5.leases (the rig
    # path: dnsmasq runs as the operator and can't write the system
    # default /var/lib/misc/dnsmasq.leases). Override via
    # WSPI5_DNSMASQ_LEASES if the local rig stores leases elsewhere.
    local lease_file="${WSPI5_DNSMASQ_LEASES:-/tmp/dnsmasq-wspi5.leases}"
    if [ "$strict_dhcp_pool" = "true" ] \
       && [ "${NETWORK_MODE:-}" = "dhcp" ] \
       && [ -r "$lease_file" ]; then
        local lease_ip
        lease_ip=$(awk '$3 ~ /^10\.0\.0\.(10[0-9]|110)$/ {print $1, $3}' \
                       "$lease_file" \
                   | sort -k1 -n | tail -1 | awk '{print $2}')
        if [ -n "$lease_ip" ]; then
            export PI4_IP="$lease_ip"
            echo "  PI4_IP source: dnsmasq.leases pool entry -> ${PI4_IP}"
            return 0
        fi
    fi
    # Retry budget for mDNS resolve. The Pi's announce fires ~750 ms
    # after BOUND, plus a few seconds for DHCP DISCOVER → ACK in DHCP
    # mode and laptop-side avahi cache propagation. 30 s with 1 s
    # cadence covers the worst case with margin while a steady-state
    # resolve still returns in ~100 ms.
    if command -v avahi-resolve >/dev/null 2>&1; then
        local resolved candidate attempt deadline
        deadline=$(( $(date +%s) + 30 ))
        attempt=0
        while [ "$(date +%s)" -lt "$deadline" ]; do
            attempt=$((attempt + 1))
            if resolved=$(avahi-resolve -4 -n "$PI4_FQDN" 2>/dev/null) \
                    && [ -n "$resolved" ]; then
                candidate="$(echo "$resolved" | awk '{print $2}')"
                if [ "$strict_dhcp_pool" = "true" ] \
                   && [ "${NETWORK_MODE:-}" = "dhcp" ] \
                   && ! [[ "$candidate" =~ ^10\.0\.0\.(10[0-9]|110)$ ]]; then
                    sleep 1
                    continue
                fi
                PI4_IP="$candidate"
                export PI4_IP
                echo "  PI4_IP source: mDNS resolve of ${PI4_FQDN}" \
                     "-> ${PI4_IP} (attempt ${attempt})"
                return 0
            fi
            sleep 1
        done
    fi
    # Budget exhausted (or avahi-resolve unavailable). Fallback policy
    # depends on NETWORK_MODE — see dual_config_tests.sh for the
    # static/dhcp dispatch:
    #   static : fall back to 10.0.0.2 (matches the rig's pinned IP)
    #   dhcp   : hard-fail; 10.0.0.2 is provably wrong because the Pi's
    #            address comes from dnsmasq's lease pool 10.0.0.100-110
    #   unset  : fall back to 10.0.0.2 (backwards-compatible default)
    case "${NETWORK_MODE:-}" in
        dhcp)
            echo "  PI4_IP resolve FAILED: 30 s budget exhausted in" \
                 "NETWORK_MODE=dhcp" >&2
            echo "    static fallback (10.0.0.2) is invalid in DHCP" \
                 "mode — Pi's IP" >&2
            echo "    comes from dnsmasq pool 10.0.0.100-110. Is" \
                 "dnsmasq up? Is the" >&2
            echo "    Pi's kernel actually doing DHCP?" >&2
            return 1
            ;;
        *)
            export PI4_IP="10.0.0.2"
            echo "  PI4_IP source: static fallback (mDNS resolve" \
                 "exhausted) -> ${PI4_IP}"
            ;;
    esac
}

# If the caller explicitly set PI4_IP at script entry, snapshot it so
# subsequent resolve_pi4_ip calls keep honoring it instead of querying
# mDNS. This lets a CI driver or operator pin a known IP for a whole
# run while the function-based design still serves the unpinned case.
if [ -n "${PI4_IP:-}" ]; then
    PI4_IP_PIN="$PI4_IP"
fi
# Hard-fail at startup if NETWORK_MODE=dhcp and the Pi isn't yet on
# the network — better to abort with a clear error than run pytest
# against an empty PI4_IP and watch every test ARP-time-out.
if ! resolve_pi4_ip; then
    exit 1
fi

# --- arg parse -------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --no-reflash) NO_REFLASH=true; shift ;;
        --no-restore) RESTORE_DEFAULT=false; shift ;;
        --continue-on-fail) CONTINUE_ON_FAIL=true; shift ;;
        --data-only)
            # --data-only is for the perf cron — record stats, do
            # not gate. Implies --continue-on-fail (always) and
            # disables the perf_check.py regression call. The only
            # things that fail with --data-only are hangs (phase
            # exceeds PHASE_TIMEOUT_S wall-clock) and harness
            # crashes (build failure, missing venv, etc.). See D016.
            DATA_ONLY=true
            CONTINUE_ON_FAIL=true
            shift
            ;;
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
            sed -n '2,38p' "$0"
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
    # NETWORK_CONF=<path> overrides the SD's initramfs network.conf for
    # this boot — hw_send.py prepends the file's bytes as Intel HEX
    # records targeting 0x20000000. Empty / unset means "no override":
    # the kernel reads whatever network.conf the firmware loaded from
    # the SD's FAT32 partition. Used to drive dual-config test runs
    # (static vs DHCP) from the same chainloader SD.
    local hw_send_args=()
    if [ -n "${NETWORK_CONF:-}" ]; then
        hw_send_args+=(--network-conf "$NETWORK_CONF")
    fi
    "$VENV" scripts/hw_send.py "${hw_send_args[@]}" kernel8.img \
        > "$logfile" 2>&1 &
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
    # Re-resolve in case the per-bucket reflash gave the Pi a new
    # DHCP-assigned address (no-op for static and pinned env runs).
    # Hard-fail in NETWORK_MODE=dhcp if mDNS doesn't come back —
    # 10.0.0.2 fallback is wrong there and would just turn into a
    # confusing ARP timeout downstream. --strict-dhcp-pool rejects
    # stale avahi cache entries outside dnsmasq's pool (10.0.0.100-110)
    # so we don't latch onto a prior static pass's wspi5.local
    # announce.
    if ! resolve_pi4_ip --strict-dhcp-pool; then
        kill "$hw_pid" 2>/dev/null || true
        note_fail "$label" "Pi 4 mDNS resolve failed after boot"
        return 1
    fi
    # Retry ping for ~15 s. In DHCP mode, "GENET Gigabit Ethernet" can
    # appear several seconds before the Pi is actually reachable on its
    # leased IP — DHCP DISCOVER/OFFER/REQUEST/ACK runs after that print,
    # then the kernel finishes initializing NTP / mDNS / HTTP, and only
    # then is the IP layer settled enough to reliably reply to ICMP.
    # Static mode doesn't need this margin (the IP is committed at
    # config_parse time, before GENET prints), but the retry is harmless
    # there: a healthy static Pi replies on the first try and exits the
    # loop in well under a second.
    local boot_ping_deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$boot_ping_deadline" ]; do
        if ping -c 1 -W 1 "$PI4_IP" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    kill "$hw_pid" 2>/dev/null || true
    note_fail "$label" "Pi 4 not reachable at $PI4_IP after boot"
    return 1
}

run_pytest() {
    # run_pytest <selector_args...> ; returns nonzero on failure
    HW_TEST=1 "$VENV" -m pytest hw_test/ "$@" --tb=short -q
}

# _record_hang <label> <perf_flavor> <reason>
# Append a HANG marker to perf_runs.log and bump ANY_FAIL. Used when
# a perf phase exceeds PHASE_TIMEOUT_S. The marker is in the same
# file as the data so a human (or perf_check.py) reading the log
# sees the hang in trend context. Per D016.
_record_hang() {
    local label="$1"
    local perf_flavor="$2"
    local reason="$3"
    echo "=== HANG: [$label] $reason ===" >&2
    {
        echo ""
        echo "--- HANG $COMMIT $(date -u +%Y-%m-%dT%H:%M:%SZ) PERF=$perf_flavor $reason ---"
    } >> "$PERF_LOG"
    FAILED_LABELS+=("${label}-HANG")
    ANY_FAIL=1
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
    # Phase budget starts AFTER flash_and_wait. flash_and_wait has its
    # own internal 150 s boot-poll timeout, so a wedged flash is
    # bounded already; charging it against PHASE_TIMEOUT_S would
    # synthetic-fail later runs that haven't actually hung.
    local phase_start_s=$SECONDS
    for i in $(seq 1 "$PERF_RUNS"); do
        # Wall-clock budget: a phase that hasn't completed by
        # PHASE_TIMEOUT_S wall-clock is a hang. Check before each
        # new run so we don't start one that's guaranteed to bust
        # the budget. Each run also wraps pytest in `timeout` with
        # the remaining budget so a single hung run can't run past
        # the phase budget. See D016.
        local elapsed_s=$((SECONDS - phase_start_s))
        local remaining_s=$((PHASE_TIMEOUT_S - elapsed_s))
        if [ $remaining_s -le 0 ]; then
            _record_hang "$label" "$perf_flavor" \
                "phase exceeded ${PHASE_TIMEOUT_S}s wall-clock before run $i/$PERF_RUNS started"
            rm -f "$out"
            return 1
        fi
        echo "=== [$label] perf run $i/$PERF_RUNS (-m \"$marker_expr\", remaining=${remaining_s}s) ==="
        # Pytest exit codes: 0 = pass, 1 = fail, 5 = no tests collected.
        # 124 = `timeout` SIGTERM'd; --kill-after=10s SIGKILLs 10 s
        # later if SIGTERM was ignored (pytest in a blocking syscall,
        # scapy sniff loop, etc.). timeout's default mode places the
        # command in a new process group and signals the whole group,
        # so descendants (hw_send.py, scapy children) die too.
        # Pytest doesn't currently emit 124 itself; the assumption
        # is "rc=124 ⇒ timeout fired" until/unless pytest does.
        # The PIPESTATUS dance is because `tee` clobbers $?.
        set +e
        timeout --kill-after=10s "${remaining_s}s" \
            env HW_TEST=1 "$VENV" -m pytest hw_test/ -m "$marker_expr" \
            --tb=short -q -s 2>&1 | tee "$out"
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -eq 124 ]; then
            _record_hang "$label" "$perf_flavor" \
                "run $i/$PERF_RUNS killed by timeout after ${remaining_s}s"
            rm -f "$out"
            return 1
        fi
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
    # In --data-only mode, the cron is data-gathering, not gating.
    # perf_check.py is invoked only by pre-push-integration.sh. See D016.
    if [ "$DATA_ONLY" = "true" ]; then
        echo "  [skip perf_check: --data-only — trend log retains the data]"
        return 0
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
