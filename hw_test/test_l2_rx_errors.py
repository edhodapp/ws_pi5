"""
test_l2_rx_errors.py — RX error frame handling.

SKELETON. These tests exercise behaviour that depends on a future
kernel-side change: lib/eth.S / drivers/genet.S need to inspect the
length_status error bits in the RX descriptor and increment a drop
counter for bad frames. Without that, there's nothing testable from
the wire — bad frames just look like silently-dropped frames.

Tracked as L2 hardening queue item 3:
    project_l2_hardening_plan.md (memory)

When the kernel-side handler lands, drop the @pytest.mark.skip and
flesh out the test bodies. The test stubs are here so the report
itself is the TODO list — `pytest -k l2_` will show these as
SKIPPED with the reason linking back to the queue item.
"""

import pytest

from conftest import requires_hardware


SKIP_REASON = (
    "blocked on L2 hardening queue item 3 — RX error frame handling "
    "in genet_recv (drop bad-CRC/length-error frames cleanly, "
    "increment drop counter). See project_l2_hardening_plan.md."
)


@requires_hardware
@pytest.mark.l2
class TestRxErrors:

    @pytest.mark.skip(reason=SKIP_REASON)
    def test_bad_crc_frame_dropped_silently(self):
        """A frame with a deliberately broken FCS is silently dropped
        and the Pi remains responsive.

        TODO once the kernel handler lands:
        - Open WireCapture for replies-from-Pi
        - Send a frame with a forced-bad FCS (depends on USB NIC
          letting us bypass hardware FCS — needs investigation)
        - Assert no Pi response in silence window
        - Assert Pi answers a normal ARP afterwards
        - Read back the new drop counter via UART or via a
          debug-dump endpoint (depends on L2 hardening item 2)
        """
        raise NotImplementedError

    @pytest.mark.skip(reason=SKIP_REASON)
    def test_length_error_frame_dropped_silently(self):
        """A frame with a length field shorter than the actual data
        is silently dropped.

        TODO: same shape as test_bad_crc_frame_dropped_silently but
        with a different error bit triggered.
        """
        raise NotImplementedError

    @pytest.mark.skip(reason=SKIP_REASON)
    def test_drop_counter_increments_on_bad_frame(self):
        """The Pi's RX-drop MIB counter increments when an error
        frame is received.

        TODO: needs the genet_dump_state debug-dump path
        (skeleton in test_l2_dump_state.py).
        """
        raise NotImplementedError
