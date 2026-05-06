"""
test_dhcp_wedge_recovery.py — kernel self-recovery validation.

The dhcp-dynamics suite occasionally observes a wedge: after several
back-to-back DHCP rebinds, the Pi stops responding to /status and
DHCP renew/rebind traffic. The kernel does not panic — mDNS state
machine remains in LIVE — but the GENET I/O path appears stuck.
Until now every observed wedge was followed by a reflash (DTR
power-cycle), so we don't actually know whether the kernel ever
heals on its own given enough idle time.

This test answers that question. It runs in two phases:

  Phase 1 — induce: rapid-fire NAK rebinds to provoke the wedge.
    If after INDUCE_ATTEMPTS the Pi is still responding, skip the
    test (the wedge is rare per-pass; this iteration got lucky).

  Phase 2 — idle and probe: stop all dnsmasq mutations and avahi
    queries, sleep with exponential backoff, and probe /status at
    each step. Pass if the Pi answers within the deadline; fail if
    it remains silent — that failure is the empirical proof that
    the kernel needs a watchdog / GENET reset path.

Phase 2 deliberately does NOT use the dnsmasq fixture or
avahi-resolve. The only host-side stimulus is one short curl plus
the ARP request that precedes it, which matches what an unrelated
real client would send anyway.

Module-level marker is `wedge_recovery` — opt-in only, never picked
up by the default `-m dhcp_dynamics` sweep. Drive with
`scripts/wedge_recovery_test.sh`.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=line-too-long
# mypy: ignore-errors

import subprocess
import time

import pytest

from conftest import requires_hardware
from test_dhcp_dynamics import (
    RIG_PI_BASELINE_IP,
    RIG_PI_MAC,
    _wait_for_lease,
)


# ----- knobs -----

# Number of rebind cycles to attempt in phase 1 before giving up.
# Take-1 hit a wedge in a 30-cycle run; 6 here gives a reasonable
# probability without making a passing iteration take 25 min.
INDUCE_ATTEMPTS = 6

# Per-rebind deadline. The dynamics suite uses 180 s; we cut to 60 s
# because either the rebind happens fast or the Pi has already
# silenced — we don't want to waste budget waiting for a wedge we
# can detect in seconds via /status probe.
REBIND_DEADLINE_S = 60.0

# Backoff schedule for phase 2. Total budget = sum = 520 s ≈ 8.7 min.
# Picked so a kernel that recovers within 30 s is observed quickly
# while still giving a slow recovery path up to ~9 min.
RECOVERY_BACKOFF_S = (10, 30, 60, 120, 300)

# Targets to alternate through during the induction loop. Keeps the
# Pi forced to NAK + DISCOVER each cycle. The .109 baseline is
# deliberately omitted so every cycle is a real rebind.
REBIND_TARGETS = ("10.0.0.103", "10.0.0.105", "10.0.0.107")

pytestmark = [
    pytest.mark.l5,
    pytest.mark.dhcp_only,
    pytest.mark.wedge_recovery,
    pytest.mark.slow,
]


def _http_alive(ip: str) -> bool:
    """One short HTTP GET; True if the Pi answered. Two-second
    timeout matches the sampler — it's the same threshold the rest
    of the suite uses for "responsive vs silent."""
    try:
        proc = subprocess.run(
            ["curl", "-sS", "-m", "2", f"http://{ip}/status"],
            capture_output=True, text=True, timeout=3, check=False,
        )
    except subprocess.TimeoutExpired:
        return False
    return proc.returncode == 0 and bool(proc.stdout.strip())


def _last_rig_lease_ip(lease_reader, mac: str) -> str | None:
    """Most-recent lease IP for the rig MAC, or None if no record."""
    leases = [lease for lease in lease_reader() if lease["mac"] == mac]
    if not leases:
        return None
    leases.sort(key=lambda lease: lease["expire"])
    return leases[-1]["ip"]


def _any_alive(candidate_ips):
    """Probe every plausible IP. Return the first one that answers,
    or None if all silent. Used to distinguish a real wedge ("nothing
    answers anywhere") from "Pi moved to an IP we weren't tracking."

    The latter is the dominant noise mode in this test: rapid-fire
    rebind cycles with `clear_mac` shorten effective leases enough
    that the Pi can be in transit from IP-A to IP-B at the moment
    a `_wait_for_lease(ip == IP-B)` deadline expires. Probing only
    last_known_ip would misread "in transit" as "wedged."
    """
    for ip in candidate_ips:
        if _http_alive(ip):
            return ip
    return None


@requires_hardware
class TestWedgeRecovery:

    def test_wedge_self_recovery_within_deadline(
        self, dnsmasq_apply_conf, lease_reader,
    ):
        """Force back-to-back rebinds until the Pi goes silent, then
        observe whether it recovers on its own within ~9 minutes of
        idle. See module docstring for design rationale."""

        last_known_ip = RIG_PI_BASELINE_IP
        # Track every IP we've ever directed the Pi toward. When an
        # attempt's _wait_for_lease times out we probe ALL of these
        # plus any current lease record before concluding wedge —
        # otherwise a Pi that's just moved on to the next target
        # reads as silent on the last_known_ip we were watching.
        targets_tried = {RIG_PI_BASELINE_IP}

        # ---- Phase 1: induce wedge ----
        wedged = False
        attempts_done = 0
        for attempt in range(INDUCE_ATTEMPTS):
            attempts_done = attempt + 1
            target = REBIND_TARGETS[attempt % len(REBIND_TARGETS)]
            targets_tried.add(target)
            dnsmasq_apply_conf(
                [
                    "dhcp-range=10.0.0.100,10.0.0.110,255.255.255.0,1m",
                    f"dhcp-host={RIG_PI_MAC},{target}",
                ],
                clear_mac=RIG_PI_MAC,
            )
            rebound = _wait_for_lease(
                lease_reader,
                lambda lease: lease["mac"] == RIG_PI_MAC and lease["ip"] == target,
                deadline_s=REBIND_DEADLINE_S,
                poll_s=0.5,
            )
            if rebound is not None:
                last_known_ip = rebound["ip"]
                continue

            # Rebind didn't land within the deadline. Two cases:
            # (a) the Pi is silent on every IP we know about → wedge.
            # (b) the Pi has moved to one of the other targets / a
            #     lease we haven't observed yet → not wedged, just
            #     in transit.
            time.sleep(2)  # let DHCP retransmits settle
            recent_lease = _last_rig_lease_ip(lease_reader, RIG_PI_MAC)
            candidates = set(targets_tried)
            if recent_lease is not None:
                candidates.add(recent_lease)
            alive_at = _any_alive(candidates)
            if alive_at is None:
                wedged = True
                break
            # Pi alive somewhere; absorb that IP and keep inducing.
            last_known_ip = alive_at

        if not wedged:
            pytest.skip(
                f"could not induce wedge in {attempts_done} rebinds; "
                f"the kernel is more robust on this iteration than "
                f"during take-1 of the 15-pass run, or the rig is "
                f"on a lucky path. Re-run to retry. Test is "
                f"inconclusive, not a failure."
            )

        wedge_observed_at = time.monotonic()
        print(
            f"\nWedge induced after {attempts_done} rebind attempts; "
            f"last known IP = {last_known_ip}. Probing self-recovery."
        )

        # ---- Phase 2: idle + probe ----
        # No more dnsmasq calls, no avahi queries. Just sleep + curl.
        elapsed = 0.0
        for backoff_s in RECOVERY_BACKOFF_S:
            time.sleep(backoff_s)
            elapsed = time.monotonic() - wedge_observed_at

            # The Pi might still be at last_known_ip, at one of the
            # other rebind targets we tried, or at a lease that
            # arrived since (unlikely without traffic, but check).
            candidates = set(targets_tried)
            candidates.add(last_known_ip)
            recent = _last_rig_lease_ip(lease_reader, RIG_PI_MAC)
            if recent is not None:
                candidates.add(recent)

            alive_at = _any_alive(candidates)
            if alive_at is not None:
                print(
                    f"\nKernel self-recovered after {elapsed:.0f} s "
                    f"of idle (responding at {alive_at}; "
                    f"last known {last_known_ip})"
                )
                return  # pass

        pytest.fail(
            f"Pi did not self-recover within {elapsed:.0f} s of induced "
            f"wedge. Last known IP: {last_known_ip}. The kernel needs "
            f"a GENET watchdog / self-restart path — without it, a "
            f"production wedge requires physical power cycle."
        )
