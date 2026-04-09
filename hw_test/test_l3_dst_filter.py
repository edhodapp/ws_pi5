"""
test_l3_dst_filter.py — IPv4 destination-address filtering in ip_handle.

Pins the `IP.DST == net_our_ip` check in lib/ip.S::ip_handle. The
Pi performs this check as an exact 32-bit wire-format compare
(no masking, no range tests), which means every non-matching dst
address — unicast to a different host, broadcast, directed
broadcast, multicast — drops at the same instruction.

This file exists separately from test_l3_malformed_ip.py because
destination filtering is a specific semantic contract worth pinning
independently of the "bad header" class of drops.

NOTE ON L2: ws_pi5's lib/eth.S currently has no MAC-level filter —
any Ethernet frame the GENET driver hands up is accepted at L2
regardless of Ethernet destination. So broadcast/multicast IP frames
reach ip_handle directly. Even so, every test here uses
`eth.dst = pi_mac` to force the frame through a unicast L2 path
and isolate the L3 destination check from any future L2 filter.
(test_l2_reachability.py already covers the "broadcast reaches L2"
side of that contract.)

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l3_dst_filter.py -v
"""

import pytest

import eth_frames
import ip_frames
import wire
from conftest import PI4_IP, requires_hardware
from icmp_helpers import (
    icmp_bpf_from_pi,
    is_any_icmp_from_pi,
    parse_reply,
    send_echo_and_wait,
)


# Addresses we expect the Pi to reject at the L3 destination check.
# Each test below picks from this list and asserts silent drop.

OTHER_HOST_IP          = "10.0.0.99"      # another unicast in our subnet
LIMITED_BROADCAST_IP   = "255.255.255.255"
DIRECTED_BROADCAST_IP  = "10.0.0.255"     # subnet broadcast
ALL_SYSTEMS_MULTICAST  = "224.0.0.1"      # RFC 1112 all-systems
ADDITIONAL_MULTICAST   = "239.1.2.3"      # admin-scoped multicast


# ==============================================================
# Shared helper — send a bogus-dst frame, assert silence, then
# prove the Pi is still alive via a follow-up normal echo.
# ==============================================================

def _assert_dst_is_filtered(
    eth_iface: str,
    bogus_dst_ip: str,
    *,
    pi_mac: bytes,
    laptop_mac: bytes,
    laptop_ip: str,
    rtt_p99_ms: float,
) -> None:
    """Send a well-formed ICMP echo with `dst_ip = bogus_dst_ip`
    (but eth.dst = pi_mac to ensure the frame reaches L3). Assert
    the Pi sends NO ICMP reply within the silence window, then send
    a normal echo and assert a reply arrives.

    Uses `is_any_icmp_from_pi` as the silence predicate so an
    unexpected ICMP ERROR reply also trips the assertion — the
    Pi should silently drop, not generate any response at all.
    """
    # Build an otherwise-valid ICMP echo. Only the IP destination is
    # out of spec.
    frame = ip_frames.build_icmp_echo_frame(
        laptop_mac, pi_mac, laptop_ip, bogus_dst_ip,
        ident=0x5900, seq=1, payload=b"wrong-dst",
    )

    silence_ms = int(max(5.0 * rtt_p99_ms, 50.0))
    bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)

    with wire.WireCapture(eth_iface, bpf=bpf) as cap:
        wire.send_frame(eth_iface, frame)
        uninvited = wire.wait_for_frame(
            cap,
            lambda data: is_any_icmp_from_pi(
                data, pi_mac=pi_mac, laptop_mac=laptop_mac,
                pi_ip=PI4_IP,
            ),
            deadline_ms=silence_ms,
        )
    assert uninvited is None, (
        f"Pi replied to an ICMP echo with dst_ip={bogus_dst_ip} — "
        f"the L3 destination filter is not dropping this address. "
        f"Reply hex (first 80B): {uninvited[:80].hex() if uninvited else None}"
    )

    # Prove the Pi is still alive.
    probe = send_echo_and_wait(
        eth_iface,
        pi_mac=pi_mac, laptop_mac=laptop_mac,
        pi_ip=PI4_IP, laptop_ip=laptop_ip,
        ident=0x59FF, seq=1, payload=b"alive?",
        deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
    )
    assert probe is not None, (
        f"Pi did not reply to a normal echo after receiving a frame "
        f"with dst_ip={bogus_dst_ip} — may be hung"
    )


# ==============================================================
# Baseline — unicast to our IP accepted
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestOurIpAccepted:
    """Positive control: the exact IP the Pi expects gets a reply.
    Redundant with test_l3_reachability.py, but wedged here too so
    the dst-filter contract has both sides pinned in one file.
    """

    def test_unicast_to_our_ip_accepted(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        reply = send_echo_and_wait(
            eth_iface,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
            ident=0x5800, seq=1, payload=b"baseline",
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert reply is not None
        r = parse_reply(reply)
        assert r["ip"]["dst_ip"] == laptop_ip
        assert r["ip"]["src_ip"] == PI4_IP
        assert r["icmp"]["payload"] == b"baseline"


# ==============================================================
# Filtered destinations
# ==============================================================

@requires_hardware
@pytest.mark.l3
class TestForeignUnicastDropped:

    def test_other_host_in_subnet_dropped(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Unicast to 10.0.0.99 (a different host in the same
        subnet). The ip_handle dst check is an exact compare, so
        this fails even though the IP is in our subnet.
        """
        _assert_dst_is_filtered(
            eth_iface, OTHER_HOST_IP,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
        )


@requires_hardware
@pytest.mark.l3
class TestBroadcastDropped:
    """ws_pi5 does not participate in broadcast. Both limited and
    directed broadcast must be dropped silently.
    """

    def test_limited_broadcast_dropped(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """255.255.255.255 — the limited broadcast address. Per
        RFC 1812 every IPv4 host recognizes this as broadcast; ws_pi5
        ignores it because it's not our unicast IP.
        """
        _assert_dst_is_filtered(
            eth_iface, LIMITED_BROADCAST_IP,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
        )

    def test_directed_broadcast_dropped(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """10.0.0.255 — the subnet-directed broadcast for the /24
        ws_pi5 lives on. RFC 2644 (BCP 34) deprecated directed
        broadcasts for security reasons; ws_pi5 simply doesn't
        recognize them at all.
        """
        _assert_dst_is_filtered(
            eth_iface, DIRECTED_BROADCAST_IP,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
        )


@requires_hardware
@pytest.mark.l3
class TestMulticastDropped:
    """ws_pi5 is not a member of any IPv4 multicast group. Even the
    "all-systems" 224.0.0.1 is ignored — the Pi has no multicast
    membership state at all.
    """

    def test_all_systems_multicast_dropped(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """224.0.0.1 — RFC 1112 all-systems multicast. On Linux
        hosts this is always joined (link-local); ws_pi5 explicitly
        ignores it.
        """
        _assert_dst_is_filtered(
            eth_iface, ALL_SYSTEMS_MULTICAST,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
        )

    def test_admin_scoped_multicast_dropped(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """239.1.2.3 — an administratively-scoped multicast address
        (RFC 2365). A second multicast test against a different
        class-D range so a future "accept 224.0.0.1" special case
        doesn't silently let ALL multicast through.
        """
        _assert_dst_is_filtered(
            eth_iface, ADDITIONAL_MULTICAST,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            laptop_ip=laptop_ip, rtt_p99_ms=rtt_p99_ms,
        )
