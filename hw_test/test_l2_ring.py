# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=unused-import,unused-variable,inconsistent-quotes
# pylint: disable=line-too-long,unused-argument
# mypy: ignore-errors
# flake8: noqa: E501
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

# Extra settle delay before tests with bursts larger than the ring
# (>256). The motivation is the bimodal reply distribution observed
# on repeated runs of N=1024: fast userspace sends (~2ms) give
# ~600 replies, slow sends (~4-5ms) give ~450 replies, with nothing
# in between. Hypothesis: the laptop NIC's AF_PACKET TX buffer / CPU
# scheduler state from the previous run is contaminating the next
# send rate. A longer settle delay before large-burst tests should
# let all of that drain and flatten the bimodality.
LARGE_BURST_SETTLE_MS = 2000


@requires_hardware
@pytest.mark.l2
@pytest.mark.perf
class TestRingWraparound:

    @pytest.mark.parametrize("n", RING_BURST_SIZES)
    def test_burst_n_arp_replies_received(
        self, n, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
        tmp_path,
    ):
        """Send `n` ARP requests as a tight burst, count replies.

        ASSERTION: every request gets a reply. Zero loss.

        Send side uses tcpreplay (PACKET_MMAP) against a pre-built
        pcap to avoid the bimodal send-rate variance seen when doing
        the same job with a Python AF_PACKET send loop on the r8152
        USB NIC. See wire.tcpreplay_send docstring for background.

        Currently FAILS at n >= ~444 due to the GENET ARP burst loss
        anomaly tracked in project_genet_arp_burst_loss.md. When the
        kernel-side fix lands, the assertion stays the same and the
        test should turn green.
        """
        time.sleep(PRE_TEST_QUIESCE_MS / 1000.0)
        if n > 256:
            time.sleep(LARGE_BURST_SETTLE_MS / 1000.0)

        laptop_mac_str = ":".join(f"{b:02x}" for b in laptop_mac)
        expected_pi_mac = pi_mac
        expected_pi_ip = PI4_IP

        # Build the burst pcap once for this test. Done outside the
        # RawL2Socket with-block so the recv socket is open for as
        # short a time as possible before tcpreplay fires (minimising
        # the chance of missing early replies).
        pcap_path = tmp_path / f"arp_burst_{n}.pcap"
        wire.build_arp_pcap(
            pcap_path,
            count=n,
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
                and arp["sha"] == expected_pi_mac
                and arp["spa"] == expected_pi_ip
            )

        # Reset per-stage perf counters BEFORE the burst so the
        # snapshot we take after captures only the work from this
        # burst (plus the snapshot query's own single iteration,
        # which is a ~0.1% accounting error at N=1024). Silently
        # skip if the Pi is running a default (non-PERF) build —
        # perf_query raises WireError on timeout, which means the
        # readout handler was never compiled in.
        perf_reset_ok = False
        try:
            wire.perf_query(
                eth_iface, expected_pi_mac, laptop_mac, reset=True
            )
            perf_reset_ok = True
        except wire.WireError:
            pass

        with wire.RawL2Socket(eth_iface) as sock:
            sock.drain()  # discard any pre-test stragglers

            # Deterministic-rate send via tcpreplay + PACKET_MMAP.
            # --topspeed is "as fast as the NIC will accept"; this
            # matches the original Python-loop test intent but with
            # far lower variance (see tcpreplay_send docstring).
            t0 = time.monotonic()
            result = wire.tcpreplay_send(
                eth_iface, pcap_path, topspeed=True,
            )
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
        wire_pps = result["pps"]

        # Always emit a one-line machine-parseable summary (both on
        # pass and fail) so hw_test/bin/burst_stats.py can collect
        # reply counts / send times for variance analysis regardless
        # of test outcome. Prefixed with BURST_STATS: for grep.
        print(
            f"BURST_STATS: n={n} replies={len(replies)} "
            f"send_ms={send_ms:.1f} wire_pps={wire_pps:.0f} "
            f"total_ms={total_ms:.1f}"
        )

        # Snapshot perf counters AFTER the burst. Only attempted if
        # the pre-burst reset succeeded (indicating the Pi is a
        # PERF build). Emit a second parseable line with raw ticks
        # AND per-stage ns-per-frame derived from Pi 4's 54 MHz
        # CNTVCT_EL0. Either line (BURST_STATS or PERF_STATS) can
        # be absent; burst_stats.py handles both cases.
        if perf_reset_ok:
            try:
                perf = wire.perf_query(
                    eth_iface, expected_pi_mac, laptop_mac
                )
                recv_ns = (
                    wire.perf_ticks_to_ns(perf["recv_ticks"])
                    / max(perf["recv_count"], 1)
                )
                disp_ns = (
                    wire.perf_ticks_to_ns(perf["dispatch_ticks"])
                    / max(perf["dispatch_count"], 1)
                )
                send_ns = (
                    wire.perf_ticks_to_ns(perf["send_ticks"])
                    / max(perf["send_count"], 1)
                )
                print(
                    f"PERF_STATS: n={n} "
                    f"recv_count={perf['recv_count']} "
                    f"recv_none={perf['recv_none']} "
                    f"dispatch_count={perf['dispatch_count']} "
                    f"drop_count={perf['drop_count']} "
                    f"send_count={perf['send_count']} "
                    f"send_fail={perf['send_fail']} "
                    f"max_burst={perf['max_burst']} "
                    f"rx_discards={perf['rx_discards']} "
                    f"recv_ns={recv_ns:.0f} "
                    f"dispatch_ns={disp_ns:.0f} "
                    f"send_ns={send_ns:.0f}"
                )
            except wire.WireError:
                pass

        # Lossless assertion. When the GENET burst-loss bug is fixed,
        # this stays green; until then it surfaces the count clearly.
        assert len(replies) == n, (
            f"GENET ARP burst loss: got {len(replies)}/{n} replies "
            f"(send_time={send_ms:.1f}ms wire={wire_pps:.0f}pps "
            f"total={total_ms:.1f}ms). "
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
