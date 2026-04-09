/* Network protocol constants: Ethernet, ARP, static IP config */

/* Ethernet header offsets and sizes */
.equ ETH_DST,          0
.equ ETH_SRC,          6
.equ ETH_TYPE,         12
.equ ETH_PAYLOAD,      14
.equ ETH_HDR_LEN,      14
.equ ETH_ADDR_LEN,     6
.equ ETH_MTU,          1500
.equ ETH_FRAME_MAX,    1514

/* EtherType values (host order) */
.equ ETHERTYPE_ARP,    0x0806
.equ ETHERTYPE_IPV4,   0x0800

/* ARP packet offsets (relative to ETH_PAYLOAD) */
.equ ARP_HTYPE,        0
.equ ARP_PTYPE,        2
.equ ARP_HLEN,         4
.equ ARP_PLEN,         5
.equ ARP_OPER,         6
.equ ARP_SHA,          8
.equ ARP_SPA,          14
.equ ARP_THA,          18
.equ ARP_TPA,          24
.equ ARP_PKT_LEN,      28
.equ ARP_FRAME_LEN,    42

/* ARP operation codes (host order) */
.equ ARP_OP_REQUEST,   1
.equ ARP_OP_REPLY,     2

/* ARP cache refresh interval (seconds) */
.equ ARP_REFRESH_SECS, 300

/* ARP send context struct offsets (follows NTP pattern) */
.equ ARPC_DWC2_BASE,   0       /* x: DWC2 register base */
.equ ARPC_ECM_STATE,   8       /* x: ecm_state pointer */
.equ ARPC_TX_BUF,      16      /* x: TX buffer pointer */
.equ ARPC_TIMER_POOL,  24      /* x: timer pool pointer */
.equ ARPC_SEND_FN,     32      /* x: cdc_ecm_send function pointer */
.equ ARPC_TIMER_FREQ,  40      /* x: CNTFRQ_EL0 cached */
.equ ARPC_SIZE,        48

/* IPv4 header offsets (relative to ETH_PAYLOAD) */
.equ IP_VER_IHL,       0
.equ IP_DSCP_ECN,      1
.equ IP_TOTLEN,        2
.equ IP_ID,            4
.equ IP_FLAGS_FRAG,    6
.equ IP_TTL,           8
.equ IP_PROTO,         9
.equ IP_CHECKSUM,      10
.equ IP_SRC,           12
.equ IP_DST,           16
.equ IP_HDR_MIN,       20
.equ IP_DEFAULT_TTL,   64

/* IP protocol numbers */
.equ IP_PROTO_ICMP,    1
.equ IP_PROTO_TCP,     6
.equ IP_PROTO_UDP,     17

/* ICMP offsets (relative to IP payload, i.e., ETH_PAYLOAD + IP_HDR_MIN) */
.equ ICMP_TYPE,        0
.equ ICMP_CODE,        1
.equ ICMP_CHECKSUM,    2
.equ ICMP_ID,          4
.equ ICMP_SEQ,         6
.equ ICMP_HDR_LEN,     8
.equ ICMP_ECHO_REQUEST, 8
.equ ICMP_ECHO_REPLY,  0
.equ ICMP_DEST_UNREACHABLE, 3
.equ ICMP_REDIRECT,    5
.equ ICMP_TIME_EXCEEDED, 11
.equ ICMP_PARAM_PROBLEM, 12

/* ICMP Destination Unreachable codes */
.equ ICMP_CODE_NET_UNREACH,    0
.equ ICMP_CODE_HOST_UNREACH,   1
.equ ICMP_CODE_PROTO_UNREACH,  2
.equ ICMP_CODE_PORT_UNREACH,   3
.equ ICMP_CODE_FRAG_NEEDED,    4

/* ICMP error frame: ETH(14) + IP(20) + ICMP(8) + orig_IP(20) + orig_payload(8) */
.equ ICMP_ERROR_FRAME_LEN,    70

/* ICMP rate limiting */
.equ ICMP_ERR_BURST,           10

/* ICMP send context struct offsets */
.equ ICMPC_DWC2_BASE,  0       /* x: DWC2 register base */
.equ ICMPC_ECM_STATE,  8       /* x: ecm_state pointer */
.equ ICMPC_TX_BUF,     16      /* x: TX buffer pointer */
.equ ICMPC_SEND_FN,    24      /* x: cdc_ecm_send function pointer */
.equ ICMPC_SIZE,       32

/* UDP offsets (relative to IP payload, i.e., ETH_PAYLOAD + IP_HDR_MIN) */
.equ UDP_SPORT,        0
.equ UDP_DPORT,        2
.equ UDP_LENGTH,       4
.equ UDP_CHECKSUM,     6
.equ UDP_HDR_LEN,      8
.equ UDP_ECHO_PORT,    7

/* IP fragment reassembly — slot layout
 *
 * DESIGN NOTE — REASM_BUF_SIZE is an over-provisioned upper bound,
 * NOT the effective reassembly ceiling. The real operational ceiling
 * is 1480 bytes of reassembled IP total_length. See below.
 *
 * Where 2048 came from:
 *   * IPv4's fragment-offset field is in 8-byte units (RFC 791 §3.1),
 *     so the natural representation is a bitmap with one bit per
 *     8-byte payload unit.
 *   * The bitmap is 32 bytes = 256 bits. 32 was chosen so that
 *     ip_reasm_init can zero the bitmap in exactly two
 *     `stp xzr, xzr` instructions (see lib/ip_reasm.S).
 *   * 256 bits × 8 bytes/bit = 2048 bytes of slot-buffer capacity.
 *     `REASM_BUF_SIZE = 2048` is a *consequence* of the bitmap
 *     geometry, not an independent size decision.
 *
 * Where 1480 comes from:
 *   * ip_reasm_input rebuilds the reassembled datagram IN PLACE in
 *     the 1514-byte Ethernet frame buffer it received the last
 *     fragment in.
 *   * At completion time the engine enforces:
 *       REASM_TOTAL_LEN + ETH_HDR_LEN + IP_HDR_MIN <= ETH_FRAME_MAX
 *       i.e. total_length + 34 <= 1514
 *       i.e. total_length <= 1480
 *   * Any fragmented datagram whose reassembled IP payload exceeds
 *     1480 bytes is silently dropped at that check (RFC-compliant;
 *     hosts may cap their reassembly buffer). The check lives in
 *     lib/ip_reasm.S at the `.Lri_complete` label.
 *
 * Consequence:
 *   * ~568 bytes per slot × 4 slots ≈ 2.3 KB of BSS is addressable
 *     but never usefully reachable. Negligible at this memory
 *     budget (~32 MB total runtime footprint).
 *
 * Why we leave it as-is:
 *   1. Shrinking the bitmap to match 1480 would require either a
 *      24-byte bitmap (does not zero cleanly in stp-pair init) or
 *      a 16-byte bitmap (1024-byte capacity, tighter than the
 *      in-place ceiling). Neither is a clean win.
 *   2. Lifting the in-place-rebuild constraint would require
 *      rewriting icmp_handle / udp_handle / tcp_handle to accept a
 *      separate reassembly output buffer and a length parameter
 *      instead of owning a 1514-byte frame. Larger refactor,
 *      explicitly out of scope for the L3 cycle.
 *
 * The inconsistency between REASM_BUF_SIZE (2048) and the
 * effective ceiling (1480) is recorded here so future readers
 * don't trip over it the way the L3 hardening plan did when it
 * proposed 2×1024-byte fragment test cases that would have
 * silently failed the completion check. See README "Design
 * Decisions" for additional context.
 */
.equ REASM_SRC_IP,       0      /* u32: source IP (NBO) */
.equ REASM_DST_IP,       4      /* u32: dest IP (NBO) */
.equ REASM_IP_ID,        8      /* u16: IP identification (NBO) */
.equ REASM_PROTO,        10     /* u8:  IP protocol */
.equ REASM_FLAGS,        11     /* u8:  bit 0=have_last, bit 7=active */
.equ REASM_TOTAL_LEN,    12     /* u16: total payload bytes (valid when have_last) */
.equ REASM_TIMER_SLOT,   14     /* u8:  timer pool slot (0xFF=none) */
.equ REASM_MIN_TTL,      15     /* u8:  minimum TTL across fragments */
.equ REASM_HDR_SIZE,     32     /* padded to 32 */
.equ REASM_BITMAP,       32     /* 32-byte bitmap (256 bits, 1 per 8-byte unit) */
.equ REASM_BITMAP_SIZE,  32
.equ REASM_DATA,         64     /* payload buffer */
.equ REASM_BUF_SIZE,     2048   /* over-provisioned — see DESIGN NOTE above */
.equ REASM_SLOT_SIZE,    2112   /* 64 + 2048 */
.equ REASM_MAX_SLOTS,    4
.equ REASM_TIMEOUT_SECS, 30

/* Static IP configuration (network byte order for zero-cost wire comparison) */
.equ NET_IP_NBO,       0x0A00020F      /* 10.0.2.15 */
.equ NET_GW_NBO,       0x0A000202      /* 10.0.2.2 */
.equ NET_MASK_NBO,     0xFFFFFF00      /* 255.255.255.0 */
