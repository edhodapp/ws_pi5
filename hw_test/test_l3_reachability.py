"""
test_l3_reachability.py — L3 baseline ICMP echo reachability.

These are the foundation tests for the L3 hardening suite. They MUST
pass before any other test_l3_*.py file is meaningful: every later
L3 test depends on the Pi's icmp_handle path being able to build a
correct echo reply from a crafted frame.

Unlike the L2 suite's system-ping tests, these use raw L2 sockets and
craft the entire Ethernet + IPv4 + ICMP frame ourselves. This is the
only way to:
  * Exercise the Pi's ip_handle dispatch path under known inputs
  * Pin specific IP header fields (identification, DF, TOS) that the
    system ping doesn't expose
  * Build a foundation that the malformed-header and fragment tests
    can extend without rewriting the send-and-verify machinery

Each test asserts on meaningful values, not just "didn't crash".

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l3_reachability.py -v
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


# ==============================================================
# Tests
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestIcmpReachability:
    """A crafted ICMP echo request gets a well-formed reply."""

    def test_crafted_echo_gets_reply(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Build an ICMP echo request ourselves, send it, and assert
        every observable field of the reply is correct.

        This pins the Pi's icmp_handle behaviour end-to-end:
          * Ethernet src/dst are swapped
          * IPv4 src/dst are swapped
          * IPv4 TTL is set to 64 (IP_DEFAULT_TTL)
          * IPv4 checksum verifies to 0
          * ICMP type is 0 (echo reply), code is 0
          * ICMP checksum verifies to 0
          * ICMP ident/seq are echoed back
          * ICMP payload is byte-for-byte identical
        """
        ident, seq = 0x1234, 0x0001
        payload = bytes(range(32))  # 0..31
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))

        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=ident, seq=seq, payload=payload,
            deadline_ms=deadline_ms,
        )
        assert reply is not None, (
            f"no ICMP echo reply from {PI4_IP} within {deadline_ms} ms"
        )

        # Full field audit of the reply.
        r = parse_reply(reply)
        assert r["eth"]["src"] == pi_mac
        assert r["eth"]["dst"] == laptop_mac
        assert r["eth"]["ethertype"] == eth_frames.ETHERTYPE_IPV4

        assert r["ip"]["version"] == 4
        assert r["ip"]["ihl"] == 5
        assert r["ip"]["protocol"] == ip_frames.IP_PROTO_ICMP
        assert r["ip"]["src_ip"] == PI4_IP
        assert r["ip"]["dst_ip"] == laptop_ip
        assert r["ip"]["ttl"] == ip_frames.IP_DEFAULT_TTL, (
            f"Pi should set reply TTL to {ip_frames.IP_DEFAULT_TTL}, "
            f"got {r['ip']['ttl']}"
        )
        assert ip_frames.ip_checksum(r["ip_bytes"]) == 0, (
            "reply IP checksum does not verify — header corruption"
        )

        assert r["icmp"]["type"] == ip_frames.ICMP_ECHO_REPLY
        assert r["icmp"]["code"] == 0
        assert r["icmp"]["ident"] == ident
        assert r["icmp"]["seq"] == seq
        assert r["icmp"]["payload"] == payload, (
            "ICMP payload corrupted in round-trip"
        )
        assert ip_frames.ip_checksum(r["icmp_bytes"]) == 0, (
            "reply ICMP checksum does not verify"
        )

    def test_ident_and_seq_pairs_are_echoed_without_crosstalk(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Ten sequential echoes with distinct (ident, seq) pairs all
        come back with the matching pair. No cross-talk.
        """
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        pairs = [(0x1000 + i, 0x8000 - i) for i in range(10)]

        for ident, seq in pairs:
            reply = send_echo_and_wait(
                eth_iface,
                pi_mac=pi_mac, laptop_mac=laptop_mac,
                pi_ip=PI4_IP, laptop_ip=laptop_ip,
                ident=ident, seq=seq, payload=b"abcdefgh",
                deadline_ms=deadline_ms,
            )
            assert reply is not None, (
                f"no reply for (id={ident:#06x}, seq={seq:#06x})"
            )
            r = parse_reply(reply)
            assert r["icmp"]["ident"] == ident
            assert r["icmp"]["seq"] == seq

    def test_echo_payload_integrity(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """A 64-byte payload with a structured pattern returns
        byte-for-byte intact — catches single-byte corruption that
        a shorter or all-identical payload would miss.
        """
        # Pattern: alternating 0xAA/0x55, then incrementing bytes,
        # then 0x00/0xFF pairs. Each half is 32 bytes = 64 total.
        payload = (
            b"\xAA\x55" * 16 +
            bytes((i & 0xFF) for i in range(32))
        )
        assert len(payload) == 64

        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0xBEEF, seq=0x0001, payload=payload,
            deadline_ms=deadline_ms,
        )
        assert reply is not None
        r = parse_reply(reply)
        assert r["icmp"]["payload"] == payload, (
            "payload corrupted:\n"
            f"  sent: {payload.hex()}\n"
            f"  recv: {r['icmp']['payload'].hex()}"
        )

    def test_rtt_within_ceiling(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """20 sequential crafted ICMP echoes, measure per-echo RTT,
        assert p99 is within 3x the L2 ARP baseline.

        L3 ICMP is heavier than L2 ARP (checksum + IP dispatch), so
        some slack is expected, but 3x is a sanity ceiling — if an
        L3 echo takes > 3x an ARP round-trip, something is broken.
        """
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        samples_ms: list[float] = []

        for i in range(20):
            t0 = time.monotonic()
            reply = send_echo_and_wait(
                eth_iface,
                pi_mac=pi_mac, laptop_mac=laptop_mac,
                pi_ip=PI4_IP, laptop_ip=laptop_ip,
                ident=0xAB00 + i, seq=i, payload=b"rtt",
                deadline_ms=deadline_ms,
            )
            elapsed_ms = (time.monotonic() - t0) * 1000.0
            assert reply is not None, f"lost echo at sample {i}"
            samples_ms.append(elapsed_ms)

        samples_ms.sort()
        p99_idx = max(0, int(len(samples_ms) * 0.99) - 1)
        p99 = samples_ms[p99_idx]
        # Sanity ceiling: L3 shouldn't be >3x the L2 baseline plus a
        # fixed 200ms slack for the wire_capture startup overhead.
        ceiling = 3 * rtt_p99_ms + 200.0
        assert p99 < ceiling, (
            f"L3 ICMP p99 {p99:.2f} ms over ceiling {ceiling:.2f} ms "
            f"(L2 baseline p99 {rtt_p99_ms:.2f} ms, "
            f"samples: min={samples_ms[0]:.2f} "
            f"median={samples_ms[len(samples_ms)//2]:.2f} "
            f"max={samples_ms[-1]:.2f})"
        )

    def test_back_to_back_10_echoes(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Burst 10 crafted echoes into a single WireCapture and
        assert all 10 replies arrive. Catches re-entrancy bugs in the
        Pi's L3 path that a one-at-a-time test would miss.
        """
        deadline_ms = int(max(30.0 * rtt_p99_ms, 1000.0))
        ident_base = 0x7000
        frames = [
            ip_frames.build_icmp_echo_frame(
                laptop_mac, pi_mac, laptop_ip, PI4_IP,
                ident=ident_base + i, seq=0,
                payload=b"burst" + bytes([i]),
            )
            for i in range(10)
        ]
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            for f in frames:
                wire.send_frame(eth_iface, f)

            def is_burst_reply(data: bytes) -> bool:
                if not is_any_echo_reply_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                ):
                    return False
                ident = parse_reply(data)["icmp"]["ident"]
                return ident_base <= ident < ident_base + 10

            replies = wire.wait_for_frames(
                cap, is_burst_reply,
                count=10, deadline_ms=deadline_ms,
            )
        assert len(replies) == 10, (
            f"burst got only {len(replies)}/10 replies within "
            f"{deadline_ms} ms"
        )
        # Each ident in the burst must appear exactly once.
        got_idents = {parse_reply(r)["icmp"]["ident"] for r in replies}
        expected = set(range(ident_base, ident_base + 10))
        assert got_idents == expected, (
            f"burst idents missing: {expected - got_idents}, "
            f"duplicates observed via set collapse: "
            f"{len(replies) - len(got_idents)}"
        )

    def test_echo_preserves_ip_ident(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Pin the Pi's echo-reply behaviour: the reply carries the
        SAME IP.id as the request (lib/icmp.S builds the reply in
        place without touching IP.id).

        This is not required by any RFC — it's just what the current
        implementation does, and a future change that starts generating
        fresh IP.ids should update this test explicitly.
        """
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        ip_ident_val = 0xC0DE
        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x0100, seq=0x0001, payload=b"id-check",
            deadline_ms=deadline_ms,
            ip_ident=ip_ident_val,
        )
        assert reply is not None
        r = parse_reply(reply)
        assert r["ip"]["ident"] == ip_ident_val, (
            f"Pi did not preserve IP.id in reply: sent {ip_ident_val:#06x}, "
            f"got {r['ip']['ident']:#06x}. Update this test if the "
            f"behaviour intentionally changed."
        )
