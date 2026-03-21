#!/usr/bin/env python3
"""
gen_corpus.py -- Generate seed corpus for net_recv_one fuzzing

Builds binary seeds with computed IP/TCP checksums that exercise each major
code path through the network parser stack.

Output: fuzz/corpus/*.bin
"""

import os
import struct


# --- Network constants (must match lib/net_cfg.S and include/tcp.inc) ---

OUR_MAC  = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
PEER_MAC = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
OUR_IP   = bytes([0x0A, 0x00, 0x02, 0x0F])  # 10.0.2.15
PEER_IP  = bytes([0x0A, 0x00, 0x02, 0x02])  # 10.0.2.2


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


def build_ip_frame(proto, src_ip, dst_ip, payload):
    """Build ETH+IP frame with computed IP checksum."""
    ip_total = 20 + len(payload)

    ip_hdr = struct.pack('!BBHHHBBH4s4s',
        0x45, 0x00,
        ip_total,
        0x1234, 0x0000,
        64, proto,
        0,  # checksum placeholder
        src_ip, dst_ip)
    ip_cksum = ip_checksum(ip_hdr)
    ip_hdr = ip_hdr[:10] + struct.pack('!H', ip_cksum) + ip_hdr[12:]

    eth = OUR_MAC + PEER_MAC + struct.pack('!H', 0x0800)
    return eth + ip_hdr + payload


def build_tcp_frame(sport, dport, seq, ack_num, flags, window):
    """Build ETH+IP+TCP frame with computed checksums."""
    tcp_hdr = struct.pack('!HHIIBBHHH',
        sport, dport,
        seq, ack_num,
        0x50, flags,
        window,
        0,  # checksum placeholder
        0)  # urgent pointer

    cksum = tcp_checksum(PEER_IP, OUR_IP, tcp_hdr)
    tcp_hdr = tcp_hdr[:16] + struct.pack('!H', cksum) + tcp_hdr[18:]

    return build_ip_frame(6, PEER_IP, OUR_IP, tcp_hdr)


def main():
    outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'corpus')
    os.makedirs(outdir, exist_ok=True)

    seeds = {}

    # 1. Valid ARP request for 10.0.2.15 (42 bytes)
    arp_payload = struct.pack('!HHBBH',
        0x0001, 0x0800, 6, 4, 0x0001)  # HTYPE, PTYPE, HLEN, PLEN, OPER=request
    arp_payload += PEER_MAC + PEER_IP   # SHA + SPA
    arp_payload += b'\x00' * 6 + OUR_IP  # THA + TPA
    eth_arp = b'\xFF' * 6 + PEER_MAC + struct.pack('!H', 0x0806) + arp_payload
    seeds['arp_request.bin'] = eth_arp

    # 2. Valid ICMP echo request for 10.0.2.15
    icmp_payload = struct.pack('!BBH HH',
        8, 0, 0,   # type=echo request, code=0, checksum placeholder
        1, 1)       # id=1, seq=1
    icmp_cksum = ip_checksum(icmp_payload)
    icmp_payload = icmp_payload[:2] + struct.pack('!H', icmp_cksum) + icmp_payload[4:]
    seeds['icmp_echo.bin'] = build_ip_frame(1, PEER_IP, OUR_IP, icmp_payload)

    # 3. Short frame (10 bytes) — triggers drop
    seeds['short_frame.bin'] = b'\xFF' * 6 + b'\xAA\xBB\xCC\xDD'

    # 4. Unknown EtherType 0x86DD (IPv6) — 14-byte header, no payload
    seeds['unknown_ethertype.bin'] = OUR_MAC + PEER_MAC + struct.pack('!H', 0x86DD)

    # 5. IPv4 with wrong dest IP (10.0.2.99) — rejected at DST check
    wrong_dst = bytes([0x0A, 0x00, 0x02, 0x63])
    icmp_payload_raw = struct.pack('!BBH HH', 8, 0, 0, 1, 1)
    icmp_cksum = ip_checksum(icmp_payload_raw)
    icmp_payload_raw = icmp_payload_raw[:2] + struct.pack('!H', icmp_cksum) + icmp_payload_raw[4:]
    seeds['ip_wrong_dst.bin'] = build_ip_frame(1, PEER_IP, wrong_dst, icmp_payload_raw)

    # 6. IPv4 with proto=UDP (17) — rejected at proto check
    udp_payload = b'\x00' * 8  # dummy
    seeds['ip_udp.bin'] = build_ip_frame(17, PEER_IP, OUR_IP, udp_payload)

    # 7. IPv4 ICMP with totlen=20 (no ICMP room) — icmp_handle rejects
    #    Build raw: IP header only, no ICMP payload
    seeds['icmp_short.bin'] = build_ip_frame(1, PEER_IP, OUR_IP, b'')

    # 8. TCP SYN to port 80
    seeds['tcp_syn_80.bin'] = build_tcp_frame(
        sport=12345, dport=80, seq=1, ack_num=0, flags=0x02, window=65535)

    # 9. TCP ACK to port 80 — no matching connection → RST
    seeds['tcp_ack_80.bin'] = build_tcp_frame(
        sport=12345, dport=80, seq=100, ack_num=200, flags=0x10, window=65535)

    # 10. TCP SYN to port 12345 — no LISTEN match → RST
    seeds['tcp_syn_wrong_port.bin'] = build_tcp_frame(
        sport=54321, dport=12345, seq=1, ack_num=0, flags=0x02, window=65535)

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
