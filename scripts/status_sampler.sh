#!/usr/bin/env bash
# status_sampler.sh — poll the Pi's HTTP /status at ~1 Hz and write
# every snapshot to a log, with a timestamp header and a separator
# between samples. Designed for dynamics-suite runs where the Pi
# can go silent mid-test; the last successful sample before
# "(unreachable)" pinpoints where the kernel got to.
#
# Usage:
#   scripts/status_sampler.sh <initial_pi4_ip> <output_file>
#
# The first arg is the Pi's initial IP — used until the lease file
# at $WSPI5_DNSMASQ_LEASES has a valid entry for the rig MAC. Each
# loop iteration re-reads the lease file and uses the MOST RECENT
# pool-range IP as the sampling target. This is critical for the
# rebind / scope-change scenarios: the Pi's IP changes mid-run, and
# a fixed-target sampler would log "unreachable" for the rest of
# the run after the move (the Pi is alive at the NEW IP, just not
# at the one we started with).
#
# Run it in the background, capture its PID, kill on test teardown:
#   scripts/status_sampler.sh 10.0.0.109 /tmp/status-samples.log &
#   SAMPLER_PID=$!
#   trap 'kill "$SAMPLER_PID" 2>/dev/null || true' EXIT
#
# Each sample is bracketed by a UTC ISO-8601 timestamp header so a
# post-failure read knows the exact second of each snapshot. Failed
# curls land in the log as "(unreachable: <reason>)" so the moment
# the Pi went silent is immediately visible — last good sample
# before the unreachable run shows the kernel's last known state.
#
# The dnsmasq lease file is dumped alongside each sample so
# dhcp-side state and Pi-side state can be cross-referenced
# directly without a separate timeline.

set -uo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <pi4_ip> <output_file>" >&2
    exit 2
fi

initial_ip="$1"
out="$2"
leases="${WSPI5_DNSMASQ_LEASES:-/tmp/dnsmasq-wspi5-dynamics.leases}"

# Truncate the output file at start so each run gets a fresh log.
: > "$out"

# Resolve the current Pi IP each iteration: pick the lease entry
# with the latest expire-epoch from the pool 10.0.0.50-110 (covers
# both the canonical 100-110 range and the scope-change 50-60).
# Falls back to the initial IP when the lease file is empty / the
# pool has no entries.
current_ip() {
    local ip
    ip=$(awk '$3 ~ /^10\.0\.0\.([5-9][0-9]|10[0-9]|110)$/ {print $1, $3}' \
             "$leases" 2>/dev/null \
         | sort -k1 -n | tail -1 | awk '{print $2}')
    if [ -n "$ip" ]; then
        echo "$ip"
    else
        echo "$initial_ip"
    fi
}

while :; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    ip="$(current_ip)"
    {
        echo "=== $ts ip=$ip ==="
        body="$(curl -sS -m 2 "http://${ip}/status" 2>&1)"
        rc=$?
        if [ $rc -eq 0 ]; then
            # Extract only the diagnostic block — the HTML wrapper is
            # noise in this context. Falls back to the full body if
            # the markers aren't present.
            if echo "$body" | grep -q '<h2>Diagnostics</h2>'; then
                echo "$body" | sed -n '/<pre>/,/<\/pre>/{ /<pre>/d; /<\/pre>/d; p }'
            else
                echo "$body"
            fi
        else
            echo "(unreachable: curl rc=$rc)"
        fi
        if [ -r "$leases" ]; then
            n=$(wc -l < "$leases" 2>/dev/null || echo 0)
            echo "leases: $n entries in $leases"
            cat "$leases" 2>/dev/null | sed 's/^/  /'
        fi
        echo
    } >> "$out"
    sleep 1
done
