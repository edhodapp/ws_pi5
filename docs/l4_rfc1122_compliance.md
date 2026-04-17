# L4 TCP RFC Compliance Checklist

Requirements from RFC 1122 §4.2, RFC 9293, RFC 7323, RFC 2018,
RFC 6298, RFC 5681. Audited by Claude + independent Gemini review.
412 unit tests pass. All 8 defects closed. Every deviation tracked.

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
| 20 | Window scaling (RFC 7323) | — | YES | test_tcp_wscale_* (4 tests) | OK |
| 21 | Timestamps + PAWS (RFC 7323) | — | YES | test_tcp_ts_* (9 tests) | OK |
| 22 | SACK permitted + parsing (RFC 2018) | — | YES | test_tcp_sack_* (5 tests) | OK |
| 23 | RFC 6298 RTO computation | — | YES | test_tcp_rtt_init, _rto_double | OK |
| 24 | Congestion control (RFC 5681) | — | YES | test_tcp_cwnd_* (5 tests) | OK |

## Defects Found (Claude + Gemini independent audit)

### HIGH — ALL CLOSED

| # | Defect | Fix | Commit |
|---|--------|-----|--------|
| D1 | FIN+data: FIN processed even if data dropped. Data loss. | tcp_estab_fin_handler rolls back state on data drop | 4b0ac49 |
| D2 | Zero-window probe pure ACK ineffective. | Probe SEQ patched to SND_NXT-1 + checksum recompute | 4b0ac49 |

### MEDIUM — ALL CLOSED

| # | Defect | Fix | Commit |
|---|--------|-----|--------|
| D3 | No Challenge ACK for blind RST. | Exact-match RST; in-window non-exact → Challenge ACK | 3e9f427 |
| D4 | FIN+ACK in FIN_WAIT_1 → CLOSING instead of TIME_WAIT. | Check ACK flag + SEG.ACK==SND_NXT → TIME_WAIT + 2MSL | 1fff404 |
| D5 | SYN window scaled immediately (RFC 7323 §2.2 forbids). | Remove SND_WND scaling from SYN handler | this commit |
| D6 | TS_RECENT updated before SEQ validation — OOO poisons PAWS. | Defer TS_RECENT update until after SEQ check | this commit |
| D7 | Partial ACK in close handlers → spurious RST. | Three-way ACK split: partial returns 0, stays in state | 4d26b2b |
| D8 | No fast recovery cwnd inflation/deflation (RFC 5681 §3.2). | Dup ACKs > 3 inflate cwnd; new ACK exits recovery → cwnd=ssthresh | this commit |

### DESIGN DECISIONS

| # | Item | Rationale |
|---|------|-----------|
| DD1 | No Active Open (SYN_SENT) — server only | Bare-metal web server, no outbound connections |
| DD2 | No Nagle's algorithm (SWS sender avoidance) | HTTP responses are pre-built, not interactive |
| DD3 | No SACK block generation on RX | Complexity vs benefit for a server with small RX buffers |
| DD4 | No urgent pointer handling | Not used by HTTP |
| DD5 | 3-tuple matching (no local IP check) | Single-IP host, no multihoming |
