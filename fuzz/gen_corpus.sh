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

echo "Generated $(ls "$DIR"/*.bin | wc -l) seed files in $DIR/"
ls -la "$DIR"/*.bin
