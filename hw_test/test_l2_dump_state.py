"""
test_l2_dump_state.py — runtime snapshot of GENET register + driver state.

The Pi's lib/perf.S::perf_handle gained a PERF_CMD_DUMP_REGS command
that delegates to platform/pi/drivers/genet.S::genet_dump_state. The
kernel reads 16 u32 fields (UMAC_CMD, FIFO status, RDMA/TDMA indices
and control, RDMA XON/XOFF threshold, and the driver's software copy
of the ring indices) into a 64-byte payload and ships it back over
the custom ethertype 0x88B6 query protocol.

This file exercises the dump path from the laptop side:

  * test_dump_state_returns_well_formed_snapshot — baseline sanity
    check. Queries the snapshot on a fresh-boot quiescent Pi and
    asserts every field looks reasonable: UMAC_CMD has TX_EN + RX_EN
    + one SPEED bit; DMA_CTRL has DMA_EN and ring16_en; the
    hardware-side ring indices (RDMA_PROD/CONS, TDMA_PROD/CONS)
    agree with the driver's software state_rx_* / state_tx_*; and
    the XON/XOFF threshold register matches the value we program
    during init. Runs against any PERF build.

  * test_rx_indices_advance_after_arp — pokes the Pi with a single
    ARP request, re-snapshots, and asserts that both the hardware
    RDMA_PROD_INDEX and the driver's state_rx_cidx advanced by at
    least 1. Demonstrates that the dump gives us a live view of
    the recv path, not a cached one.

  * test_tx_indices_advance_after_arp — same as above for the TX
    side: ARP request → ARP reply → TDMA_PROD_INDEX and
    state_tx_pidx both move.

All tests skip gracefully when the Pi is not a PERF build, because
the perf_query handler is compiled out there.

Tracked as L2 hardening queue item 2:
    ~/.claude/projects/-home-ed-ws-pi5/memory/project_l2_hardening_plan.md
"""

import time

import pytest

import eth_frames
import wire
from conftest import requires_hardware, PI4_IP


# UMAC_CMD bits we assert on (from include/perf.inc + Linux unimac.h)
CMD_TX_EN       = 1 << 0
CMD_RX_EN       = 1 << 1
CMD_SPEED_MASK  = 3 << 2   # bits 2-3 hold the speed code
CMD_SPEED_100   = 1 << 2
CMD_SPEED_1000  = 2 << 2   # yes, value "2" in bits [3:2]

# Wait, we actually use a different encoding in genet_init —
# UMAC_CMD_SPEED_100 is (1 << 2) and UMAC_CMD_SPEED_1000 is (1 << 3).
# So the speed bits aren't a 2-bit field in our driver; they're
# two individual flag bits. Re-do the constants to match our kernel.
# See platform/pi/include/genet.inc:
#     .equ UMAC_CMD_SPEED_100,      (1 << 2)
#     .equ UMAC_CMD_SPEED_1000,     (1 << 3)
CMD_SPEED_100_BIT  = 1 << 2
CMD_SPEED_1000_BIT = 1 << 3

# DMA_CTRL bits (from genet.inc DMA_CTRL_EN = 0x00020001)
DMA_CTRL_EN          = 1 << 0     # DMA enable
DMA_CTRL_RING16_EN   = 1 << 17    # ring 16 (default queue) enable

# RDMA_XON_XOFF_THRESH value we program in genet_init
# (matches Linux DMA_FC_THRESH_VALUE = (DMA_FC_THRESH_LO << 16) |
# DMA_FC_THRESH_HI = (5 << 16) | 16 = 0x00050010)
EXPECTED_XON_XOFF_THRESH = 0x00050010


def _snapshot_or_skip(eth_iface, pi_mac, laptop_mac):
    """Query the Pi for a GENET snapshot, or skip the test.

    All tests in this file depend on the Pi running a PERF build
    with the 0x88B6 handler compiled in. Without it, perf_query
    times out. We translate the timeout into a pytest skip so the
    test report distinguishes "PERF not available" from "test
    failed."
    """
    try:
        return wire.perf_query(
            eth_iface, pi_mac, laptop_mac, dump_regs=True
        )
    except wire.WireError as e:
        pytest.skip(
            f"genet_dump_state not available: {e}. Reflash with "
            f"`make PLATFORM=pi4 PERF=recv` (or any PERF flavor)."
        )


@requires_hardware
@pytest.mark.l2
class TestGenetDumpState:

    def test_dump_state_returns_well_formed_snapshot(
        self, eth_iface, laptop_mac, pi_mac
    ):
        """Basic shape check: the snapshot parses and every field
        looks reasonable on a quiescent, link-up Pi.

        Verified invariants:
          - UMAC_CMD has TX_EN and RX_EN set
          - UMAC_CMD has either SPEED_100 or SPEED_1000 (exactly one)
          - RDMA_DMA_CTRL has DMA_EN and ring16_en
          - TDMA_DMA_CTRL has DMA_EN and ring16_en
          - RDMA_XON_XOFF_THRESH matches what genet_init programs
          - state_rx_cidx matches rdma_cons_index (software caught
            up with hardware on RX)
          - state_tx_pidx matches tdma_prod_index (software caught
            up with hardware on TX)
        """
        regs = _snapshot_or_skip(eth_iface, pi_mac, laptop_mac)

        # --- UMAC_CMD ---
        assert regs["umac_cmd"] & CMD_TX_EN, (
            f"UMAC_CMD.TX_EN not set: {regs['umac_cmd']:#010x}"
        )
        assert regs["umac_cmd"] & CMD_RX_EN, (
            f"UMAC_CMD.RX_EN not set: {regs['umac_cmd']:#010x}"
        )
        speed_bits = regs["umac_cmd"] & (CMD_SPEED_100_BIT | CMD_SPEED_1000_BIT)
        assert speed_bits in (CMD_SPEED_100_BIT, CMD_SPEED_1000_BIT), (
            f"UMAC_CMD speed bits invalid (expected exactly one of "
            f"SPEED_100 or SPEED_1000): {regs['umac_cmd']:#010x}"
        )

        # --- DMA_CTRL for both rings ---
        for reg_name in ("rdma_dma_ctrl", "tdma_dma_ctrl"):
            val = regs[reg_name]
            assert val & DMA_CTRL_EN, (
                f"{reg_name}.DMA_EN not set: {val:#010x}"
            )
            assert val & DMA_CTRL_RING16_EN, (
                f"{reg_name}.ring16_en not set: {val:#010x}"
            )

        # --- Flow-control threshold ---
        assert regs["rdma_xon_xoff_thresh"] == EXPECTED_XON_XOFF_THRESH, (
            f"RDMA_XON_XOFF_THRESH = {regs['rdma_xon_xoff_thresh']:#010x}, "
            f"expected {EXPECTED_XON_XOFF_THRESH:#010x} (the value we "
            f"program in genet_init)"
        )

        # --- HW ↔ SW ring index agreement ---
        # The driver masks both ring indices to 16 bits before
        # storing; the hardware register's lower 16 bits are the
        # same value. Upper 16 bits of RDMA_PROD_INDEX are the
        # discard counter, which we ignore here.
        hw_rx_cons = regs["rdma_cons_index"] & 0xFFFF
        sw_rx_cidx = regs["state_rx_cidx"] & 0xFFFF
        assert hw_rx_cons == sw_rx_cidx, (
            f"HW RDMA_CONS_INDEX ({hw_rx_cons}) != SW state_rx_cidx "
            f"({sw_rx_cidx}) — driver out of sync with hardware"
        )

        hw_tx_prod = regs["tdma_prod_index"] & 0xFFFF
        sw_tx_pidx = regs["state_tx_pidx"] & 0xFFFF
        assert hw_tx_prod == sw_tx_pidx, (
            f"HW TDMA_PROD_INDEX ({hw_tx_prod}) != SW state_tx_pidx "
            f"({sw_tx_pidx}) — driver out of sync with hardware"
        )

    def test_rx_indices_advance_after_arp(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac
    ):
        """A single ARP request to the Pi moves both the hardware
        RDMA_PROD_INDEX and the driver's state_rx_cidx forward.

        Demonstrates that the dump is a live view — registers track
        real traffic, not stale init-time values.
        """
        before = _snapshot_or_skip(eth_iface, pi_mac, laptop_mac)

        # Send one valid ARP request and give the Pi a moment to
        # process and reply. We don't care about the reply here —
        # this test is about the driver/HW state, not the wire.
        req = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
        with wire.RawL2Socket(eth_iface) as sock:
            sock.drain()
            sock.send(req)
            time.sleep(0.02)  # 20ms settle — plenty for one frame

        after = _snapshot_or_skip(eth_iface, pi_mac, laptop_mac)

        # RDMA_PROD_INDEX and state_rx_cidx should both have moved
        # forward by at least 2 frames (the ARP we sent + our own
        # dump_regs query frame). The exact delta can vary if
        # background traffic (ARP refresh timer) also fired.
        before_prod = before["rdma_prod_index"] & 0xFFFF
        after_prod  = after["rdma_prod_index"]  & 0xFFFF
        delta_prod  = (after_prod - before_prod) & 0xFFFF
        assert delta_prod >= 2, (
            f"RDMA_PROD_INDEX did not advance enough: before={before_prod}, "
            f"after={after_prod}, delta={delta_prod} (expected >= 2: the "
            f"ARP request + the post-burst dump_regs query frame)"
        )

        before_cidx = before["state_rx_cidx"] & 0xFFFF
        after_cidx  = after["state_rx_cidx"]  & 0xFFFF
        delta_cidx  = (after_cidx - before_cidx) & 0xFFFF
        assert delta_cidx >= 2, (
            f"state_rx_cidx did not advance enough: before={before_cidx}, "
            f"after={after_cidx}, delta={delta_cidx}"
        )

    def test_tx_indices_advance_after_arp(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac
    ):
        """The TX ring indices advance when the Pi replies to an ARP.

        Sends one ARP request so the Pi builds and sends one reply,
        then re-snapshots. Both TDMA_PROD_INDEX and state_tx_pidx
        should move forward.
        """
        before = _snapshot_or_skip(eth_iface, pi_mac, laptop_mac)

        req = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
        with wire.RawL2Socket(eth_iface) as sock:
            sock.drain()
            sock.send(req)
            time.sleep(0.02)

        after = _snapshot_or_skip(eth_iface, pi_mac, laptop_mac)

        # TDMA advances by at least 2: the ARP reply to our request
        # + the reply to our subsequent dump_regs query. Background
        # traffic (ARP refresh, NTP if it ever fires) may add more,
        # hence the ">=".
        before_tp = before["tdma_prod_index"] & 0xFFFF
        after_tp  = after["tdma_prod_index"]  & 0xFFFF
        delta_tp  = (after_tp - before_tp) & 0xFFFF
        assert delta_tp >= 2, (
            f"TDMA_PROD_INDEX did not advance: before={before_tp}, "
            f"after={after_tp}, delta={delta_tp}"
        )

        before_sp = before["state_tx_pidx"] & 0xFFFF
        after_sp  = after["state_tx_pidx"]  & 0xFFFF
        delta_sp  = (after_sp - before_sp) & 0xFFFF
        assert delta_sp >= 2, (
            f"state_tx_pidx did not advance: before={before_sp}, "
            f"after={after_sp}, delta={delta_sp}"
        )
