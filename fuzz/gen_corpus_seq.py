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


def build_frame_ts(sport, dport, seq, ack_num, flags, window, tsval, tsecr,
                   payload=b''):
    """Build ETH+IP+TCP frame with TCP Timestamps option."""
    tcp_hdr_len = 32    # 20 + 12 (NOP NOP Kind=8 Len=10 TSval TSecr)
    tcp_len = tcp_hdr_len + len(payload)
    ip_total = 20 + tcp_len

    tcp_hdr = struct.pack('!HHIIBBHHH',
        sport, dport,
        seq, ack_num,
        0x80,           # data offset = 8 words (32 bytes)
        flags,
        window,
        0, 0)
    ts_opt = struct.pack('!BBBBII', 1, 1, 8, 10, tsval, tsecr)
    tcp_seg = tcp_hdr + ts_opt + payload

    cksum = tcp_checksum(PEER_IP, OUR_IP, tcp_seg)
    tcp_seg = tcp_seg[:16] + struct.pack('!H', cksum) + tcp_seg[18:]

    ip_hdr = struct.pack('!BBHHHBBH4s4s',
        0x45, 0x00, ip_total,
        0x1234, 0x0000, 64, 6, 0,
        PEER_IP, OUR_IP)
    ip_cksum = ip_checksum(ip_hdr)
    ip_hdr = ip_hdr[:10] + struct.pack('!H', ip_cksum) + ip_hdr[12:]

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

    # 6. tcp_dup_data.bin — Handshake + data + duplicate data (same SEQ)
    #    Exercises duplicate-data re-ACK path (SEQ < RCV_NXT after first accept)
    dup_frame = build_frame(PEER_PORT, LISTEN_PORT,
                            seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                            flags=PSH | ACK, window=65535,
                            payload=b'Hello')
    seeds['tcp_dup_data.bin'] = pack_sequence([
        syn, handshake_ack, data_frame, dup_frame])

    # 7. tcp_dup_syn.bin — SYN + duplicate SYN (second should get RST)
    #    First SYN allocates conn, second finds exact match in SYN_RCVD
    seeds['tcp_dup_syn.bin'] = pack_sequence([syn, syn])

    # 8. tcp_full_close.bin — Handshake + peer FIN → CLOSE_WAIT + ACK of FIN
    #    Exercises passive close: ESTABLISHED → CLOSE_WAIT via estab_fin_handler
    seeds['tcp_full_close.bin'] = pack_sequence([
        syn, handshake_ack, fin_frame])

    # 9. tcp_data_then_rst.bin — Handshake + data + RST
    #    Exercises conn_close_handler with tcp_rtx_clear (RST clears retransmit)
    rst_estab = build_frame(PEER_PORT, LISTEN_PORT,
                            seq=peer_seq + 1 + 5, ack_num=SERVER_ISN + 1,
                            flags=RST, window=0)
    seeds['tcp_data_then_rst.bin'] = pack_sequence([
        syn, handshake_ack, data_frame, rst_estab])

    # 10. tcp_bad_seq_data.bin — Handshake + data with future SEQ (> RCV_NXT)
    #     Exercises OOO buffering + dup ACK path in estab_ack_handler
    bad_seq_frame = build_frame(PEER_PORT, LISTEN_PORT,
                                seq=peer_seq + 1 + 999, ack_num=SERVER_ISN + 1,
                                flags=PSH | ACK, window=65535,
                                payload=b'Future')
    seeds['tcp_bad_seq_data.bin'] = pack_sequence([
        syn, handshake_ack, bad_seq_frame])

    # Close sentinel: empty frame → flen=0 → triggers tcp_close in harness
    CLOSE = b''

    # 11. tcp_active_close.bin — Active close: ESTABLISHED → FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT
    #     After handshake: server SND_NXT=1, peer next seq=peer_seq+1=2
    #     Close sentinel → tcp_close → FIN_WAIT_1, server SND_NXT=2
    #     Peer ACK of FIN: ack=2 → FIN_WAIT_2
    #     Peer FIN+ACK: → TIME_WAIT
    ack_our_fin = build_frame(PEER_PORT, LISTEN_PORT,
                              seq=peer_seq + 1, ack_num=SERVER_ISN + 2,
                              flags=ACK, window=65535)
    peer_fin = build_frame(PEER_PORT, LISTEN_PORT,
                           seq=peer_seq + 1, ack_num=SERVER_ISN + 2,
                           flags=FIN | ACK, window=65535)
    seeds['tcp_active_close.bin'] = pack_sequence([
        syn, handshake_ack, CLOSE, ack_our_fin, peer_fin])

    # 12. tcp_last_ack.bin — Passive close then our close:
    #     ESTABLISHED → CLOSE_WAIT → LAST_ACK → CLOSED
    #     Peer FIN+ACK → CLOSE_WAIT (RCV_NXT = peer_seq+2 = 3)
    #     Close sentinel → tcp_close → LAST_ACK (SND_NXT = 2)
    #     Peer ACK: ack=2 → CLOSED
    peer_fin_passive = build_frame(PEER_PORT, LISTEN_PORT,
                                   seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                                   flags=FIN | ACK, window=65535)
    ack_last = build_frame(PEER_PORT, LISTEN_PORT,
                           seq=peer_seq + 2, ack_num=SERVER_ISN + 2,
                           flags=ACK, window=65535)
    seeds['tcp_last_ack.bin'] = pack_sequence([
        syn, handshake_ack, peer_fin_passive, CLOSE, ack_last])

    # 13. tcp_simultaneous_close.bin — Both sides FIN at same time:
    #     ESTABLISHED → FIN_WAIT_1 → CLOSING → TIME_WAIT
    #     Close sentinel → FIN_WAIT_1 (SND_NXT=2)
    #     Peer FIN (ack=1, doesn't ack our FIN yet) → CLOSING (RCV_NXT=3)
    #     Peer ACK (ack=2, acks our FIN) → TIME_WAIT
    peer_fin_simul = build_frame(PEER_PORT, LISTEN_PORT,
                                 seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                                 flags=FIN | ACK, window=65535)
    peer_ack_closing = build_frame(PEER_PORT, LISTEN_PORT,
                                   seq=peer_seq + 2, ack_num=SERVER_ISN + 2,
                                   flags=ACK, window=65535)
    seeds['tcp_simultaneous_close.bin'] = pack_sequence([
        syn, handshake_ack, CLOSE, peer_fin_simul, peer_ack_closing])

    # 14. tcp_ts_handshake.bin — SYN with TS option → exercises timestamp paths
    #     Server echoes TSval; fuzz harness timer_now returns 0 → server TSval=0
    syn_ts = build_frame_ts(PEER_PORT, LISTEN_PORT,
                            seq=peer_seq, ack_num=0, flags=SYN, window=65535,
                            tsval=1000, tsecr=0)
    ack_ts = build_frame_ts(PEER_PORT, LISTEN_PORT,
                            seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                            flags=ACK, window=65535,
                            tsval=1001, tsecr=0)
    seeds['tcp_ts_handshake.bin'] = pack_sequence([syn_ts, ack_ts])

    # 15. tcp_ooo_merge.bin — Handshake + out-of-order segment + gap fill
    #     Exercises OOO buffering then in-order merge in estab_ack_handler
    #     After handshake: RCV_NXT = peer_seq+1 = 2
    #     Send seg at SEQ=7 (gap of 5) → OOO buffered, dup ACK
    #     Send seg at SEQ=2 (fills gap) → accepted, OOO merge advances RCV_NXT
    ooo_seg = build_frame(PEER_PORT, LISTEN_PORT,
                          seq=peer_seq + 1 + 5, ack_num=SERVER_ISN + 1,
                          flags=PSH | ACK, window=65535,
                          payload=b'World')
    gap_fill = build_frame(PEER_PORT, LISTEN_PORT,
                           seq=peer_seq + 1, ack_num=SERVER_ISN + 1,
                           flags=PSH | ACK, window=65535,
                           payload=b'Hello')
    seeds['tcp_ooo_merge.bin'] = pack_sequence([
        syn, handshake_ack, ooo_seg, gap_fill])

    # 16. tcp_dup_syn_flood.bin — 4 SYNs from different source ports
    #     Exercises SYN_RCVD eviction + RST rate-limit paths when AFL mutates
    flood_syns = []
    for i in range(4):
        flood_syns.append(build_frame(PEER_PORT + i, LISTEN_PORT,
                                      seq=peer_seq, ack_num=0,
                                      flags=SYN, window=65535))
    seeds['tcp_dup_syn_flood.bin'] = pack_sequence(flood_syns)

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
