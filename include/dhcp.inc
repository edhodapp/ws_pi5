/*
 * include/dhcp.inc — DHCP client constants (D017).
 *
 * State and event ordinals are NORMATIVE — the verify script reads
 * tests/func/dhcp_fsa_vectors.tsv and indexes the transition table
 * by (state * DHCP_NEVENTS + event). Reordering or renumbering
 * either set requires updating the .py state/event maps in lockstep.
 *
 * Transition-table entry layout matches include/vmio.inc's TRANS_*:
 *   +0  next_state   u32  (DHCP_NEXT_NONE = 0xFFFFFFFF means "no transition")
 *   +4  pad          u32
 *   +8  handler_ptr  u64  (0 = no handler)
 *  size 16 B
 */

.equ DHCP_NSTATES,         6
.equ DHCP_NEVENTS,         9

/* States — order MUST match scripts/verify_dhcp_fsa_table.py STATES. */
.equ S_INIT,               0
.equ S_SELECTING,          1
.equ S_REQUESTING,         2
.equ S_BOUND,              3
.equ S_RENEWING,           4
.equ S_REBINDING,          5

/* Events — order MUST match scripts/verify_dhcp_fsa_table.py EVENTS. */
.equ E_START,                  0
.equ E_TIMER_RETRANS_RETRY,    1
.equ E_TIMER_RETRANS_GIVEUP,   2
.equ E_TIMER_T1,               3
.equ E_TIMER_T2,               4
.equ E_TIMER_LEASE,            5
.equ E_RX_OFFER_VALID,         6
.equ E_RX_ACK_VALID,           7
.equ E_RX_NAK_VALID,           8

/* Transition-table entry layout — same shape as include/vmio.inc but
 * we redeclare the offsets so dhcp_fsa.S has no dependency on
 * vmio.inc (the DHCP FSA is single-instance, no queues, no ways). */
.equ DHCP_TRANS_NEXT,      0
.equ DHCP_TRANS_HANDLER,   8
.equ DHCP_TRANS_SIZE,      16

/* Sentinel u32 marking "table cell has no state transition". The
 * step function leaves dhcp_fsa_state untouched when next == this
 * value, regardless of whether a handler ran. */
.equ DHCP_NEXT_NONE,       0xFFFFFFFF


/* ============================================================================
 * RFC 2131 (DHCP) + RFC 951 (BOOTP) wire constants.
 *
 * BOOTP header: 236 fixed bytes + 4 magic cookie + variable options.
 * All multi-byte fields are network byte order on the wire.
 * ============================================================================ */

.equ DHCP_OP_BOOTREQUEST,    1
.equ DHCP_OP_BOOTREPLY,      2
.equ DHCP_HTYPE_ETHERNET,    1
.equ DHCP_HLEN_ETHERNET,     6

/* Magic cookie (RFC 1497): 99.130.83.99 in dotted-decimal, also
 * known as the DHCP options-block prefix. Big-endian on wire. */
.equ DHCP_MAGIC_BYTE0,       0x63
.equ DHCP_MAGIC_BYTE1,       0x82
.equ DHCP_MAGIC_BYTE2,       0x53
.equ DHCP_MAGIC_BYTE3,       0x63

/* BOOTP header field byte offsets. */
.equ BOOTP_OP,               0
.equ BOOTP_HTYPE,            1
.equ BOOTP_HLEN,             2
.equ BOOTP_HOPS,             3
.equ BOOTP_XID,              4    /* 4 B */
.equ BOOTP_SECS,             8    /* 2 B */
.equ BOOTP_FLAGS,            10   /* 2 B */
.equ BOOTP_CIADDR,           12   /* 4 B */
.equ BOOTP_YIADDR,           16   /* 4 B */
.equ BOOTP_SIADDR,           20   /* 4 B */
.equ BOOTP_GIADDR,           24   /* 4 B */
.equ BOOTP_CHADDR,           28   /* 16 B */
.equ BOOTP_SNAME,            44   /* 64 B */
.equ BOOTP_FILE,             108  /* 128 B */
.equ BOOTP_MAGIC,            236  /* 4 B */
.equ BOOTP_OPTIONS,          240
.equ BOOTP_HEADER_LEN,       240

/* DHCP option codes (RFC 2132). Only the ones we encode/decode. */
.equ DHCP_OPT_PAD,             0
.equ DHCP_OPT_SUBNET_MASK,     1
.equ DHCP_OPT_ROUTER,          3
.equ DHCP_OPT_REQUESTED_IP,    50
.equ DHCP_OPT_LEASE_TIME,      51
.equ DHCP_OPT_MSG_TYPE,        53
.equ DHCP_OPT_SERVER_ID,       54
.equ DHCP_OPT_PARAM_REQUEST,   55
.equ DHCP_OPT_END,             255

/* DHCP message types (option 53 value byte). */
.equ DHCP_MSG_DISCOVER,        1
.equ DHCP_MSG_OFFER,           2
.equ DHCP_MSG_REQUEST,         3
.equ DHCP_MSG_DECLINE,         4
.equ DHCP_MSG_ACK,             5
.equ DHCP_MSG_NAK,             6
.equ DHCP_MSG_RELEASE,         7
.equ DHCP_MSG_INFORM,          8
