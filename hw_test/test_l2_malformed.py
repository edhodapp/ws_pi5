"""
test_l2_malformed.py — malformed-frame survival tests for the Pi GENET stack.

Sends a variety of well-formed-Ethernet-but-uninteresting-or-illegal
frames at the Pi and asserts:

  1. The Pi sends NO response within the silence window.
  2. The Pi remains responsive to a valid ARP probe afterwards.

The point is twofold: (a) verify the Pi silently drops frames it
shouldn't act on (no reply leakage), and (b) verify the Pi's RX path
doesn't crash on edge cases (post-test ARP must still work).

Frame categories:
  * runts (14-59 bytes) — sub-Ethernet-minimum
  * oversize (1515-1600 bytes) — over the lib/eth.S 1514 limit AND
    over the genet UMAC max_frame 1536 limit
  * bogus ethertypes (0x0000, 0x0001, 0x88cc, 0x9999, 0xFFFF) — none
    are recognized by lib/eth.S
  * VLAN-tagged (0x8100) — Pi has no VLAN handling

Important caveat about runts: the laptop's USB Ethernet adapter may
silently pad sub-60-byte frames to 60 bytes on transmit before they
hit the wire. If so, the Pi never actually sees a runt. This can't
be reliably detected from the sender side, so the runt tests use a
bogus ethertype as the payload's "discriminator" — that way the test
asserts the right thing (Pi survives) regardless of whether the wire
saw a true runt or a hardware-padded frame.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l2_malformed.py -v
"""

import pytest

import eth_frames
import wire
from conftest import requires_hardware, PI4_IP


# A "safe" bogus ethertype for malformed-frame payloads. 0x88B7 is
# IEEE "local experimental 2" — never used by Pi. Distinct from the
# wire.WireCapture readiness probe ethertype (0x88B5) so failures
# can't be confused with probe leakage.
MALFORMED_ETHERTYPE = 0x88B7


# Boundary cases. Each item is (label, builder-callable).
RUNT_LENGTHS = [14, 30, 59]
OVERSIZE_LENGTHS = [1515, 1536, 1537, 1600]
BOGUS_ETHERTYPES = [0x0000, 0x0001, 0x88cc, 0x9999, 0xFFFF, 0x8100]


@requires_hardware
@pytest.mark.l2
class TestMalformedFrames:
    """Send malformed frames and verify the Pi remains responsive."""

    @pytest.mark.parametrize("length", RUNT_LENGTHS)
    def test_runt_does_not_brick_pi(
        self, length, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """A frame shorter than 60 bytes (the Ethernet minimum) does
        not cause the Pi to stop responding.

        See module docstring re: USB NIC padding caveat.
        """
        frame = eth_frames.build_runt(
            pi_mac, laptop_mac, length, ethertype=MALFORMED_ETHERTYPE,
        )
        _send_garbage_then_assert_alive(
            frame, length_label=f"runt[{length}]",
            eth_iface=eth_iface, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, pi_mac=pi_mac, rtt_p99_ms=rtt_p99_ms,
        )

    @pytest.mark.parametrize("length", OVERSIZE_LENGTHS)
    def test_oversize_does_not_brick_pi(
        self, length, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """A frame larger than 1514 bytes does not brick the Pi.

        Two boundaries are exercised:
          * 1515 — one over lib/eth.S `eth_type` limit
          * 1536 — at the genet UMAC `max_frame` setting
          * 1537 — one over the UMAC max_frame
          * 1600 — clearly oversized (would normally be jumbo)
        """
        frame = eth_frames.build_oversize(
            pi_mac, laptop_mac, length, ethertype=MALFORMED_ETHERTYPE,
        )
        _send_garbage_then_assert_alive(
            frame, length_label=f"oversize[{length}]",
            eth_iface=eth_iface, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, pi_mac=pi_mac, rtt_p99_ms=rtt_p99_ms,
        )

    @pytest.mark.parametrize("ethertype", BOGUS_ETHERTYPES)
    def test_bogus_ethertype_silently_dropped(
        self, ethertype, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """A well-formed frame with an ethertype the Pi doesn't
        recognize gets silently dropped, with no observable Pi response.

        Tests both arbitrary unrecognized values (0x0000, 0x0001,
        0x9999, 0xFFFF), the LLDP/IEEE 1AB ethertype (0x88cc) which
        sometimes triggers magic in real-world stacks, and the VLAN
        tag ethertype (0x8100) which the Pi has no handling for.
        """
        frame = eth_frames.build_bogus_ethertype(pi_mac, laptop_mac, ethertype)
        _send_garbage_then_assert_alive(
            frame, length_label=f"ethertype[0x{ethertype:04x}]",
            eth_iface=eth_iface, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, pi_mac=pi_mac, rtt_p99_ms=rtt_p99_ms,
        )

    def test_zero_length_payload_arp_not_replied_to(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """A frame claiming ETHERTYPE_ARP but with insufficient payload
        is silently dropped — the Pi's ARP responder must validate
        payload length before reading sender HW/IP fields.

        Catches a classic class of bug where the responder reads past
        the end of a truncated frame.
        """
        # 14-byte Ethernet header + ARP ethertype + zero ARP payload
        truncated = eth_frames.build_eth_header(
            pi_mac, laptop_mac, eth_frames.ETHERTYPE_ARP,
        )
        # Pad to wire-min so the NIC will actually send it
        truncated = truncated + bytes(eth_frames.ETH_MIN_FRAME - len(truncated))
        _send_garbage_then_assert_alive(
            truncated, length_label="arp[truncated]",
            eth_iface=eth_iface, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, pi_mac=pi_mac, rtt_p99_ms=rtt_p99_ms,
        )


# --- Internal: send a garbage frame, assert no response, assert still alive ---

def _send_garbage_then_assert_alive(
    garbage_frame, *, length_label,
    eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
):
    """Two-phase malformed-frame survival check.

    Phase 1: send the garbage frame, capture replies from the Pi
    (BPF: ether src <pi_mac> and ether dst <laptop_mac>), assert NO
    matching frame in `silence_window_ms = max(5 * rtt_p99_ms, 50ms)`.

    Phase 2: send a valid ARP request, assert the Pi replies within
    `response_window_ms = max(20 * rtt_p99_ms, 500ms)`.
    """
    bpf = (
        f"ether src {eth_frames.mac_bytes_to_str(pi_mac)} "
        f"and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
    )
    silence_window_ms = int(max(5.0 * rtt_p99_ms, 50.0))
    response_window_ms = int(max(20.0 * rtt_p99_ms, 500.0))

    # --- Phase 1: garbage in, silence out ---
    with wire.WireCapture(eth_iface, bpf=bpf) as cap:
        wire.send_frame(eth_iface, garbage_frame)
        # Predicate accepts ANY frame from Pi-MAC to laptop-MAC
        # (already filtered by BPF, but be explicit)
        leaked = wire.wait_for_frame(
            cap,
            lambda data: (
                data[:6] == laptop_mac and data[6:12] == pi_mac
            ),
            deadline_ms=silence_window_ms,
        )
    assert leaked is None, (
        f"{length_label}: Pi sent an unexpected response within "
        f"{silence_window_ms} ms — leaked frame: {leaked.hex()[:80]}..."
    )

    # --- Phase 2: still alive? ---
    valid_arp = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
    with wire.WireCapture(eth_iface, bpf=f"arp and {bpf}") as cap:
        wire.send_frame(eth_iface, valid_arp)
        reply = wire.wait_for_frame(
            cap,
            lambda data: _is_arp_reply_from(data, pi_mac, PI4_IP),
            deadline_ms=response_window_ms,
        )
    assert reply is not None, (
        f"{length_label}: Pi unresponsive to valid ARP after garbage "
        f"frame (waited {response_window_ms} ms) — Pi may be bricked"
    )
    arp = eth_frames.parse_arp(reply)
    assert arp["sha"] == pi_mac
    assert arp["spa"] == PI4_IP


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
