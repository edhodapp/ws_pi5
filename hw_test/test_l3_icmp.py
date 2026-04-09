"""
test_l3_icmp.py — ICMP echo round-trip under varying payload sizes.

Extends test_l3_reachability.py's foundation by sweeping the payload
axis: 1 byte up to the MTU ceiling (1472 bytes, one-byte-short-of-
fragmentation). Each size exercises a different slice of the Pi's
ip_checksum / icmp_handle code path:

  * 1 byte      — minimum-sized payload (odd length on ICMP side too)
  * 64 bytes    — a "typical" small ping
  * 512 bytes   — larger than any single copy chunk
  * 1000 bytes  — above the 1KB "obvious" boundary
  * 1400 bytes  — just under typical tunnel MTU
  * 1472 bytes  — exactly Ethernet MTU (14 + 20 + 8 + 1472 = 1514)

Plus an explicit odd-length test (payload == 37) to pin the
checksum tail-byte path on real hardware, and a 10-concurrent-stream
test to catch any ident/seq crosstalk that a one-at-a-time loop
would miss.

Each test asserts on every observable field, not just "reply arrived".

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l3_icmp.py -v
"""

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


# The classic ping size matrix plus the two ends of the range.
# 1472 is the exact payload size that produces a 1514-byte frame on
# the wire — one byte more and the kernel fragments it (with DF) or
# the Pi drops it (ip_total_length > frame_len).
PAYLOAD_SIZES = [1, 64, 512, 1000, 1400, 1472]


def _patterned_payload(size: int) -> bytes:
    """Return `size` bytes of a structured pattern that maximises the
    chance of catching a single-byte corruption bug.

    The pattern combines alternating 0xAA/0x55, incrementing bytes,
    and position-dependent XOR. Any off-by-one in a copy loop shows
    up as a mismatch at the bug's offset.
    """
    return bytes(
        ((0xAA if i & 1 else 0x55) ^ (i & 0xFF)) & 0xFF
        for i in range(size)
    )


@requires_hardware
@pytest.mark.l3
class TestEchoPayloadSizes:
    """ICMP echo round-trip across the payload-size sweep."""

    @pytest.mark.parametrize("size", PAYLOAD_SIZES)
    def test_echo_round_trip(
        self, size, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """One ICMP echo at `size` bytes of payload: reply arrives,
        every IP + ICMP field validates, payload is byte-for-byte
        correct, both checksums verify.

        Larger sizes need more slack on the deadline because:
          * the Pi copies the payload to build the reply
          * the wire time itself is longer at 1 gbit
          * more bytes of tcpdump to scan in the pcap
        """
        payload = _patterned_payload(size)
        # RTT ceiling: baseline + 5ms per 1KB of payload as rough slack
        deadline_ms = int(
            max(20.0 * rtt_p99_ms, 500.0) + 5.0 * (size / 1024.0)
        )

        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x1000 + size, seq=1, payload=payload,
            deadline_ms=deadline_ms,
        )
        assert reply is not None, (
            f"no echo reply for {size}-byte payload within {deadline_ms} ms"
        )

        r = parse_reply(reply)
        # Natural frame length is 14 + 20 + 8 + size, but frames
        # shorter than the 60-byte Ethernet minimum are zero-padded
        # on transmit by the r8152 USB NIC (same behaviour documented
        # in eth_frames.py for the L2 runt tests). The IP
        # total_length is the authoritative value — the pad is invisible
        # to the protocol stack.
        natural_frame_len = eth_frames.ETH_HEADER_LEN + 20 + 8 + size
        expected_frame_len = max(natural_frame_len, eth_frames.ETH_MIN_FRAME)
        assert len(reply) == expected_frame_len, (
            f"reply frame length mismatch for {size}-byte payload: "
            f"got {len(reply)}, expected {expected_frame_len} "
            f"(natural={natural_frame_len}, "
            f"min-Ethernet={eth_frames.ETH_MIN_FRAME})"
        )
        assert r["ip"]["total_length"] == 20 + 8 + size
        assert r["ip"]["ttl"] == ip_frames.IP_DEFAULT_TTL
        assert r["ip"]["protocol"] == ip_frames.IP_PROTO_ICMP
        assert r["ip"]["src_ip"] == PI4_IP
        assert r["ip"]["dst_ip"] == laptop_ip
        assert ip_frames.ip_checksum(r["ip_bytes"]) == 0, (
            f"{size}-byte reply: IP checksum does not verify"
        )

        assert r["icmp"]["type"] == ip_frames.ICMP_ECHO_REPLY
        assert r["icmp"]["code"] == 0
        assert r["icmp"]["ident"] == 0x1000 + size
        assert r["icmp"]["seq"] == 1
        assert ip_frames.ip_checksum(r["icmp_bytes"]) == 0, (
            f"{size}-byte reply: ICMP checksum does not verify"
        )
        assert r["icmp"]["payload"] == payload, (
            f"{size}-byte payload corrupted in round-trip"
        )

    def test_max_mtu_frame_size_is_exactly_1514(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """A 1472-byte payload produces exactly a 1514-byte reply —
        the exact Ethernet MTU. Pins the high-water-mark frame size
        so a future change that bumps the header size (e.g. adding
        IP options) can't silently exceed the MTU.
        """
        payload = _patterned_payload(1472)
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0) + 10)

        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x7FFF, seq=1, payload=payload,
            deadline_ms=deadline_ms,
        )
        assert reply is not None
        assert len(reply) == 1514, (
            f"max-MTU reply length is {len(reply)}, expected exactly 1514"
        )


@requires_hardware
@pytest.mark.l3
class TestEchoOddLengthPayload:
    """The ip_checksum loop in lib/ip.S has an explicit odd-byte-tail
    path (`ldrb w3` then add). The QEMU unit tests already cover this,
    but pin it on real hardware too so a future copy-loop rewrite
    can't quietly break the tail.
    """

    @pytest.mark.parametrize("size", [1, 3, 37, 73, 129, 1471])
    def test_odd_length_payload(
        self, size, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        assert size % 2 == 1, "this test class is for odd-length payloads only"
        payload = _patterned_payload(size)
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0) + 5)

        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x2000 + size, seq=1, payload=payload,
            deadline_ms=deadline_ms,
        )
        assert reply is not None, f"no reply for odd-length {size}"
        r = parse_reply(reply)
        assert ip_frames.ip_checksum(r["icmp_bytes"]) == 0, (
            f"odd-length {size}: ICMP checksum does not verify — "
            f"the Pi's ip_checksum odd-byte-tail path is broken"
        )
        assert r["icmp"]["payload"] == payload, (
            f"odd-length {size}: payload corrupted"
        )


@requires_hardware
@pytest.mark.l3
class TestConcurrentEchoStreams:
    """Ten distinct (ident, seq) streams interleaved in a single
    burst. Pins "no cross-talk between ident/seq pairs" under
    real burst load, not just sequential one-at-a-time.
    """

    def test_10_concurrent_streams_no_crosstalk(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send 10 echoes with 10 distinct (ident, seq) pairs and
        assert every reply carries the exact pair we sent for it.
        Replies are matched by ident, and we then verify seq matches.
        """
        deadline_ms = int(max(30.0 * rtt_p99_ms, 1500.0))
        # Distinct idents, distinct seqs, distinct payloads — every
        # reply has a unique byte pattern so a cross-talk bug that
        # swapped payloads between idents would be caught here too.
        streams = [
            (0x3000 + i, 0x9000 + (i * 7 & 0xFFFF), f"stream-{i:02d}".encode())
            for i in range(10)
        ]
        ident_set = {s[0] for s in streams}
        expected_for_ident = {s[0]: s for s in streams}

        frames = [
            ip_frames.build_icmp_echo_frame(
                laptop_mac, pi_mac, laptop_ip, PI4_IP,
                ident=ident, seq=seq, payload=payload,
            )
            for (ident, seq, payload) in streams
        ]

        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            for f in frames:
                wire.send_frame(eth_iface, f)

            def is_one_of_ours(data: bytes) -> bool:
                if not is_any_echo_reply_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                ):
                    return False
                return parse_reply(data)["icmp"]["ident"] in ident_set

            replies = wire.wait_for_frames(
                cap, is_one_of_ours,
                count=10, deadline_ms=deadline_ms,
            )

        assert len(replies) == 10, (
            f"concurrent burst: only {len(replies)}/10 replies within "
            f"{deadline_ms} ms"
        )

        # Every reply's (ident, seq, payload) must match exactly one
        # stream, and every stream must appear exactly once.
        seen_idents: set[int] = set()
        for reply in replies:
            r = parse_reply(reply)
            ident = r["icmp"]["ident"]
            assert ident in expected_for_ident, (
                f"unexpected ident in reply: {ident:#06x}"
            )
            assert ident not in seen_idents, (
                f"duplicate reply for ident {ident:#06x}"
            )
            seen_idents.add(ident)

            expected_ident, expected_seq, expected_payload = expected_for_ident[ident]
            assert r["icmp"]["seq"] == expected_seq, (
                f"ident {ident:#06x}: seq mismatch, "
                f"got {r['icmp']['seq']:#06x}, "
                f"expected {expected_seq:#06x} — CROSS-TALK"
            )
            assert r["icmp"]["payload"] == expected_payload, (
                f"ident {ident:#06x}: payload mismatch, "
                f"got {r['icmp']['payload']!r}, "
                f"expected {expected_payload!r} — CROSS-TALK"
            )

        assert seen_idents == ident_set, (
            f"missing idents: {ident_set - seen_idents}"
        )
