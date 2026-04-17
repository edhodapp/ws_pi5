# L4 TCP RFC Compliance Checklist

Requirements from RFC 1122 §4.2, RFC 9293, RFC 7323, RFC 2018,
RFC 6298, RFC 5681. Audited by Claude + independent Gemini review.
193 TCP unit tests exist. Every deviation tracked.

## Connection Management

| # | Requirement | RFC | Impl | Tested | Status |
|---|-------------|-----|------|--------|--------|
| 1 | Checksum on every TX segment | MUST (1122 §4.2.2.7) | YES | test_tcp_checksum{,_data} | OK |
| 2 | Discard bad checksum on RX | MUST (1122 §4.2.2.7) | YES | test_tcp_bad_checksum | OK |
| 3 | State transitions follow RFC 793 | MUST (1122 §4.2.2.8) | YES | 20+ FSA tests | OK |
| 4 | ISN hard to predict | MUST (1122 §4.2.2.9) | YES | test_tcp_isn_* (3 tests) | OK |
| 5 | MUST NOT RST in response to RST | MUST NOT (1122 §4.2.2.12) | YES | test_tcp_timewait_rst etc | OK |
| 6 | RST for non-existent connection | MUST (1122 §4.2.2.12) | YES | test_tcp_rst_syn/ack/port | OK |
| 7 | TIME-WAIT 2*MSL | MUST (1122 §4.2.2.13) | YES | test_tcp_timewait_timeout | OK |
| 8 | Passive OPEN (LISTEN) | MUST (1122 §4.2.2.18) | YES | test_tcp_listen_* (3 tests) | OK |
| 9 | MSS option | MUST (1122 §4.2.2.6) | YES | test_tcp_synack_mss, _peer_mss | OK |

## Data Communication

| # | Requirement | RFC | Impl | Tested | Status |
|---|-------------|-----|------|--------|--------|
| 10 | In-order delivery | MUST (1122 §4.2.2.14) | YES | test_tcp_rx_buffer* | OK |
| 11 | Exponential backoff | MUST (1122 §4.2.2.15) | YES | test_tcp_rto_double | OK |
| 12 | Minimum RTO >= 1 second | MUST (1122 §4.2.2.15) | YES | test_tcp_rtt_init | OK |
| 13 | Window management | MUST (1122 §4.2.2.16) | YES | test_tcp_snd_wnd_* | OK |
| 14 | Zero-window probing | MUST (1122 §4.2.2.17) | YES | test_tcp_persist_* | OK |
| 15 | Karn's algorithm | MUST (1122 §4.2.3.1) | YES | test_tcp_rtt_karn | OK |
| 16 | RTTVAR in RTO | MUST (1122 §4.2.3.1) | YES | test_tcp_rtt_init | OK |
| 17 | Retransmission limits | MUST (1122 §4.2.3.5) | YES | test_tcp_rtx_cb_max_retries | OK |

## ICMP Interaction

| # | Requirement | RFC | Impl | Tested | Status |
|---|-------------|-----|------|--------|--------|
| 18 | ICMP error handling | MUST (1122 §4.2.3.9) | YES | test_tcp_icmp_err_* (7 tests) | OK |
| 19 | ICMP not immediate termination | MUST NOT (1122 §4.2.3.9) | YES | test_tcp_icmp_err_match | OK |

## Extensions

| # | Requirement | RFC | Impl | Tested | Status |
|---|-------------|-----|------|--------|--------|
| 20 | Window scaling (RFC 7323) | — | YES | test_tcp_wscale_* (3 tests) | OK |
| 21 | Timestamps + PAWS (RFC 7323) | — | YES | test_tcp_ts_* (8 tests) | OK |
| 22 | SACK permitted + parsing (RFC 2018) | — | YES | test_tcp_sack_* (5 tests) | OK |
| 23 | RFC 6298 RTO computation | — | YES | test_tcp_rtt_init, _rto_double | OK |
| 24 | Congestion control (RFC 5681) | — | YES | test_tcp_cwnd_* (3 tests) | OK |

## Defects Found (Claude + Gemini independent audit)

### HIGH

| # | Defect | Source | RFC ref |
|---|--------|--------|---------|
| D1 | FIN+data: FIN processed even if data dropped (buffer overflow/OOO). Data loss. | Gemini | RFC 9293 §3.10 |
| D2 | Zero-window probe sends pure ACK (0-length, SEQ=SND_NXT). RFC requires >=1 byte or out-of-window SEQ. Peer silently ignores → persist ineffective. | Gemini | RFC 9293 §3.8.6.1 |

### MEDIUM

| # | Defect | Source | RFC ref |
|---|--------|--------|---------|
| D3 | No RFC 5961 Challenge ACK for blind RST. In-window RST accepted immediately. | Gemini | RFC 5961 §3.2 / RFC 9293 §3.10.7.4 |
| D4 | FIN+ACK in FIN_WAIT_1: ACK portion ignored, transitions to CLOSING instead of TIME_WAIT. | Gemini | RFC 9293 state diagram |
| D5 | SYN window scaled immediately — RFC 7323 §2.2 says SYN window is NEVER scaled. | Gemini | RFC 7323 §2.2 |
| D6 | TS_RECENT updated before sequence number validation — OOO segment with future TSval poisons PAWS. | Gemini | RFC 7323 §4.3 |
| D7 | Partial ACK in close handlers doesn't advance SND_UNA — causes unnecessary retransmission. | Gemini | RFC 1122 §4.2.2.13 |
| D8 | No fast recovery cwnd inflation (dup ACKs after 3rd) or deflation (new ACK). | Gemini | RFC 5681 §3.2 |

### DESIGN DECISIONS

| # | Item | Rationale |
|---|------|-----------|
| DD1 | No Active Open (SYN_SENT) — server only | Bare-metal web server, no outbound connections |
| DD2 | No Nagle's algorithm (SWS sender avoidance) | HTTP responses are pre-built, not interactive |
| DD3 | No SACK block generation on RX | Complexity vs benefit for a server with small RX buffers |
| DD4 | No urgent pointer handling | Not used by HTTP |
| DD5 | 3-tuple matching (no local IP check) | Single-IP host, no multihoming |
