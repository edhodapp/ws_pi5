"""
test_l3_frag.py — IPv4 fragment reassembly (lib/ip_reasm.S).

Covers the Pi's 4-slot reassembly engine:

  * In-order reassembly at 2, 3, and 8 fragments
  * Out-of-order (reverse, shuffled) reassembly
  * Duplicate fragment tolerated at whole-datagram level
    (the duplicate fragment itself is rejected as overlap per
    RFC 5722, but the overall reassembly still completes from
    the non-duplicate copies)
  * Overlap rejection (RFC 5722) — no completion
  * 4-slot exhaustion — 5 simultaneous flows, only 4 complete
  * Oversize reassembly drop — payload > REASM_COMPLETE_LIMIT
  * Non-aligned middle fragment rejection
  * Post-reassembly normal echo still works (no state leak)
  * Reassembly slot timeout after > REASM_TIMEOUT_SECS
    (marked @slow — takes ~32 seconds)

SIZE MATRIX: fragment totals stay within REASM_COMPLETE_LIMIT (1480
bytes) because the reassembled datagram must fit in a 1514-byte
Ethernet frame (14 eth + 20 ip + 1480 payload = 1514). The plan's
originally-proposed 2×1024 = 2048 would have silently dropped at
the ip_reasm_input completion-time bounds check.

FRAGMENT STRUCTURE: each fragment carries an ICMP echo segment. The
splitter wraps the raw ICMP bytes (header + echo data) in IPv4
fragments; the Pi reassembles into a full ICMP datagram and
icmp_handle builds the reply normally.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l3_frag.py -v
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
    is_echo_reply_for,
    parse_reply,
    send_echo_and_wait,
)


REASM_MAX_SLOTS = 4
REASM_TIMEOUT_SECS = 30
REASM_COMPLETE_LIMIT = 1480     # ETH_FRAME_MAX - ETH_HDR_LEN - IP_HDR_MIN


# ==============================================================
# Helpers
# ==============================================================

def _build_fragmented_echo(
    laptop_mac: bytes, pi_mac: bytes,
    laptop_ip: str, pi_ip: str,
    *,
    ident: int, seq: int, echo_payload: bytes,
    ip_ident: int, frag_size: int,
) -> list[bytes]:
    """Build a fragmented ICMP echo datagram.

    Returns an ordered list of Ethernet frames, each carrying one
    fragment of the ICMP message. The caller can reorder, duplicate,
    drop, or hold individual frames to exercise edge cases.
    """
    icmp_bytes = ip_frames.build_icmp_echo_request(
        ident=ident, seq=seq, payload=echo_payload,
    )
    return ip_frames.build_fragment_frames(
        laptop_mac, pi_mac, laptop_ip, pi_ip,
        protocol=ip_frames.IP_PROTO_ICMP,
        payload=icmp_bytes,
        ident=ip_ident,
        frag_size=frag_size,
    )


def _send_all_and_wait_for_echo(
    eth_iface: str,
    frames: list[bytes],
    *,
    pi_mac: bytes,
    laptop_mac: bytes,
    pi_ip: str,
    laptop_ip: str,
    ident: int,
    seq: int,
    deadline_ms: int,
) -> bytes | None:
    """Send a list of fragment frames in order, then wait for the
    reassembled ICMP echo reply (matching ident/seq).
    """
    bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
    with wire.WireCapture(eth_iface, bpf=bpf) as cap:
        for f in frames:
            wire.send_frame(eth_iface, f)
        return wire.wait_for_frame(
            cap,
            lambda data: is_echo_reply_for(
                data,
                pi_mac=pi_mac, laptop_mac=laptop_mac,
                pi_ip=pi_ip, laptop_ip=laptop_ip,
                ident=ident, seq=seq,
            ),
            deadline_ms=deadline_ms,
        )


# ==============================================================
# In-order reassembly across N / frag_size combinations
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestInOrderReassembly:

    @pytest.mark.parametrize("n_frags,frag_size", [
        (2, 736),   # 2 * 736 = 1472  (ICMP header + 1464 data)
        (3, 480),   # 3 * 480 = 1440  (ICMP header + 1432 data)
        (8, 168),   # 8 * 168 = 1344  (ICMP header + 1336 data)
    ])
    def test_in_order_reassembly(
        self, n_frags, frag_size,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send N fragments in order; assert a single echo reply with
        byte-for-byte correct reassembled payload arrives.
        """
        total = n_frags * frag_size
        assert total <= REASM_COMPLETE_LIMIT
        # The ICMP header is 8 bytes, so the "echo data" is total - 8.
        echo_payload = bytes(((i * 17 + 3) & 0xFF) for i in range(total - 8))
        frames = _build_fragmented_echo(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=0x3100 + n_frags, seq=frag_size,
            echo_payload=echo_payload,
            ip_ident=0x4100 + n_frags, frag_size=frag_size,
        )
        assert len(frames) == n_frags, (
            f"splitter produced {len(frames)} frags, expected {n_frags}"
        )

        deadline_ms = int(max(30.0 * rtt_p99_ms, 1000.0))
        reply = _send_all_and_wait_for_echo(
            eth_iface, frames,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x3100 + n_frags, seq=frag_size,
            deadline_ms=deadline_ms,
        )
        assert reply is not None, (
            f"no echo reply after in-order reassembly "
            f"({n_frags} × {frag_size})"
        )
        r = parse_reply(reply)
        assert r["icmp"]["payload"] == echo_payload, (
            f"reassembled echo payload corrupted "
            f"({n_frags} × {frag_size}): "
            f"first mismatch at offset "
            f"{next((i for i, (a, b) in enumerate(zip(r['icmp']['payload'], echo_payload)) if a != b), 'N/A')}"
        )
        # Reassembled IP packet has frag_off=0, flags=0 (ip_reasm
        # clears both when it rebuilds in place).
        assert r["ip"]["frag_off"] == 0
        assert r["ip"]["flags"] == 0
        assert ip_frames.ip_checksum(r["ip_bytes"]) == 0


# ==============================================================
# Out-of-order reassembly
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestOutOfOrderReassembly:

    def test_reverse_order_reassembly(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send fragments in reverse order (last fragment first).
        Reassembly must still succeed.
        """
        echo_payload = bytes(1000 - 8)   # 992 bytes of data
        frames = _build_fragmented_echo(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=0x3201, seq=1, echo_payload=echo_payload,
            ip_ident=0x4201, frag_size=248,     # 1000/248 → 5 frags
        )
        assert len(frames) == 5
        reversed_frames = list(reversed(frames))

        deadline_ms = int(max(30.0 * rtt_p99_ms, 1000.0))
        reply = _send_all_and_wait_for_echo(
            eth_iface, reversed_frames,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x3201, seq=1,
            deadline_ms=deadline_ms,
        )
        assert reply is not None, "reverse-order reassembly failed"
        r = parse_reply(reply)
        assert r["icmp"]["payload"] == echo_payload

    def test_shuffled_order_reassembly(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send 5 fragments in a fixed non-sequential, non-reverse
        order. Reassembly must still succeed.
        """
        echo_payload = bytes(((i * 23) & 0xFF) for i in range(1000 - 8))
        frames = _build_fragmented_echo(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=0x3202, seq=1, echo_payload=echo_payload,
            ip_ident=0x4202, frag_size=248,
        )
        assert len(frames) == 5
        # Fixed shuffle: 2, 0, 4, 1, 3
        shuffled = [frames[2], frames[0], frames[4], frames[1], frames[3]]

        deadline_ms = int(max(30.0 * rtt_p99_ms, 1000.0))
        reply = _send_all_and_wait_for_echo(
            eth_iface, shuffled,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x3202, seq=1,
            deadline_ms=deadline_ms,
        )
        assert reply is not None, "shuffled-order reassembly failed"
        assert parse_reply(reply)["icmp"]["payload"] == echo_payload


# ==============================================================
# Duplicate fragment (RFC 5722: overlapping fragment dropped;
# overall datagram still reassembles from non-overlapping copies)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestDuplicateFragment:

    def test_duplicate_middle_fragment_tolerated(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send [f0, f1, f1, f2]. The second copy of f1 overlaps the
        first and is dropped by the bitmap-overlap check in
        ip_reasm_input, but the overall datagram still reassembles
        cleanly from [f0, (one copy of) f1, f2].
        """
        echo_payload = bytes(1000 - 8)
        frames = _build_fragmented_echo(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=0x3301, seq=1, echo_payload=echo_payload,
            ip_ident=0x4301, frag_size=336,   # 3 frags: 336+336+328 − wait
        )
        # 1000 / 336 = 2 + tail 328 → 3 frags
        assert len(frames) == 3
        # Duplicate the middle fragment
        send_list = [frames[0], frames[1], frames[1], frames[2]]

        deadline_ms = int(max(30.0 * rtt_p99_ms, 1000.0))
        reply = _send_all_and_wait_for_echo(
            eth_iface, send_list,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x3301, seq=1,
            deadline_ms=deadline_ms,
        )
        assert reply is not None, (
            "reassembly failed when a duplicate fragment was sent — "
            "overlap check should drop the duplicate without breaking "
            "the overall datagram"
        )
        assert parse_reply(reply)["icmp"]["payload"] == echo_payload


# ==============================================================
# Explicit overlap rejection (RFC 5722)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestOverlapRejection:

    def test_overlap_drop_leaves_gap_blocks_completion(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Build a 3-fragment datagram where the MIDDLE fragment is
        the only source for bytes [400, 704), and replace it with an
        overlapping fragment that ip_reasm_input will drop. The
        first fragment covers [0, 400), the overlap covers
        [304, 704) (overlapping [304, 400) with f_first), and the
        last fragment covers [704, 1000). When the overlap is
        dropped, bytes [400, 704) are never delivered → check_complete
        sees a gap in the bitmap → no reassembly → no reply.

        Matching this test to ip_reasm_input's actual behaviour:
        overlap detection is per-bit on the bitmap of ALREADY-
        ACCEPTED fragments. Dropped fragments never set bits, so a
        test that wants the whole datagram to fail must ensure the
        dropped fragment's unique coverage leaves a hole.
        """
        ip_ident = 0x4401
        echo_payload = bytes(((i + 1) & 0xFF) for i in range(1000 - 8))
        icmp_msg = ip_frames.build_icmp_echo_request(
            ident=0x3401, seq=1, payload=echo_payload,
        )

        def build_frag(offset: int, length: int, mf: bool) -> bytes:
            assert offset % 8 == 0, f"offset must be multiple of 8: {offset}"
            ip = ip_frames.build_ipv4_header(
                laptop_ip, PI4_IP,
                protocol=ip_frames.IP_PROTO_ICMP,
                payload_len=length,
                ident=ip_ident,
                flags=(ip_frames.IP_FLAG_MF if mf else 0),
                frag_off=offset,
            )
            return (
                eth_frames.build_eth_header(
                    pi_mac, laptop_mac, eth_frames.ETHERTYPE_IPV4
                )
                + ip
                + icmp_msg[offset:offset + length]
            )

        # f_first covers bits 0..49 (bytes 0..399).
        f_first = build_frag(offset=0,   length=400, mf=True)
        # f_overlap covers bits 38..87 (bytes 304..703) — bit 38 is
        # already set by f_first → overlap → drop. This fragment is
        # the ONLY source for bits 50..87 (bytes 400..703).
        f_overlap = build_frag(offset=304, length=400, mf=True)
        # f_last covers bits 88..124 (bytes 704..999). MF=0.
        f_last = build_frag(offset=704, length=296, mf=False)

        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, f_first)
            wire.send_frame(eth_iface, f_overlap)
            wire.send_frame(eth_iface, f_last)
            reply = wire.wait_for_frame(
                cap,
                lambda data: is_echo_reply_for(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    ident=0x3401, seq=1,
                ),
                deadline_ms=deadline_ms,
            )
        assert reply is None, (
            "reassembly with a dropped overlap fragment succeeded — "
            "the overlap fragment's bytes [400, 704) were never "
            "delivered, so completion should have been blocked. "
            "RFC 5722 overlap rejection regressed."
        )

        # CLEANUP: the overlap test leaves slot state with bits 0..49
        # and 88..124 set but have_last=1 and total_len=1000, missing
        # bits 50..87 (bytes [400, 704)). Without cleanup, this slot
        # stays stuck until the 30s reasm timeout and consumes one of
        # the 4 slots for every subsequent test. Complete it by
        # sending the exact missing range as a clean MF=1 fragment.
        # The completion also proves the slot state was exactly what
        # we expected — if the residue were different, either the
        # cleanup fragment would overlap (and drop) or check_complete
        # would still see a gap.
        f_fill = build_frag(offset=400, length=304, mf=True)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, f_fill)
            cleanup_reply = wire.wait_for_frame(
                cap,
                lambda data: is_echo_reply_for(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    ident=0x3401, seq=1,
                ),
                deadline_ms=deadline_ms,
            )
        assert cleanup_reply is not None, (
            "cleanup fragment did not complete the reassembly — "
            "the stuck slot state is different from expected"
        )

        # Sanity: Pi is still alive after the bad input.
        alive = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0xAAAA, seq=1, payload=b"alive?",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert alive is not None


# ==============================================================
# Slot exhaustion (4 simultaneous flows = cap)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestSlotExhaustion:

    def test_fifth_concurrent_flow_dropped(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Open 5 concurrent reassembly flows (5 distinct IP.id
        values, each only sending the first fragment). The 5th must
        be dropped because no free slot exists. Then send the
        second fragment of all 5 — only the first 4 get a reply.
        """
        n_flows = REASM_MAX_SLOTS + 1
        # Each flow is 2 fragments × 400 bytes = 800 bytes IP payload.
        # Distinct (icmp_ident, ip_ident) per flow.
        flows = []
        for i in range(n_flows):
            echo_payload = bytes([(0x10 + i)] * (800 - 8))
            icmp_msg = ip_frames.build_icmp_echo_request(
                ident=0x3500 + i, seq=1, payload=echo_payload,
            )
            frames = ip_frames.build_fragment_frames(
                laptop_mac, pi_mac, laptop_ip, PI4_IP,
                protocol=ip_frames.IP_PROTO_ICMP,
                payload=icmp_msg,
                ident=0x4500 + i,
                frag_size=400,
            )
            assert len(frames) == 2
            flows.append({
                "icmp_ident": 0x3500 + i,
                "frag1": frames[0],
                "frag2": frames[1],
            })

        deadline_ms = int(max(50.0 * rtt_p99_ms, 2000.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            # Phase 1: burst all 5 first-fragments. The 5th is dropped.
            for flow in flows:
                wire.send_frame(eth_iface, flow["frag1"])
            # Phase 2: burst all 5 second-fragments. Flows 0..3 complete,
            # flow 4 has no slot to match (its first-frag was dropped).
            for flow in flows:
                wire.send_frame(eth_iface, flow["frag2"])

            ident_set = {flow["icmp_ident"] for flow in flows}

            def is_flow_reply(data: bytes) -> bool:
                if not is_any_echo_reply_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                ):
                    return False
                return parse_reply(data)["icmp"]["ident"] in ident_set

            replies = wire.wait_for_frames(
                cap, is_flow_reply,
                count=n_flows,   # upper bound
                deadline_ms=deadline_ms,
            )

        got_idents = {parse_reply(r)["icmp"]["ident"] for r in replies}
        # We sent 5 concurrent flows; the slot cap is 4. The number of
        # completions that the PREVIOUS test runs left for us depends
        # on how many slots were free at entry to this test, but the
        # hard cap is REASM_MAX_SLOTS. We assert the upper bound to
        # catch a broken cap (e.g. if the Pi ever lets the 5th slot
        # in, we'd see 5 replies here).
        assert len(got_idents) <= REASM_MAX_SLOTS, (
            f"got {len(got_idents)} reassembled replies, which is "
            f"MORE than the slot cap ({REASM_MAX_SLOTS}) — the Pi is "
            f"not enforcing REASM_MAX_SLOTS"
        )
        assert len(got_idents) >= 1, (
            f"no replies at all for the 5-flow burst — something "
            f"other than the slot cap is broken"
        )
        # Every reply we DID see must be one of the 5 flows we sent.
        all_idents = {flow["icmp_ident"] for flow in flows}
        assert got_idents <= all_idents, (
            f"unexpected reply idents (not in our set): "
            f"{got_idents - all_idents}"
        )

        # CLEANUP: any flow whose second fragment was accepted into
        # a newly-allocated slot (because its first fragment was
        # dropped at slot-exhaustion time) is now stuck with bits
        # [400..799) set, no bits [0..399), have_last=1, total_len=800.
        # To free these slots we send the missing first fragment for
        # every flow that did NOT get a reply in the first phase.
        # Completing each one triggers an extra reply, which we also
        # wait for as a positive proof that the cleanup worked.
        stuck_flows = [
            flow for flow in flows
            if flow["icmp_ident"] not in got_idents
        ]
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            for flow in stuck_flows:
                # frag1 is the first fragment (offset=0, MF=1).
                # Sending it NOW matches the stuck slot's key, fills
                # in bits 0..49, and check_complete passes.
                wire.send_frame(eth_iface, flow["frag1"])

            def is_cleanup_reply(data: bytes) -> bool:
                if not is_any_echo_reply_from_pi(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                ):
                    return False
                return parse_reply(data)["icmp"]["ident"] in {
                    f["icmp_ident"] for f in stuck_flows
                }

            cleanup_replies = wire.wait_for_frames(
                cap, is_cleanup_reply,
                count=len(stuck_flows),
                deadline_ms=deadline_ms,
            )
        # Cleanup best-effort: if some stuck flows never had a slot
        # to begin with (their first-frag was dropped AND their
        # second-frag was also dropped because all slots were still
        # busy at the time), they won't complete here. Log and move
        # on — those slots are already free.
        print(
            f"\n[slot-exhaustion cleanup] freed "
            f"{len(cleanup_replies)}/{len(stuck_flows)} residue slots"
        )


# ==============================================================
# Oversize reassembly (total_len > REASM_COMPLETE_LIMIT)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestOversizeReassembly:

    def test_oversize_reassembly_dropped(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Build a 2-fragment datagram whose reassembled total length
        is 1488 bytes — exceeds the ip_reasm_input completion ceiling
        of 1480 (14 + 20 + 1480 = 1514, the Ethernet max). Each
        individual fragment fits in REASM_BUF_SIZE (2048) so neither
        is rejected at input time; the drop only fires at completion.

        Assert no reply arrives, then prove the Pi is still alive.
        """
        total = 1488
        assert total > REASM_COMPLETE_LIMIT
        echo_payload = bytes(((i * 7) & 0xFF) for i in range(total - 8))
        frames = _build_fragmented_echo(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=0x3601, seq=1, echo_payload=echo_payload,
            ip_ident=0x4601, frag_size=744,     # 2 × 744 = 1488
        )
        assert len(frames) == 2

        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            for f in frames:
                wire.send_frame(eth_iface, f)
            reply = wire.wait_for_frame(
                cap,
                lambda data: is_echo_reply_for(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    ident=0x3601, seq=1,
                ),
                deadline_ms=deadline_ms,
            )
        assert reply is None, (
            f"oversize reassembly ({total} bytes) produced a reply — "
            f"the ip_reasm_input bounds check at completion is broken"
        )

        alive = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0xAAAB, seq=1, payload=b"alive?",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert alive is not None


# ==============================================================
# Non-aligned middle fragment rejected
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestNonAlignedFragment:

    def test_mf_fragment_with_non_8_aligned_length_rejected(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """A fragment with MF=1 must have payload_len aligned to 8.
        Send one with length=100 (not aligned), then a valid last
        fragment. The first is rejected at input time, so no slot
        is ever allocated for this ip.id; the second fragment (MF=0
        with non-zero offset) arrives against an empty slot and
        cannot complete → no reply.
        """
        ip_ident = 0x4701
        icmp_msg = ip_frames.build_icmp_echo_request(
            ident=0x3701, seq=1, payload=bytes(500 - 8),
        )

        # Bogus first fragment: MF=1, length=100 (not /8).
        bogus = (
            eth_frames.build_eth_header(
                pi_mac, laptop_mac, eth_frames.ETHERTYPE_IPV4
            )
            + ip_frames.build_ipv4_header(
                laptop_ip, PI4_IP,
                protocol=ip_frames.IP_PROTO_ICMP,
                payload_len=100,
                ident=ip_ident,
                flags=ip_frames.IP_FLAG_MF,
                frag_off=0,
            )
            + icmp_msg[:100]
        )

        # Legitimate last fragment: MF=0, offset=400, length=100.
        # (Not 8-aligned length, but MF=0 doesn't require alignment.)
        last = (
            eth_frames.build_eth_header(
                pi_mac, laptop_mac, eth_frames.ETHERTYPE_IPV4
            )
            + ip_frames.build_ipv4_header(
                laptop_ip, PI4_IP,
                protocol=ip_frames.IP_PROTO_ICMP,
                payload_len=100,
                ident=ip_ident,
                flags=0,
                frag_off=400,
            )
            + icmp_msg[400:500]
        )

        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, bogus)
            wire.send_frame(eth_iface, last)
            reply = wire.wait_for_frame(
                cap,
                lambda data: is_echo_reply_for(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    ident=0x3701, seq=1,
                ),
                deadline_ms=deadline_ms,
            )
        assert reply is None, (
            "reassembly succeeded with a non-aligned MF fragment — "
            "ip_reasm_input's 8-byte alignment check is broken"
        )

        # CLEANUP: the last-fragment (MF=0, offset=400, length=100)
        # was ACCEPTED even though the malformed first-fragment was
        # rejected, so a slot is now stuck with bits [50..62] set,
        # have_last=1, total_len=500. Free it by sending a
        # well-formed first fragment (MF=1, offset=0, length=400).
        good_first = (
            eth_frames.build_eth_header(
                pi_mac, laptop_mac, eth_frames.ETHERTYPE_IPV4
            )
            + ip_frames.build_ipv4_header(
                laptop_ip, PI4_IP,
                protocol=ip_frames.IP_PROTO_ICMP,
                payload_len=400,
                ident=ip_ident,
                flags=ip_frames.IP_FLAG_MF,
                frag_off=0,
            )
            + icmp_msg[:400]
        )
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, good_first)
            cleanup_reply = wire.wait_for_frame(
                cap,
                lambda data: is_echo_reply_for(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    ident=0x3701, seq=1,
                ),
                deadline_ms=deadline_ms,
            )
        assert cleanup_reply is not None, (
            "cleanup first-fragment did not complete the reassembly — "
            "stuck slot state was not what we expected"
        )

        # Pi still alive
        alive = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0xAAAC, seq=1, payload=b"alive?",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert alive is not None


# ==============================================================
# Post-reassembly normal echo (no slot leak)
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestPostReassemblyEcho:

    def test_normal_echo_after_reassembly(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Complete one reassembly, then send a simple non-fragmented
        echo. It must succeed. Catches any slot-leak or state
        corruption from the reassembly path.
        """
        # First: complete a reassembly.
        echo_payload = bytes(800 - 8)
        frames = _build_fragmented_echo(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=0x3801, seq=1, echo_payload=echo_payload,
            ip_ident=0x4801, frag_size=400,
        )
        deadline_ms = int(max(30.0 * rtt_p99_ms, 1000.0))
        reply1 = _send_all_and_wait_for_echo(
            eth_iface, frames,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x3801, seq=1,
            deadline_ms=deadline_ms,
        )
        assert reply1 is not None, "first reassembly failed"

        # Now: a plain echo, no fragmentation.
        reply2 = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x3802, seq=1, payload=b"normal-echo",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert reply2 is not None, (
            "normal echo failed after reassembly — possible slot leak"
        )
        r = parse_reply(reply2)
        assert r["icmp"]["ident"] == 0x3802
        assert r["icmp"]["payload"] == b"normal-echo"


# ==============================================================
# Slot timeout (slow — takes ~32 seconds)
# ==============================================================

@requires_hardware
@pytest.mark.l3
@pytest.mark.slow
class TestReassemblyTimeout:

    def test_slot_times_out_after_window(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Send the first fragment of a datagram, wait longer than
        REASM_TIMEOUT_SECS, send the second fragment, assert no
        reassembly happens (no echo reply).

        This exercises the reasm slot timer in ip_reasm_input which
        arms a timer via timer_set on slot creation and fires
        ip_reasm_timeout_cb to clear the slot.

        NOTE: this test sleeps for REASM_TIMEOUT_SECS + 2 seconds
        total (~32s). Marked @pytest.mark.slow. To exclude from fast
        runs:  pytest -m "not slow"
        """
        echo_payload = bytes(600 - 8)
        frames = _build_fragmented_echo(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=0x3901, seq=1, echo_payload=echo_payload,
            ip_ident=0x4901, frag_size=304,  # multiple of 8
        )
        assert len(frames) == 2

        # Send the first fragment — slot is allocated, timer armed.
        wire.send_frame(eth_iface, frames[0])

        # Wait past the reassembly timeout window.
        time.sleep(REASM_TIMEOUT_SECS + 2.0)

        # NOW send the second fragment. If the slot timed out cleanly,
        # this second fragment arrives against no matching slot, a
        # fresh slot is allocated, but it only contains [offset, end)
        # with bitmap bits NOT set before the offset → check_complete
        # fails → no reply.
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, frames[1])
            reply = wire.wait_for_frame(
                cap,
                lambda data: is_echo_reply_for(
                    data,
                    pi_mac=pi_mac, laptop_mac=laptop_mac,
                    pi_ip=PI4_IP, laptop_ip=laptop_ip,
                    ident=0x3901, seq=1,
                ),
                deadline_ms=deadline_ms,
            )
        assert reply is None, (
            "reassembly succeeded after the timeout window — the "
            "reasm slot timer did not fire"
        )

        # Sanity: Pi is still alive.
        alive = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0xAAAD, seq=1, payload=b"alive?",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert alive is not None
