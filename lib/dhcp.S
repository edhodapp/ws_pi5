/*
 * lib/dhcp.S — DHCP client wire-format builders (D017, RFC 2131 + 2132).
 *
 * Three pure functions that fill a caller-supplied buffer with a
 * BOOTP-formatted DHCP packet. The caller is responsible for
 * wrapping the result in Eth + IP (broadcast, except for RENEWING
 * which unicasts) + UDP (port 68 → 67) at send time. Parsers
 * (dhcp_parse_offer / dhcp_parse_ack) land in I16-4.
 *
 * Public entry points:
 *
 *   dhcp_build_discover(x0=buf, w1=xid)
 *     → w0 = packet length.
 *
 *   dhcp_build_request_selecting(x0=buf, w1=xid, w2=server_id, w3=requested_ip)
 *     → w0 = packet length. server_id and requested_ip are u32
 *       wire-order (bytes as they appear on the wire from net_our_ip).
 *
 *   dhcp_build_request_renewing(x0=buf, w1=xid, w2=ciaddr)
 *     → w0 = packet length. ciaddr is u32 wire-order, normally a
 *       copy of net_our_ip when the lease is bound.
 *
 * Reads net_our_mac for the BOOTP chaddr field. All multi-byte
 * fields are written in network byte order (big-endian on the
 * wire); since AArch64 is little-endian, multi-byte writes use
 * byte-at-a-time stores.
 *
 * Register convention inside builders:
 *   x19  buffer base (callee-saved across helper bls)
 *   x20  cursor (callee-saved)
 *
 * Helpers preserve x19..x28; transient state lives in x9..x16.
 */

.include "dhcp.inc"
.include "net.inc"

.global dhcp_build_discover
.global dhcp_build_request_selecting
.global dhcp_build_request_renewing

.section .text


/* ---------------------------------------------------------------------------
 * _dhcp_zero_header — write the fixed BOOTP header at [x0, x0+240).
 *
 *   x0 = buffer base (16-byte aligned not required; bytewise stores)
 *   w1 = xid (host-order u32; written big-endian on wire)
 *   w2 = ciaddr (u32 wire-order; written verbatim — already NBO)
 *
 * Side effects:
 *   - All 240 header bytes written.
 *   - chaddr[0..5] copied from net_our_mac; chaddr[6..15] zeroed.
 *   - sname (64 B) and file (128 B) zeroed.
 *   - Magic cookie at offset 236.
 *
 * Preserves x19..x28; clobbers x0..x16 and x30.
 * --------------------------------------------------------------------------- */
_dhcp_zero_header:
    /* op = BOOTREQUEST */
    mov     w3, #DHCP_OP_BOOTREQUEST
    strb    w3, [x0, #BOOTP_OP]
    /* htype = Ethernet */
    mov     w3, #DHCP_HTYPE_ETHERNET
    strb    w3, [x0, #BOOTP_HTYPE]
    /* hlen = 6 */
    mov     w3, #DHCP_HLEN_ETHERNET
    strb    w3, [x0, #BOOTP_HLEN]
    /* hops = 0 */
    strb    wzr, [x0, #BOOTP_HOPS]

    /* xid: write w1 big-endian (high byte at lowest offset). */
    lsr     w3, w1, #24
    strb    w3, [x0, #(BOOTP_XID + 0)]
    lsr     w3, w1, #16
    strb    w3, [x0, #(BOOTP_XID + 1)]
    lsr     w3, w1, #8
    strb    w3, [x0, #(BOOTP_XID + 2)]
    strb    w1, [x0, #(BOOTP_XID + 3)]

    /* secs = 0, flags = 0 */
    strh    wzr, [x0, #BOOTP_SECS]
    strh    wzr, [x0, #BOOTP_FLAGS]

    /* ciaddr (caller-provided, already wire-order). */
    str     w2, [x0, #BOOTP_CIADDR]
    /* yiaddr / siaddr / giaddr = 0 */
    str     wzr, [x0, #BOOTP_YIADDR]
    str     wzr, [x0, #BOOTP_SIADDR]
    str     wzr, [x0, #BOOTP_GIADDR]

    /* chaddr: 16 bytes. First 6 from net_our_mac, last 10 zero. */
    adrp    x3, net_our_mac
    add     x3, x3, :lo12:net_our_mac
    ldrb    w4, [x3, #0]; strb w4, [x0, #(BOOTP_CHADDR + 0)]
    ldrb    w4, [x3, #1]; strb w4, [x0, #(BOOTP_CHADDR + 1)]
    ldrb    w4, [x3, #2]; strb w4, [x0, #(BOOTP_CHADDR + 2)]
    ldrb    w4, [x3, #3]; strb w4, [x0, #(BOOTP_CHADDR + 3)]
    ldrb    w4, [x3, #4]; strb w4, [x0, #(BOOTP_CHADDR + 4)]
    ldrb    w4, [x3, #5]; strb w4, [x0, #(BOOTP_CHADDR + 5)]
    str     xzr, [x0, #(BOOTP_CHADDR + 6)]   /* 8 bytes: chaddr[6..13] */
    strh    wzr, [x0, #(BOOTP_CHADDR + 14)]  /* 2 bytes: chaddr[14..15] */

    /* sname (64 bytes) — write 8 × 8 bytes. */
    str     xzr, [x0, #(BOOTP_SNAME + 0)]
    str     xzr, [x0, #(BOOTP_SNAME + 8)]
    str     xzr, [x0, #(BOOTP_SNAME + 16)]
    str     xzr, [x0, #(BOOTP_SNAME + 24)]
    str     xzr, [x0, #(BOOTP_SNAME + 32)]
    str     xzr, [x0, #(BOOTP_SNAME + 40)]
    str     xzr, [x0, #(BOOTP_SNAME + 48)]
    str     xzr, [x0, #(BOOTP_SNAME + 56)]

    /* file (128 bytes) — 16 × 8. */
    mov     w3, #16
    add     x4, x0, #BOOTP_FILE
.Lzh_file_loop:
    str     xzr, [x4], #8
    sub     w3, w3, #1
    cbnz    w3, .Lzh_file_loop

    /* Magic cookie. */
    mov     w3, #DHCP_MAGIC_BYTE0
    strb    w3, [x0, #(BOOTP_MAGIC + 0)]
    mov     w3, #DHCP_MAGIC_BYTE1
    strb    w3, [x0, #(BOOTP_MAGIC + 1)]
    mov     w3, #DHCP_MAGIC_BYTE2
    strb    w3, [x0, #(BOOTP_MAGIC + 2)]
    mov     w3, #DHCP_MAGIC_BYTE3
    strb    w3, [x0, #(BOOTP_MAGIC + 3)]
    ret


/* ---------------------------------------------------------------------------
 * _dhcp_append_msg_type — write [opt=53, len=1, value=msg_type] at [x0].
 *   x0 = cursor
 *   w1 = message type (1=DISCOVER, 3=REQUEST, ...)
 * Returns: x0 advanced by 3.
 * --------------------------------------------------------------------------- */
_dhcp_append_msg_type:
    mov     w2, #DHCP_OPT_MSG_TYPE
    strb    w2, [x0], #1
    mov     w2, #1
    strb    w2, [x0], #1
    strb    w1, [x0], #1
    ret


/* ---------------------------------------------------------------------------
 * _dhcp_append_param_request — write [opt=55, len=3, 1, 3, 51] at [x0].
 *   x0 = cursor
 * Returns: x0 advanced by 5.
 *
 * The list MUST stay consistent across DISCOVER and REQUEST per
 * RFC 2131 §4.4.1.
 * --------------------------------------------------------------------------- */
_dhcp_append_param_request:
    mov     w1, #DHCP_OPT_PARAM_REQUEST
    strb    w1, [x0], #1
    mov     w1, #3
    strb    w1, [x0], #1
    mov     w1, #DHCP_OPT_SUBNET_MASK
    strb    w1, [x0], #1
    mov     w1, #DHCP_OPT_ROUTER
    strb    w1, [x0], #1
    mov     w1, #DHCP_OPT_LEASE_TIME
    strb    w1, [x0], #1
    ret


/* ---------------------------------------------------------------------------
 * _dhcp_append_ip_option — write [opt=N, len=4, ip_bytes] at [x0].
 *   x0 = cursor
 *   w1 = option code
 *   w2 = IP value (u32 wire-order — 4 bytes written verbatim)
 * Returns: x0 advanced by 6.
 *
 * Byte-at-a-time stores: option offsets aren't guaranteed to be
 * 4-aligned, so a `str w2` here would alignment-fault on hardware
 * with strict alignment checking enabled (SCTLR_EL1.A) even though
 * Normal memory permits unaligned access today.
 * --------------------------------------------------------------------------- */
_dhcp_append_ip_option:
    strb    w1, [x0], #1
    mov     w1, #4
    strb    w1, [x0], #1
    strb    w2, [x0], #1                /* IP byte 0 */
    lsr     w3, w2, #8
    strb    w3, [x0], #1                /* IP byte 1 */
    lsr     w3, w2, #16
    strb    w3, [x0], #1                /* IP byte 2 */
    lsr     w3, w2, #24
    strb    w3, [x0], #1                /* IP byte 3 */
    ret


/* ---------------------------------------------------------------------------
 * _dhcp_append_end — write [opt=255] at [x0]. Returns x0 + 1.
 * --------------------------------------------------------------------------- */
_dhcp_append_end:
    mov     w1, #DHCP_OPT_END
    strb    w1, [x0], #1
    ret


/* ===========================================================================
 * dhcp_build_discover
 *
 *   x0 = buffer
 *   w1 = xid
 * Returns:
 *   w0 = packet length (BOOTP header + options + END = 249).
 *
 * Wire layout post-call:
 *   240 BOOTP header (op=1, ciaddr=0, chaddr=net_our_mac, magic)
 *     3 Option 53 (msg-type = DISCOVER)
 *     5 Option 55 (parameter request list: subnet, router, lease)
 *     1 Option 255 (END)
 * =========================================================================== */
dhcp_build_discover:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     x19, x0                     /* buf base */

    /* Header with ciaddr=0. */
    mov     w2, #0
    bl      _dhcp_zero_header

    /* Options at buf + BOOTP_OPTIONS. */
    add     x20, x19, #BOOTP_OPTIONS
    mov     x0, x20
    mov     w1, #DHCP_MSG_DISCOVER
    bl      _dhcp_append_msg_type
    bl      _dhcp_append_param_request
    bl      _dhcp_append_end
    /* x0 now points to end of packet. */
    sub     x0, x0, x19                 /* 64-bit subtract; fits in w0 */

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* ===========================================================================
 * dhcp_build_request_selecting
 *
 *   x0 = buffer
 *   w1 = xid
 *   w2 = server_id  (u32 wire-order)
 *   w3 = requested_ip (u32 wire-order)
 *
 * RFC 2131 §4.4.1: REQUEST in SELECTING state MUST include both
 *   Option 50 (requested IP) and Option 54 (server identifier).
 * =========================================================================== */
dhcp_build_request_selecting:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                     /* buf */
    mov     w21, w2                     /* server_id */
    mov     w22, w3                     /* requested_ip */

    /* Header with ciaddr=0. _dhcp_zero_header uses x3+ as scratch
     * and doesn't touch w1 (xid), so the caller's w1 reaches the
     * helper unchanged. */
    mov     w2, #0
    bl      _dhcp_zero_header

    add     x0, x19, #BOOTP_OPTIONS
    mov     w1, #DHCP_MSG_REQUEST
    bl      _dhcp_append_msg_type
    /* Option 50 = requested IP. */
    mov     w1, #DHCP_OPT_REQUESTED_IP
    mov     w2, w22
    bl      _dhcp_append_ip_option
    /* Option 54 = server identifier. */
    mov     w1, #DHCP_OPT_SERVER_ID
    mov     w2, w21
    bl      _dhcp_append_ip_option
    bl      _dhcp_append_param_request
    bl      _dhcp_append_end
    sub     x0, x0, x19                 /* 64-bit subtract; fits in w0 */

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


/* ===========================================================================
 * dhcp_build_request_renewing
 *
 *   x0 = buffer
 *   w1 = xid
 *   w2 = ciaddr (u32 wire-order; the bound IP we're renewing)
 *
 * RFC 2131 §4.3.6: REQUEST in BOUND/RENEWING/REBINDING MUST set
 *   ciaddr to the bound IP and MUST NOT include Option 50 or 54.
 * =========================================================================== */
dhcp_build_request_renewing:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     x19, x0                     /* buf */

    /* Header with ciaddr = w2 (caller-supplied). */
    bl      _dhcp_zero_header

    add     x0, x19, #BOOTP_OPTIONS
    mov     w1, #DHCP_MSG_REQUEST
    bl      _dhcp_append_msg_type
    bl      _dhcp_append_param_request
    bl      _dhcp_append_end
    sub     x0, x0, x19                 /* 64-bit subtract; fits in w0 */

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
