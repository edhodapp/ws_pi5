"""
test_l2_dump_state.py — read-back of GENET register state via the
kernel-side debug-dump path.

SKELETON. These tests would exercise the `genet_dump_state` function
that needs to be added to drivers/genet.S — a read-only register dump
covering RDMA/TDMA CTRL+STATUS, PROD/CONS indices, UMAC_CMD,
UMAC_TX_FIFO_STATUS, UMAC_RX_FIFO_STATUS, and the TX/RX MIB counters
(good, dropped, error). Without this, there is no externally
observable kernel-side state for L2 tests to assert on beyond the
wire — counters can drift silently and we'd never know.

Open questions for the kernel side:
  * How does the dump get back to the test driver? Options:
    (a) printed over UART, parseable from /dev/ttyUSB0
    (b) written into a magic memory window readable via JTAG
    (c) returned as the body of an HTTP GET to a debug endpoint

Tracked as L2 hardening queue item 2:
    project_l2_hardening_plan.md (memory)
"""

import pytest

from conftest import requires_hardware


SKIP_REASON = (
    "blocked on L2 hardening queue item 2 — genet_dump_state debug "
    "register dump function. Needs implementation in "
    "drivers/genet.S plus a transport for getting the dump back to "
    "the test driver (UART parser? HTTP debug endpoint?). See "
    "project_l2_hardening_plan.md."
)


@requires_hardware
@pytest.mark.l2
class TestGenetDumpState:

    @pytest.mark.skip(reason=SKIP_REASON)
    def test_dump_state_returns_well_formed_snapshot(self):
        """genet_dump_state returns a parseable register snapshot
        with all expected fields populated.

        TODO once the kernel function lands:
        - Trigger a dump (mechanism TBD per open question above)
        - Parse the dump into a dict
        - Assert presence and reasonable bounds for each field:
          rdma_ctrl, tdma_ctrl, rdma_prod, rdma_cons, tdma_prod,
          tdma_cons, umac_cmd, tx_fifo_status, rx_fifo_status,
          mib_tx_good, mib_tx_drop, mib_rx_good, mib_rx_drop,
          mib_rx_error
        """
        raise NotImplementedError

    @pytest.mark.skip(reason=SKIP_REASON)
    def test_rx_good_counter_increments_on_arp(self):
        """RX-good MIB counter goes up by exactly 1 after a single
        ARP request reaches the Pi.

        TODO: snapshot dump → send 1 ARP → snapshot dump again →
        assert delta is exactly 1.
        """
        raise NotImplementedError

    @pytest.mark.skip(reason=SKIP_REASON)
    def test_tx_good_counter_increments_on_reply(self):
        """TX-good MIB counter goes up by exactly 1 after the Pi
        sends a single ARP reply.

        TODO: snapshot dump → trigger one reply → snapshot again →
        assert delta is exactly 1.
        """
        raise NotImplementedError
