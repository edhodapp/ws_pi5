# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=unused-import,unused-variable,inconsistent-quotes
# pylint: disable=line-too-long,redefined-outer-name
# mypy: ignore-errors
# flake8: noqa: E501,E221
"""
test_l3_perf.py — L3 instrumentation assertions.

Exercises the PERF_L3 counters in lib/ip.S, lib/icmp.S, and
lib/ip_reasm.S via the 0x88B6 query protocol wired up in commit #9
(kernel side) and commit #10 (laptop side).

Requires a Pi running a PERF=l3 build. If the Pi is a default build,
wire.perf_query(block="l3") raises WireError because the magic tag
doesn't match — the tests catch that at fixture time and skip
gracefully with a clear reason instead of failing deep in an
assertion.

COVERAGE (plan commit #11):
  * test_echo_burst_100_delivered: send 100 echoes, assert 100
    replies AND perf_counters2.icmp_count increased by 100.
  * test_echo_per_frame_cost_under_ceiling: derive ns/frame from
    the perf counters; assert it's below a calibrated ceiling.
  * test_echo_cost_scales_with_size: parametric over payload
    sizes; assert larger payloads cost more (ip_checksum dominates
    at scale).
  * test_frag_reassembly_cost_accounted: fragmented echo bumps
    both frag_reassembled and frag_ticks; post-reassembly
    frag_active returns to 0.
  * test_icmp_error_generation_cost_accounted: proto-unreachable
    trigger bumps icmp_err_gen AND ip_drops (per commit #8's
    semantics — proto-unreach counts as a drop from ip_handle's
    perspective and as an error generation from icmp_send_error's).
  * test_dispatch_accounted_under_l3_load: PERF_DISPATCH ticks
    from the L2 perf line increment during an echo burst, cross-
    checking that the L2 and L3 counters agree on frame count.
    Requires PERF=all (or the Pi having both L2 and L3 flags).

CEILING CALIBRATION: the per-frame cost ceiling is set to ~2-2.6x
the values observed on a PERF=all Pi 4 build, 2026-04-09. The
ceilings exist to catch a MAJOR regression (~2x), not to lock in
current numbers.

  64B payload:   ip_handle ≈ 580 ns   →  ceiling 1500 ns (2.6x)
  1400B payload: ip_handle ≈ 7333 ns  →  ceiling 15000 ns (2.0x)
  64B payload:   icmp_handle ≈ 481 ns →  ceiling 1500 ns (3.1x)

At large payload sizes, ip_ticks ≈ icmp_ticks because ip_handle's
timed region includes the nested bl icmp_handle call, and the
ICMP checksum over ~1.4 KB dominates both. See commit #11 message
for the full calibration log.

If a future optimisation measurably shrinks these numbers, tighten
the ceilings alongside — the goal is "catch a 2x regression", so
the ratio to observed should stay ~2x.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l3_perf.py -v
"""

import time

import pytest

import eth_frames
import ip_frames
import wire
from conftest import PI4_IP, requires_hardware
from icmp_helpers import (
    icmp_bpf_from_pi,
    is_any_echo_reply_from_pi,
    parse_reply,
    send_echo_and_wait,
)

pytestmark = pytest.mark.perf


# Per-frame cost ceilings (ns). See module docstring for calibration.
IP_HANDLE_CEILING_NS_64B   = 1500.0    # observed ~580
IP_HANDLE_CEILING_NS_1400B = 15000.0   # observed ~7333
ICMP_HANDLE_CEILING_NS_64B = 1500.0    # observed ~481


# ==============================================================
# PERF=l3 gate fixture
# ==============================================================

@pytest.fixture
def perf_l3_session(eth_iface, laptop_mac, pi_mac):
    """Return a helper object that wraps perf_query(block='l3'),
    or skip the test if the Pi isn't a PERF=l3 build.

    Each test gets a fresh object with a reset() method so it can
    clear the counters at the start of its assertion window.
    """
    try:
        wire.perf_query(eth_iface, pi_mac, laptop_mac, block="l3")
    except wire.WireError as e:
        pytest.skip(
            f"Pi is not a PERF=l3 build (perf_query failed: {e})"
        )

    class L3Perf:
        def snapshot(self) -> dict:
            return wire.perf_query(
                eth_iface, pi_mac, laptop_mac, block="l3",
            )

        def reset(self) -> dict:
            """Reset counters; returns the pre-reset snapshot."""
            return wire.perf_query(
                eth_iface, pi_mac, laptop_mac, block="l3", reset=True,
            )

    return L3Perf()


# ==============================================================
# Helpers
# ==============================================================

def _send_icmp_burst_and_count(
    eth_iface: str,
    pi_mac: bytes,
    laptop_mac: bytes,
    laptop_ip: str,
    n: int,
    payload: bytes,
    *,
    ident_base: int = 0xE000,
    rtt_p99_ms: float = 1.0,
) -> int:
    """Send `n` ICMP echoes to the Pi in a single WireCapture,
    match replies by ident, return the number delivered.
    """
    frames = [
        ip_frames.build_icmp_echo_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=ident_base + i, seq=0, payload=payload,
        )
        for i in range(n)
    ]
    bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
    expected_idents = set(range(ident_base, ident_base + n))

    def is_ours(data: bytes) -> bool:
        if not is_any_echo_reply_from_pi(
            data,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
        ):
            return False
        return parse_reply(data)["icmp"]["ident"] in expected_idents

    deadline_ms = int(max(100.0 * rtt_p99_ms, 2000.0) + 2.0 * n)
    with wire.WireCapture(eth_iface, bpf=bpf) as cap:
        for f in frames:
            wire.send_frame(eth_iface, f)
        replies = wire.wait_for_frames(
            cap, is_ours, count=n, deadline_ms=deadline_ms,
        )
    return len(replies)


# ==============================================================
# Burst delivery + counter increment
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestEchoBurstDelivered:

    def test_100_echoes_delivered_and_counted(
        self, perf_l3_session,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send 100 ICMP echo requests. Assert:
          * All 100 replies arrive
          * perf_counters2.icmp_count increased by exactly 100
          * perf_counters2.ip_count increased by at least 100
            (could be more if there's ambient IP traffic, but
            not less)
          * perf_counters2.ip_ticks > 0 and icmp_ticks > 0
        """
        perf_l3_session.reset()
        n = 100
        payload = bytes(range(64))
        delivered = _send_icmp_burst_and_count(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            n, payload, ident_base=0xE100, rtt_p99_ms=rtt_p99_ms,
        )
        assert delivered == n, (
            f"burst of {n} echoes: only {delivered} replies"
        )

        snap = perf_l3_session.snapshot()
        assert snap["icmp_count"] == n, (
            f"icmp_count should be exactly {n}, got {snap['icmp_count']}"
        )
        assert snap["ip_count"] >= n, (
            f"ip_count should be >= {n}, got {snap['ip_count']}"
        )
        assert snap["ip_ticks"] > 0, "ip_ticks did not accumulate"
        assert snap["icmp_ticks"] > 0, "icmp_ticks did not accumulate"
        # Sanity: icmp_ticks should be less than ip_ticks because
        # icmp_handle runs inside the ip_handle timing window but
        # is just one of the dispatch targets.
        assert snap["icmp_ticks"] <= snap["ip_ticks"], (
            f"icmp_ticks {snap['icmp_ticks']} should be <= ip_ticks "
            f"{snap['ip_ticks']}"
        )


# ==============================================================
# Per-frame cost under ceiling
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestEchoPerFrameCost:

    def test_64B_echo_cost_under_ceiling(
        self, perf_l3_session,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send 100 64-byte echoes, derive per-frame ns from the
        Pi's own ticks, assert below the calibrated ceiling.
        """
        perf_l3_session.reset()
        n = 100
        payload = bytes(64)
        delivered = _send_icmp_burst_and_count(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            n, payload, ident_base=0xE200, rtt_p99_ms=rtt_p99_ms,
        )
        assert delivered == n

        snap = perf_l3_session.snapshot()
        ip_ns_per_frame = wire.perf_ticks_to_ns(snap["ip_ticks"]) / snap["ip_count"]
        icmp_ns_per_frame = wire.perf_ticks_to_ns(snap["icmp_ticks"]) / snap["icmp_count"]

        print(
            f"\n64B burst: ip_ns={ip_ns_per_frame:.0f} "
            f"icmp_ns={icmp_ns_per_frame:.0f}"
        )

        assert ip_ns_per_frame < IP_HANDLE_CEILING_NS_64B, (
            f"ip_handle per-frame cost {ip_ns_per_frame:.0f} ns exceeds "
            f"64B ceiling {IP_HANDLE_CEILING_NS_64B} ns — 3x regression?"
        )
        assert icmp_ns_per_frame < ICMP_HANDLE_CEILING_NS_64B, (
            f"icmp_handle per-frame cost {icmp_ns_per_frame:.0f} ns "
            f"exceeds 64B ceiling {ICMP_HANDLE_CEILING_NS_64B} ns"
        )

    def test_1400B_echo_cost_under_ceiling(
        self, perf_l3_session,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Same as above but with a 1400-byte payload. The ceiling
        is looser because ip_checksum's per-byte cost dominates at
        large frame sizes.
        """
        perf_l3_session.reset()
        n = 50
        payload = bytes((i & 0xFF) for i in range(1400))
        delivered = _send_icmp_burst_and_count(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            n, payload, ident_base=0xE300, rtt_p99_ms=rtt_p99_ms,
        )
        assert delivered == n

        snap = perf_l3_session.snapshot()
        ip_ns_per_frame = wire.perf_ticks_to_ns(snap["ip_ticks"]) / snap["ip_count"]
        print(f"\n1400B burst: ip_ns={ip_ns_per_frame:.0f}")
        assert ip_ns_per_frame < IP_HANDLE_CEILING_NS_1400B, (
            f"ip_handle per-frame cost {ip_ns_per_frame:.0f} ns exceeds "
            f"1400B ceiling {IP_HANDLE_CEILING_NS_1400B} ns"
        )


@requires_hardware
@pytest.mark.l3
class TestCostScalesWithPayload:
    """Larger payloads should cost strictly more per frame because
    ip_checksum scans every byte of the header + the ICMP header,
    and icmp_handle recomputes the ICMP checksum over the full
    ICMP segment. The test asserts a monotonic relationship rather
    than hardcoded numbers, so the calibration stays robust to
    future optimizations.
    """

    @pytest.mark.parametrize("size_small,size_big", [
        (64, 1400),
    ])
    def test_bigger_payload_costs_more(
        self, size_small, size_big,
        perf_l3_session,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        def measure(size: int, ident_base: int) -> float:
            perf_l3_session.reset()
            payload = bytes((i & 0xFF) for i in range(size))
            n = 50
            delivered = _send_icmp_burst_and_count(
                eth_iface, pi_mac, laptop_mac, laptop_ip,
                n, payload, ident_base=ident_base, rtt_p99_ms=rtt_p99_ms,
            )
            assert delivered == n
            snap = perf_l3_session.snapshot()
            return wire.perf_ticks_to_ns(snap["icmp_ticks"]) / snap["icmp_count"]

        cost_small = measure(size_small, 0xE400)
        cost_big = measure(size_big, 0xE500)
        print(
            f"\npayload {size_small}B → icmp_ns={cost_small:.0f} | "
            f"{size_big}B → icmp_ns={cost_big:.0f} | "
            f"ratio={cost_big/cost_small:.2f}x"
        )

        assert cost_big > cost_small, (
            f"{size_big}B cost {cost_big:.0f} ns should be > "
            f"{size_small}B cost {cost_small:.0f} ns — ip_checksum "
            f"is supposed to dominate at large payloads"
        )
        # Sanity upper bound: the ratio shouldn't be more than
        # ~(size_big / size_small) * 2. If it is, something else
        # is scaling worse than linear with payload size.
        max_ratio = (size_big / size_small) * 2.0
        ratio = cost_big / cost_small
        assert ratio < max_ratio, (
            f"cost ratio {ratio:.2f} exceeds expected max "
            f"{max_ratio:.2f} — super-linear scaling?"
        )


# ==============================================================
# Fragment reassembly cost accounted
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestFragReassemblyCost:

    def test_fragmented_echo_bumps_frag_counters(
        self, perf_l3_session,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send a 3-fragment ICMP echo. Assert:
          * frag_reassembled increments by exactly 1
          * frag_ticks accumulates non-zero ticks
          * frag_active returns to 0 after completion
          * frag_drops does NOT increment
          * icmp_count increments by 1 (the reassembled echo
            still runs through icmp_handle)
        """
        perf_l3_session.reset()

        # Build a 3-fragment ICMP echo.
        echo_payload = bytes(((i * 5 + 1) & 0xFF) for i in range(1000 - 8))
        icmp_msg = ip_frames.build_icmp_echo_request(
            ident=0xE601, seq=1, payload=echo_payload,
        )
        frames = ip_frames.build_fragment_frames(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            protocol=ip_frames.IP_PROTO_ICMP,
            payload=icmp_msg,
            ident=0xE701,
            frag_size=336,  # 1000/336 → 3 fragments
        )
        assert len(frames) == 3

        # Send and wait for the reassembled reply.
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            for f in frames:
                wire.send_frame(eth_iface, f)

            def is_our_reply(data: bytes) -> bool:
                if not is_any_echo_reply_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                ):
                    return False
                return parse_reply(data)["icmp"]["ident"] == 0xE601

            reply = wire.wait_for_frame(
                cap, is_our_reply,
                deadline_ms=int(max(30.0 * rtt_p99_ms, 1000.0)),
            )
        assert reply is not None, "reassembled echo reply did not arrive"

        snap = perf_l3_session.snapshot()
        assert snap["frag_reassembled"] == 1, (
            f"frag_reassembled should be 1, got {snap['frag_reassembled']}"
        )
        assert snap["frag_ticks"] > 0, "frag_ticks did not accumulate"
        assert snap["frag_drops"] == 0, (
            f"frag_drops should be 0 (clean reassembly), "
            f"got {snap['frag_drops']}"
        )
        assert snap["frag_active"] == 0, (
            f"frag_active should be 0 after completion, got "
            f"{snap['frag_active']}"
        )
        assert snap["icmp_count"] == 1, (
            f"icmp_count should be 1, got {snap['icmp_count']}"
        )


# ==============================================================
# ICMP error generation cost accounted
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestIcmpErrorGenerationCost:

    def test_proto_unreach_bumps_err_gen_and_drops(
        self, perf_l3_session,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send one protocol-unreachable trigger (IP protocol=99).
        Assert:
          * icmp_err_gen increments by exactly 1 (the error frame
            was built and sent, all three icmp_send_error guards
            passed)
          * ip_drops increments by exactly 1 (proto-unreach falls
            through to .Lip_drop per commit #8's semantics)
          * ip_count does NOT increment (unknown protocol is NOT
            a successful dispatch to a known L4 protocol)
          * icmp_count does NOT increment (icmp_handle never runs)
        """
        # Wait past the rate-limit refill window to guarantee we
        # have at least one token available.
        time.sleep(1.2)
        perf_l3_session.reset()

        frame = ip_frames.build_ip_frame_with_proto(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            protocol=99, payload=bytes(8),
        )

        # Send and wait for the ICMP error reply.
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, frame)

            def is_proto_unreach(data: bytes) -> bool:
                try:
                    eth = eth_frames.parse_eth_header(data)
                    if eth["src"] != pi_mac or eth["dst"] != laptop_mac:
                        return False
                    if eth["ethertype"] != eth_frames.ETHERTYPE_IPV4:
                        return False
                    ip = ip_frames.parse_ipv4_header(
                        data[eth_frames.ETH_HEADER_LEN:
                             eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN]
                    )
                    if ip["protocol"] != ip_frames.IP_PROTO_ICMP:
                        return False
                    icmp = ip_frames.parse_icmp(
                        data[eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN:
                             eth_frames.ETH_HEADER_LEN + ip["total_length"]]
                    )
                    return (
                        icmp["type"] == ip_frames.ICMP_DEST_UNREACHABLE
                        and icmp["code"] == ip_frames.ICMP_CODE_PROTO_UNREACH
                    )
                except (ValueError, OSError):
                    return False

            reply = wire.wait_for_frame(
                cap, is_proto_unreach,
                deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
            )
        assert reply is not None, "no proto-unreachable reply received"

        snap = perf_l3_session.snapshot()
        assert snap["icmp_err_gen"] == 1, (
            f"icmp_err_gen should be 1, got {snap['icmp_err_gen']}"
        )
        assert snap["ip_drops"] == 1, (
            f"ip_drops should be 1 (proto-unreach is counted as "
            f"a drop per commit #8), got {snap['ip_drops']}"
        )
        assert snap["ip_count"] == 0, (
            f"ip_count should be 0 (unknown proto did not reach a "
            f"known-protocol dispatch), got {snap['ip_count']}"
        )
        assert snap["icmp_count"] == 0, (
            f"icmp_count should be 0 (icmp_handle was not called), "
            f"got {snap['icmp_count']}"
        )


# ==============================================================
# Dispatch counter cross-check (L2 vs L3)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestDispatchCrossCheck:
    """Cross-check that the L2 dispatch counter (from perf_counters)
    and the L3 ip_count (from perf_counters2) agree on the number
    of frames dispatched. A divergence would mean either the L2
    PERF_DISPATCH probe is missing some frames or the L3 PERF_L3_IP
    probe is missing some — either way a bug.

    Only runs under a PERF=all build (both L2 PERF_DISPATCH and L3
    PERF_L3 counters active). If the Pi is a PERF=l3 build without
    PERF_DISPATCH, the L2 dispatch_count stays at 0 and the cross-
    check would fail. The test detects that and skips.
    """

    def test_l2_dispatch_matches_l3_ip_count(
        self, perf_l3_session,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        # Probe the L2 counters first to check PERF_DISPATCH is
        # active. If dispatch_count stays at 0 after a known
        # round-trip, skip.
        wire.perf_query(
            eth_iface, pi_mac, laptop_mac,
            block="l2", reset=True,
        )
        perf_l3_session.reset()

        # Baseline echo to populate L2 dispatch_count for the
        # detection check.
        send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0xE801, seq=1, payload=b"probe",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        l2 = wire.perf_query(
            eth_iface, pi_mac, laptop_mac, block="l2",
        )
        if l2["dispatch_count"] == 0:
            pytest.skip(
                "L2 PERF_DISPATCH probe inactive (dispatch_count=0 "
                "after a round-trip) — this test requires PERF=all"
            )

        # Reset and run a controlled burst.
        wire.perf_query(
            eth_iface, pi_mac, laptop_mac,
            block="l2", reset=True,
        )
        perf_l3_session.reset()

        n = 25
        payload = bytes(64)
        delivered = _send_icmp_burst_and_count(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            n, payload, ident_base=0xE900, rtt_p99_ms=rtt_p99_ms,
        )
        assert delivered == n

        l2 = wire.perf_query(eth_iface, pi_mac, laptop_mac, block="l2")
        l3 = perf_l3_session.snapshot()

        # L2 dispatch_count counts every frame the Pi pulled out
        # of the GENET RX ring and handed to a protocol handler.
        # That includes our N echoes, the N reply frames the Pi
        # itself sent (which are NOT dispatched), and any
        # ambient frames. So l2.dispatch_count is the number of
        # INCOMING frames dispatched — should be >= N.
        #
        # L3 ip_count counts every IP frame that reached a known
        # L4 protocol dispatch in ip_handle. For an echo burst
        # that's exactly N.
        #
        # The cross-check: l2.dispatch_count >= l3.ip_count,
        # and l3.ip_count >= N.
        assert l3["ip_count"] >= n, (
            f"L3 ip_count {l3['ip_count']} < expected {n}"
        )
        assert l2["dispatch_count"] >= l3["ip_count"], (
            f"L2 dispatch_count {l2['dispatch_count']} < "
            f"L3 ip_count {l3['ip_count']} — some frames are "
            f"reaching ip_handle without being counted at L2?"
        )
