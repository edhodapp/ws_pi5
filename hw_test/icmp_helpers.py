"""
icmp_helpers.py — shared ICMP send/receive helpers for the L3 suite.

These are the primitives each test_l3_*.py file uses to drive the Pi:
build a crafted ICMP echo frame, send it, wait for the reply, and
parse it into structured dicts. Factored out of test_l3_reachability
so the payload-size / fragment / malformed / dst-filter tests can
reuse the same "one-shot echo" loop without copy-paste.

No hardware access at import time — just pure Python plus the
existing wire / eth_frames / ip_frames modules. Fine to import from
any L3 test.
"""

from typing import Callable

import eth_frames
import ip_frames
import wire


def is_echo_reply_for(
    frame: bytes,
    *,
    pi_mac: bytes,
    laptop_mac: bytes,
    pi_ip: str,
    laptop_ip: str,
    ident: int,
    seq: int,
) -> bool:
    """Predicate: frame is an ICMP echo reply from pi_mac to
    laptop_mac carrying the given (ident, seq).

    Catches parse errors — the predicate runs on every captured frame
    including noise, so it must never throw.
    """
    try:
        eth = eth_frames.parse_eth_header(frame)
        if eth["ethertype"] != eth_frames.ETHERTYPE_IPV4:
            return False
        if eth["src"] != pi_mac or eth["dst"] != laptop_mac:
            return False
        ip = ip_frames.parse_ipv4_header(
            frame[eth_frames.ETH_HEADER_LEN:
                  eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN]
        )
        if ip["protocol"] != ip_frames.IP_PROTO_ICMP:
            return False
        if ip["src_ip"] != pi_ip or ip["dst_ip"] != laptop_ip:
            return False
        icmp = ip_frames.parse_icmp(
            frame[eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN:
                  eth_frames.ETH_HEADER_LEN + ip["total_length"]]
        )
        if icmp["type"] != ip_frames.ICMP_ECHO_REPLY:
            return False
        return icmp["ident"] == ident and icmp["seq"] == seq
    except (ValueError, OSError):
        return False


def is_any_echo_reply_from_pi(
    frame: bytes,
    *,
    pi_mac: bytes,
    laptop_mac: bytes,
    pi_ip: str,
    laptop_ip: str,
) -> bool:
    """Predicate: any ICMP echo reply from the Pi to us, regardless of
    (ident, seq). Used by burst tests that accept replies for any of
    a set of idents and verify the set afterwards.
    """
    try:
        eth = eth_frames.parse_eth_header(frame)
        if eth["ethertype"] != eth_frames.ETHERTYPE_IPV4:
            return False
        if eth["src"] != pi_mac or eth["dst"] != laptop_mac:
            return False
        ip = ip_frames.parse_ipv4_header(
            frame[eth_frames.ETH_HEADER_LEN:
                  eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN]
        )
        if ip["protocol"] != ip_frames.IP_PROTO_ICMP:
            return False
        if ip["src_ip"] != pi_ip or ip["dst_ip"] != laptop_ip:
            return False
        icmp = ip_frames.parse_icmp(
            frame[eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN:
                  eth_frames.ETH_HEADER_LEN + ip["total_length"]]
        )
        return icmp["type"] == ip_frames.ICMP_ECHO_REPLY
    except (ValueError, OSError):
        return False


def icmp_bpf_from_pi(pi_mac: bytes, laptop_mac: bytes) -> str:
    """BPF filter expression: ICMP frames from the Pi to the laptop.
    Used as the WireCapture BPF for every "one-shot echo" test so the
    pcap doesn't get swamped with noise.
    """
    return (
        f"icmp and ether src {eth_frames.mac_bytes_to_str(pi_mac)} "
        f"and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
    )


def send_echo_and_wait(
    eth_iface: str,
    *,
    pi_mac: bytes,
    laptop_mac: bytes,
    pi_ip: str,
    laptop_ip: str,
    ident: int,
    seq: int,
    payload: bytes,
    deadline_ms: int,
    df: bool = False,
    ip_ident: int = 0,
    ttl: int = ip_frames.IP_DEFAULT_TTL,
) -> bytes | None:
    """Build one ICMP echo request, send it, and wait for the matching
    reply. Returns the reply frame bytes or None at deadline.

    This is the canonical "one echo" primitive — every single-echo
    L3 test uses it. For bursts, use send_echo_burst_and_wait().
    """
    frame = ip_frames.build_icmp_echo_frame(
        laptop_mac, pi_mac, laptop_ip, pi_ip,
        ident=ident, seq=seq, payload=payload,
        ttl=ttl, ip_ident=ip_ident, df=df,
    )
    bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
    with wire.WireCapture(eth_iface, bpf=bpf) as cap:
        wire.send_frame(eth_iface, frame)
        return wire.wait_for_frame(
            cap,
            lambda data: is_echo_reply_for(
                data,
                pi_mac=pi_mac, laptop_mac=laptop_mac,
                pi_ip=pi_ip, laptop_ip=laptop_ip,
                ident=ident, seq=seq,
            ),
            deadline_ms=deadline_ms,
        )


def send_echo_burst_and_wait(
    eth_iface: str,
    *,
    pi_mac: bytes,
    laptop_mac: bytes,
    pi_ip: str,
    laptop_ip: str,
    frames: list[bytes],
    expected_count: int,
    match: Callable[[bytes], bool],
    deadline_ms: int,
) -> list[bytes]:
    """Send a list of pre-built frames into one WireCapture and wait
    for up to `expected_count` replies matching `match`.

    Returns whatever replies were collected before the deadline — the
    caller asserts `len(result) == expected_count` so failures show
    the actual short count.
    """
    bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
    with wire.WireCapture(eth_iface, bpf=bpf) as cap:
        for f in frames:
            wire.send_frame(eth_iface, f)
        return wire.wait_for_frames(
            cap, match,
            count=expected_count,
            deadline_ms=deadline_ms,
        )


def parse_reply(frame: bytes) -> dict:
    """Parse an Ethernet + IPv4 + ICMP frame into structured dicts.

    Returns {eth, ip, icmp, icmp_bytes, ip_bytes} where the _bytes
    fields are the raw slices suitable for re-checksumming.
    """
    eth = eth_frames.parse_eth_header(frame)
    ip_bytes = frame[eth_frames.ETH_HEADER_LEN:
                     eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN]
    ip = ip_frames.parse_ipv4_header(ip_bytes)
    icmp_bytes = frame[eth_frames.ETH_HEADER_LEN + ip_frames.IP_HDR_MIN:
                       eth_frames.ETH_HEADER_LEN + ip["total_length"]]
    icmp = ip_frames.parse_icmp(icmp_bytes)
    return {
        "eth": eth,
        "ip": ip,
        "icmp": icmp,
        "ip_bytes": ip_bytes,
        "icmp_bytes": icmp_bytes,
    }
