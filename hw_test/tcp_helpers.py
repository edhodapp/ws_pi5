"""
tcp_helpers.py — Raw TCP packet construction for integration tests.

Builds TCP segments with full control over flags, options (WSCALE,
SACK-Permitted, Timestamps, SACK blocks), and sequence numbers.
Used by raw-socket tests that need to exercise specific TCP behaviors
on the bare-metal stack.

Two layers:
  - Low-level: build_tcp_segment, build_tcp_packet, build_tcp_frame
  - High-level: RawTCPSession — stateful seq/ack driver for
    multi-segment exchanges (handshake, data, close) via raw L2
"""

# pylint: disable=line-too-long,inconsistent-quotes,unused-variable
# mypy: disable-error-code="no-untyped-def,call-overload,return-value,type-arg,no-any-return"
# flake8: noqa: E127,E128,E501
from __future__ import annotations

import struct
import socket
from typing import Optional

import eth_frames
import wire


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


def build_tcp_frame(
    src_mac: bytes, dst_mac: bytes,
    src_ip: str, dst_ip: str,
    src_port: int, dst_port: int,
    seq: int, ack: int, flags: int,
    window: int = 65535,
    payload: bytes = b'',
    options: bytes = b'',
) -> bytes:
    """Build a complete Ethernet + IP + TCP frame for wire.py.

    Returns bytes ready for wire.send_frame().
    """
    ip_tcp = build_tcp_packet(
        src_ip, dst_ip, src_port, dst_port,
        seq, ack, flags, window, payload, options,
    )
    eth_hdr = eth_frames.build_eth_header(
        dst_mac, src_mac, eth_frames.ETHERTYPE_IPV4,
    )
    return eth_hdr + ip_tcp


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


def parse_ip_header(data: bytes) -> Optional[dict[str, object]]:
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


# --- Stateful TCP Session Driver ---

ETH_HDR_LEN = 14
IP_HDR_LEN = 20
TCP_HDR_MIN = 20


def _is_tcp_from(
    frame: bytes,
    src_mac: bytes, dst_mac: bytes,
    src_ip: str, dst_ip: str,
    src_port: int, dst_port: int,
) -> bool:
    """Predicate: frame is a TCP segment from the expected peer."""
    if len(frame) < ETH_HDR_LEN + IP_HDR_LEN + TCP_HDR_MIN:
        return False
    eth = eth_frames.parse_eth_header(frame)
    if eth["src"] != src_mac or eth["dst"] != dst_mac:
        return False
    if eth["ethertype"] != eth_frames.ETHERTYPE_IPV4:
        return False
    ip = parse_ip_header(frame[ETH_HDR_LEN:ETH_HDR_LEN + IP_HDR_LEN])
    if ip is None or ip["proto"] != 6:
        return False
    if ip["src"] != src_ip or ip["dst"] != dst_ip:
        return False
    tcp = parse_tcp_header(frame, ETH_HDR_LEN + IP_HDR_LEN)
    if tcp is None:
        return False
    return tcp["src_port"] == src_port and tcp["dst_port"] == dst_port


class RawTCPSession:
    """Stateful TCP session driver using raw L2 frames.

    Tracks seq/ack numbers and provides methods for each phase
    of a TCP exchange. All frames are sent/received via wire.py
    raw sockets — no kernel TCP stack involvement.

    Usage::

        sess = RawTCPSession(
            iface, laptop_mac, pi_mac, laptop_ip, pi_ip,
            local_port=44444, remote_port=80,
        )
        synack = sess.connect()        # SYN → SYN-ACK → ACK
        reply = sess.send(b"GET / HTTP/1.1\\r\\n\\r\\n")
        sess.close()                    # FIN exchange
    """

    def __init__(
        self,
        iface: str,
        local_mac: bytes,
        remote_mac: bytes,
        local_ip: str,
        remote_ip: str,
        local_port: int,
        remote_port: int,
        deadline_ms: int = 2000,
    ) -> None:
        self.iface = iface
        self.local_mac = local_mac
        self.remote_mac = remote_mac
        self.local_ip = local_ip
        self.remote_ip = remote_ip
        self.local_port = local_port
        self.remote_port = remote_port
        self.deadline_ms = deadline_ms

        self.seq = 1000  # our ISN
        self.ack = 0     # peer's next expected seq
        self.peer_window = 0

    def _build(
        self,
        flags: int,
        payload: bytes = b"",
        options: bytes = b"",
        window: int = 65535,
        seq_override: Optional[int] = None,
        ack_override: Optional[int] = None,
    ) -> bytes:
        """Build an L2 frame for this session."""
        return build_tcp_frame(
            self.local_mac, self.remote_mac,
            self.local_ip, self.remote_ip,
            self.local_port, self.remote_port,
            seq_override if seq_override is not None else self.seq,
            ack_override if ack_override is not None else self.ack,
            flags, window, payload, options,
        )

    def _send_and_recv(
        self,
        frame: bytes,
        deadline_ms: Optional[int] = None,
    ) -> Optional[bytes]:
        """Send a frame and wait for one reply from the peer."""
        dl = deadline_ms or self.deadline_ms
        bpf = (
            f"tcp and src host {self.remote_ip} "
            f"and src port {self.remote_port} "
            f"and dst port {self.local_port}"
        )
        with wire.WireCapture(self.iface, bpf=bpf) as cap:
            wire.send_frame(self.iface, frame)
            reply = wire.wait_for_frame(
                cap,
                lambda data: _is_tcp_from(
                    data,
                    self.remote_mac, self.local_mac,
                    self.remote_ip, self.local_ip,
                    self.remote_port, self.local_port,
                ),
                deadline_ms=dl,
            )
        return reply

    def _parse_reply(self, frame: bytes) -> dict[str, object]:
        """Extract TCP header from a reply frame."""
        return parse_tcp_header(frame, ETH_HDR_LEN + IP_HDR_LEN)

    def _tcp_payload(self, frame: bytes) -> bytes:
        """Extract TCP payload from a reply frame."""
        ip = parse_ip_header(frame[ETH_HDR_LEN:])
        if ip is None:
            return b""
        ip_total = int(ip["total_len"])
        tcp = self._parse_reply(frame)
        tcp_hdr_len = int(tcp["data_offset"])
        payload_start = ETH_HDR_LEN + IP_HDR_LEN + tcp_hdr_len
        payload_end = ETH_HDR_LEN + ip_total
        if payload_end <= payload_start:
            return b""
        return frame[payload_start:payload_end]

    def connect(
        self, options: Optional[bytes] = None,
    ) -> dict[str, object]:
        """Three-way handshake: SYN → SYN-ACK → ACK.

        Returns the parsed SYN-ACK header.
        """
        if options is None:
            options = syn_options()

        # SYN
        syn = self._build(SYN, options=options)
        reply = self._send_and_recv(syn)
        assert reply is not None, "no SYN-ACK received"
        sa = self._parse_reply(reply)
        assert sa["flags"] == SYN_ACK, (
            f"expected SYN-ACK, got flags=0x{sa['flags']:02x}"
        )

        # Update state from SYN-ACK
        self.ack = (int(sa["seq"]) + 1) & 0xFFFFFFFF
        self.seq += 1  # SYN consumes one seq
        self.peer_window = int(sa["window"])
        # ACK
        ack_frame = self._build(ACK)
        wire.send_frame(self.iface, ack_frame)

        return sa

    def send(self, data: bytes) -> Optional[bytes]:
        """Send data and wait for the reply (ACK + optional data).

        Returns the full reply frame, or None on timeout.
        """
        frame = self._build(PSH_ACK, payload=data)
        reply = self._send_and_recv(frame)
        if reply is not None:
            payload = self._tcp_payload(reply)
            # Advance our seq by data sent
            self.seq = (self.seq + len(data)) & 0xFFFFFFFF
            # Advance ack by any payload received
            if payload:
                self.ack = (self.ack + len(payload)) & 0xFFFFFFFF
        return reply

    def send_fin(self) -> Optional[bytes]:
        """Send FIN+ACK and wait for peer's response."""
        frame = self._build(FIN_ACK)
        reply = self._send_and_recv(frame)
        if reply is not None:
            self.seq += 1  # FIN consumes one seq
        return reply

    def send_raw(
        self,
        flags: int,
        payload: bytes = b"",
        options: bytes = b"",
        window: int = 65535,
        seq_override: Optional[int] = None,
        ack_override: Optional[int] = None,
    ) -> Optional[bytes]:
        """Send an arbitrary segment and wait for reply.

        Does NOT update seq/ack state — caller manages manually.
        For testing specific protocol edge cases.
        """
        frame = self._build(
            flags, payload, options, window,
            seq_override, ack_override,
        )
        return self._send_and_recv(frame)

    def send_raw_no_wait(
        self,
        flags: int,
        payload: bytes = b"",
        options: bytes = b"",
        window: int = 65535,
        seq_override: Optional[int] = None,
        ack_override: Optional[int] = None,
    ) -> None:
        """Send an arbitrary segment without waiting for reply.

        Does NOT update seq/ack state.
        """
        frame = self._build(
            flags, payload, options, window,
            seq_override, ack_override,
        )
        wire.send_frame(self.iface, frame)

    def ack_last(self) -> None:
        """Send a bare ACK with current seq/ack (no wait)."""
        frame = self._build(ACK)
        wire.send_frame(self.iface, frame)
