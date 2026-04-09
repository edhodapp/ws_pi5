"""
ip_frames.py — IPv4, ICMP, UDP, and fragment construction & parsing.

Pure functions, no I/O. Mirrors the style of eth_frames.py and is
intentionally importable from anywhere with no side effects so it can
be unit-tested off-hardware.

Used by test_l3_*.py tests via wire.send_frame() and WireCapture.

Layering on top of eth_frames.py: this module builds the L3/L4
payload, then hands it to eth_frames.build_eth_frame() to wrap with
an Ethernet header. Combined "build_*_frame" helpers at the bottom
of this module do both steps in one call.
"""

import socket
import struct

from eth_frames import ETHERTYPE_IPV4, build_eth_header


# --- IPv4 constants ---

IP_VERSION_4  = 4
IP_HDR_MIN    = 20            # bytes, no options (VER_IHL == 0x45)
IP_DEFAULT_TTL = 64

IP_PROTO_ICMP = 1
IP_PROTO_TCP  = 6
IP_PROTO_UDP  = 17

# IP flags (high 3 bits of the 16-bit flags/frag_off word in host order)
IP_FLAG_DF = 0x4000   # Don't Fragment
IP_FLAG_MF = 0x2000   # More Fragments
IP_FRAG_OFFSET_MASK = 0x1FFF

# REASM_BUF_SIZE from include/net.inc — max bytes of reassembled IP
# payload the Pi's ip_reasm engine can buffer. The real drop threshold
# at completion is tighter (see REASM_COMPLETE_LIMIT) because the
# reassembled datagram must also fit in a 1514-byte Ethernet frame.
REASM_BUF_SIZE = 2048

# Reassembly completion ceiling: ip_reasm_input drops the completed
# datagram if REASM_TOTAL_LEN + ETH_HDR_LEN + IP_HDR_MIN > ETH_FRAME_MAX,
# i.e. payload_len > 1514 - 14 - 20 = 1480. Tests that want to probe
# the oversize drop path must exceed this value but keep each
# individual fragment's (frag_off + payload_len) within REASM_BUF_SIZE.
REASM_COMPLETE_LIMIT = 1480


# --- ICMP constants ---

ICMP_ECHO_REQUEST     = 8
ICMP_ECHO_REPLY       = 0
ICMP_DEST_UNREACHABLE = 3
ICMP_REDIRECT         = 5
ICMP_TIME_EXCEEDED    = 11
ICMP_PARAM_PROBLEM    = 12

ICMP_CODE_NET_UNREACH   = 0
ICMP_CODE_HOST_UNREACH  = 1
ICMP_CODE_PROTO_UNREACH = 2
ICMP_CODE_PORT_UNREACH  = 3

ICMP_HDR_LEN = 8


# --- UDP constants ---

UDP_HDR_LEN = 8
UDP_ECHO_PORT = 7
NTP_PORT = 123


# --- One's-complement checksum (RFC 1071) ---

def ip_checksum(data: bytes) -> int:
    """16-bit ones' complement checksum over `data` per RFC 1071.

    For an IP header that includes the correct checksum in place, this
    returns 0. To build a new header, zero the checksum field, call
    this, and store the result.

    Handles odd-length buffers by padding a trailing zero byte (the
    tail byte becomes the high byte of an implicit 16-bit word).
    """
    if len(data) & 1:
        data = data + b"\x00"
    s = 0
    # struct.unpack_from is faster than a python-level byte loop and
    # matches Pi-side behaviour (both sum 16-bit words). We use
    # network-byte-order ("!H") here — the output is a 16-bit number
    # in *host* order that the caller is free to pack into the frame
    # with "!H". The Pi's ip_checksum in lib/ip.S uses ldrh (little-
    # endian halfwords) but because RFC 1071's fold is symmetric the
    # byte order cancels; both implementations produce the same
    # wire-format checksum.
    words = struct.unpack(f"!{len(data) // 2}H", data)
    for w in words:
        s += w
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


# --- IPv4 header build/parse ---

def build_ipv4_header(
    src_ip: str,
    dst_ip: str,
    *,
    protocol: int,
    payload_len: int,
    ttl: int = IP_DEFAULT_TTL,
    ident: int = 0,
    flags: int = 0,          # IP_FLAG_DF / IP_FLAG_MF
    frag_off: int = 0,       # byte offset; must be multiple of 8
    tos: int = 0,
    version: int = IP_VERSION_4,
    ihl: int = 5,            # in 32-bit words — 5 = no options
    checksum: int | None = None,
) -> bytes:
    """Build a 20-byte IPv4 header (no options, i.e. ihl must be 5
    for the Pi to accept — the Pi requires VER_IHL == 0x45 exactly).

    Args:
        src_ip, dst_ip: dotted-quad strings
        protocol: IP_PROTO_{ICMP,UDP,TCP} or an arbitrary byte (used
            by malformed-header tests to force ip_handle's drop path)
        payload_len: number of bytes that will follow the header; the
            total_length field is written as payload_len + 20
        ttl: time-to-live byte (0..255)
        ident: 16-bit identification
        flags: 16-bit flags field, high 3 bits (DF/MF/reserved).
            Must NOT have offset bits set — use frag_off for that.
        frag_off: byte offset of this fragment from the start of the
            reassembled payload. Must be a multiple of 8. Encoded as
            frag_off // 8 in the low 13 bits of the wire flags field.
        tos: 8-bit TOS / DSCP+ECN byte
        version: 4 by default; tests set this to exercise the
            VER_IHL != 0x45 drop path on the Pi
        ihl: 5 by default (no options); tests set this < 5 or > 5
            to exercise the same drop path
        checksum: if None (default), the correct checksum is computed
            and stored. If an int, it is used verbatim — this is how
            bad-checksum tests force a non-zero verify result on the Pi.

    Returns the 20-byte header as bytes. Does not include any payload.
    """
    if not (0 <= version <= 0xF):
        raise ValueError(f"version out of range: {version}")
    if not (0 <= ihl <= 0xF):
        raise ValueError(f"ihl out of range: {ihl}")
    if not (0 <= tos <= 0xFF):
        raise ValueError(f"tos out of range: {tos}")
    if not (0 <= ttl <= 0xFF):
        raise ValueError(f"ttl out of range: {ttl}")
    if not (0 <= protocol <= 0xFF):
        raise ValueError(f"protocol out of range: {protocol}")
    if not (0 <= ident <= 0xFFFF):
        raise ValueError(f"ident out of range: {ident}")
    if payload_len < 0 or payload_len > 0xFFFF - IP_HDR_MIN:
        raise ValueError(f"payload_len out of range: {payload_len}")
    if frag_off < 0 or frag_off > (IP_FRAG_OFFSET_MASK * 8):
        raise ValueError(f"frag_off out of range: {frag_off}")
    if frag_off & 0x7:
        raise ValueError(f"frag_off must be multiple of 8: {frag_off}")
    if flags & IP_FRAG_OFFSET_MASK:
        raise ValueError(
            f"flags must not overlap frag_off bits: {flags:#06x}"
        )

    ver_ihl = (version << 4) | ihl
    total_length = payload_len + IP_HDR_MIN
    frag_word = flags | (frag_off >> 3)

    header = struct.pack(
        "!BBHHHBBH4s4s",
        ver_ihl,
        tos,
        total_length,
        ident,
        frag_word,
        ttl,
        protocol,
        0,                           # checksum placeholder
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip),
    )
    if checksum is None:
        cksum = ip_checksum(header)
    else:
        if not (0 <= checksum <= 0xFFFF):
            raise ValueError(f"checksum out of range: {checksum}")
        cksum = checksum
    # Splice the computed checksum into bytes 10..12
    return header[:10] + struct.pack("!H", cksum) + header[12:]


def parse_ipv4_header(data: bytes) -> dict:
    """Parse a 20-byte IPv4 header.

    Returns dict keys: version, ihl, tos, total_length, ident,
    flags (just the high 3 bits, shifted), frag_off (bytes),
    ttl, protocol, checksum, src_ip, dst_ip.
    """
    if len(data) < IP_HDR_MIN:
        raise ValueError(f"too short for IPv4 header: {len(data)}")
    (ver_ihl, tos, total_length, ident, frag_word, ttl, protocol,
     checksum, src_bytes, dst_bytes) = struct.unpack(
        "!BBHHHBBH4s4s", data[:IP_HDR_MIN]
    )
    return {
        "version":      ver_ihl >> 4,
        "ihl":          ver_ihl & 0xF,
        "tos":          tos,
        "total_length": total_length,
        "ident":        ident,
        "flags":        frag_word & ~IP_FRAG_OFFSET_MASK,
        "frag_off":     (frag_word & IP_FRAG_OFFSET_MASK) * 8,
        "ttl":          ttl,
        "protocol":     protocol,
        "checksum":     checksum,
        "src_ip":       socket.inet_ntoa(src_bytes),
        "dst_ip":       socket.inet_ntoa(dst_bytes),
    }


# --- ICMP build/parse ---

def build_icmp_echo_request(
    ident: int,
    seq: int,
    payload: bytes = b"",
    *,
    bad_checksum: bool = False,
) -> bytes:
    """Build an ICMP echo request (type 8, code 0) with the given
    (ident, seq) and payload.

    The returned bytes are just the ICMP portion — the caller wraps
    them in an IP header. Use build_icmp_echo_frame() for the full
    Ethernet+IP+ICMP combo.

    Args:
        bad_checksum: if True, force the stored checksum to 0xDEAD so
            the Pi's icmp_handle path takes the "bad checksum → drop"
            branch. Used by test_l3_malformed_ip.py.
    """
    if not (0 <= ident <= 0xFFFF):
        raise ValueError(f"ident out of range: {ident}")
    if not (0 <= seq <= 0xFFFF):
        raise ValueError(f"seq out of range: {seq}")

    header = struct.pack(
        "!BBHHH",
        ICMP_ECHO_REQUEST,
        0,                           # code
        0,                           # checksum placeholder
        ident,
        seq,
    )
    body = header + payload
    if bad_checksum:
        cksum = 0xDEAD
    else:
        cksum = ip_checksum(body)
    return body[:2] + struct.pack("!H", cksum) + body[4:]


def build_icmp_raw(
    icmp_type: int, icmp_code: int, rest_of_header: bytes,
    payload: bytes = b"",
) -> bytes:
    """Build a generic ICMP message with an arbitrary type/code and a
    4-byte "rest of header" field. Used by the loop-suppression test
    which needs to send an ICMP dest-unreachable *to* the Pi, not an
    echo request.
    """
    if not (0 <= icmp_type <= 0xFF):
        raise ValueError(f"icmp_type out of range: {icmp_type}")
    if not (0 <= icmp_code <= 0xFF):
        raise ValueError(f"icmp_code out of range: {icmp_code}")
    if len(rest_of_header) != 4:
        raise ValueError(
            f"rest_of_header must be 4 bytes, got {len(rest_of_header)}"
        )
    # header = type(1) + code(1) + checksum(2) + rest(4) = 8 bytes
    header = struct.pack("!BBH", icmp_type, icmp_code, 0) + rest_of_header
    body = header + payload
    cksum = ip_checksum(body)
    return body[:2] + struct.pack("!H", cksum) + body[4:]


def parse_icmp(data: bytes) -> dict:
    """Parse an ICMP message header + payload.

    Returns dict: type, code, checksum, ident, seq, rest (the 4-byte
    "rest of header" as raw bytes), payload (everything past the
    8-byte header).

    For echo request/reply, ident and seq are the parsed fields. For
    other ICMP types, ident/seq are still provided (from the same
    offsets) but the "rest" bytes are the authoritative view.
    """
    if len(data) < ICMP_HDR_LEN:
        raise ValueError(f"too short for ICMP header: {len(data)}")
    icmp_type, icmp_code, checksum, ident, seq = struct.unpack(
        "!BBHHH", data[:ICMP_HDR_LEN]
    )
    return {
        "type":     icmp_type,
        "code":     icmp_code,
        "checksum": checksum,
        "ident":    ident,
        "seq":      seq,
        "rest":     data[4:8],
        "payload":  data[ICMP_HDR_LEN:],
    }


# --- UDP build/parse ---

def build_udp_header(
    src_port: int, dst_port: int, payload: bytes,
    *,
    checksum: int | None = None,
    pseudo_src_ip: str | None = None,
    pseudo_dst_ip: str | None = None,
) -> bytes:
    """Build a UDP header + payload.

    The Pi's udp_handle accepts UDP datagrams with checksum == 0
    (RFC 768 "not computed") OR a correct one. By default we set the
    checksum to 0 because that matches RFC 768's "the checksum is
    optional for IPv4" behaviour and keeps negative-test frames
    unambiguous. Pass pseudo_src_ip/dst_ip plus checksum=None to
    compute a real checksum.
    """
    if not (0 <= src_port <= 0xFFFF):
        raise ValueError(f"src_port out of range: {src_port}")
    if not (0 <= dst_port <= 0xFFFF):
        raise ValueError(f"dst_port out of range: {dst_port}")
    length = UDP_HDR_LEN + len(payload)
    if length > 0xFFFF:
        raise ValueError(f"udp length out of range: {length}")

    if checksum is None and pseudo_src_ip and pseudo_dst_ip:
        # Compute real UDP checksum with IPv4 pseudo-header.
        header = struct.pack("!HHHH", src_port, dst_port, length, 0)
        udp_segment = header + payload
        pseudo = (
            socket.inet_aton(pseudo_src_ip)
            + socket.inet_aton(pseudo_dst_ip)
            + struct.pack("!BBH", 0, IP_PROTO_UDP, length)
        )
        cksum = ip_checksum(pseudo + udp_segment)
        if cksum == 0:
            cksum = 0xFFFF  # RFC 768: 0 means "not computed", use 0xFFFF
        return struct.pack("!HHHH", src_port, dst_port, length, cksum) + payload
    if checksum is None:
        cksum = 0  # "not computed"
    else:
        if not (0 <= checksum <= 0xFFFF):
            raise ValueError(f"checksum out of range: {checksum}")
        cksum = checksum
    return struct.pack("!HHHH", src_port, dst_port, length, cksum) + payload


# --- Combined frame builders (Ethernet + IP + L4) ---

def build_icmp_echo_frame(
    src_mac: bytes, dst_mac: bytes,
    src_ip: str, dst_ip: str,
    *,
    ident: int, seq: int,
    payload: bytes = b"",
    ttl: int = IP_DEFAULT_TTL,
    ip_ident: int = 0,
    df: bool = False,
    bad_ip_checksum: bool = False,
    bad_icmp_checksum: bool = False,
) -> bytes:
    """Build an end-to-end Ethernet frame containing an ICMP echo
    request. Each knob is a test's single independent variable; the
    defaults produce a well-formed frame that the Pi will reply to.

    Args:
        df: set the Don't Fragment flag (the Pi accepts DF either way;
            this is primarily for pinning that behaviour)
        bad_ip_checksum: force a wrong IP checksum (0x1234)
        bad_icmp_checksum: force a wrong ICMP checksum
    """
    icmp = build_icmp_echo_request(ident, seq, payload,
                                   bad_checksum=bad_icmp_checksum)
    flags = IP_FLAG_DF if df else 0
    ip = build_ipv4_header(
        src_ip, dst_ip,
        protocol=IP_PROTO_ICMP,
        payload_len=len(icmp),
        ttl=ttl,
        ident=ip_ident,
        flags=flags,
        checksum=(0x1234 if bad_ip_checksum else None),
    )
    return build_eth_header(dst_mac, src_mac, ETHERTYPE_IPV4) + ip + icmp


def build_udp_frame(
    src_mac: bytes, dst_mac: bytes,
    src_ip: str, dst_ip: str,
    *,
    src_port: int, dst_port: int,
    payload: bytes = b"",
    ttl: int = IP_DEFAULT_TTL,
    ip_ident: int = 0,
    udp_checksum: int | None = 0,
) -> bytes:
    """Build an Ethernet + IPv4 + UDP frame. Used by
    test_l3_icmp_errors.py to trigger port-unreachable replies from
    the Pi's udp_handle.

    The default udp_checksum=0 ("not computed") bypasses the checksum
    verify path on the Pi — we just want the port-dispatch path to
    reach the "unknown port → ICMP error" branch.
    """
    udp = build_udp_header(src_port, dst_port, payload,
                           checksum=udp_checksum)
    ip = build_ipv4_header(
        src_ip, dst_ip,
        protocol=IP_PROTO_UDP,
        payload_len=len(udp),
        ttl=ttl,
        ident=ip_ident,
    )
    return build_eth_header(dst_mac, src_mac, ETHERTYPE_IPV4) + ip + udp


def build_ip_frame_with_proto(
    src_mac: bytes, dst_mac: bytes,
    src_ip: str, dst_ip: str,
    *,
    protocol: int,
    payload: bytes = b"",
    ttl: int = IP_DEFAULT_TTL,
    ip_ident: int = 0,
) -> bytes:
    """Build an Ethernet + IPv4 frame carrying an arbitrary protocol
    byte and payload. Used by test_l3_icmp_errors.py to trigger the
    "protocol unreachable" path in ip_handle by setting protocol to
    something the Pi doesn't dispatch (e.g. 99)."""
    ip = build_ipv4_header(
        src_ip, dst_ip,
        protocol=protocol,
        payload_len=len(payload),
        ttl=ttl,
        ident=ip_ident,
    )
    return build_eth_header(dst_mac, src_mac, ETHERTYPE_IPV4) + ip + payload


# --- Fragment splitter ---

def build_fragment_frames(
    src_mac: bytes, dst_mac: bytes,
    src_ip: str, dst_ip: str,
    *,
    protocol: int,
    payload: bytes,
    ident: int,
    frag_size: int,
    ttl: int = IP_DEFAULT_TTL,
) -> list[bytes]:
    """Split `payload` into fragments of `frag_size` bytes (except the
    last which may be shorter), wrap each in an IPv4 header + Ethernet
    header, and return the list in original order.

    All fragments share the same IP.id. Non-last fragments have MF=1
    and `frag_size` MUST be a multiple of 8 (the Pi's ip_reasm_input
    drops non-aligned middle/head fragments). The last fragment has
    MF=0 and may have an unaligned length.

    The caller is responsible for:
      - reordering (tests that exercise out-of-order reassembly)
      - keeping total payload bytes within REASM_COMPLETE_LIMIT if
        they want the reassembly to complete successfully
      - keeping individual `frag_off + frag_size` within REASM_BUF_SIZE
    """
    if frag_size <= 0:
        raise ValueError(f"frag_size must be > 0: {frag_size}")
    if frag_size & 0x7:
        raise ValueError(
            f"frag_size must be multiple of 8 (MF fragments require "
            f"alignment): {frag_size}"
        )
    if len(payload) == 0:
        raise ValueError("payload must be non-empty to fragment")

    frames: list[bytes] = []
    offset = 0
    while offset < len(payload):
        chunk = payload[offset:offset + frag_size]
        is_last = (offset + len(chunk)) >= len(payload)
        flags = 0 if is_last else IP_FLAG_MF
        ip = build_ipv4_header(
            src_ip, dst_ip,
            protocol=protocol,
            payload_len=len(chunk),
            ttl=ttl,
            ident=ident,
            flags=flags,
            frag_off=offset,
        )
        frame = build_eth_header(dst_mac, src_mac, ETHERTYPE_IPV4) + ip + chunk
        frames.append(frame)
        offset += len(chunk)
    return frames


def reassemble_fragments_python(frames: list[bytes]) -> bytes:
    """Python-side reference reassembler used by the off-hardware unit
    test to prove build_fragment_frames is correct before we ever send
    a fragment to the Pi. Takes a list of frames, parses each IP
    header, sorts by frag_off, and concatenates the payloads.

    This is NOT a hardened reassembler — no overlap detection, no MF
    gap check. It exists purely to round-trip the splitter in the unit
    test, same way test_eth_frames_unit.py round-trips build_arp_*.
    """
    from eth_frames import ETH_HEADER_LEN  # local import: avoids circular
    pieces: list[tuple[int, bytes]] = []
    for f in frames:
        ip = parse_ipv4_header(f[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        start = ETH_HEADER_LEN + IP_HDR_MIN
        end = ETH_HEADER_LEN + ip["total_length"]
        pieces.append((ip["frag_off"], f[start:end]))
    pieces.sort(key=lambda p: p[0])
    return b"".join(p[1] for p in pieces)


# --- Bogus / malformed IP builder ---

def build_bogus_ip_frame(
    src_mac: bytes, dst_mac: bytes,
    src_ip: str, dst_ip: str,
    *,
    version: int = IP_VERSION_4,
    ihl: int = 5,
    tos: int = 0,
    total_length_override: int | None = None,
    ident: int = 0,
    flags: int = 0,
    frag_off: int = 0,
    ttl: int = IP_DEFAULT_TTL,
    protocol: int = IP_PROTO_ICMP,
    bad_checksum: bool = False,
    options: bytes = b"",
    payload: bytes = b"",
    truncate_to: int | None = None,
) -> bytes:
    """Build an Ethernet + IPv4 frame with one or more fields out of
    spec. Used by test_l3_malformed_ip.py — each test flips exactly
    one knob at a time so the failure is attributable to that knob.

    Args:
        version: defaults to 4; set to 6 to test the Pi's drop-on-
            "VER_IHL != 0x45" path without leaving IPv4 ethertype
        ihl: defaults to 5 (no options); set to 4 (below minimum) or
            6 (with 4 bytes of options) to test the same drop path
        total_length_override: if set, this value is written into the
            IP total_length field verbatim. If None, total_length is
            computed as IP_HDR_MIN + len(options) + len(payload).
        options: if ihl > 5 you MUST provide (ihl - 5) * 4 bytes of
            options (or the header length field won't match the
            on-wire layout)
        bad_checksum: if True, the IP checksum is forced to 0xBEEF.
        truncate_to: if set, the built frame is truncated to this
            many bytes (after Ethernet header). Used to send a frame
            shorter than its declared IP total_length.
    """
    if options and len(options) != (ihl - 5) * 4:
        raise ValueError(
            f"options length {len(options)} does not match ihl {ihl}: "
            f"expected {(ihl - 5) * 4}"
        )
    if ihl > 5 and not options:
        options = bytes((ihl - 5) * 4)

    # Build the header fields manually to allow an override of total_length.
    ver_ihl = (version << 4) | ihl
    if total_length_override is not None:
        total_length = total_length_override
    else:
        total_length = IP_HDR_MIN + len(options) + len(payload)
    if not (0 <= total_length <= 0xFFFF):
        raise ValueError(f"total_length out of range: {total_length}")
    frag_word = (flags & ~IP_FRAG_OFFSET_MASK) | ((frag_off >> 3) & IP_FRAG_OFFSET_MASK)

    header = struct.pack(
        "!BBHHHBBH4s4s",
        ver_ihl,
        tos,
        total_length,
        ident,
        frag_word,
        ttl,
        protocol,
        0,                           # checksum placeholder
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip),
    )
    # Compute checksum over the full header including any options.
    if bad_checksum:
        cksum = 0xBEEF
    else:
        cksum = ip_checksum(header + options)
    header = header[:10] + struct.pack("!H", cksum) + header[12:]

    frame = build_eth_header(dst_mac, src_mac, ETHERTYPE_IPV4) + header + options + payload
    if truncate_to is not None:
        # truncate_to counts post-Ethernet bytes (i.e. IP section)
        from eth_frames import ETH_HEADER_LEN  # local import
        frame = frame[:ETH_HEADER_LEN + truncate_to]
    return frame
