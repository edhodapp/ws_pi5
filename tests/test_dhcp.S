/*
 * test_dhcp.S — wire-format tests for lib/dhcp.S builders (I16-3).
 *
 * Three builders, each producing a DHCP message body that the
 * caller will wrap in Eth+IP+UDP at send time:
 *
 *   dhcp_build_discover(x0=buf, w1=xid)
 *     → w0 = length. BOOTREQUEST, opcode 53=DISCOVER, parameter
 *       request list with subnet/router/lease, no requested-ip,
 *       no server-id.
 *
 *   dhcp_build_request_selecting(x0=buf, w1=xid,
 *                                w2=server_id, w3=requested_ip)
 *     → w0 = length. BOOTREQUEST, opcode 53=REQUEST, includes
 *       option 54 (server-id from OFFER) AND option 50 (requested
 *       IP from OFFER) per RFC 2131 §4.4.1.
 *
 *   dhcp_build_request_renewing(x0=buf, w1=xid, w2=ciaddr)
 *     → w0 = length. BOOTREQUEST, opcode 53=REQUEST, ciaddr
 *       set to our currently-bound IP, NO option 50, NO option 54
 *       per RFC 2131 §4.3.6.
 *
 * Tests don't assert byte-perfectly on the whole packet — they pin
 * the field offsets that change across builders so any silent
 * drift in the wire format trips a failure.
 */

.include "dhcp.inc"
.include "net.inc"

.global test_dhcp_build_discover_header
.global test_dhcp_build_discover_options
.global test_dhcp_build_request_selecting_has_50_and_54
.global test_dhcp_build_request_renewing_uses_ciaddr

.section .text

/* All three tests share a setup that sets net_our_mac to a known
 * value (02:00:00:00:00:01 = QEMU default — same as the existing
 * mDNS tests). net_our_ip is also set so the renewing test can
 * assert ciaddr matches. We don't bother saving/restoring net_*
 * because the QEMU defaults are what the tests would restore to. */
_dhcp_test_set_state:
    adrp    x0, net_our_mac
    add     x0, x0, :lo12:net_our_mac
    mov     w1, #0x02
    strb    w1, [x0, #0]
    strb    wzr, [x0, #1]
    strb    wzr, [x0, #2]
    strb    wzr, [x0, #3]
    strb    wzr, [x0, #4]
    mov     w1, #0x01
    strb    w1, [x0, #5]
    /* net_our_ip = 10.0.2.15 */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    mov     w1, #0x0A
    strb    w1, [x0, #0]
    strb    wzr, [x0, #1]
    mov     w1, #0x02
    strb    w1, [x0, #2]
    mov     w1, #0x0F
    strb    w1, [x0, #3]
    ret


/* ========================================================================
 * test_dhcp_build_discover_header — BOOTP header fields are correct.
 * Asserts: op=1, htype=1, hlen=6, hops=0, xid bytes echoed BE,
 * ciaddr/yiaddr/siaddr/giaddr all zero, chaddr[0..5] = our MAC,
 * magic cookie at offset 236.
 * ======================================================================== */
test_dhcp_build_discover_header:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_set_state

    /* xid = 0xDEADBEEF, but DHCP wire is BE so on the wire we'll
     * see DE AD BE EF starting at BOOTP_XID. */
    ldr     x0, =_dhcp_test_buf
    movz    w1, #0xBEEF
    movk    w1, #0xDEAD, lsl #16
    bl      dhcp_build_discover
    cbz     w0, .Lhdr_fail              /* must produce a packet */

    ldr     x0, =_dhcp_test_buf

    /* op = BOOTREQUEST. */
    ldrb    w1, [x0, #BOOTP_OP]
    cmp     w1, #DHCP_OP_BOOTREQUEST
    b.ne    .Lhdr_fail

    /* htype = Ethernet. */
    ldrb    w1, [x0, #BOOTP_HTYPE]
    cmp     w1, #DHCP_HTYPE_ETHERNET
    b.ne    .Lhdr_fail

    /* hlen = 6. */
    ldrb    w1, [x0, #BOOTP_HLEN]
    cmp     w1, #DHCP_HLEN_ETHERNET
    b.ne    .Lhdr_fail

    /* hops = 0. */
    ldrb    w1, [x0, #BOOTP_HOPS]
    cbnz    w1, .Lhdr_fail

    /* xid bytes (BE). */
    ldrb    w1, [x0, #(BOOTP_XID + 0)]
    cmp     w1, #0xDE
    b.ne    .Lhdr_fail
    ldrb    w1, [x0, #(BOOTP_XID + 1)]
    cmp     w1, #0xAD
    b.ne    .Lhdr_fail
    ldrb    w1, [x0, #(BOOTP_XID + 2)]
    cmp     w1, #0xBE
    b.ne    .Lhdr_fail
    ldrb    w1, [x0, #(BOOTP_XID + 3)]
    cmp     w1, #0xEF
    b.ne    .Lhdr_fail

    /* ciaddr = 0. */
    ldr     w1, [x0, #BOOTP_CIADDR]
    cbnz    w1, .Lhdr_fail
    /* yiaddr = 0. */
    ldr     w1, [x0, #BOOTP_YIADDR]
    cbnz    w1, .Lhdr_fail
    /* siaddr = 0. */
    ldr     w1, [x0, #BOOTP_SIADDR]
    cbnz    w1, .Lhdr_fail
    /* giaddr = 0. */
    ldr     w1, [x0, #BOOTP_GIADDR]
    cbnz    w1, .Lhdr_fail

    /* chaddr[0..5] = our MAC. */
    ldrb    w1, [x0, #(BOOTP_CHADDR + 0)]
    cmp     w1, #0x02
    b.ne    .Lhdr_fail
    ldrb    w1, [x0, #(BOOTP_CHADDR + 5)]
    cmp     w1, #0x01
    b.ne    .Lhdr_fail

    /* Magic cookie. */
    ldrb    w1, [x0, #(BOOTP_MAGIC + 0)]
    cmp     w1, #DHCP_MAGIC_BYTE0
    b.ne    .Lhdr_fail
    ldrb    w1, [x0, #(BOOTP_MAGIC + 3)]
    cmp     w1, #DHCP_MAGIC_BYTE3
    b.ne    .Lhdr_fail

    ldr     x0, =_dhcp_name_discover_header
    bl      test_pass
    b       .Lhdr_done
.Lhdr_fail:
    ldr     x0, =_dhcp_name_discover_header
    bl      test_fail
.Lhdr_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_build_discover_options — DISCOVER option block contains
 * Option 53 (msg-type=DISCOVER), Option 55 (parameter request list
 * with subnet/router/lease), and Option 255 (END). The exact
 * positions are linear so we walk by offset.
 * ======================================================================== */
test_dhcp_build_discover_options:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_set_state

    ldr     x0, =_dhcp_test_buf
    movz    w1, #0x0001
    bl      dhcp_build_discover
    cbz     w0, .Lopt_fail

    ldr     x0, =_dhcp_test_buf
    /* First option is at BOOTP_OPTIONS = 240. */
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 0)]
    cmp     w1, #DHCP_OPT_MSG_TYPE
    b.ne    .Lopt_fail
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 1)]
    cmp     w1, #1                              /* length */
    b.ne    .Lopt_fail
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 2)]
    cmp     w1, #DHCP_MSG_DISCOVER
    b.ne    .Lopt_fail

    /* Option 55 (parameter request list) at offset 243. */
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 3)]
    cmp     w1, #DHCP_OPT_PARAM_REQUEST
    b.ne    .Lopt_fail
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 4)]
    cmp     w1, #3                              /* 3 params */
    b.ne    .Lopt_fail
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 5)]
    cmp     w1, #DHCP_OPT_SUBNET_MASK
    b.ne    .Lopt_fail
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 6)]
    cmp     w1, #DHCP_OPT_ROUTER
    b.ne    .Lopt_fail
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 7)]
    cmp     w1, #DHCP_OPT_LEASE_TIME
    b.ne    .Lopt_fail

    /* END at offset 248. */
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 8)]
    cmp     w1, #DHCP_OPT_END
    b.ne    .Lopt_fail

    ldr     x0, =_dhcp_name_discover_options
    bl      test_pass
    b       .Lopt_done
.Lopt_fail:
    ldr     x0, =_dhcp_name_discover_options
    bl      test_fail
.Lopt_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_build_request_selecting_has_50_and_54 — REQUEST in
 * SELECTING state MUST include both server-id (54) and requested-ip
 * (50) per RFC 2131 §4.4.1.
 * ======================================================================== */
test_dhcp_build_request_selecting_has_50_and_54:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_set_state

    /* server_id = 0x0a000001 (10.0.0.1 wire), requested_ip = 0x0a000064 (10.0.0.100) */
    ldr     x0, =_dhcp_test_buf
    mov     w1, #0x0001
    movz    w2, #0x0001
    movk    w2, #0x0a00, lsl #16          /* 0x0a000001 */
    movz    w3, #0x0064
    movk    w3, #0x0a00, lsl #16          /* 0x0a000064 */
    bl      dhcp_build_request_selecting
    cbz     w0, .Lreq_fail
    /* Save returned length so we can scan options. */
    mov     w19, w0

    ldr     x0, =_dhcp_test_buf
    /* Option 53 = REQUEST. */
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 0)]
    cmp     w1, #DHCP_OPT_MSG_TYPE
    b.ne    .Lreq_fail
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 2)]
    cmp     w1, #DHCP_MSG_REQUEST
    b.ne    .Lreq_fail

    /* Walk options looking for 50 and 54. */
    mov     w20, #0                          /* found_50 */
    mov     w21, #0                          /* found_54 */
    mov     w2, #BOOTP_OPTIONS               /* cursor */
.Lreq_walk:
    cmp     w2, w19
    b.hs    .Lreq_walked
    ldrb    w3, [x0, x2]
    cmp     w3, #DHCP_OPT_END
    b.eq    .Lreq_walked
    cmp     w3, #DHCP_OPT_PAD
    b.eq    .Lreq_walk_pad
    cmp     w3, #DHCP_OPT_REQUESTED_IP
    b.ne    .Lreq_check_54
    mov     w20, #1
.Lreq_check_54:
    cmp     w3, #DHCP_OPT_SERVER_ID
    b.ne    .Lreq_skip
    mov     w21, #1
.Lreq_skip:
    /* len byte is at cursor+1; advance by 2 + len. */
    add     w2, w2, #1
    ldrb    w4, [x0, x2]
    add     w2, w2, #1
    add     w2, w2, w4
    b       .Lreq_walk
.Lreq_walk_pad:
    add     w2, w2, #1
    b       .Lreq_walk
.Lreq_walked:
    /* Both options must have been found. */
    cbz     w20, .Lreq_fail
    cbz     w21, .Lreq_fail

    ldr     x0, =_dhcp_name_request_selecting
    bl      test_pass
    b       .Lreq_done
.Lreq_fail:
    ldr     x0, =_dhcp_name_request_selecting
    bl      test_fail
.Lreq_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_build_request_renewing_uses_ciaddr — REQUEST in RENEWING
 * state MUST set ciaddr to the bound IP (RFC 2131 §4.3.6) and MUST
 * NOT include options 50 or 54.
 * ======================================================================== */
test_dhcp_build_request_renewing_uses_ciaddr:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_set_state

    ldr     x0, =_dhcp_test_buf
    mov     w1, #0x0001
    /* ciaddr = 10.0.2.15 (matches net_our_ip wire bytes). */
    adrp    x2, net_our_ip
    add     x2, x2, :lo12:net_our_ip
    ldr     w2, [x2]
    bl      dhcp_build_request_renewing
    cbz     w0, .Lren_fail
    mov     w19, w0

    ldr     x0, =_dhcp_test_buf
    /* ciaddr field = 10.0.2.15. */
    ldrb    w1, [x0, #(BOOTP_CIADDR + 0)]
    cmp     w1, #10
    b.ne    .Lren_fail
    ldrb    w1, [x0, #(BOOTP_CIADDR + 3)]
    cmp     w1, #15
    b.ne    .Lren_fail

    /* Option 53 = REQUEST. */
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 0)]
    cmp     w1, #DHCP_OPT_MSG_TYPE
    b.ne    .Lren_fail
    ldrb    w1, [x0, #(BOOTP_OPTIONS + 2)]
    cmp     w1, #DHCP_MSG_REQUEST
    b.ne    .Lren_fail

    /* Walk options confirming opt 50 and opt 54 are ABSENT. */
    mov     w2, #BOOTP_OPTIONS
.Lren_walk:
    cmp     w2, w19
    b.hs    .Lren_walked
    ldrb    w3, [x0, x2]
    cmp     w3, #DHCP_OPT_END
    b.eq    .Lren_walked
    cmp     w3, #DHCP_OPT_PAD
    b.eq    .Lren_walk_pad
    cmp     w3, #DHCP_OPT_REQUESTED_IP
    b.eq    .Lren_fail
    cmp     w3, #DHCP_OPT_SERVER_ID
    b.eq    .Lren_fail
    add     w2, w2, #1
    ldrb    w4, [x0, x2]
    add     w2, w2, #1
    add     w2, w2, w4
    b       .Lren_walk
.Lren_walk_pad:
    add     w2, w2, #1
    b       .Lren_walk
.Lren_walked:
    ldr     x0, =_dhcp_name_request_renewing
    bl      test_pass
    b       .Lren_done
.Lren_fail:
    ldr     x0, =_dhcp_name_request_renewing
    bl      test_fail
.Lren_done:
    ldp     x29, x30, [sp], #16
    ret


.section .rodata
_dhcp_name_discover_header:    .asciz "dhcp_build_discover_header"
_dhcp_name_discover_options:   .asciz "dhcp_build_discover_options"
_dhcp_name_request_selecting:  .asciz "dhcp_build_request_selecting"
_dhcp_name_request_renewing:   .asciz "dhcp_build_request_renewing"


.section .bss
.balign 8
_dhcp_test_buf:
    .space 512                          /* enough for any v1 builder */
