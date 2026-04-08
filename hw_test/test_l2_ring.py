"""
test_l2_ring.py — GENET descriptor ring wraparound exercises.

Bursts ARP requests at the Pi at boundary multiples of the 256-entry
RX descriptor ring and asserts:

  1. The Pi replies to all of the burst (lossless).
  2. The Pi remains responsive after the burst (post-burst probe gets
     a reply within normal RTT).

Uses RawL2Socket for both send and recv. WireCapture's per-poll pcap
re-open is too slow at high frame rates and was over-reporting loss
in the first iteration of this file (the framework was lying about
the Pi). RawL2Socket reads directly from a single AF_PACKET socket
with no parser in the hot path.

Parametrizes across [1, 50, 255, 256, 257, 512, 1024]:
  * 1, 50: sanity baselines
  * 255: one below the RX ring wrap
  * 256: exactly at the wrap
  * 257: one wrap
  * 512: two full cycles
  * 1024: four full cycles

Reproduces the GENET ARP burst loss anomaly tracked in
project_genet_arp_burst_loss.md (memory) when present. When the
GENET fix lands, this test should go all-green without any threshold
relaxation.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l2_ring.py -v
"""

import time

import pytest

import eth_frames
import wire
from conftest import requires_hardware, PI4_IP


# Boundaries around the 256-entry GENET RX ring.
RING_BURST_SIZES = [1, 50, 255, 256, 257, 512, 1024]

# How long to wait after the last send before declaring "no more
# replies are coming." Tuned generously: at the highest burst the Pi
# may need 100s of ms to drain its TX queue.
REPLY_QUIESCE_MS = 500

# Settle delay between tests so each parametrized run gets a clean
# Pi state. Without this, leftover state from a previous large-burst
# test contaminates the next test's measurement.
PRE_TEST_QUIESCE_MS = 100


@requires_hardware
@pytest.mark.l2
class TestRingWraparound:

    @pytest.mark.parametrize("n", RING_BURST_SIZES)
    def test_burst_n_arp_replies_received(
        self, n, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Send `n` ARP requests as a tight burst, count replies.

        ASSERTION: every request gets a reply. Zero loss.

        Currently FAILS at n >= ~444 due to the GENET ARP burst loss
        anomaly tracked in project_genet_arp_burst_loss.md. When the
        kernel-side fix lands, the assertion stays the same and the
        test should turn green.
        """
        time.sleep(PRE_TEST_QUIESCE_MS / 1000.0)

        request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
        burst = [request] * n
        expected_pi_mac = pi_mac
        expected_pi_ip = PI4_IP

        def is_target_reply(frame: bytes) -> bool:
            try:
                arp = eth_frames.parse_arp(frame)
            except (ValueError, OSError):
                return False
            return (
                arp["opcode"] == eth_frames.ARP_OP_REPLY
                and arp["sha"] == expected_pi_mac
                and arp["spa"] == expected_pi_ip
            )

        with wire.RawL2Socket(eth_iface) as sock:
            sock.drain()  # discard any pre-test stragglers

            # Tight send loop. RawL2Socket.send is one syscall per
            # frame; AF_PACKET batches under the hood.
            t0 = time.monotonic()
            for frame in burst:
                sock.send(frame)
            send_done = time.monotonic()

            # Drain replies until we see no more for REPLY_QUIESCE_MS.
            replies: list[bytes] = []
            while True:
                reply = sock.recv(
                    timeout_ms=REPLY_QUIESCE_MS,
                    predicate=is_target_reply,
                )
                if reply is None:
                    break
                replies.append(reply)
                if len(replies) >= n:
                    # Got everything; no need to wait further
                    break
            recv_done = time.monotonic()

        send_ms = (send_done - t0) * 1000.0
        total_ms = (recv_done - t0) * 1000.0

        # Lossless assertion. When the GENET burst-loss bug is fixed,
        # this stays green; until then it surfaces the count clearly.
        assert len(replies) == n, (
            f"GENET ARP burst loss: got {len(replies)}/{n} replies "
            f"(send_time={send_ms:.1f}ms total={total_ms:.1f}ms). "
            f"See project_genet_arp_burst_loss.md."
        )

        # Spot-check the first and last replies for well-formedness.
        # All-frames validation in a 1024-entry list is wasteful and
        # repeats what eth_frames.parse_arp already did inside the
        # predicate. Two boundary checks are enough to catch any
        # lurking field-ordering bug.
        for i in (0, len(replies) - 1):
            arp = eth_frames.parse_arp(replies[i])
            assert arp["opcode"] == eth_frames.ARP_OP_REPLY
            assert arp["sha"] == pi_mac
            assert arp["spa"] == PI4_IP
            assert arp["tha"] == laptop_mac
            assert arp["tpa"] == laptop_ip

    @pytest.mark.parametrize("n", RING_BURST_SIZES)
    def test_pi_responsive_after_burst(
        self, n, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """After an n-frame burst, the Pi answers a fresh probe within
        normal RTT — proving the GENET driver state (and the
        descriptor rings) recovered cleanly.

        Run as a separate test from the burst-counting one so the
        report distinguishes "burst lost some frames" from "Pi was
        permanently bricked by the burst." This is the more important
        of the two: lossless replies under blast load is a stretch
        goal; surviving the blast and resuming service is mandatory.
        """
        time.sleep(PRE_TEST_QUIESCE_MS / 1000.0)

        request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
        burst = [request] * n

        with wire.RawL2Socket(eth_iface) as sock:
            sock.drain()
            for frame in burst:
                sock.send(frame)
            # Don't bother counting burst replies — that's the other
            # test's job. Just drain whatever's queued so we don't
            # confuse the post-burst probe with leftover replies.
            time.sleep(REPLY_QUIESCE_MS / 1000.0)
            sock.drain()

            # Now send ONE fresh probe and assert reply within a
            # generous-but-not-unbounded deadline. 50x baseline RTT
            # absorbs any post-burst settle time on the Pi.
            recovery_deadline_ms = int(max(50.0 * rtt_p99_ms, 1000.0))
            sock.send(request)
            reply = sock.recv(
                timeout_ms=recovery_deadline_ms,
                predicate=lambda f: _is_arp_reply_from(f, pi_mac, PI4_IP),
            )

        assert reply is not None, (
            f"Pi unresponsive after {n}-frame burst — no ARP reply within "
            f"{recovery_deadline_ms} ms"
        )
        arp = eth_frames.parse_arp(reply)
        assert arp["sha"] == pi_mac
        assert arp["spa"] == PI4_IP


# --- Module-private predicate ---

def _is_arp_reply_from(frame: bytes, expected_mac: bytes, expected_ip: str) -> bool:
    try:
        arp = eth_frames.parse_arp(frame)
    except (ValueError, OSError):
        return False
    return (
        arp["opcode"] == eth_frames.ARP_OP_REPLY
        and arp["sha"] == expected_mac
        and arp["spa"] == expected_ip
    )
