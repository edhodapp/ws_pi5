#!/usr/bin/env python3
"""
gen_corpus_seq.py -- Generate seed corpus for multi-packet TCP sequence fuzzer

Builds binary seeds with computed IP/TCP checksums that exercise multi-step
TCP state transitions. Each seed is a sequence of length-prefixed Ethernet
frames: [u16be len][frame bytes][u16be len][frame bytes]...

Output: fuzz/corpus_seq/*.bin
"""

import os
import struct

# --- Network constants (must match lib/net_cfg.S and include/tcp.inc) ---

OUR_MAC  = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
PEER_MAC = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
OUR_IP   = bytes([0x0A, 0x00, 0x02, 0x0F])  # 10.0.2.15
PEER_IP  = bytes([0x0A, 0x00, 0x02, 0x02])  # 10.0.2.2

LISTEN_PORT = 80
PEER_PORT   = 12345

# ISN from fuzz harness counter: first call returns 0, so server ISN = 0
# After SYN-ACK, server's SND_NXT = ISN + 1 = 1
SERVER_ISN = 0

# TCP flags
FIN = 0x01
SYN = 0x02
RST = 0x04
PSH = 0x08
ACK = 0x10


def ip_checksum(data):
    """RFC 1071 one's-complement checksum over raw bytes."""
    if len(data) % 2:
        data = data + b'\x00'
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def tcp_checksum(src_ip, dst_ip, tcp_segment):
    """TCP checksum with pseudo-header."""
    tcp_len = len(tcp_segment)
    pseudo = src_ip + dst_ip + struct.pack('!BBH', 0, 6, tcp_len)
    return ip_checksum(pseudo + tcp_segment)


def build_frame(sport, dport, seq, ack_num, flags, window, payload=b''):
    """Build a complete ETH+IP+TCP frame with valid checksums.

    Returns the raw frame bytes (peer → us).
    """
    tcp_len = 20 + len(payload)
    ip_total = 20 + tcp_len

    # --- TCP header (checksum zeroed initially) ---
    tcp_hdr = struct.pack('!HHIIBBHHH',
        sport, dport,
        seq, ack_num,
        0x50,           # data offset = 5 words, reserved = 0
        flags,
        window,
        0,              # checksum placeholder
        0)              # urgent pointer
    tcp_seg = tcp_hdr + payload

    # Compute TCP checksum
    cksum = tcp_checksum(PEER_IP, OUR_IP, tcp_seg)
    tcp_seg = tcp_seg[:16] + struct.pack('!H', cksum) + tcp_seg[18:]

    # --- IP header (checksum zeroed initially) ---
    ip_hdr = struct.pack('!BBHHHBBH4s4s',
        0x45, 0x00,     # ver=4, ihl=5, DSCP/ECN=0
        ip_total,
        0x1234, 0x0000, # ID, flags/frag
        64, 6,          # TTL=64, proto=TCP
        0,              # checksum placeholder
        PEER_IP, OUR_IP)
    ip_cksum = ip_checksum(ip_hdr)
    ip_hdr = ip_hdr[:10] + struct.pack('!H', ip_cksum) + ip_hdr[12:]

    # --- Ethernet header ---
    eth = OUR_MAC + PEER_MAC + struct.pack('!H', 0x0800)

    return eth + ip_hdr + tcp_seg


def pack_sequence(frames):
    """Pack a list of frames into length-prefixed format."""
    out = b''
    for f in frames:
        out += struct.pack('!H', len(f)) + f
    return out


def main():
    outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'corpus_seq')
    os.makedirs(outdir, exist_ok=True)

    # Peer's initial SEQ for the SYN
    peer_seq = 1

    # After SYN-ACK from server: server expects ACK# = SERVER_ISN + 1 = 1
    # Server's RCV_NXT = peer_seq + 1 (after SYN consumes one seq)
    # So the ACK completing handshake needs:
    #   SEQ = peer_seq + 1 (our next seq after SYN)
    #   ACK = SERVER_ISN + 1 (ack the server's SYN-ACK)

    syn = build_frame(PEER_PORT, LISTEN_PORT,
                      seq=peer_seq, ack_num=0, flags=SYN, window=65535)
    handshake_ack = build_frame(PEER_PORT, LISTEN_PORT,
                                seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                                flags=ACK, window=65535)

    # 1. tcp_handshake.bin — SYN + ACK → ESTABLISHED
    seeds = {}
    seeds['tcp_handshake.bin'] = pack_sequence([syn, handshake_ack])

    # 2. tcp_handshake_data.bin — SYN + ACK + PSH+ACK("Hello")
    data_frame = build_frame(PEER_PORT, LISTEN_PORT,
                             seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                             flags=PSH | ACK, window=65535,
                             payload=b'Hello')
    seeds['tcp_handshake_data.bin'] = pack_sequence([syn, handshake_ack, data_frame])

    # 3. tcp_handshake_fin.bin — SYN + ACK + FIN+ACK
    fin_frame = build_frame(PEER_PORT, LISTEN_PORT,
                            seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                            flags=FIN | ACK, window=65535)
    seeds['tcp_handshake_fin.bin'] = pack_sequence([syn, handshake_ack, fin_frame])

    # 4. tcp_handshake_rst.bin — SYN + ACK + RST
    rst_frame = build_frame(PEER_PORT, LISTEN_PORT,
                            seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                            flags=RST, window=65535)
    seeds['tcp_handshake_rst.bin'] = pack_sequence([syn, handshake_ack, rst_frame])

    # 5. tcp_handshake_multi.bin — SYN + ACK + 3x PSH+ACK data segments
    seg1 = build_frame(PEER_PORT, LISTEN_PORT,
                       seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                       flags=PSH | ACK, window=65535,
                       payload=b'AAAA')
    seg2 = build_frame(PEER_PORT, LISTEN_PORT,
                       seq=peer_seq + 1 + 4, ack_num=SERVER_ISN + 1,
                       flags=PSH | ACK, window=65535,
                       payload=b'BBBB')
    seg3 = build_frame(PEER_PORT, LISTEN_PORT,
                       seq=peer_seq + 1 + 8, ack_num=SERVER_ISN + 1,
                       flags=PSH | ACK, window=65535,
                       payload=b'CCCC')
    seeds['tcp_handshake_multi.bin'] = pack_sequence([
        syn, handshake_ack, seg1, seg2, seg3])

    for name, data in seeds.items():
        path = os.path.join(outdir, name)
        with open(path, 'wb') as f:
            f.write(data)

    print(f"Generated {len(seeds)} seed files in {outdir}/")
    for name in sorted(seeds):
        path = os.path.join(outdir, name)
        size = os.path.getsize(path)
        print(f"  {name} ({size} bytes)")


if __name__ == '__main__':
    main()
