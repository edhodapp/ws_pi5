"""
test_l2_dsb.py — DSB (Data Synchronization Barrier) coverage in GENET.

SKELETON. These tests would exercise behaviour that depends on a
future kernel-side change: drivers/genet.S needs DSB barriers in
genet_send (before writing PROD_INDEX) and genet_recv (before
updating CONS_INDEX). Without barriers, descriptor writes and ring
index updates can be reordered relative to each other, producing
intermittent dropped frames or descriptor corruption under cache
pressure.

The barriers are prophylactic — they fix probable latent cache/bus
ordering bugs that may not be reproducible from a Python test driver
on a desktop x86 host. The tests here are STRESS tests that try to
provoke ordering bugs by maximizing concurrent activity, then
asserting nothing was lost or corrupted.

Tracked as L2 hardening queue item 1:
    project_l2_hardening_plan.md (memory)

When the kernel barriers land, unskip these and tune the burst
sizes / thread counts until the test reproducibly stresses the
descriptor ring.
"""

import pytest

from conftest import requires_hardware


SKIP_REASON = (
    "blocked on L2 hardening queue item 1 — DSB barriers in "
    "genet_send / genet_recv (descriptor writes must be visible "
    "before PROD_INDEX update; RX re-arm before CONS_INDEX publish). "
    "See project_l2_hardening_plan.md."
)


@requires_hardware
@pytest.mark.l2
class TestDsbBarriers:

    @pytest.mark.skip(reason=SKIP_REASON)
    def test_concurrent_burst_no_descriptor_corruption(self):
        """Maximum-rate concurrent burst followed by integrity check.

        TODO once barriers are in:
        - Send a sustained burst of valid ARP requests at the highest
          rate the laptop's AF_PACKET socket can push
        - Capture all replies via wire.WireCapture / wait_for_frames
        - Assert each reply parses cleanly (no truncated/garbled
          frames — that would be the symptom of a missing barrier
          letting CONS_INDEX advance before the descriptor write
          settled)
        - Assert the count is within a tight tolerance of expected
        """
        raise NotImplementedError

    @pytest.mark.skip(reason=SKIP_REASON)
    def test_no_phantom_replies_after_quiescent_period(self):
        """After a busy period, the Pi quiesces — no phantom frames
        from the descriptor ring.

        TODO: send a burst, drain replies, idle for ~1s, capture for
        another ~500ms, assert ZERO frames captured. Catches
        descriptor-publish-after-quiesce bugs.
        """
        raise NotImplementedError
