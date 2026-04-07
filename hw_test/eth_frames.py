"""
eth_frames.py — Ethernet (L2) and ARP frame construction & parsing.

Pure functions, no I/O. Mirrors the style of tcp_helpers.py and is
intentionally importable from anywhere with no side effects so it can
be unit-tested off-hardware.

Used by test_l2_*.py tests via wire.send_frame() and WireCapture.
"""

import socket
import struct


# --- Constants ---

ETHERTYPE_IPV4 = 0x0800
ETHERTYPE_ARP  = 0x0806
ETHERTYPE_VLAN = 0x8100  # used in negative tests; Pi has no VLAN handling

ETH_HEADER_LEN = 14
ETH_MIN_PAYLOAD = 46     # minimum payload to reach the 60-byte (pre-FCS) wire min
ETH_MIN_FRAME = 60       # 14 header + 46 payload, FCS added by hardware
ETH_MAX_FRAME = 1514     # 14 header + 1500 payload (eth.S enforces this on the Pi)

BROADCAST_MAC = b"\xff" * 6
ZERO_MAC      = b"\x00" * 6

ARP_HTYPE_ETH    = 1
ARP_PTYPE_IPV4   = ETHERTYPE_IPV4
ARP_HLEN_ETH     = 6
ARP_PLEN_IPV4    = 4
ARP_OP_REQUEST   = 1
ARP_OP_REPLY     = 2
ARP_PACKET_LEN   = 28    # bytes of ARP payload (post-Ethernet header)


# --- MAC address conversion ---

def mac_str_to_bytes(mac: str) -> bytes:
    """Convert an "aa:bb:cc:dd:ee:ff" string to 6 raw bytes.

    Raises ValueError on malformed input. Accepts upper or lowercase
    hex; rejects anything that isn't exactly six colon-separated octets.
    """
    parts = mac.split(":")
    if len(parts) != 6:
        raise ValueError(f"MAC must have 6 octets, got {len(parts)}: {mac!r}")
    out = bytearray(6)
    for i, p in enumerate(parts):
        if len(p) == 0 or len(p) > 2:
            raise ValueError(f"MAC octet {i} invalid: {p!r}")
        out[i] = int(p, 16)
    return bytes(out)


def mac_bytes_to_str(mac: bytes) -> str:
    """Convert 6 raw MAC bytes to canonical lowercase "aa:bb:..." string."""
    if len(mac) != 6:
        raise ValueError(f"MAC must be 6 bytes, got {len(mac)}")
    return ":".join(f"{b:02x}" for b in mac)


# --- Ethernet header ---

def build_eth_header(dst: bytes, src: bytes, ethertype: int) -> bytes:
    """Build a 14-byte Ethernet II header.

    Args:
        dst: 6-byte destination MAC
        src: 6-byte source MAC
        ethertype: 16-bit ethertype (e.g. ETHERTYPE_ARP)

    The FCS is appended by the NIC hardware on transmit; do not include
    it in the returned bytes.
    """
    if len(dst) != 6 or len(src) != 6:
        raise ValueError("dst and src MACs must be exactly 6 bytes")
    if not (0 <= ethertype <= 0xFFFF):
        raise ValueError(f"ethertype out of range: {ethertype:#x}")
    return dst + src + struct.pack("!H", ethertype)


def build_eth_frame(dst: bytes, src: bytes, ethertype: int,
                    payload: bytes, pad_to: int | None = None) -> bytes:
    """Build a complete Ethernet frame (header + payload + optional pad).

    Args:
        pad_to: if set, the returned frame is zero-padded to at least
            this many bytes. Used to reach the 60-byte wire minimum.
            If the natural frame is already >= pad_to, no padding is
            added.
    """
    frame = build_eth_header(dst, src, ethertype) + payload
    if pad_to is not None and len(frame) < pad_to:
        frame = frame + bytes(pad_to - len(frame))
    return frame


def parse_eth_header(frame: bytes) -> dict:
    """Parse a 14-byte Ethernet II header.

    Returns a dict with keys: dst (bytes), src (bytes), ethertype (int).
    Raises ValueError if the frame is shorter than 14 bytes.
    """
    if len(frame) < ETH_HEADER_LEN:
        raise ValueError(f"frame too short for Ethernet header: {len(frame)}")
    dst = frame[0:6]
    src = frame[6:12]
    (ethertype,) = struct.unpack("!H", frame[12:14])
    return {"dst": dst, "src": src, "ethertype": ethertype}


# --- ARP ---

def _build_arp_payload(opcode: int,
                       sha: bytes, spa: str,
                       tha: bytes, tpa: str) -> bytes:
    """Build the 28-byte ARP payload (no Ethernet header)."""
    if len(sha) != 6 or len(tha) != 6:
        raise ValueError("ARP HW addresses must be 6 bytes")
    return struct.pack(
        "!HHBBH6s4s6s4s",
        ARP_HTYPE_ETH,
        ARP_PTYPE_IPV4,
        ARP_HLEN_ETH,
        ARP_PLEN_IPV4,
        opcode,
        sha,
        socket.inet_aton(spa),
        tha,
        socket.inet_aton(tpa),
    )


def build_arp_request(src_mac: bytes, src_ip: str, target_ip: str,
                      *, dst_mac: bytes = BROADCAST_MAC) -> bytes:
    """Build a complete ARP "who has target_ip" request frame.

    Args:
        src_mac: requester's MAC (sender HW address)
        src_ip: requester's IP (sender protocol address)
        target_ip: IP being queried
        dst_mac: Ethernet destination — defaults to broadcast (the
            standard ARP request destination). Tests can override to
            send unicast ARP for filtering coverage.

    The returned frame is padded to 60 bytes so it meets Ethernet
    minimum-size at the wire. The Pi's eth_type() validates >= 14, so
    padding is harmless.
    """
    arp = _build_arp_payload(
        ARP_OP_REQUEST,
        sha=src_mac, spa=src_ip,
        tha=ZERO_MAC, tpa=target_ip,
    )
    return build_eth_frame(dst_mac, src_mac, ETHERTYPE_ARP, arp,
                           pad_to=ETH_MIN_FRAME)


def build_arp_reply(src_mac: bytes, src_ip: str,
                    target_mac: bytes, target_ip: str) -> bytes:
    """Build an ARP reply frame.

    The Ethernet destination is `target_mac` (unicast back to the
    original requester), per RFC 826.
    """
    arp = _build_arp_payload(
        ARP_OP_REPLY,
        sha=src_mac, spa=src_ip,
        tha=target_mac, tpa=target_ip,
    )
    return build_eth_frame(target_mac, src_mac, ETHERTYPE_ARP, arp,
                           pad_to=ETH_MIN_FRAME)


def parse_arp(frame: bytes) -> dict:
    """Parse an ARP frame (Ethernet + ARP payload).

    Returns dict: {opcode, sha, spa, tha, tpa, eth_dst, eth_src}.
    Raises ValueError if the frame is not a valid Ethernet+ARP packet.
    """
    eth = parse_eth_header(frame)
    if eth["ethertype"] != ETHERTYPE_ARP:
        raise ValueError(f"not an ARP frame: ethertype={eth['ethertype']:#x}")
    if len(frame) < ETH_HEADER_LEN + ARP_PACKET_LEN:
        raise ValueError(f"frame too short for ARP: {len(frame)}")

    body = frame[ETH_HEADER_LEN:ETH_HEADER_LEN + ARP_PACKET_LEN]
    htype, ptype, hlen, plen, opcode, sha, spa, tha, tpa = struct.unpack(
        "!HHBBH6s4s6s4s", body
    )
    if htype != ARP_HTYPE_ETH or ptype != ARP_PTYPE_IPV4:
        raise ValueError(
            f"unsupported ARP htype/ptype: {htype:#x}/{ptype:#x}"
        )
    if hlen != ARP_HLEN_ETH or plen != ARP_PLEN_IPV4:
        raise ValueError(
            f"unsupported ARP hlen/plen: {hlen}/{plen}"
        )
    return {
        "eth_dst": eth["dst"],
        "eth_src": eth["src"],
        "opcode":  opcode,
        "sha":     sha,
        "spa":     socket.inet_ntoa(spa),
        "tha":     tha,
        "tpa":     socket.inet_ntoa(tpa),
    }


# --- Boundary-test frame builders ---
#
# These intentionally produce frames that violate Ethernet/eth.S rules.
# Used by test_l2_malformed.py to verify the Pi drops them without
# crashing AND remains responsive afterward.

def build_runt(dst: bytes, src: bytes, length: int,
               ethertype: int = ETHERTYPE_ARP) -> bytes:
    """Build a frame shorter than the 60-byte Ethernet minimum.

    Args:
        length: total frame length in bytes (must be >= ETH_HEADER_LEN
            so the header is well-formed). Common runt lengths: 14, 30, 59.

    NOTE: most NICs (and many USB Ethernet adapters) silently pad
    sub-60-byte frames to 60 bytes on transmit. test_l2_malformed.py
    detects this and marks runt subtests xfail when applicable.
    """
    if length < ETH_HEADER_LEN:
        raise ValueError(
            f"runt length must be >= {ETH_HEADER_LEN} for header: got {length}"
        )
    if length >= ETH_MIN_FRAME:
        raise ValueError(
            f"runt length must be < {ETH_MIN_FRAME}: got {length}"
        )
    payload = bytes(length - ETH_HEADER_LEN)
    return build_eth_header(dst, src, ethertype) + payload


def build_oversize(dst: bytes, src: bytes, length: int,
                   ethertype: int = ETHERTYPE_ARP) -> bytes:
    """Build a frame larger than the 1514-byte Ethernet maximum.

    Args:
        length: total frame length in bytes. Common oversize lengths:
            1515 (one over eth.S limit), 1536 (genet UMAC max_frame),
            1537 (one over UMAC max_frame), 1600 (clearly oversized).
    """
    if length <= ETH_MAX_FRAME:
        raise ValueError(
            f"oversize length must be > {ETH_MAX_FRAME}: got {length}"
        )
    payload = bytes(length - ETH_HEADER_LEN)
    return build_eth_header(dst, src, ethertype) + payload


def build_bogus_ethertype(dst: bytes, src: bytes, ethertype: int,
                          payload_len: int = ETH_MIN_PAYLOAD) -> bytes:
    """Build a well-formed-but-unrecognized-ethertype frame.

    The Pi's lib/eth.S only recognizes ETHERTYPE_ARP and ETHERTYPE_IPV4.
    Anything else should be silently dropped without affecting the Pi's
    ability to handle subsequent valid frames.
    """
    return build_eth_frame(dst, src, ethertype, bytes(payload_len),
                           pad_to=ETH_MIN_FRAME)
