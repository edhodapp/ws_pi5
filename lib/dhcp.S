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
.global dhcp_parse_inbound
.global dhcp_parsed
.global dhcp_wrap_broadcast
.global dhcp_dispatch

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

    /* secs = 0, flags = 0x8000 (BROADCAST). Per RFC 2131 §4.1, a
     * client that cannot receive unicast IP datagrams until its
     * stack has an IP MUST set BROADCAST so the server replies to
     * 255.255.255.255 instead of unicasting to the offered yiaddr
     * (which we don't own yet). */
    strh    wzr, [x0, #BOOTP_SECS]
    mov     w3, #0x80
    strb    w3, [x0, #BOOTP_FLAGS]
    strb    wzr, [x0, #(BOOTP_FLAGS + 1)]

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


/* ===========================================================================
 * dhcp_parse_inbound — RFC 2131 receive-path validator.
 *
 *   x0 = DHCP payload pointer (UDP body, starting at BOOTP_OP)
 *   w1 = payload length in bytes
 *   w2 = expected xid (host order; the xid we sent in DISCOVER /
 *        REQUEST and are still tracking)
 *
 * Returns:
 *   w0 = msg_type (DHCP_MSG_OFFER, DHCP_MSG_ACK, DHCP_MSG_NAK), or
 *        0 if the packet is malformed, addressed to someone else,
 *        or violates a "MUST" rule (e.g. OFFER without server-id).
 *
 * Side effect: on success (return != 0), dhcp_parsed.* is populated.
 * On failure dhcp_parsed is left in whatever state — caller MUST
 * NOT read it. Setting msg_type=0 explicitly makes it safe to
 * inspect even after a drop.
 *
 * Validation (drops cause w0=0):
 *   1. len >= BOOTP_HEADER_LEN + 1
 *   2. op == BOOTREPLY
 *   3. htype == 1, hlen == 6
 *   4. xid == expected_xid (BE on wire → host order compare)
 *   5. chaddr[0..5] == net_our_mac
 *   6. magic cookie == 63 82 53 63
 *   7. options walk: opt 53 (msg-type) MUST be present
 *   8. for OFFER/ACK: opt 54 (server-id) and opt 51 (lease) MUST
 *      be present
 *
 * Register convention:
 *   x19 payload pointer (callee-saved)
 *   w20 payload length (callee-saved)
 *   w21 expected_xid (callee-saved)
 *   x22 dhcp_parsed pointer (callee-saved)
 *   w23 cursor offset into options (callee-saved)
 * =========================================================================== */
dhcp_parse_inbound:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    str     x23, [sp, #48]

    mov     x19, x0
    mov     w20, w1
    mov     w21, w2

    /* Reset dhcp_parsed (also clears msg_type so a drop leaves it safe). */
    adrp    x22, dhcp_parsed
    add     x22, x22, :lo12:dhcp_parsed
    str     xzr, [x22, #0]
    str     xzr, [x22, #8]
    str     xzr, [x22, #16]

    /* 1. length */
    cmp     w20, #(BOOTP_HEADER_LEN + 1)
    b.lt    .Lparse_drop

    /* 2. op == BOOTREPLY */
    ldrb    w0, [x19, #BOOTP_OP]
    cmp     w0, #DHCP_OP_BOOTREPLY
    b.ne    .Lparse_drop

    /* 3. htype == 1, hlen == 6 */
    ldrb    w0, [x19, #BOOTP_HTYPE]
    cmp     w0, #DHCP_HTYPE_ETHERNET
    b.ne    .Lparse_drop
    ldrb    w0, [x19, #BOOTP_HLEN]
    cmp     w0, #DHCP_HLEN_ETHERNET
    b.ne    .Lparse_drop

    /* 4. xid match. Wire is BE; reassemble to host order. */
    ldrb    w0, [x19, #(BOOTP_XID + 0)]
    ldrb    w1, [x19, #(BOOTP_XID + 1)]
    ldrb    w3, [x19, #(BOOTP_XID + 2)]
    ldrb    w4, [x19, #(BOOTP_XID + 3)]
    lsl     w0, w0, #24
    orr     w0, w0, w1, lsl #16
    orr     w0, w0, w3, lsl #8
    orr     w0, w0, w4
    cmp     w0, w21
    b.ne    .Lparse_drop

    /* 5. chaddr[0..5] == net_our_mac. Byte compare so unaligned
     * MAC storage doesn't matter. */
    adrp    x3, net_our_mac
    add     x3, x3, :lo12:net_our_mac
    mov     w4, #0
.Lparse_mac_loop:
    cmp     w4, #6
    b.eq    .Lparse_mac_ok
    add     x5, x19, w4, uxtw
    ldrb    w0, [x5, #BOOTP_CHADDR]
    ldrb    w1, [x3, w4, uxtw]
    cmp     w0, w1
    b.ne    .Lparse_drop
    add     w4, w4, #1
    b       .Lparse_mac_loop
.Lparse_mac_ok:

    /* 6. magic cookie */
    ldrb    w0, [x19, #(BOOTP_MAGIC + 0)]
    cmp     w0, #DHCP_MAGIC_BYTE0
    b.ne    .Lparse_drop
    ldrb    w0, [x19, #(BOOTP_MAGIC + 1)]
    cmp     w0, #DHCP_MAGIC_BYTE1
    b.ne    .Lparse_drop
    ldrb    w0, [x19, #(BOOTP_MAGIC + 2)]
    cmp     w0, #DHCP_MAGIC_BYTE2
    b.ne    .Lparse_drop
    ldrb    w0, [x19, #(BOOTP_MAGIC + 3)]
    cmp     w0, #DHCP_MAGIC_BYTE3
    b.ne    .Lparse_drop

    /* Header passed validation. Stash yiaddr (always 4 bytes,
     * wire-order) so OFFER/ACK action handlers find it ready. */
    ldrb    w0, [x19, #(BOOTP_YIADDR + 0)]
    strb    w0, [x22, #(DHCP_PARSED_YIADDR + 0)]
    ldrb    w0, [x19, #(BOOTP_YIADDR + 1)]
    strb    w0, [x22, #(DHCP_PARSED_YIADDR + 1)]
    ldrb    w0, [x19, #(BOOTP_YIADDR + 2)]
    strb    w0, [x22, #(DHCP_PARSED_YIADDR + 2)]
    ldrb    w0, [x19, #(BOOTP_YIADDR + 3)]
    strb    w0, [x22, #(DHCP_PARSED_YIADDR + 3)]

    /* 7. Walk options. */
    mov     w23, #BOOTP_OPTIONS
.Lparse_opt_loop:
    cmp     w23, w20
    b.hs    .Lparse_opt_done
    ldrb    w0, [x19, w23, uxtw]
    cmp     w0, #DHCP_OPT_END
    b.eq    .Lparse_opt_done
    cmp     w0, #DHCP_OPT_PAD
    b.eq    .Lparse_opt_pad

    /* len byte must exist and the option's data must fit. */
    add     w1, w23, #1
    cmp     w1, w20
    b.hs    .Lparse_drop
    ldrb    w3, [x19, w1, uxtw]                  /* w3 = option len */
    add     w1, w1, #1                           /* w1 = data start offset */
    add     w4, w1, w3                           /* w4 = data end offset */
    cmp     w4, w20
    b.hi    .Lparse_drop

    /* Dispatch on option code. */
    cmp     w0, #DHCP_OPT_MSG_TYPE
    b.eq    .Lparse_opt_msg_type
    cmp     w0, #DHCP_OPT_SERVER_ID
    b.eq    .Lparse_opt_server_id
    cmp     w0, #DHCP_OPT_LEASE_TIME
    b.eq    .Lparse_opt_lease
    cmp     w0, #DHCP_OPT_SUBNET_MASK
    b.eq    .Lparse_opt_subnet
    cmp     w0, #DHCP_OPT_ROUTER
    b.eq    .Lparse_opt_router
    /* Unknown option: skip. */
    mov     w23, w4
    b       .Lparse_opt_loop

.Lparse_opt_pad:
    add     w23, w23, #1
    b       .Lparse_opt_loop

.Lparse_opt_msg_type:
    cmp     w3, #1
    b.ne    .Lparse_drop
    ldrb    w0, [x19, w1, uxtw]
    strb    w0, [x22, #DHCP_PARSED_MSG_TYPE]
    mov     w23, w4
    b       .Lparse_opt_loop

.Lparse_opt_server_id:
    cmp     w3, #4
    b.ne    .Lparse_drop
    add     x5, x19, w1, uxtw
    ldrb    w0, [x5, #0]; strb w0, [x22, #(DHCP_PARSED_SERVER_ID + 0)]
    ldrb    w0, [x5, #1]; strb w0, [x22, #(DHCP_PARSED_SERVER_ID + 1)]
    ldrb    w0, [x5, #2]; strb w0, [x22, #(DHCP_PARSED_SERVER_ID + 2)]
    ldrb    w0, [x5, #3]; strb w0, [x22, #(DHCP_PARSED_SERVER_ID + 3)]
    ldrb    w0, [x22, #DHCP_PARSED_FLAGS]
    orr     w0, w0, #DHCP_FLAG_SEEN_SERVER
    strb    w0, [x22, #DHCP_PARSED_FLAGS]
    mov     w23, w4
    b       .Lparse_opt_loop

.Lparse_opt_lease:
    cmp     w3, #4
    b.ne    .Lparse_drop
    /* RFC: 32-bit BE seconds. Convert to host order here so callers
     * compare directly against `now + lease` in seconds. */
    add     x5, x19, w1, uxtw
    ldrb    w0, [x5, #0]
    ldrb    w6, [x5, #1]
    ldrb    w7, [x5, #2]
    ldrb    w8, [x5, #3]
    lsl     w0, w0, #24
    orr     w0, w0, w6, lsl #16
    orr     w0, w0, w7, lsl #8
    orr     w0, w0, w8
    str     w0, [x22, #DHCP_PARSED_LEASE_TIME]
    ldrb    w0, [x22, #DHCP_PARSED_FLAGS]
    orr     w0, w0, #DHCP_FLAG_SEEN_LEASE
    strb    w0, [x22, #DHCP_PARSED_FLAGS]
    mov     w23, w4
    b       .Lparse_opt_loop

.Lparse_opt_subnet:
    cmp     w3, #4
    b.ne    .Lparse_drop
    add     x5, x19, w1, uxtw
    ldrb    w0, [x5, #0]; strb w0, [x22, #(DHCP_PARSED_SUBNET_MASK + 0)]
    ldrb    w0, [x5, #1]; strb w0, [x22, #(DHCP_PARSED_SUBNET_MASK + 1)]
    ldrb    w0, [x5, #2]; strb w0, [x22, #(DHCP_PARSED_SUBNET_MASK + 2)]
    ldrb    w0, [x5, #3]; strb w0, [x22, #(DHCP_PARSED_SUBNET_MASK + 3)]
    ldrb    w0, [x22, #DHCP_PARSED_FLAGS]
    orr     w0, w0, #DHCP_FLAG_SEEN_SUBNET
    strb    w0, [x22, #DHCP_PARSED_FLAGS]
    mov     w23, w4
    b       .Lparse_opt_loop

.Lparse_opt_router:
    /* Option 3 may carry multiple router IPs; we record only the
     * first per D010 (always-via-gateway routing). */
    cmp     w3, #4
    b.lt    .Lparse_drop
    add     x5, x19, w1, uxtw
    ldrb    w0, [x5, #0]; strb w0, [x22, #(DHCP_PARSED_ROUTER_IP + 0)]
    ldrb    w0, [x5, #1]; strb w0, [x22, #(DHCP_PARSED_ROUTER_IP + 1)]
    ldrb    w0, [x5, #2]; strb w0, [x22, #(DHCP_PARSED_ROUTER_IP + 2)]
    ldrb    w0, [x5, #3]; strb w0, [x22, #(DHCP_PARSED_ROUTER_IP + 3)]
    ldrb    w0, [x22, #DHCP_PARSED_FLAGS]
    orr     w0, w0, #DHCP_FLAG_SEEN_ROUTER
    strb    w0, [x22, #DHCP_PARSED_FLAGS]
    mov     w23, w4
    b       .Lparse_opt_loop

.Lparse_opt_done:
    /* 8. Required-options check based on msg_type. */
    ldrb    w0, [x22, #DHCP_PARSED_MSG_TYPE]
    cmp     w0, #DHCP_MSG_OFFER
    b.eq    .Lparse_check_offer_ack
    cmp     w0, #DHCP_MSG_ACK
    b.eq    .Lparse_check_offer_ack
    cmp     w0, #DHCP_MSG_NAK
    b.eq    .Lparse_ok                  /* NAK has no required options */
    /* msg_type missing or other → drop */
    b       .Lparse_drop

.Lparse_check_offer_ack:
    /* Both server-id (54) and lease (51) MUST be present. */
    ldrb    w1, [x22, #DHCP_PARSED_FLAGS]
    and     w3, w1, #(DHCP_FLAG_SEEN_LEASE | DHCP_FLAG_SEEN_SERVER)
    cmp     w3, #(DHCP_FLAG_SEEN_LEASE | DHCP_FLAG_SEEN_SERVER)
    b.ne    .Lparse_drop

.Lparse_ok:
    /* w0 already holds msg_type from the check above. */
    b       .Lparse_done
.Lparse_drop:
    /* Force msg_type=0 in dhcp_parsed so callers that ignore the
     * return value can still safely read it. */
    strb    wzr, [x22, #DHCP_PARSED_MSG_TYPE]
    mov     w0, #0
.Lparse_done:
    ldr     x23, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


.section .bss
.balign 8
dhcp_parsed:
    .space DHCP_PARSED_SIZE


.section .text
/* ===========================================================================
 * dhcp_wrap_broadcast — write Eth+IP+UDP broadcast headers for an
 * outbound DHCPDISCOVER or DHCPREQUEST (SELECTING / REBINDING).
 *
 *   x0 = frame buffer (contains BOOTP payload at offset 42)
 *   w1 = payload length (DHCP body length, e.g. 249 for DISCOVER)
 *
 * Wire details:
 *   Eth dst = ff:ff:ff:ff:ff:ff  (broadcast)
 *   Eth src = net_our_mac
 *   Eth type = 0x0800
 *   IP ver/IHL = 0x45, TOS = 0
 *   IP totlen = 28 + payload_len (BE)
 *   IP id/flags/frag = 0
 *   IP TTL = 64
 *   IP proto = 17 (UDP)
 *   IP src = 0.0.0.0
 *   IP dst = 255.255.255.255
 *   UDP sport = 68 (client)
 *   UDP dport = 67 (server)
 *   UDP length = 8 + payload_len (BE)
 *   UDP checksum = 0 (RFC 768 permits zero for IPv4)
 *
 * Caller is responsible for the BOOTP payload at frame[42..].
 * Preserves x19..x28; clobbers x0..x16, x30 (calls ip_checksum).
 * --------------------------------------------------------------------------- */
dhcp_wrap_broadcast:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x23, [sp, #16]
    str     x24, [sp, #24]

    mov     x23, x0                     /* frame */
    mov     w24, w1                     /* payload_len */

    /* Eth dst = broadcast (ff × 6). */
    mov     w0, #0xFF
    strb    w0, [x23, #0]
    strb    w0, [x23, #1]
    strb    w0, [x23, #2]
    strb    w0, [x23, #3]
    strb    w0, [x23, #4]
    strb    w0, [x23, #5]

    /* Eth src = net_our_mac. */
    adrp    x9, net_our_mac
    add     x9, x9, :lo12:net_our_mac
    ldrb    w0, [x9, #0]; strb w0, [x23, #6]
    ldrb    w0, [x9, #1]; strb w0, [x23, #7]
    ldrb    w0, [x9, #2]; strb w0, [x23, #8]
    ldrb    w0, [x9, #3]; strb w0, [x23, #9]
    ldrb    w0, [x9, #4]; strb w0, [x23, #10]
    ldrb    w0, [x9, #5]; strb w0, [x23, #11]

    /* Eth type = 0x0800 (IPv4). */
    mov     w0, #0x08
    strb    w0, [x23, #12]
    strb    wzr, [x23, #13]

    /* IP header at offset 14. ver/IHL = 0x45, TOS = 0. */
    mov     w0, #0x45
    strb    w0, [x23, #(14 + 0)]
    strb    wzr, [x23, #(14 + 1)]

    /* totlen = 20 + 8 + payload_len (BE). */
    add     w0, w24, #(20 + 8)
    lsr     w1, w0, #8
    strb    w1, [x23, #(14 + 2)]
    strb    w0, [x23, #(14 + 3)]

    /* id, flags+frag = 0. */
    strb    wzr, [x23, #(14 + 4)]
    strb    wzr, [x23, #(14 + 5)]
    strb    wzr, [x23, #(14 + 6)]
    strb    wzr, [x23, #(14 + 7)]

    /* TTL = 64 (typical for client broadcasts). */
    mov     w0, #64
    strb    w0, [x23, #(14 + 8)]
    /* Protocol = UDP. */
    mov     w0, #17
    strb    w0, [x23, #(14 + 9)]
    /* IP checksum = 0 (will be filled below). */
    strb    wzr, [x23, #(14 + 10)]
    strb    wzr, [x23, #(14 + 11)]

    /* IP src = 0.0.0.0. */
    strb    wzr, [x23, #(14 + 12)]
    strb    wzr, [x23, #(14 + 13)]
    strb    wzr, [x23, #(14 + 14)]
    strb    wzr, [x23, #(14 + 15)]

    /* IP dst = 255.255.255.255. */
    mov     w0, #0xFF
    strb    w0, [x23, #(14 + 16)]
    strb    w0, [x23, #(14 + 17)]
    strb    w0, [x23, #(14 + 18)]
    strb    w0, [x23, #(14 + 19)]

    /* IP checksum over the 20-byte header. ip_checksum returns
     * the value already in wire-byte order (low byte first when
     * stored at offset 10), matching how lib/icmp.S writes it. */
    add     x0, x23, #14
    mov     w1, #20
    bl      ip_checksum
    lsr     w1, w0, #8
    strb    w0, [x23, #(14 + 10)]
    strb    w1, [x23, #(14 + 11)]

    /* UDP header at offset 34. sport = 68, dport = 67. */
    strb    wzr, [x23, #(14 + 20)]
    mov     w0, #68
    strb    w0, [x23, #(14 + 21)]
    strb    wzr, [x23, #(14 + 22)]
    mov     w0, #67
    strb    w0, [x23, #(14 + 23)]

    /* UDP length = 8 + payload_len (BE). */
    add     w0, w24, #8
    lsr     w1, w0, #8
    strb    w1, [x23, #(14 + 24)]
    strb    w0, [x23, #(14 + 25)]

    /* UDP checksum = 0. */
    strb    wzr, [x23, #(14 + 26)]
    strb    wzr, [x23, #(14 + 27)]

    ldr     x24, [sp, #24]
    ldr     x23, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* ===========================================================================
 * dhcp_dispatch — UDP-port-68 frame handler.
 *
 *   x0 = frame buffer (Eth + IP + UDP + DHCP body)
 *   w1 = frame length
 *
 * Returns:
 *   w0 = 0 always — DHCP responses don't generate immediate replies.
 *        The FSA action handlers (h_record_offer_send_request,
 *        h_commit_lease_arm_timers, etc.) emit any outbound packets
 *        asynchronously when the corresponding event fires.
 *
 * Pipeline:
 *   1. Confirm frame is long enough to contain Eth+IP+UDP headers.
 *   2. Compute payload pointer = frame + 42, payload length = frame_len - 42.
 *   3. Read ctx.XID as the expected transaction id.
 *   4. dhcp_parse_inbound(payload, len, expected_xid) → msg_type.
 *   5. Switch msg_type:
 *      - DHCP_MSG_OFFER → fire E_RX_OFFER_VALID
 *      - DHCP_MSG_ACK   → fire E_RX_ACK_VALID
 *      - DHCP_MSG_NAK   → fire E_RX_NAK_VALID
 *      - 0 (drop)       → no event
 *
 * The FSA's transition table decides what to do with each event
 * based on current state — invalid combinations (e.g., RX_ACK in
 * INIT) are NONE/NONE and silently no-op.
 * =========================================================================== */
.equ DHCP_FRAME_PAYLOAD_OFF, (14 + 20 + 8)   /* 42: ETH+IP+UDP */

dhcp_dispatch:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x19, [sp, #16]

    /* Length sanity. */
    cmp     w1, #DHCP_FRAME_PAYLOAD_OFF
    b.lt    .Ldd_done

    /* Read expected_xid from ctx. */
    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     w2, [x19, #DHCPC_XID]

    /* Parse: x0=payload, w1=payload_len, w2=expected_xid */
    add     x0, x0, #DHCP_FRAME_PAYLOAD_OFF
    sub     w1, w1, #DHCP_FRAME_PAYLOAD_OFF
    bl      dhcp_parse_inbound

    /* w0 = msg_type or 0. Map to FSA event. */
    cmp     w0, #DHCP_MSG_OFFER
    b.eq    .Ldd_offer
    cmp     w0, #DHCP_MSG_ACK
    b.eq    .Ldd_ack
    cmp     w0, #DHCP_MSG_NAK
    b.eq    .Ldd_nak
    /* Drop (msg_type = 0 or anything else). */
    b       .Ldd_done

.Ldd_offer:
    mov     w0, #E_RX_OFFER_VALID
    bl      dhcp_fsa_step
    b       .Ldd_done
.Ldd_ack:
    mov     w0, #E_RX_ACK_VALID
    bl      dhcp_fsa_step
    b       .Ldd_done
.Ldd_nak:
    mov     w0, #E_RX_NAK_VALID
    bl      dhcp_fsa_step

.Ldd_done:
    mov     w0, #0
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
