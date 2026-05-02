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


/* dhcp_parsed — receive-path scratch where dhcp_parse_inbound
 * stashes the extracted option values for the FSA action handlers
 * to read. All fields are in HOST byte order (parse converts BE to
 * LE) except yiaddr / server_id / subnet_mask / router_ip which
 * stay wire-order so they can be written into net_cfg globals
 * (which already store wire-order).
 *
 *  +0   msg_type        u8   (DHCP_MSG_*; 0 = invalid/dropped)
 *  +1   flags           u8   (which options were seen — bit 0 = 51 lease,
 *                              bit 1 = 54 server-id, bit 2 = 1 subnet,
 *                              bit 3 = 3 router)
 *  +4   yiaddr          u32  wire-order (server's offered IP)
 *  +8   server_id       u32  wire-order (option 54)
 * +12   lease_time      u32  HOST order (option 51, RFC 2131 calls
 *                              0xFFFFFFFF "infinite")
 * +16   subnet_mask     u32  wire-order (option 1)
 * +20   router_ip       u32  wire-order (option 3)
 *  size 24
 */
.equ DHCP_PARSED_MSG_TYPE,    0
.equ DHCP_PARSED_FLAGS,       1
.equ DHCP_PARSED_YIADDR,      4
.equ DHCP_PARSED_SERVER_ID,   8
.equ DHCP_PARSED_LEASE_TIME,  12
.equ DHCP_PARSED_SUBNET_MASK, 16
.equ DHCP_PARSED_ROUTER_IP,   20
.equ DHCP_PARSED_SIZE,        24

/* dhcp_parsed.flags bits — set as the parser walks options. */
.equ DHCP_FLAG_SEEN_LEASE,    1
.equ DHCP_FLAG_SEEN_SERVER,   2
.equ DHCP_FLAG_SEEN_SUBNET,   4
.equ DHCP_FLAG_SEEN_ROUTER,   8


/* ============================================================================
 * dhcp_send_ctx — context the FSA action handlers read to drive the
 * client. Populated by dhcp_start; read-mostly thereafter except for
 * xid / retries / lease deadlines which the handlers update.
 *
 *  +0   DWC2_BASE        u64  driver base (genet on Pi 4)
 *  +8   ECM_STATE        u64  driver state (genet_state)
 * +16   TX_BUF           u64  scratch frame buffer (≥ 350 B)
 * +24   TIMER_POOL       u64  pool for retrans / T1 / T2 / lease timers
 * +32   TIMER_FREQ       u64  CNTFRQ_EL0 cached at start
 * +40   SEND_FN          u64  send_fn(base, state, frame, len)
 * +48   XID              u32  current transaction id
 * +52   RETRIES          u32  retries remaining in SELECTING / REQUESTING
 * +56   LEASE_TIME       u32  lease seconds from last ACK (host order)
 * +64   T1_DEADLINE      u64  CNTPCT_EL0 absolute tick (lease/2)
 * +72   T2_DEADLINE      u64  CNTPCT_EL0 absolute tick (lease * 7/8)
 * +80   LEASE_DEADLINE   u64  CNTPCT_EL0 absolute tick (full lease)
 *  size 88
 * ============================================================================ */
.equ DHCPC_DWC2_BASE,        0
.equ DHCPC_ECM_STATE,        8
.equ DHCPC_TX_BUF,           16
.equ DHCPC_TIMER_POOL,       24
.equ DHCPC_TIMER_FREQ,       32
.equ DHCPC_SEND_FN,          40
.equ DHCPC_XID,              48
.equ DHCPC_RETRIES,          52
.equ DHCPC_LEASE_TIME,       56
.equ DHCPC_T1_DEADLINE,      64
.equ DHCPC_T2_DEADLINE,      72
.equ DHCPC_LEASE_DEADLINE,   80
.equ DHCPC_SIZE,             88

/* RFC 2131 §4.1: 4 s, 8 s, 16 s exponential backoff, 3 retries
 * before panic_d per D017. */
.equ DHCP_MAX_RETRIES,       3
