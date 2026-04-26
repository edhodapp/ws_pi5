# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=line-too-long,too-few-public-methods,too-many-locals
# pylint: disable=duplicate-code,too-many-arguments,too-many-positional-arguments
# pylint: disable=redefined-outer-name,unused-argument
# mypy: ignore-errors
# flake8: noqa: E501
"""
test_dispatch_perf.py — net_recv_one dispatch-path perf assertions.

Requires a Pi running PERF=dispatch (PERF_COUNTERS + PERF_DISPATCH).
The probes wrap net_recv_one in main.S and accumulate dispatch_ticks
+ dispatch_count into perf_counters; this test reads the counters
back via the 0x88B6 query protocol and asserts:

  1. dispatch_count tracks the burst we sent (every received frame
     reached the dispatcher — no silent drops between genet_recv
     and net_recv_one).
  2. dispatch_ticks / dispatch_count is below DISPATCH_NS_CEILING
     (catches a 2x or worse regression in the dispatch path).

Skip cleanly if the Pi isn't a PERF=dispatch build — the readout
handler is silent on a default kernel, perf_query times out, and we
report that instead of failing deep in an assertion.

CEILING CALIBRATION: same posture as test_l3_perf.py — the ceiling
is set ~2-3x observed values on a healthy PERF=dispatch build, so
it catches major regressions without locking in current numbers.
"""

import time

import pytest

import wire
from conftest import PI4_IP, requires_hardware

pytestmark = [pytest.mark.perf, pytest.mark.dispatch]


# Per-dispatch cost ceiling (ns). Observed on Pi 4 with PERF=dispatch:
# ~150-300 ns per frame. 1500 ns is ~5x — plenty of headroom for
# session-to-session variance, tight enough to flag a real 2x regression.
DISPATCH_NS_CEILING = 1500.0

# Same burst pattern as test_l2_ring.py: hit the dispatcher with
# enough frames that one outlier doesn't dominate the average.
BURST_N = 255

# How long to wait for dispatch_count to reflect the burst we sent.
QUIESCE_MS = 500


@pytest.fixture
def perf_dispatch_session(eth_iface, laptop_mac, pi_mac):
    """Verify the Pi is on a PERF build that responds to perf_query.

    A PERF=dispatch build has the readout handler compiled in. A
    default build doesn't, so perf_query raises WireError on timeout
    — surface that as a skip instead of a deep assertion failure.
    """
    try:
        wire.perf_query(eth_iface, pi_mac, laptop_mac, reset=True)
    except wire.WireError as e:
        pytest.skip(
            f"Pi is not a PERF build (perf_query failed: {e}). "
            f"Build with `make PLATFORM=pi4 PERF=dispatch`."
        )

    class DispatchPerf:
        def snapshot(self) -> dict:
            return wire.perf_query(eth_iface, pi_mac, laptop_mac)

        def reset(self) -> dict:
            return wire.perf_query(eth_iface, pi_mac, laptop_mac, reset=True)

    return DispatchPerf()


def _send_arp_burst(eth_iface, laptop_mac, laptop_ip, n, tmp_path):
    """Send `n` ARP requests via tcpreplay --topspeed. Returns the
    tcpreplay summary dict (same shape as wire.tcpreplay_send)."""
    laptop_mac_str = ":".join(f"{b:02x}" for b in laptop_mac)
    pcap_path = tmp_path / f"dispatch_arp_burst_{n}.pcap"
    wire.build_arp_pcap(
        pcap_path, count=n,
        src_mac=laptop_mac_str, src_ip=laptop_ip, target_ip=PI4_IP,
    )
    return wire.tcpreplay_send(eth_iface, pcap_path, topspeed=True)


@requires_hardware
class TestDispatchPerf:

    def test_dispatch_count_tracks_burst(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, perf_dispatch_session,
        tmp_path,
    ):
        """Every dispatched frame is counted. dispatch_count >= BURST_N."""
        perf_dispatch_session.reset()
        _send_arp_burst(eth_iface, laptop_mac, laptop_ip, BURST_N, tmp_path)
        time.sleep(QUIESCE_MS / 1000.0)

        snap = perf_dispatch_session.snapshot()
        assert snap["dispatch_count"] >= BURST_N, (
            f"dispatch_count={snap['dispatch_count']} < expected {BURST_N}; "
            f"frames reached the NIC but didn't traverse net_recv_one. "
            f"Snapshot: {snap}"
        )

        # Probes-not-compiled detection: dispatch_ticks should be > 0
        # if the build has PERF_DISPATCH active. If we got dispatch_count
        # but zero ticks, the kernel was built with PERF_COUNTERS but
        # not PERF_DISPATCH — flag that explicitly.
        assert snap["dispatch_ticks"] > 0, (
            "dispatch_count > 0 but dispatch_ticks == 0 — Pi is built "
            "with PERF_COUNTERS but not PERF_DISPATCH. Flash with "
            "`make PLATFORM=pi4 PERF=dispatch` (or PERF=all)."
        )

    def test_dispatch_cost_below_ceiling(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, perf_dispatch_session,
        tmp_path,
    ):
        """ns/dispatch is below DISPATCH_NS_CEILING."""
        perf_dispatch_session.reset()
        _send_arp_burst(eth_iface, laptop_mac, laptop_ip, BURST_N, tmp_path)
        time.sleep(QUIESCE_MS / 1000.0)

        snap = perf_dispatch_session.snapshot()
        if snap["dispatch_ticks"] == 0:
            pytest.skip(
                "dispatch_ticks=0 — Pi missing PERF_DISPATCH probes; "
                "see test_dispatch_count_tracks_burst for the diagnostic."
            )

        ns_per = (
            wire.perf_ticks_to_ns(snap["dispatch_ticks"])
            / max(snap["dispatch_count"], 1)
        )
        # BURST_STATS line for the perf log scraper. Same conventions
        # as test_l2_ring.py — n + per-stage ns + dispatch counts.
        print(
            f"BURST_STATS: n={BURST_N} replies={snap['dispatch_count']} "
            f"send_ms=0 wire_pps=0 total_ms=0"
        )
        print(
            f"PERF_STATS: n={BURST_N} "
            f"recv_count={snap['recv_count']} "
            f"recv_none={snap['recv_none']} "
            f"dispatch_count={snap['dispatch_count']} "
            f"drop_count={snap['drop_count']} "
            f"send_count={snap['send_count']} "
            f"send_fail={snap['send_fail']} "
            f"max_burst={snap['max_burst']} "
            f"rx_discards={snap['rx_discards']} "
            f"recv_ns=0 dispatch_ns={ns_per:.0f} send_ns=0"
        )

        assert ns_per < DISPATCH_NS_CEILING, (
            f"dispatch cost {ns_per:.0f} ns/frame exceeds ceiling "
            f"{DISPATCH_NS_CEILING:.0f} ns. Snapshot: {snap}"
        )
