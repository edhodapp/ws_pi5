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

/* Connection struct (64 bytes, Phase 2+) */
.equ TCONN_STATE,      0       /* u8  */
.equ TCONN_PAD1,       1
.equ TCONN_LPORT,      2       /* u16 — network byte order */
.equ TCONN_RPORT,      4       /* u16 — network byte order */
.equ TCONN_PAD2,       6
.equ TCONN_RIP,        8       /* u32 — network byte order */
.equ TCONN_PAD3,       12
.equ TCONN_SND_UNA,    16      /* u32 — oldest unACKed seq */
.equ TCONN_SND_NXT,    24      /* u32 — next seq to send */
.equ TCONN_RCV_NXT,    32      /* u32 — next expected seq from peer */
.equ TCONN_SND_WND,    40      /* u16 — peer's advertised window */
.equ TCONN_RCV_WND,    42      /* u16 — our advertised window */
.equ TCONN_TIMER_SLOT, 44      /* w32 — retransmit timer slot (-1=none) */
.equ TCONN_PAD4,       48
.equ TCONN_SIZE,       64      /* power of 2 → lsl #6 for indexing */

/* Connection table */
.equ TCP_MAX_CONNS,    16
.equ TCP_CONN_TABLE_SIZE, 1024 /* 16 * 64 */

/* FSA event codes (priority: RST > SYN > FIN > ACK) */
.equ TCP_EVT_RST,      0
.equ TCP_EVT_SYN,      1       /* SYN set, ACK not set */
.equ TCP_EVT_SYNACK,   2       /* SYN + ACK both set */
.equ TCP_EVT_FIN,      3       /* FIN set (may have ACK) */
.equ TCP_EVT_ACK,      4       /* ACK set, no SYN/FIN/RST */
.equ TCP_N_EVENTS,     5
.equ TCP_N_STATES,     9       /* CLOSED(0) through TIME_WAIT(8) */
