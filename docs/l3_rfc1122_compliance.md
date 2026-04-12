# L3 RFC 1122 Compliance Checklist

Requirements from RFC 1122 Section 3 (Internet Layer) for a host
implementation. Every deviation is either a DEFECT (to be fixed) or
a DESIGN DECISION (documented rationale).

## IP Layer (Section 3.2.1)

| # | Requirement | RFC | Impl | Tested | Status |
|---|-------------|-----|------|--------|--------|
| 1 | Discard datagrams with version != 4 | MUST (3.2.1.1) | YES | test_ip_handle_bad_ver | OK |
| 2 | Verify IP header checksum, discard bad | MUST (3.2.1.2) | YES | test_ip_handle_bad_cksum | OK |
| 3 | Discard datagrams not destined for us | MUST (3.2.1.3) | YES | test_ip_handle_not_ours | OK |
| 4a | Discard src=0.0.0.0 | MUST (3.2.1.3) | YES | test_ip_handle_martian_src_zero | OK |
| 4b | Discard src=127.0.0.0/8 | MUST (3.2.1.3) | YES | test_ip_handle_martian_src_loopback{,_high} | OK |
| 4c | Discard src=self | MUST (3.2.1.3) | YES | test_ip_handle_martian_src_self | OK |
| 4d | Discard src=broadcast | MUST (3.2.1.3) | YES | test_ip_handle_martian_src_bcast | OK |
| 4e | Discard src=multicast (224/4) | MUST (3.2.1.3) | YES | test_ip_handle_martian_src_mcast | OK |
| 5 | Support IP fragment reassembly | MUST (3.2.1.4) | YES | test_ip_reasm_* (5 tests) | OK |
| 6 | MUST NOT discard TTL < 2 | MUST NOT (3.2.1.7) | YES | test_ip_handle_ttl_zero | OK — drops TTL=0, accepts TTL=1 |
| 7 | Handle IP headers > 20 bytes (options) | MUST (3.2.1.8) | NO | test_ip_handle_bad_ver | **DESIGN DECISION** — single-host bare-metal server, no forwarding. Packets with options are dropped safely (not misinterpreted). Revisit if source routing or record route needed. |
| 8 | totlen validation (not < header, not > frame) | implicit | YES | test_ip_handle_totlen_short, _overrun | OK |
| 9 | TTL=0 on receive → drop (host does not forward) | implicit | YES | test_ip_handle_ttl_zero | OK |

## ICMP Layer (Section 3.2.2)

| # | Requirement | RFC | Impl | Tested | Status |
|---|-------------|-----|------|--------|--------|
| 10 | Echo Reply for Echo Request (preserve id/seq/data) | MUST (3.2.2.6) | YES | test_icmp_echo_reply, _payload, _payload_odd | OK |
| 11 | ICMP checksum validation | MUST (3.2.2) | YES | test_icmp_bad_checksum | OK |
| 12 | No ICMP error in response to ICMP error | MUST NOT (3.2.2) | YES | test_icmp_send_loop_suppress | OK |
| 13 | No ICMP error for broadcast/multicast dst | MUST NOT (3.2.2) | YES | test_icmp_err_bcast_dst, test_icmp_err_mcast_dst | OK |
| 14 | No ICMP error for non-unicast source | MUST NOT (3.2.2) | YES | — | IP layer now filters bcast/mcast sources (4d/4e) before they reach ICMP. Defense in depth: icmp_send_error also guards on dst. |
| 15 | Dest Unreachable for unknown protocol/port | MUST (3.2.2.1) | YES | test_udp_wrong_port, test_icmp_send_error | OK |
| 16 | Time Exceeded (code 1: reassembly timeout) | MUST (3.2.2.4) | YES | test_ip_reasm_timeout_icmp | OK |
| 17 | MUST NOT originate Redirect | MUST NOT (3.2.2.2) | YES | — | OK — we never generate redirects |
| 18 | Unknown ICMP type → silently ignore | MUST (3.2.2) | YES | test_icmp_unknown_type | OK |
| 19 | ICMP error rate limiting | SHOULD (3.2.2) | YES | test_icmp_rate_allow, _deny | OK |

## UDP Layer (Section 3.2.3 / RFC 768)

| # | Requirement | RFC | Impl | Tested | Status |
|---|-------------|-----|------|--------|--------|
| 20 | UDP checksum validation | MUST (RFC 1122 4.1.3.4) | YES | test_udp_bad_checksum | OK |
| 21 | UDP checksum=0 means "not computed" | MUST (RFC 768) | YES | test_udp_checksum_zero | OK |
| 22 | Port Unreachable for closed ports | MUST (3.2.2.1) | YES | test_udp_wrong_port | OK |
| 23 | UDP length validation | implicit | YES | test_udp_len_mismatch | OK |

## Defect Summary

| Defect | RFC ref | Priority | Status |
|--------|---------|----------|--------|
| ~~4d: broadcast source not filtered~~ | 3.2.1.3 | HIGH | FIXED — ip.S martian filter |
| ~~4e: multicast source not filtered~~ | 3.2.1.3 | HIGH | FIXED — ip.S martian filter |
| ~~13: ICMP error sent for broadcast dst~~ | 3.2.2 | HIGH | FIXED — icmp_send_error guard |
| ~~14: ICMP error sent for non-unicast src~~ | 3.2.2 | HIGH | FIXED — IP layer blocks upstream |
| ~~16: No Time Exceeded for reassembly timeout~~ | 3.2.2.4 | MEDIUM | FIXED — ip_reasm_timeout_cb now sends ICMP type 11 code 1 |
