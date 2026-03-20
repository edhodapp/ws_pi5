#!/bin/bash
# gen_corpus.sh -- Generate seed corpus for net_recv_one fuzzing
#
# Produces minimal binary files that exercise each major code path
# through the network parser stack.

set -euo pipefail

DIR="$(dirname "$0")/corpus"
mkdir -p "$DIR"

# 1. Valid ARP request for 10.0.2.15 (42 bytes)
#    Exercises: eth_type → ARP branch → arp_handle (full reply path)
printf '\xFF\xFF\xFF\xFF\xFF\xFF'       > "$DIR/arp_request.bin"  # ETH dst: broadcast
printf '\xAA\xBB\xCC\xDD\xEE\xFF'     >> "$DIR/arp_request.bin"  # ETH src
printf '\x08\x06'                       >> "$DIR/arp_request.bin"  # EtherType: ARP
printf '\x00\x01\x08\x00\x06\x04'     >> "$DIR/arp_request.bin"  # HTYPE/PTYPE/HLEN/PLEN
printf '\x00\x01'                       >> "$DIR/arp_request.bin"  # OPER: request
printf '\xAA\xBB\xCC\xDD\xEE\xFF'     >> "$DIR/arp_request.bin"  # SHA: sender MAC
printf '\x0A\x00\x02\x02'             >> "$DIR/arp_request.bin"  # SPA: 10.0.2.2
printf '\x00\x00\x00\x00\x00\x00'     >> "$DIR/arp_request.bin"  # THA: unknown
printf '\x0A\x00\x02\x0F'             >> "$DIR/arp_request.bin"  # TPA: 10.0.2.15

# 2. Valid ICMP echo request for 10.0.2.15 (42 bytes)
#    Exercises: eth_type → IPv4 branch → ip_handle → icmp_handle (full reply path)
printf '\x02\x00\x00\x00\x00\x01'     > "$DIR/icmp_echo.bin"     # ETH dst: our MAC
printf '\xAA\xBB\xCC\xDD\xEE\xFF'    >> "$DIR/icmp_echo.bin"     # ETH src
printf '\x08\x00'                      >> "$DIR/icmp_echo.bin"     # EtherType: IPv4
printf '\x45\x00\x00\x1C'             >> "$DIR/icmp_echo.bin"     # ver/ihl, totlen=28
printf '\x12\x34\x00\x00'             >> "$DIR/icmp_echo.bin"     # id, flags
printf '\x40\x01\x50\x9D'             >> "$DIR/icmp_echo.bin"     # ttl=64, proto=ICMP, cksum
printf '\x0A\x00\x02\x02'             >> "$DIR/icmp_echo.bin"     # IP src: 10.0.2.2
printf '\x0A\x00\x02\x0F'             >> "$DIR/icmp_echo.bin"     # IP dst: 10.0.2.15
printf '\x08\x00\xF7\xFD'             >> "$DIR/icmp_echo.bin"     # ICMP echo req, cksum
printf '\x00\x01\x00\x01'             >> "$DIR/icmp_echo.bin"     # ICMP id=1, seq=1

# 3. Short frame (10 bytes) — triggers eth_type → -1 → drop
printf '\xFF\xFF\xFF\xFF\xFF\xFF\xAA\xBB\xCC\xDD' > "$DIR/short_frame.bin"

# 4. Unknown EtherType 0x86DD (IPv6) — 14-byte header, no payload
#    Exercises: eth_type → unknown → drop
printf '\x02\x00\x00\x00\x00\x01'     > "$DIR/unknown_ethertype.bin"
printf '\xAA\xBB\xCC\xDD\xEE\xFF'    >> "$DIR/unknown_ethertype.bin"
printf '\x86\xDD'                      >> "$DIR/unknown_ethertype.bin"

# --- Seeds behind the IP checksum gate (pre-computed checksums) ---

# 5. IPv4 with wrong dest IP (10.0.2.99) — valid checksum 0x5049
#    Passes ip_handle checks 1-5, rejected at check 6 (DST != ours)
printf '\x02\x00\x00\x00\x00\x01'     > "$DIR/ip_wrong_dst.bin"
printf '\xAA\xBB\xCC\xDD\xEE\xFF'    >> "$DIR/ip_wrong_dst.bin"
printf '\x08\x00'                      >> "$DIR/ip_wrong_dst.bin"
printf '\x45\x00\x00\x1C'             >> "$DIR/ip_wrong_dst.bin"     # totlen=28
printf '\x12\x34\x00\x00'             >> "$DIR/ip_wrong_dst.bin"
printf '\x40\x01\x50\x49'             >> "$DIR/ip_wrong_dst.bin"     # cksum for dst=10.0.2.99
printf '\x0A\x00\x02\x02'             >> "$DIR/ip_wrong_dst.bin"
printf '\x0A\x00\x02\x63'             >> "$DIR/ip_wrong_dst.bin"     # dst: 10.0.2.99
printf '\x08\x00\xF7\xFD'             >> "$DIR/ip_wrong_dst.bin"
printf '\x00\x01\x00\x01'             >> "$DIR/ip_wrong_dst.bin"

# 6. IPv4 with proto=UDP (17) — valid checksum 0x508D
#    Passes ip_handle checks 1-6, rejected at check 7 (proto != ICMP)
printf '\x02\x00\x00\x00\x00\x01'     > "$DIR/ip_udp.bin"
printf '\xAA\xBB\xCC\xDD\xEE\xFF'    >> "$DIR/ip_udp.bin"
printf '\x08\x00'                      >> "$DIR/ip_udp.bin"
printf '\x45\x00\x00\x1C'             >> "$DIR/ip_udp.bin"           # totlen=28
printf '\x12\x34\x00\x00'             >> "$DIR/ip_udp.bin"
printf '\x40\x11\x50\x8D'             >> "$DIR/ip_udp.bin"           # proto=UDP(17), cksum
printf '\x0A\x00\x02\x02'             >> "$DIR/ip_udp.bin"
printf '\x0A\x00\x02\x0F'             >> "$DIR/ip_udp.bin"
printf '\x00\x00\x00\x00'             >> "$DIR/ip_udp.bin"           # dummy payload
printf '\x00\x00\x00\x00'             >> "$DIR/ip_udp.bin"

# 7. IPv4 ICMP with totlen=20 (no ICMP room) — valid checksum 0xA550
#    Passes all ip_handle checks, icmp_handle rejects (ICMP len 0 < 8)
printf '\x02\x00\x00\x00\x00\x01'     > "$DIR/icmp_short.bin"
printf '\xAA\xBB\xCC\xDD\xEE\xFF'    >> "$DIR/icmp_short.bin"
printf '\x08\x00'                      >> "$DIR/icmp_short.bin"
printf '\x45\x00\x00\x14'             >> "$DIR/icmp_short.bin"       # totlen=20
printf '\x12\x34\x00\x00'             >> "$DIR/icmp_short.bin"
printf '\x40\x01\x50\xA5'             >> "$DIR/icmp_short.bin"       # proto=ICMP, cksum
printf '\x0A\x00\x02\x02'             >> "$DIR/icmp_short.bin"
printf '\x0A\x00\x02\x0F'             >> "$DIR/icmp_short.bin"

# --- TCP seeds (valid IP + TCP checksums, exercises tcp_handle paths) ---

# 8. TCP SYN to port 80 — valid checksums, exercises LISTEN → SYN-ACK
#    sport=12345, dport=80, SEQ=1, flags=SYN
#    IP cksum=508C, TCP cksum=4867
printf '\x02\x00\x00\x00\x00\x01'     > "$DIR/tcp_syn_80.bin"
printf '\xAA\xBB\xCC\xDD\xEE\xFF'    >> "$DIR/tcp_syn_80.bin"
printf '\x08\x00'                      >> "$DIR/tcp_syn_80.bin"
printf '\x45\x00\x00\x28'             >> "$DIR/tcp_syn_80.bin"
printf '\x12\x34\x00\x00'             >> "$DIR/tcp_syn_80.bin"
printf '\x40\x06\x50\x8C'             >> "$DIR/tcp_syn_80.bin"
printf '\x0A\x00\x02\x02'             >> "$DIR/tcp_syn_80.bin"
printf '\x0A\x00\x02\x0F'             >> "$DIR/tcp_syn_80.bin"
printf '\x30\x39\x00\x50'             >> "$DIR/tcp_syn_80.bin"       # sport:12345 dport:80
printf '\x00\x00\x00\x01'             >> "$DIR/tcp_syn_80.bin"       # seq: 1
printf '\x00\x00\x00\x00'             >> "$DIR/tcp_syn_80.bin"       # ack: 0
printf '\x50\x02\xFF\xFF'             >> "$DIR/tcp_syn_80.bin"       # doff=5, SYN, win=65535
printf '\x67\x48\x00\x00'             >> "$DIR/tcp_syn_80.bin"       # TCP cksum, urgent=0

# 9. TCP ACK to port 80 — no matching connection → RST
#    sport=12345, dport=80, SEQ=100, ACK=200, flags=ACK
#    IP cksum=508C, TCP cksum=0F66
printf '\x02\x00\x00\x00\x00\x01'     > "$DIR/tcp_ack_80.bin"
printf '\xAA\xBB\xCC\xDD\xEE\xFF'    >> "$DIR/tcp_ack_80.bin"
printf '\x08\x00'                      >> "$DIR/tcp_ack_80.bin"
printf '\x45\x00\x00\x28'             >> "$DIR/tcp_ack_80.bin"
printf '\x12\x34\x00\x00'             >> "$DIR/tcp_ack_80.bin"
printf '\x40\x06\x50\x8C'             >> "$DIR/tcp_ack_80.bin"
printf '\x0A\x00\x02\x02'             >> "$DIR/tcp_ack_80.bin"
printf '\x0A\x00\x02\x0F'             >> "$DIR/tcp_ack_80.bin"
printf '\x30\x39\x00\x50'             >> "$DIR/tcp_ack_80.bin"       # sport:12345 dport:80
printf '\x00\x00\x00\x64'             >> "$DIR/tcp_ack_80.bin"       # seq: 100
printf '\x00\x00\x00\xC8'             >> "$DIR/tcp_ack_80.bin"       # ack: 200
printf '\x50\x10\xFF\xFF'             >> "$DIR/tcp_ack_80.bin"       # doff=5, ACK, win=65535
printf '\x66\x0F\x00\x00'             >> "$DIR/tcp_ack_80.bin"       # TCP cksum, urgent=0

# 10. TCP SYN to port 12345 — no LISTEN match → RST
#     sport=54321, dport=12345, SEQ=1, flags=SYN
#     IP cksum=508C, TCP cksum=6693
printf '\x02\x00\x00\x00\x00\x01'     > "$DIR/tcp_syn_wrong_port.bin"
printf '\xAA\xBB\xCC\xDD\xEE\xFF'    >> "$DIR/tcp_syn_wrong_port.bin"
printf '\x08\x00'                      >> "$DIR/tcp_syn_wrong_port.bin"
printf '\x45\x00\x00\x28'             >> "$DIR/tcp_syn_wrong_port.bin"
printf '\x12\x34\x00\x00'             >> "$DIR/tcp_syn_wrong_port.bin"
printf '\x40\x06\x50\x8C'             >> "$DIR/tcp_syn_wrong_port.bin"
printf '\x0A\x00\x02\x02'             >> "$DIR/tcp_syn_wrong_port.bin"
printf '\x0A\x00\x02\x0F'             >> "$DIR/tcp_syn_wrong_port.bin"
printf '\xD4\x31\x30\x39'             >> "$DIR/tcp_syn_wrong_port.bin" # sport:54321 dport:12345
printf '\x00\x00\x00\x01'             >> "$DIR/tcp_syn_wrong_port.bin" # seq: 1
printf '\x00\x00\x00\x00'             >> "$DIR/tcp_syn_wrong_port.bin" # ack: 0
printf '\x50\x02\xFF\xFF'             >> "$DIR/tcp_syn_wrong_port.bin" # doff=5, SYN, win=65535
printf '\x93\x66\x00\x00'             >> "$DIR/tcp_syn_wrong_port.bin" # TCP cksum, urgent=0

echo "Generated $(ls "$DIR"/*.bin | wc -l) seed files in $DIR/"
ls -la "$DIR"/*.bin
