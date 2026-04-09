"""
test_l3_malformed_ip.py — IPv4 header negative-path drop tests.

Exercises every drop path in lib/ip.S::ip_handle:

  1. frame_len < 34 (ETH_HDR_LEN + IP_HDR_MIN) — covered by
     test_l2_malformed.py with undersized frames; not re-tested here.
  2. VER_IHL != 0x45 — one-byte compare, so v6, ihl<5, and ihl>5
     with options all drop at the same check.
  3. IP total_length < 20
  4. ETH_HDR_LEN + total_length > frame_len (declared length exceeds
     actual)
  5. IP checksum fails
  6. TTL == 0

And pins two properties that are NOT drops:
  * TTL == 1 is accepted (we are the destination, not a router)
  * Source IP sanity is NOT checked — the Pi has no martian filter,
    so zero source IP, loopback source IP, and our-own-IP-as-source
    are all accepted. These tests document the current policy; a
    future martian filter would need to update them explicitly.

TEST PATTERN: for drop cases, the "send bogus → silence window →
normal echo → reply" pattern from test_l2_malformed.py ensures the
Pi is still alive and the drop was silent (not a hang or wedge).
The ICMP predicate is narrowed on ident/seq so unrelated ICMP
traffic can't mask the silence assertion.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l3_malformed_ip.py -v
"""

import pytest

import eth_frames
import ip_frames
import wire
from conftest import PI4_IP, requires_hardware
from icmp_helpers import (
    icmp_bpf_from_pi,
    is_any_echo_reply_from_pi,
    is_any_icmp_from_pi,
    parse_reply,
    send_echo_and_wait,
)


# ==============================================================
# Shared helpers
# ==============================================================

def _assert_bogus_is_dropped(
    eth_iface: str,
    bogus_frame: bytes,
    *,
    pi_mac: bytes,
    laptop_mac: bytes,
    laptop_ip: str,
    rtt_p99_ms: float,
    reason: str,
) -> None:
    """Send `bogus_frame`, wait a silence window for any ICMP from
    the Pi, assert nothing came back, then send a normal echo and
    assert a reply arrives (proving the Pi is still alive and the
    drop was silent).

    The ICMP predicate here matches ANY ICMP from the Pi — if a
    malformed frame elicits any kind of reply (echo OR error), we
    want to know, since the plan assumed silent drop.
    """
    silence_ms = int(max(5.0 * rtt_p99_ms, 50.0))
    bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)

    with wire.WireCapture(eth_iface, bpf=bpf) as cap:
        wire.send_frame(eth_iface, bogus_frame)
        uninvited = wire.wait_for_frame(
            cap,
            lambda data: is_any_icmp_from_pi(
                data, pi_mac=pi_mac, laptop_mac=laptop_mac,
                pi_ip=PI4_IP,
            ),
            deadline_ms=silence_ms,
        )
    assert uninvited is None, (
        f"Pi replied to malformed frame ({reason}) — expected silent "
        f"drop. Reply hex: {uninvited.hex() if uninvited else None}"
    )

    # Prove the Pi is still alive.
    probe = send_echo_and_wait(
        eth_iface,
        pi_mac=pi_mac, laptop_mac=laptop_mac,
        pi_ip=PI4_IP, laptop_ip=laptop_ip,
        ident=0xBABE, seq=1, payload=b"alive?",
        deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
    )
    assert probe is not None, (
        f"Pi did not reply to a normal echo after the malformed "
        f"frame ({reason}) — it may be hung"
    )


# ==============================================================
# Dropped malformed headers
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestMalformedDropped:
    """Every case in this class must elicit NO reply from the Pi,
    AND must not wedge the stack (a follow-up echo still works).
    """

    def test_ip_version_6_in_ipv4_ethertype(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """ethertype=IPv4 but IP version field = 6. The Pi's
        VER_IHL != 0x45 check drops this — the IPv4 stack never
        looks at an IPv6 header.
        """
        frame = ip_frames.build_bogus_ip_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            version=6, payload=bytes(8),
        )
        _assert_bogus_is_dropped(
            eth_iface, frame,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
            reason="version=6 in IPv4 ethertype",
        )

    def test_ihl_below_minimum(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """ihl=4 (below the IPv4 minimum of 5). VER_IHL byte = 0x44."""
        frame = ip_frames.build_bogus_ip_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ihl=4, payload=bytes(8),
        )
        _assert_bogus_is_dropped(
            eth_iface, frame,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
            reason="ihl=4",
        )

    def test_ihl_6_with_options(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """ihl=6 with 4 bytes of IP options. VER_IHL = 0x46, which
        the Pi rejects because it only accepts the exact 0x45 value.
        Pins that ws_pi5 does NOT parse IP options.
        """
        # 4 bytes of NOP options (0x01 0x01 0x01 0x01)
        frame = ip_frames.build_bogus_ip_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ihl=6, options=b"\x01\x01\x01\x01", payload=bytes(8),
        )
        _assert_bogus_is_dropped(
            eth_iface, frame,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
            reason="ihl=6 with options",
        )

    def test_total_length_below_20(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """IP.total_length field = 10, below the 20-byte header
        minimum. The physical frame is still well-formed — only the
        header field is a lie.
        """
        frame = ip_frames.build_bogus_ip_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            total_length_override=10, payload=bytes(20),
        )
        _assert_bogus_is_dropped(
            eth_iface, frame,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
            reason="total_length=10",
        )

    def test_total_length_exceeds_frame(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """IP.total_length field = 1500 but the actual frame is only
        a few dozen bytes. The Pi's
        `ETH_HDR_LEN + total_length <= frame_len` check catches this.

        NOTE: the r8152 pads sub-60-byte frames to 60 on transmit,
        so the Pi sees frame_len=60. 14 + 1500 = 1514 > 60 — drop
        fires.
        """
        frame = ip_frames.build_bogus_ip_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            total_length_override=1500, payload=bytes(8),
        )
        _assert_bogus_is_dropped(
            eth_iface, frame,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
            reason="total_length=1500 but actual frame is short",
        )

    def test_bad_ip_checksum(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """IP checksum field forced to a wrong value (0xBEEF). The
        Pi recomputes and fails the ones'-complement verify.
        """
        frame = ip_frames.build_bogus_ip_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            bad_checksum=True, payload=bytes(8),
        )
        _assert_bogus_is_dropped(
            eth_iface, frame,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
            reason="bad IP checksum",
        )

    def test_ttl_zero(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """TTL=0 is dropped at the TTL check. Note: we do NOT expect
        a Time-Exceeded reply — ws_pi5 is a host, not a router, so
        it drops rather than generating an error.
        """
        frame = ip_frames.build_bogus_ip_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ttl=0, payload=bytes(8),
        )
        _assert_bogus_is_dropped(
            eth_iface, frame,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
            reason="TTL=0",
        )


# ==============================================================
# Accepted (positive) cases
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestTtl1Accepted:
    """TTL=1 is accepted — the Pi is the destination, not a router,
    so per RFC 1122 §3.2.1.7 a host MAY accept packets with TTL=1 as
    long as it's the final destination. ws_pi5's ip_handle only
    drops TTL=0.
    """

    def test_ttl_1_produces_echo_reply(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """A well-formed ICMP echo with TTL=1 gets a normal reply.
        The reply's TTL is set to the default (64), not 1.
        """
        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x5101, seq=1, payload=b"ttl-1-test",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
            ttl=1,
        )
        assert reply is not None, (
            "Pi dropped a well-formed echo with TTL=1 — ip_handle's "
            "TTL check should only drop TTL=0"
        )
        r = parse_reply(reply)
        # The Pi sets TTL=IP_DEFAULT_TTL=64 on the outgoing reply.
        assert r["ip"]["ttl"] == ip_frames.IP_DEFAULT_TTL, (
            f"reply TTL is {r['ip']['ttl']}, expected 64 — the Pi "
            f"should not reflect the request TTL"
        )
        assert r["icmp"]["payload"] == b"ttl-1-test"


# ==============================================================
# No martian filter (currently documented, not enforced)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestNoMartianFilter:
    """ws_pi5's ip_handle does NOT validate the source IP against
    any martian ranges (0.0.0.0, 127.0.0.0/8, our-own-IP). The
    checks it performs are: VER_IHL, total_length, frame bounds,
    checksum, TTL, destination IP.

    These tests pin the current NO-FILTER behaviour. If a future
    change adds a martian filter, these tests will fail, which is
    correct — they must be updated to assert "drop" instead.

    Observability: we filter on (ident, seq) AND source MAC,
    since the reply's dst_ip might be a value our kernel refuses
    to route. tcpdump sees all Ethernet traffic regardless.
    """

    def _assert_pi_replied_to_ident_seq(
        self,
        eth_iface: str,
        bogus_src_ip: str,
        *,
        pi_mac: bytes,
        laptop_mac: bytes,
        ident: int,
        seq: int,
        rtt_p99_ms: float,
    ) -> bytes:
        frame = ip_frames.build_icmp_echo_frame(
            laptop_mac, pi_mac, bogus_src_ip, PI4_IP,
            ident=ident, seq=seq, payload=b"martian?",
        )
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)

        # Custom predicate: reply is an ICMP echo reply from the Pi
        # with the matching (ident, seq). The dst_ip in the reply
        # will be bogus_src_ip (the Pi swaps the IP addresses blindly).
        def is_reply_for_bogus(data: bytes) -> bool:
            if not is_any_echo_reply_from_pi(
                data,
                pi_mac=pi_mac, laptop_mac=laptop_mac,
                pi_ip=PI4_IP, laptop_ip=bogus_src_ip,
            ):
                return False
            icmp = parse_reply(data)["icmp"]
            return icmp["ident"] == ident and icmp["seq"] == seq

        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, frame)
            reply = wire.wait_for_frame(
                cap, is_reply_for_bogus,
                deadline_ms=deadline_ms,
            )
        assert reply is not None, (
            f"Pi did NOT reply to an echo with src_ip={bogus_src_ip} — "
            f"a martian filter appears to have been added. If this "
            f"change is intentional, update this test to assert "
            f"silent drop instead."
        )
        return reply

    def test_zero_src_ip_accepted(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """src_ip = 0.0.0.0 (RFC 1122 §3.2.1.3 "this host"). Pinned
        as accepted."""
        reply = self._assert_pi_replied_to_ident_seq(
            eth_iface, "0.0.0.0",
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            ident=0x5201, seq=1, rtt_p99_ms=rtt_p99_ms,
        )
        r = parse_reply(reply)
        assert r["ip"]["dst_ip"] == "0.0.0.0"
        assert r["ip"]["src_ip"] == PI4_IP
        assert r["icmp"]["payload"] == b"martian?"

    def test_loopback_src_ip_accepted(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """src_ip = 127.0.0.1 (loopback, never valid on the wire).
        Pinned as accepted."""
        reply = self._assert_pi_replied_to_ident_seq(
            eth_iface, "127.0.0.1",
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            ident=0x5202, seq=1, rtt_p99_ms=rtt_p99_ms,
        )
        r = parse_reply(reply)
        assert r["ip"]["dst_ip"] == "127.0.0.1"
        assert r["icmp"]["payload"] == b"martian?"

    def test_our_own_ip_as_src_accepted(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """src_ip = PI4_IP (claim the packet came from the Pi
        itself). Pinned as accepted — the Pi blindly builds a reply
        that gets sent back at itself.
        """
        reply = self._assert_pi_replied_to_ident_seq(
            eth_iface, PI4_IP,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            ident=0x5203, seq=1, rtt_p99_ms=rtt_p99_ms,
        )
        r = parse_reply(reply)
        # Self-reply: both src and dst are PI4_IP on the way back.
        assert r["ip"]["dst_ip"] == PI4_IP
        assert r["ip"]["src_ip"] == PI4_IP
        assert r["icmp"]["payload"] == b"martian?"
