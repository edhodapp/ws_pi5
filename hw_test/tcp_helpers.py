"""
tcp_helpers.py — Raw TCP packet construction for integration tests

Builds TCP segments with full control over flags, options (WSCALE,
SACK-Permitted, Timestamps, SACK blocks), and sequence numbers.
Used by raw-socket tests that need to exercise specific TCP behaviors
on the bare-metal stack.
"""

import struct
import socket


def ip_checksum(data: bytes) -> int:
    """RFC 1071 ones' complement checksum."""
    if len(data) % 2:
        data += b'\x00'
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def tcp_checksum(src_ip: str, dst_ip: str, tcp_segment: bytes) -> int:
    """TCP checksum with pseudo-header."""
    src = socket.inet_aton(src_ip)
    dst = socket.inet_aton(dst_ip)
    pseudo = src + dst + struct.pack('!BBH', 0, 6, len(tcp_segment))
    return ip_checksum(pseudo + tcp_segment)


def build_ip_header(src_ip: str, dst_ip: str, payload_len: int,
                     proto: int = 6, ttl: int = 64) -> bytes:
    """Build IPv4 header with correct checksum."""
    total_len = 20 + payload_len
    hdr = struct.pack('!BBHHHBBH4s4s',
        0x45, 0x00,
        total_len,
        0x1234, 0x4000,  # ID, DF flag
        ttl, proto,
        0,  # checksum placeholder
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip))
    cksum = ip_checksum(hdr)
    return hdr[:10] + struct.pack('!H', cksum) + hdr[12:]


def build_tcp_segment(src_port: int, dst_port: int, seq: int, ack: int,
                       flags: int, window: int = 65535,
                       payload: bytes = b'',
                       options: bytes = b'') -> bytes:
    """Build a TCP segment (header + options + payload).

    Args:
        flags: TCP flag bits (SYN=0x02, ACK=0x10, FIN=0x01, RST=0x04, PSH=0x08)
        options: pre-built TCP options (must be padded to 4-byte boundary)
    """
    header_len = 20 + len(options)
    assert header_len % 4 == 0, "TCP header must be 4-byte aligned"
    data_offset = (header_len // 4) << 4

    hdr = struct.pack('!HHIIBBHHH',
        src_port, dst_port,
        seq, ack,
        data_offset, flags,
        window,
        0,  # checksum placeholder
        0)  # urgent pointer

    return hdr + options + payload


def build_tcp_packet(src_ip: str, dst_ip: str,
                      src_port: int, dst_port: int,
                      seq: int, ack: int, flags: int,
                      window: int = 65535,
                      payload: bytes = b'',
                      options: bytes = b'') -> bytes:
    """Build a complete IP + TCP packet with correct checksums."""
    segment = build_tcp_segment(src_port, dst_port, seq, ack,
                                 flags, window, payload, options)
    # Compute TCP checksum
    cksum = tcp_checksum(src_ip, dst_ip, segment)
    segment = segment[:16] + struct.pack('!H', cksum) + segment[18:]

    ip_hdr = build_ip_header(src_ip, dst_ip, len(segment))
    return ip_hdr + segment


# --- TCP Option Builders ---

def opt_mss(mss: int = 1460) -> bytes:
    """MSS option: Kind=2, Len=4, Value."""
    return struct.pack('!BBH', 2, 4, mss)


def opt_wscale(shift: int = 7) -> bytes:
    """Window Scale option: NOP + Kind=3, Len=3, Shift."""
    return struct.pack('!BBBB', 1, 3, 3, shift)


def opt_sack_permitted() -> bytes:
    """SACK-Permitted option: NOP + NOP + Kind=4, Len=2."""
    return struct.pack('!BBBB', 1, 1, 4, 2)


def opt_timestamps(tsval: int, tsecr: int = 0) -> bytes:
    """Timestamps option: NOP + NOP + Kind=8, Len=10, TSval, TSecr."""
    return struct.pack('!BBBBII', 1, 1, 8, 10, tsval, tsecr)


def opt_sack_blocks(blocks: list) -> bytes:
    """SACK blocks option: NOP + NOP + Kind=5, Len=2+8*n, blocks.

    Args:
        blocks: list of (left_edge, right_edge) tuples
    """
    n = len(blocks)
    assert 1 <= n <= 4
    data = struct.pack('!BB', 5, 2 + 8 * n)
    for left, right in blocks:
        data += struct.pack('!II', left, right)
    return b'\x01\x01' + data  # NOP NOP prefix


def syn_options(mss: int = 1460, wscale: int = 7,
                sack_permitted: bool = True) -> bytes:
    """Standard SYN options: MSS + WSCALE + SACK-Permitted, padded."""
    opts = opt_mss(mss) + opt_wscale(wscale)
    if sack_permitted:
        opts += opt_sack_permitted()
    # Pad to 4-byte boundary
    while len(opts) % 4:
        opts += b'\x00'
    return opts


# --- TCP Flag Constants ---

FIN = 0x01
SYN = 0x02
RST = 0x04
PSH = 0x08
ACK = 0x10
SYN_ACK = SYN | ACK
FIN_ACK = FIN | ACK
PSH_ACK = PSH | ACK


# --- Packet Parsing ---

def parse_tcp_header(data: bytes, offset: int = 0):
    """Parse a TCP header from raw bytes.

    Returns dict with: src_port, dst_port, seq, ack, data_offset,
    flags, window, checksum, urgent, options (raw bytes).
    """
    if len(data) < offset + 20:
        return None

    fields = struct.unpack_from('!HHIIBBHHH', data, offset)
    src_port, dst_port, seq, ack_num, doff_flags, flags, window, cksum, urgent = fields

    data_offset = (doff_flags >> 4) * 4
    options = data[offset + 20:offset + data_offset] if data_offset > 20 else b''

    return {
        'src_port': src_port,
        'dst_port': dst_port,
        'seq': seq,
        'ack': ack_num,
        'data_offset': data_offset,
        'flags': flags,
        'window': window,
        'checksum': cksum,
        'urgent': urgent,
        'options': options,
    }


def parse_ip_header(data: bytes):
    """Parse IPv4 header. Returns dict with key fields."""
    if len(data) < 20:
        return None
    fields = struct.unpack_from('!BBHHHBBH4s4s', data)
    ver_ihl, dscp, total_len, ident, flags_frag, ttl, proto, cksum, src, dst = fields
    return {
        'version': ver_ihl >> 4,
        'ihl': (ver_ihl & 0x0F) * 4,
        'total_len': total_len,
        'ttl': ttl,
        'proto': proto,
        'src': socket.inet_ntoa(src),
        'dst': socket.inet_ntoa(dst),
    }
