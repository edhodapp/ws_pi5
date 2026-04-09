"""
test_l3_icmp_errors.py — ICMP error generation and rate limiting.

Exercises the two callers of `icmp_send_error` in the Pi's L3 stack:

  * `lib/ip.S` — Protocol Unreachable (type 3, code 2) when the IP
    protocol byte is not one of ICMP/UDP/TCP.
  * `lib/udp.S` — Port Unreachable (type 3, code 3) when the UDP
    destination port is neither 7 (echo) nor 123 (NTP).

And the shared rate limiter: `icmp_err_allow` in lib/icmp.S uses a
token bucket with `ICMP_ERR_BURST = 10` tokens refilled on each
1-second boundary. This file pins that the bucket actually rate-
limits under real load and recovers after the window.

RATE LIMITER ISOLATION: the bucket is shared across all ICMP error
generators. Tests that burn it would otherwise leak state into the
next test. The `refilled_bucket` fixture sleeps just over one second
before yielding, ensuring each test starts with a full bucket.

LOOP SUPPRESSION (plan item): lib/icmp.S's icmp_send_error has a
"don't send ICMP errors in response to ICMP errors" guard, but
neither of its current callers (ip.S protocol-unreachable, udp.S
port-unreachable) can be reached with an ICMP input. So the guard is
defensive — the code exists but is unreachable from the current L3
dispatch. This file tests the observable property instead: an ICMP
dest-unreachable addressed to the Pi elicits no reply at all.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l3_icmp_errors.py -v
"""

import time

import pytest

import eth_frames
import ip_frames
import wire
from conftest import PI4_IP, requires_hardware
from icmp_helpers import (
    icmp_bpf_from_pi,
    parse_reply,
    send_echo_and_wait,
)


# Matches lib/net.inc
ICMP_ERR_BURST = 10
ICMP_ERR_REFILL_SEC = 1.0
ICMP_ERROR_FRAME_LEN = 70   # ETH(14) + IP(20) + ICMP(8) + orig(28)
UNKNOWN_IP_PROTOCOL = 99    # unassigned — triggers proto-unreachable
UNKNOWN_UDP_PORT = 9999     # not 7 (echo), not 123 (NTP)


@pytest.fixture
def refilled_bucket():
    """Sleep just over one ICMP rate-limit refill window (1 second)
    so the bucket is guaranteed full at test start.

    Slightly wasteful (~5s of sleep across the test file) but
    isolates each test from prior bucket state without requiring
    class-level ordering contracts.
    """
    time.sleep(ICMP_ERR_REFILL_SEC + 0.2)
    yield


# ==============================================================
# Predicates and helpers
# ==============================================================

def _is_icmp_error_from_pi(
    frame: bytes,
    *,
    pi_mac: bytes,
    laptop_mac: bytes,
    pi_ip: str,
    laptop_ip: str,
    expected_type: int,
    expected_code: int,
) -> bool:
    """Predicate: frame is an ICMP error (type/code match) from the
    Pi to the laptop.
    """
    try:
        eth = eth_frames.parse_eth_header(frame)
        if eth["ethertype"] != eth_frames.ETHERTYPE_IPV4:
            return False
        if eth["src"] != pi_mac or eth["dst"] != laptop_mac:
            return False
        ip = ip_frames.parse_ipv4_header(
            frame[eth_frames.ETH_HEADER_LEN:
                  eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN]
        )
        if ip["protocol"] != ip_frames.IP_PROTO_ICMP:
            return False
        if ip["src_ip"] != pi_ip or ip["dst_ip"] != laptop_ip:
            return False
        icmp = ip_frames.parse_icmp(
            frame[eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN:
                  eth_frames.ETH_HEADER_LEN + ip["total_length"]]
        )
        return icmp["type"] == expected_type and icmp["code"] == expected_code
    except (ValueError, OSError):
        return False


def _assert_error_reply_embeds_original(
    reply: bytes, original: bytes,
) -> None:
    """Assert the ICMP error reply embeds the first 28 bytes of the
    original IP datagram (20-byte IP header + 8 bytes of L4 payload)
    per RFC 792.
    """
    # ICMP error frame layout: ETH(14) + IP(20) + ICMP(8) + orig(28)
    assert len(reply) == ICMP_ERROR_FRAME_LEN, (
        f"ICMP error frame size is {len(reply)}, expected "
        f"{ICMP_ERROR_FRAME_LEN} (14 eth + 20 ip + 8 icmp + 28 orig)"
    )
    embedded_start = eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN + ip_frames.ICMP_HDR_LEN
    embedded = reply[embedded_start:embedded_start + 28]

    # The original frame's first 28 post-Ethernet bytes should equal
    # the embedded payload: full IP header (20) + first 8 bytes of
    # L4 payload.
    original_ip_start = eth_frames.ETH_HEADER_LEN
    original_slice = original[original_ip_start:original_ip_start + 28]
    # Pad with zeros if original had <8 bytes of L4 payload, since
    # icmp_send_error zeroes the destination before copying.
    if len(original_slice) < 28:
        original_slice = original_slice + bytes(28 - len(original_slice))

    assert embedded == original_slice, (
        f"embedded original in ICMP error does not match sent frame:\n"
        f"  sent  : {original_slice.hex()}\n"
        f"  embed : {embedded.hex()}"
    )


def _assert_error_reply_fields(
    reply: bytes, laptop_ip: str,
    expected_type: int, expected_code: int,
) -> None:
    """Verify the error reply's common header fields and checksums."""
    r = parse_reply(reply)
    assert r["ip"]["version"] == 4
    assert r["ip"]["ihl"] == 5
    assert r["ip"]["protocol"] == ip_frames.IP_PROTO_ICMP
    assert r["ip"]["src_ip"] == PI4_IP
    assert r["ip"]["dst_ip"] == laptop_ip
    assert r["ip"]["ttl"] == ip_frames.IP_DEFAULT_TTL
    # icmp_send_error always builds totlen = 56 (IP 20 + ICMP 8 + orig 28)
    assert r["ip"]["total_length"] == 56
    # icmp_send_error explicitly stores IP.id = 0 and no frag flags
    assert r["ip"]["ident"] == 0
    assert r["ip"]["flags"] == 0
    assert r["ip"]["frag_off"] == 0
    assert ip_frames.ip_checksum(r["ip_bytes"]) == 0, (
        "error reply IP checksum does not verify"
    )

    assert r["icmp"]["type"] == expected_type
    assert r["icmp"]["code"] == expected_code
    assert ip_frames.ip_checksum(r["icmp_bytes"]) == 0, (
        "error reply ICMP checksum does not verify"
    )


# ==============================================================
# Protocol Unreachable (ip_handle → unknown proto dispatch)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestProtocolUnreachable:

    def test_unknown_proto_elicits_protocol_unreachable(
        self, refilled_bucket,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send an IP frame with protocol=99 (unassigned). Assert the
        Pi replies with ICMP type 3, code 2, and the reply embeds the
        first 28 bytes of our sent frame (IP header + 8 bytes L4
        payload, zero-padded since our payload is 8 bytes).
        """
        payload = bytes(range(8))  # exactly 8 bytes of "L4 payload"
        original = ip_frames.build_ip_frame_with_proto(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            protocol=UNKNOWN_IP_PROTOCOL, payload=payload,
        )
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, original)
            reply = wire.wait_for_frame(
                cap,
                lambda data: _is_icmp_error_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    expected_type=ip_frames.ICMP_DEST_UNREACHABLE,
                    expected_code=ip_frames.ICMP_CODE_PROTO_UNREACH,
                ),
                deadline_ms=deadline_ms,
            )
        assert reply is not None, (
            f"no ICMP protocol-unreachable reply from Pi within "
            f"{deadline_ms} ms (sent proto={UNKNOWN_IP_PROTOCOL})"
        )
        _assert_error_reply_fields(
            reply, laptop_ip,
            ip_frames.ICMP_DEST_UNREACHABLE,
            ip_frames.ICMP_CODE_PROTO_UNREACH,
        )
        _assert_error_reply_embeds_original(reply, original)


# ==============================================================
# Port Unreachable (udp_handle → unknown port dispatch)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestPortUnreachable:

    def test_unknown_port_elicits_port_unreachable(
        self, refilled_bucket,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send a UDP datagram to port 9999 (neither 7 nor 123).
        Assert the Pi replies with ICMP type 3, code 3.
        """
        payload = b"portunr!"     # 8 bytes — fills the L4 embed slot
        original = ip_frames.build_udp_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            src_port=33333, dst_port=UNKNOWN_UDP_PORT, payload=payload,
        )
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, original)
            reply = wire.wait_for_frame(
                cap,
                lambda data: _is_icmp_error_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    expected_type=ip_frames.ICMP_DEST_UNREACHABLE,
                    expected_code=ip_frames.ICMP_CODE_PORT_UNREACH,
                ),
                deadline_ms=deadline_ms,
            )
        assert reply is not None, (
            f"no ICMP port-unreachable reply from Pi within "
            f"{deadline_ms} ms (sent UDP dport={UNKNOWN_UDP_PORT})"
        )
        _assert_error_reply_fields(
            reply, laptop_ip,
            ip_frames.ICMP_DEST_UNREACHABLE,
            ip_frames.ICMP_CODE_PORT_UNREACH,
        )
        _assert_error_reply_embeds_original(reply, original)

    def test_echo_port_still_works(
        self, refilled_bucket,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """A UDP datagram to port 7 (echo) must echo back rather than
        elicit a port-unreachable. This pins that the dispatch table
        in udp_handle routes port 7 correctly.

        (This is a UDP-level sanity check wedged into the L3 error
        file because it uses the same "port dispatch" code the
        unreachable test exercises.)
        """
        payload = b"udpecho"
        frame = ip_frames.build_udp_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            src_port=44444, dst_port=7, payload=payload,
        )
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        bpf = f"udp and ether src {eth_frames.mac_bytes_to_str(pi_mac)}"

        def is_udp_echo_reply(data: bytes) -> bool:
            try:
                eth = eth_frames.parse_eth_header(data)
                if eth["ethertype"] != eth_frames.ETHERTYPE_IPV4:
                    return False
                ip = ip_frames.parse_ipv4_header(
                    data[eth_frames.ETH_HEADER_LEN:
                         eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN]
                )
                if ip["protocol"] != ip_frames.IP_PROTO_UDP:
                    return False
                # UDP header: sport(2) dport(2) len(2) cksum(2)
                udp_start = eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN
                dport = (data[udp_start + 2] << 8) | data[udp_start + 3]
                udp_payload = data[udp_start + 8:
                                   eth_frames.ETH_HEADER_LEN + ip["total_length"]]
                # The echo port swaps src/dst; the reply dport equals
                # our original sport (44444).
                return dport == 44444 and udp_payload == payload
            except (ValueError, OSError):
                return False

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, frame)
            reply = wire.wait_for_frame(
                cap, is_udp_echo_reply,
                deadline_ms=deadline_ms,
            )
        assert reply is not None, (
            "UDP echo (port 7) did not reply — dispatch regression"
        )


# ==============================================================
# Rate limiter
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestRateLimit:
    """Token bucket rate limiting on ICMP error generation.

    The Pi's icmp_err_allow has ICMP_ERR_BURST=10 tokens refilled on
    the first call occurring >=1 second after the last refill tick.
    """

    def test_burst_is_capped_at_burst_size(
        self, refilled_bucket,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send 20 protocol-unreachable-triggering frames back-to-back
        inside a single refill window. Assert the Pi replies with no
        MORE than ICMP_ERR_BURST errors, and assert we actually see
        at least 8 (tolerating minor L2 burst loss — the documented
        GENET ARP burst loss memory ranges 0-14% at N=1024, well
        below 20% at N=20 in practice).

        A broken rate limiter would produce all 20. A completely
        broken error path would produce 0. The [8, 10] window catches
        both failure modes.
        """
        n_triggers = 20
        frames = [
            ip_frames.build_ip_frame_with_proto(
                laptop_mac, pi_mac, laptop_ip, PI4_IP,
                protocol=UNKNOWN_IP_PROTOCOL,
                payload=bytes([i]) * 8,
                ip_ident=i,
            )
            for i in range(n_triggers)
        ]
        deadline_ms = int(max(50.0 * rtt_p99_ms, 2000.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            # Burst them as quickly as wire.send_frame allows, keeping
            # the entire burst well under the 1-second refill window.
            for f in frames:
                wire.send_frame(eth_iface, f)
            # Wait for AT MOST n_triggers replies with a hard deadline.
            # Any MORE than burst_size would be a rate-limiter bug.
            replies = wire.wait_for_frames(
                cap,
                lambda data: _is_icmp_error_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    expected_type=ip_frames.ICMP_DEST_UNREACHABLE,
                    expected_code=ip_frames.ICMP_CODE_PROTO_UNREACH,
                ),
                count=n_triggers,   # upper bound; we assert below
                deadline_ms=deadline_ms,
            )

        count = len(replies)
        assert count <= ICMP_ERR_BURST, (
            f"rate limiter is broken: got {count} errors for "
            f"{n_triggers} triggers, expected at most {ICMP_ERR_BURST}"
        )
        # Minimum sanity: we should see most of the bucket drained.
        # Tolerate up to 2 L2 drops out of 20 sent.
        assert count >= ICMP_ERR_BURST - 2, (
            f"expected ~{ICMP_ERR_BURST} errors (token bucket size), "
            f"got {count} — error path may be broken or suffering "
            f"heavy L2 drops"
        )

    def test_bucket_refills_after_window(
        self, refilled_bucket,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Burn the bucket, wait longer than the refill window, then
        send one more trigger and assert a reply arrives.

        Verifies the token bucket isn't one-shot.
        """
        # Burn the bucket with a burst.
        n_burn = 15
        burn_frames = [
            ip_frames.build_ip_frame_with_proto(
                laptop_mac, pi_mac, laptop_ip, PI4_IP,
                protocol=UNKNOWN_IP_PROTOCOL,
                payload=bytes([0xAA]) * 8,
                ip_ident=0x8000 + i,
            )
            for i in range(n_burn)
        ]
        for f in burn_frames:
            wire.send_frame(eth_iface, f)

        # Wait for the burst to drain and the bucket to refill.
        time.sleep(ICMP_ERR_REFILL_SEC + 0.3)

        # Send one more trigger — this should get a reply.
        post_refill_frame = ip_frames.build_ip_frame_with_proto(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            protocol=UNKNOWN_IP_PROTOCOL,
            payload=b"refilled",
            ip_ident=0xBEEF,
        )
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, post_refill_frame)

            # Match only the post-refill reply: we key on the unique
            # embedded IP.id (0xBEEF) to avoid counting late replies
            # from the burn phase.
            def is_our_post_refill_error(data: bytes) -> bool:
                if not _is_icmp_error_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    expected_type=ip_frames.ICMP_DEST_UNREACHABLE,
                    expected_code=ip_frames.ICMP_CODE_PROTO_UNREACH,
                ):
                    return False
                # The embedded original's IP.id must be 0xBEEF.
                embed_start = (eth_frames.ETH_HEADER_LEN
                               + ip_frames.IP_HDR_MIN
                               + ip_frames.ICMP_HDR_LEN)
                if len(data) < embed_start + 28:
                    return False
                embedded = data[embed_start:embed_start + 28]
                try:
                    embedded_ip = ip_frames.parse_ipv4_header(embedded[:20])
                except ValueError:
                    return False
                return embedded_ip["ident"] == 0xBEEF

            reply = wire.wait_for_frame(
                cap, is_our_post_refill_error,
                deadline_ms=deadline_ms,
            )
        assert reply is not None, (
            "no error reply after rate-limit refill — bucket did not "
            "refill or token accounting is broken"
        )


# ==============================================================
# Loop suppression (documented as defensive / currently unreachable)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestIcmpErrorForIcmpError:
    """Observable property: sending an ICMP dest-unreachable to the Pi
    produces no reply at all.

    NOTE: the icmp_send_error "don't send ICMP errors about ICMP
    errors" guard is defensive — its two callers (ip.S protocol
    unreachable, udp.S port unreachable) never invoke it with an ICMP
    original, so the guard code is unreachable from the current L3
    path. This test therefore pins the whole-path observable:
    icmp_handle drops an incoming dest-unreachable (type != echo
    request) silently.
    """

    def test_icmp_dest_unreachable_to_pi_elicits_no_reply(
        self, refilled_bucket,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Craft an ICMP dest-unreachable addressed to the Pi. Assert
        the Pi sends no ICMP reply within 5× the baseline RTT.

        Then send a normal echo request to prove the Pi is still
        alive and the drop was silent, not a hang.
        """
        # Build the original "inner" IP+ICMP as if from the Pi to us,
        # mimicking what the Pi would embed in its own error — this
        # keeps the packet structurally similar to a real router
        # error, just in case the Pi ever tries to parse the embed.
        inner_payload = bytes(8)
        inner_frame = ip_frames.build_icmp_echo_frame(
            pi_mac, laptop_mac, PI4_IP, laptop_ip,
            ident=0, seq=0, payload=inner_payload,
        )
        inner_embed = inner_frame[
            eth_frames.ETH_HEADER_LEN:
            eth_frames.ETH_HEADER_LEN + 28
        ]
        icmp_error = ip_frames.build_icmp_raw(
            ip_frames.ICMP_DEST_UNREACHABLE,
            ip_frames.ICMP_CODE_HOST_UNREACH,
            b"\x00\x00\x00\x00",
            payload=inner_embed,
        )
        ip = ip_frames.build_ipv4_header(
            laptop_ip, PI4_IP,
            protocol=ip_frames.IP_PROTO_ICMP,
            payload_len=len(icmp_error),
        )
        frame = (
            eth_frames.build_eth_header(
                pi_mac, laptop_mac, eth_frames.ETHERTYPE_IPV4
            )
            + ip
            + icmp_error
        )

        silence_ms = int(max(5.0 * rtt_p99_ms, 50.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)

        # Any ICMP from Pi → laptop would falsify the assertion.
        def any_icmp_from_pi(data: bytes) -> bool:
            try:
                eth = eth_frames.parse_eth_header(data)
                if eth["ethertype"] != eth_frames.ETHERTYPE_IPV4:
                    return False
                if eth["src"] != pi_mac:
                    return False
                ip_hdr = ip_frames.parse_ipv4_header(
                    data[eth_frames.ETH_HEADER_LEN:
                         eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN]
                )
                return ip_hdr["protocol"] == ip_frames.IP_PROTO_ICMP
            except (ValueError, OSError):
                return False

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, frame)
            uninvited = wire.wait_for_frame(
                cap, any_icmp_from_pi,
                deadline_ms=silence_ms,
            )
        assert uninvited is None, (
            "Pi replied to an ICMP dest-unreachable sent to it — "
            "loop-suppression / unknown-type-drop behaviour regressed"
        )

        # Prove the Pi is still alive (silent drop, not a hang).
        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x4242, seq=1, payload=b"alive?",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert reply is not None, (
            "Pi did not reply to a normal echo after being sent an "
            "ICMP dest-unreachable — it may be hung"
        )


# ==============================================================
# Post-flood echo sanity
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestEchoStillWorksAfterFlood:
    """Flooding the error path must not block the normal echo path.

    Drains the bucket with unreachable triggers, then sends a normal
    echo while the bucket is empty (within the same refill window).
    The echo uses ICMP echo reply, not icmp_send_error, so it should
    be unaffected.
    """

    def test_echo_works_with_empty_bucket(
        self, refilled_bucket,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        # Burn the bucket with a burst of unreachable triggers.
        burn_frames = [
            ip_frames.build_ip_frame_with_proto(
                laptop_mac, pi_mac, laptop_ip, PI4_IP,
                protocol=UNKNOWN_IP_PROTOCOL,
                payload=b"burn-bkt",
                ip_ident=0xC000 + i,
            )
            for i in range(15)  # > ICMP_ERR_BURST
        ]
        for f in burn_frames:
            wire.send_frame(eth_iface, f)
        # Tiny pause so the burst drains through the Pi.
        time.sleep(0.05)

        # NOW send an echo — bucket is empty, but icmp_handle does
        # not touch the bucket at all (only icmp_send_error does).
        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0xA5A5, seq=1, payload=b"post-flood",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert reply is not None, (
            "ICMP echo failed after draining the error bucket — "
            "error path is incorrectly blocking the normal path"
        )
        r = parse_reply(reply)
        assert r["icmp"]["ident"] == 0xA5A5
        assert r["icmp"]["payload"] == b"post-flood"
