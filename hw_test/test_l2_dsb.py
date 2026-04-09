"""
test_l2_dsb.py — DSB (Data Synchronization Barrier) + descriptor
ordering integrity tests for the GENET recv/send path.

## What this file exists to pin

The GENET driver in platform/pi/drivers/genet.S uses `dsb sy`
barriers in two places on the hot path:

  1. genet_recv: AFTER the `dc civac` cache-invalidate loop on the
     RX buffer, BEFORE the copy into rx_buf. Ensures the cache
     invalidates are globally observed before we start reading.
     Without this, subsequent loads could pull stale cached bytes
     that the DMA write hadn't yet invalidated in the CPU view.

  2. genet_send: AFTER the `dc civac` flush loop on the TX buffer,
     BEFORE writing the descriptor fields and kicking PROD_INDEX.
     Ensures the dirty cache lines are written back to DRAM BEFORE
     the hardware reads them via DMA, otherwise the HW could see
     partial/stale data.

If either barrier is missing (or demoted to the wrong scope), the
symptoms are intermittent and data-dependent: occasional
byte-corrupted frames, phantom frames that look like fragments of
earlier frames, or truncated replies. These tests make that
contract explicit so a future barrier-weakening attempt can't pass
silently.

## Coverage relationship to other L2 tests

**These tests are intentionally redundant with test_l2_ring.**
test_l2_ring::test_burst_n_arp_replies_received[*] already exercises
the recv + send barrier paths at every interesting ring boundary
and asserts reply counts are correct. If the barriers were missing,
test_l2_ring would flake with garbled or missing replies.

What test_l2_ring does NOT do: assert on **per-frame field
correctness** across an entire burst. It spot-checks the first and
last replies' field contents (test_l2_ring.py:145-151) and leaves
the middle frames unverified — if 500 of 1024 replies had garbled
source MACs but the first and last were fine, test_l2_ring would
pass. That would be a real barrier-ordering bug hidden by the
existing test.

This file closes that gap by asserting EVERY reply's fields in
a smaller, ring-fitting burst. It's a comfort test for the
reviewer who asks "how do we know the DSB barriers are actually
in the right places?" — the answer is "test_l2_dsb asserts it
directly, and test_l2_ring asserts it at scale."

Tracked as L2 hardening queue item 1:
    ~/.claude/projects/-home-ed-ws-pi5/memory/project_l2_hardening_plan.md
"""

import time

import pytest

import eth_frames
import wire
from conftest import requires_hardware, PI4_IP


# Burst size for the integrity test. 256 fits exactly in the
# GENET RX ring (256-entry), so the Pi can drain losslessly and
# we know every reply is expected. Going above the ring would
# introduce HW ring-overflow drops that are unrelated to barrier
# correctness.
INTEGRITY_BURST_SIZE = 256

# Quiescence window for the phantom-frame test. After draining
# the burst, we wait this long for any delayed TX to reach the
# wire, then sweep the socket again. Any frames captured during
# the sweep are phantoms.
PHANTOM_QUIESCE_MS = 500


@requires_hardware
@pytest.mark.l2
class TestDsbBarriers:
    """Make the DSB barrier contract explicit.

    The existing test_l2_ring suite passively exercises the same
    barrier paths, but only spot-checks a few frames per burst.
    These tests assert per-frame integrity across an entire burst
    that fits in the ring, so any barrier-related corruption
    cannot hide in the middle.
    """

    def test_concurrent_burst_integrity_per_frame(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms, tmp_path
    ):
        """Every reply in a ring-sized burst parses cleanly and
        has the expected ARP field values.

        Sends INTEGRITY_BURST_SIZE ARPs via tcpreplay at wire
        rate, collects every reply, and asserts on EACH reply:
          - Parses as a valid Ethernet + ARP frame
          - Ethernet dst == laptop_mac (unicast reply back to us)
          - Ethernet src == pi_mac
          - ARP opcode == REPLY (2)
          - ARP sender HW address (sha) == pi_mac
          - ARP sender protocol address (spa) == PI4_IP
          - ARP target HW address (tha) == laptop_mac
          - ARP target protocol address (tpa) == laptop_ip

        test_l2_ring only spot-checks the first and last reply;
        this test checks all of them. If a DSB barrier were
        missing, a middle reply might have a garbled sha, spa,
        or dst MAC — test_l2_ring wouldn't catch it, this test
        will.
        """
        # Build the burst pcap once (tcpreplay reads from a pcap).
        pcap_path = tmp_path / f"dsb_integrity_{INTEGRITY_BURST_SIZE}.pcap"
        laptop_mac_str = ":".join(f"{b:02x}" for b in laptop_mac)
        wire.build_arp_pcap(
            pcap_path,
            count=INTEGRITY_BURST_SIZE,
            src_mac=laptop_mac_str,
            src_ip=laptop_ip,
            target_ip=PI4_IP,
        )

        def is_target_reply(frame: bytes) -> bool:
            try:
                arp = eth_frames.parse_arp(frame)
            except (ValueError, OSError):
                return False
            return (
                arp["opcode"] == eth_frames.ARP_OP_REPLY
                and arp["sha"] == pi_mac
                and arp["spa"] == PI4_IP
            )

        with wire.RawL2Socket(eth_iface) as sock:
            sock.drain()
            wire.tcpreplay_send(eth_iface, pcap_path, topspeed=True)

            # Collect EVERY reply. For a ring-sized burst we expect
            # exact lossless delivery — if any are missing that's a
            # regression worth investigating (but it's not what this
            # test is specifically for).
            replies: list[bytes] = []
            deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
            while len(replies) < INTEGRITY_BURST_SIZE:
                reply = sock.recv(
                    timeout_ms=deadline_ms,
                    predicate=is_target_reply,
                )
                if reply is None:
                    break
                replies.append(reply)

        # Lossless count assertion — not the main point of this
        # test, but if we don't even get all the replies we can't
        # check their integrity.
        assert len(replies) == INTEGRITY_BURST_SIZE, (
            f"Expected {INTEGRITY_BURST_SIZE} replies (ring-sized "
            f"burst should be 100% lossless), got {len(replies)}. "
            f"test_l2_ring[256] should also be failing; fix that first."
        )

        # Per-frame integrity check. Validate every field of every
        # reply. Any garbled field is a barrier or descriptor-
        # ordering bug.
        for i, reply in enumerate(replies):
            try:
                arp = eth_frames.parse_arp(reply)
            except (ValueError, OSError) as e:
                raise AssertionError(
                    f"Reply {i} failed to parse as ARP: {e}. "
                    f"Raw bytes (first 64): {reply[:64].hex()}. "
                    f"Likely barrier or descriptor-publish ordering bug."
                )

            assert arp["eth_dst"] == laptop_mac, (
                f"Reply {i}: eth_dst {arp['eth_dst'].hex()} "
                f"!= laptop_mac {laptop_mac.hex()}"
            )
            assert arp["eth_src"] == pi_mac, (
                f"Reply {i}: eth_src {arp['eth_src'].hex()} "
                f"!= pi_mac {pi_mac.hex()}"
            )
            assert arp["opcode"] == eth_frames.ARP_OP_REPLY, (
                f"Reply {i}: opcode {arp['opcode']} != REPLY (2)"
            )
            assert arp["sha"] == pi_mac, (
                f"Reply {i}: ARP sha {arp['sha'].hex()} "
                f"!= pi_mac {pi_mac.hex()}"
            )
            assert arp["spa"] == PI4_IP, (
                f"Reply {i}: ARP spa {arp['spa']} != PI4_IP {PI4_IP}"
            )
            assert arp["tha"] == laptop_mac, (
                f"Reply {i}: ARP tha {arp['tha'].hex()} "
                f"!= laptop_mac {laptop_mac.hex()}"
            )
            assert arp["tpa"] == laptop_ip, (
                f"Reply {i}: ARP tpa {arp['tpa']} != laptop_ip {laptop_ip}"
            )

    def test_no_phantom_replies_after_quiescent_period(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms, tmp_path
    ):
        """After a burst is fully drained and we idle, the Pi stops.

        Sends INTEGRITY_BURST_SIZE ARPs, drains every reply, then
        idles for PHANTOM_QUIESCE_MS. Any frames captured during
        the idle sweep are "phantoms" — the Pi sending something
        we didn't ask for, probably because a TX descriptor was
        stranded mid-publish and only got kicked after the burst
        ended, or because a stale descriptor was read from the
        ring after the software thought the ring was empty.

        Both of those scenarios point at descriptor-ordering bugs
        the DSB barriers are there to prevent. Catching a phantom
        frame after a clean burst would be strong evidence that
        one of the barriers is absent or mis-placed.
        """
        pcap_path = tmp_path / f"dsb_phantom_{INTEGRITY_BURST_SIZE}.pcap"
        laptop_mac_str = ":".join(f"{b:02x}" for b in laptop_mac)
        wire.build_arp_pcap(
            pcap_path,
            count=INTEGRITY_BURST_SIZE,
            src_mac=laptop_mac_str,
            src_ip=laptop_ip,
            target_ip=PI4_IP,
        )

        # The phantom we're specifically looking for is a stale
        # ARP reply from the burst — one that the HW published to
        # TX after the software thought the burst had drained.
        # We do NOT count legitimate Pi background traffic (NTP
        # client queries, periodic ARP cache refresh requests)
        # because those aren't stale-descriptor symptoms and fire
        # on their own timers regardless of our burst. Narrow the
        # predicate to "ARP reply from pi_mac with spa == PI4_IP
        # addressed to us" — the exact shape of the burst's
        # expected replies.
        def is_burst_reply(frame: bytes) -> bool:
            try:
                arp = eth_frames.parse_arp(frame)
            except (ValueError, OSError):
                return False
            return (
                arp["opcode"] == eth_frames.ARP_OP_REPLY
                and arp["sha"] == pi_mac
                and arp["spa"] == PI4_IP
                and arp["eth_dst"] == laptop_mac
            )

        with wire.RawL2Socket(eth_iface) as sock:
            sock.drain()

            # Phase 1: send burst and drain all expected replies.
            wire.tcpreplay_send(eth_iface, pcap_path, topspeed=True)
            drained = 0
            deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
            while drained < INTEGRITY_BURST_SIZE:
                reply = sock.recv(
                    timeout_ms=deadline_ms,
                    predicate=is_burst_reply,
                )
                if reply is None:
                    break
                drained += 1
            assert drained == INTEGRITY_BURST_SIZE, (
                f"Expected {INTEGRITY_BURST_SIZE} drained replies "
                f"(ring-sized burst), got {drained}"
            )

            # Phase 2: idle the socket and the Pi. Legitimate
            # background traffic from the Pi (NTP, ARP refresh)
            # WILL fire during this window in longer-running test
            # sessions; that's fine — we're only looking for late
            # burst-shaped ARP replies, not any Pi traffic.
            time.sleep(PHANTOM_QUIESCE_MS / 1000.0)

            # Phase 3: sweep for phantom ARP replies. Any reply
            # captured here matches the burst's shape, meaning the
            # Pi sent an ARP reply for a request that was already
            # counted as drained — a stale descriptor publish, the
            # exact bug the DSB barriers prevent.
            phantoms: list[bytes] = []
            while True:
                frame = sock.recv(
                    timeout_ms=10,  # short — just drain what's buffered
                    predicate=is_burst_reply,
                )
                if frame is None:
                    break
                phantoms.append(frame)

        assert len(phantoms) == 0, (
            f"Pi sent {len(phantoms)} phantom ARP reply frame(s) after "
            f"a clean burst + {PHANTOM_QUIESCE_MS}ms quiesce window. "
            f"First phantom raw: "
            f"{phantoms[0][:64].hex() if phantoms else 'n/a'}. "
            f"Possible descriptor-publish ordering bug — stale TX "
            f"descriptor being published after the software thought "
            f"the burst had drained (missing or mis-placed DSB "
            f"barrier in genet_send)."
        )
