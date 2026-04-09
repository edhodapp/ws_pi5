"""
test_l2_rx_errors.py — RX error frame handling.

Kernel side (landed 2026-04-08): `genet_recv` now inspects the lower
5 bits of the descriptor length_status word (DMA_RX_FI_MASK, covering
CRC error, overrun, oversize, truncated, and generic rxer) and drops
any frame with those bits set. The drop path advances the ring state
past the bad descriptor and increments `perf_counters.drop_count`.
Default kernel includes the drop path; the counter is only emitted
to the perf_query reply under PERF_COUNTERS builds.

Test coverage split:

* **test_drop_counter_is_zero_on_clean_traffic** — runs a clean ARP
  burst and asserts `drop_count == 0`. This is a *sanity check* on
  the counter mechanism: it confirms `perf_query` returns the counter
  and that no spurious increments happen on well-formed frames. It
  does NOT exercise the drop path itself, because we can't generate
  bad frames from userspace (see below).

* **test_bad_crc_frame_dropped_silently** and
  **test_length_error_frame_dropped_silently** — still skipped, but
  the skip reason is now "test harness", not "kernel". The kernel
  drop path is implemented and correct by code review; what's
  missing is a way to inject a bad-CRC or length-error frame from
  the laptop side. The r8152 USB gigabit NIC hardware-appends the
  FCS on every transmit and does not expose a userspace mechanism
  to corrupt it. Testing these paths end-to-end would require:

  (a) a specialized server NIC that allows FCS override
      (e.g. Intel X520, Mellanox ConnectX with ethtool --set-priv-flags),
  (b) a managed switch between the laptop and Pi with a "corrupt frame"
      injection feature, or
  (c) a second Pi acting as traffic source with direct DMA writes
      to the descriptor ring (bypassing its own MAC's FCS generation).

  None of these are in the current test bench. When any of them
  becomes available, unskip the two tests and flesh them out.

Tracked as L2 hardening queue item 3:
    ~/.claude/projects/-home-ed-ws-pi5/memory/project_l2_hardening_plan.md
"""

import pytest
import time

import eth_frames
import wire
from conftest import requires_hardware, PI4_IP


BAD_FRAME_SKIP_REASON = (
    "Cannot inject bad-CRC or length-error frames from the r8152 laptop "
    "USB NIC — hardware appends the FCS and userspace can't corrupt it. "
    "Kernel drop path in genet_recv is implemented (see DMA_RX_FI_MASK "
    "branch + PERF_DROP_COUNT), but end-to-end verification needs "
    "specialized hardware. See this file's module docstring."
)


@requires_hardware
@pytest.mark.l2
class TestRxErrors:

    def test_drop_counter_is_zero_on_clean_traffic(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac
    ):
        """A normal ARP burst produces zero HW RX error drops.

        Sanity-checks the perf_query mechanism for drop_count by
        sending a small burst of valid ARP requests and verifying
        the counter remains at 0. A non-zero result would indicate
        either (a) the drop path is firing spuriously on good frames
        — i.e. we misread the DMA_RX_FI_MASK semantics — or (b)
        there are real hardware errors on this cable/NIC pair, which
        would also be valuable to know.

        This test REQUIRES a PERF-instrumented kernel (any PERF
        stage). Without PERF_COUNTERS defined, perf_query returns
        WireError on timeout and we skip.
        """
        # Reset counters before the burst. If the Pi isn't a PERF
        # build, perf_query times out and we can't test.
        try:
            wire.perf_query(
                eth_iface, pi_mac, laptop_mac, reset=True
            )
        except wire.WireError:
            pytest.skip(
                "Pi is not a PERF build — perf_query not available. "
                "Reflash with `make PLATFORM=pi4 PERF=recv` (or all)."
            )

        # Send a small valid ARP burst. 50 is chosen to easily fit
        # in the RX ring without overflow — we specifically don't
        # want rx_discards to fire either, so the test's signal is
        # "drop_count stayed at zero" not "rx_discards stayed at
        # zero" (those are separate counters).
        request = eth_frames.build_arp_request(
            laptop_mac, laptop_ip, PI4_IP
        )
        with wire.RawL2Socket(eth_iface) as sock:
            sock.drain()
            for _ in range(50):
                sock.send(request)
            # Brief quiescence so the Pi finishes processing.
            time.sleep(0.1)

        # Snapshot the counters.
        perf = wire.perf_query(eth_iface, pi_mac, laptop_mac)

        assert perf["drop_count"] == 0, (
            f"drop_count incremented to {perf['drop_count']} during a "
            f"clean 50-frame ARP burst. Either genet_recv's drop path "
            f"is firing spuriously on good frames (misread of "
            f"DMA_RX_FI_MASK semantics?) or there is a real hardware "
            f"issue on this cable/NIC pair."
        )

    @pytest.mark.skip(reason=BAD_FRAME_SKIP_REASON)
    def test_bad_crc_frame_dropped_silently(self):
        """A frame with a deliberately broken FCS is silently dropped
        and the Pi remains responsive.

        When unblocked (see module docstring for the hardware
        required), the test body should:
          * Reset perf counters via perf_query(reset=True)
          * Send one bad-CRC ARP request
          * Send one valid ARP request as a probe
          * Assert exactly one reply (to the valid request)
          * Assert perf_query().drop_count == 1
          * Assert Pi stays responsive to a post-burst probe
        """
        raise NotImplementedError

    @pytest.mark.skip(reason=BAD_FRAME_SKIP_REASON)
    def test_length_error_frame_dropped_silently(self):
        """A frame with a length field shorter than the actual data
        is silently dropped.

        Same shape as test_bad_crc_frame_dropped_silently but with
        a different error bit triggered (DMA_RX_LG or DMA_RX_NO).
        """
        raise NotImplementedError
