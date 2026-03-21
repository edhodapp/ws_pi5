/* TCP header offsets (relative to start of TCP segment) */
.equ TCP_SPORT,        0       /* u16 — source port (network byte order) */
.equ TCP_DPORT,        2       /* u16 — destination port */
.equ TCP_SEQ,          4       /* u32 — sequence number */
.equ TCP_ACK,          8       /* u32 — acknowledgment number */
.equ TCP_DATA_OFF,     12      /* u8  — data offset (high 4 bits) + reserved */
.equ TCP_FLAGS,        13      /* u8  — flags */
.equ TCP_WINDOW,       14      /* u16 — window size */
.equ TCP_CHECKSUM,     16      /* u16 — checksum */
.equ TCP_URGENT,       18      /* u16 — urgent pointer */
.equ TCP_HDR_MIN,      20      /* minimum header (no options) */

/* Flag bits */
.equ TCP_FIN,          0x01
.equ TCP_SYN,          0x02
.equ TCP_RST,          0x04
.equ TCP_PSH,          0x08
.equ TCP_ACK_FLAG,     0x10
.equ TCP_URG,          0x20

/* Pre-combined flag values */
.equ TCP_RST_ACK,      0x14    /* RST + ACK */
.equ TCP_SYN_ACK,      0x12    /* SYN + ACK (Phase 2) */

/* Listen port */
.equ TCP_HTTP_PORT,    80

/* Pseudo-header protocol (LE halfword of 00 06 on wire) */
.equ TCP_PROTO_LE,     0x0600

/* RST reply frame size */
.equ TCP_RST_FRAME_LEN, 54    /* ETH(14) + IP(20) + TCP(20) */

/* Connection states (Phase 2+) */
.equ TCPS_CLOSED,      0
.equ TCPS_LISTEN,      1
.equ TCPS_SYN_RCVD,    2
.equ TCPS_ESTABLISHED,  3
.equ TCPS_CLOSE_WAIT,  4
.equ TCPS_LAST_ACK,    5
.equ TCPS_FIN_WAIT_1,  6
.equ TCPS_FIN_WAIT_2,  7
.equ TCPS_TIME_WAIT,   8
.equ TCPS_CLOSING,     9

/* Pre-combined flag values (additions) */
.equ TCP_FIN_ACK,      0x11    /* FIN + ACK */
.equ TCP_PSH_ACK,      0x18    /* PSH + ACK */

/* Connection struct (128 bytes, Phase 2+) */
.equ TCONN_STATE,      0       /* u8  */
.equ TCONN_PAD1,       1
.equ TCONN_LPORT,      2       /* u16 — network byte order */
.equ TCONN_RPORT,      4       /* u16 — network byte order */
.equ TCONN_PAD2,       6
.equ TCONN_RIP,        8       /* u32 — network byte order */
.equ TCONN_PAD3,       12
.equ TCONN_SND_UNA,    16      /* u32 — oldest unACKed seq */
.equ TCONN_RXLEN,      20      /* u16 — rx buffer fill */
.equ TCONN_SND_NXT,    24      /* u32 — next seq to send */
.equ TCONN_RCV_NXT,    32      /* u32 — next expected seq from peer */
.equ TCONN_SND_WND,    40      /* u16 — peer's advertised window */
.equ TCONN_RCV_WND,    42      /* u16 — our advertised window */
.equ TCONN_TIMER_SLOT, 44      /* w32 — retransmit timer slot (-1=none) */
.equ TCONN_RMAC,       48      /* 6 bytes — peer MAC (captured from SYN) */
.equ TCONN_PAD4,       54
.equ TCONN_RTXLEN,     56      /* u16 — retransmit frame length (0 = no pending) */
.equ TCONN_RTXCOUNT,   58      /* u8  — retry count (incremented each timeout) */
.equ TCONN_TS_ENABLED, 59      /* u8  — 0=disabled, 1=enabled (negotiated from SYN) */
.equ TCONN_TS_RECENT,  60      /* u32 — last received TSval from peer (host order) */
.equ TCONN_PEER_MSS,   64      /* u16 — peer's advertised MSS (host order, default 536) */
.equ TCONN_CWND,       66      /* u16 — congestion window (bytes) */
.equ TCONN_SSTHRESH,   68      /* u16 — slow-start threshold */
.equ TCONN_DUP_ACK_CNT, 70    /* u8  — duplicate ACK counter */
.equ TCONN_OOO_COUNT,  71      /* u8  — number of OOO slots in use (0-4) */
.equ TCONN_OOO_SLOTS,  72      /* 32 bytes — 4 × {SEQ u32, LEN u16, PAD u16} */
/* 104-127: reserved for future use */
.equ TCONN_SIZE,       128     /* power of 2 → lsl #7 for indexing */

/* Connection table */
.equ TCP_MAX_CONNS,    16
.equ TCP_CONN_TABLE_SIZE, 2048 /* 16 * 128 */

/* Receive buffer pool */
.equ TCP_RXBUF_SIZE,      2048   /* bytes per connection, power of 2 */
.equ TCP_RXBUF_SHIFT,     11     /* log2(2048) */
.equ TCP_RXBUF_POOL_SIZE, 32768  /* 16 * 2048 */

/* FSA event codes (priority: RST > SYN > FIN > ACK) */
.equ TCP_EVT_RST,      0
.equ TCP_EVT_SYN,      1       /* SYN set, ACK not set */
.equ TCP_EVT_SYNACK,   2       /* SYN + ACK both set */
.equ TCP_EVT_FIN,      3       /* FIN set (may have ACK) */
.equ TCP_EVT_ACK,      4       /* ACK set, no SYN/FIN/RST */
.equ TCP_N_EVENTS,     5
.equ TCP_N_STATES,     10      /* CLOSED(0) through CLOSING(9) */

/* Retransmission constants */
.equ TCP_MAX_RETRIES,      8       /* max retransmit attempts before RST+close */
.equ TCP_RTO_SHIFT_CAP,    5       /* max shift for backoff: 1<<5 = 32 seconds */
.equ TCP_RTXBUF_POOL_SIZE, 32768   /* 16 × 2048 (same layout as rxbuf_pool) */

/* TCP send context struct (for retransmit callback) */
.equ TSCTX_DWC2_BASE,  0       /* u64 */
.equ TSCTX_ECM_STATE,  8       /* u64 */
.equ TSCTX_TX_BUF,     16      /* u64 */
.equ TSCTX_SEND_FN,    24      /* u64 */
.equ TSCTX_SIZE,        32

/* TCP option constants */
.equ TCP_OPT_EOL,         0
.equ TCP_OPT_NOP,         1
.equ TCP_OPT_TIMESTAMPS,  8
.equ TCP_OPT_TS_LEN,      10      /* Kind=8, Length=10 */
.equ TCP_TSOPT_SIZE,       12      /* NOP NOP Kind Len TSval(4) TSecr(4) */
.equ TCP_TS_FRAME_LEN,    66      /* ETH(14) + IP(20) + TCP(32) */
.equ TCP_ISN_SECRET_SIZE,  8

/* MSS option constants */
.equ TCP_OPT_MSS,        2
.equ TCP_OPT_MSS_LEN,    4
.equ TCP_DEFAULT_MSS,     536   /* RFC 1122 */
.equ TCP_OUR_MSS,         1460  /* ETH_MTU(1500) - IP(20) - TCP(20) */
