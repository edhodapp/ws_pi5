/*
 * test_mdns.S — smoke tests for lib/mdns.S (I15, first commit).
 *
 * Three cases:
 *   1. test_mdns_a_query_match     — A query for "wspi5.local" (or
 *                                     whatever net_hostname holds)
 *                                     → returns response, header
 *                                     flags = 0x8400, ancount = 1.
 *   2. test_mdns_a_query_no_match  — A query for a different name
 *                                     → returns 0.
 *   3. test_mdns_aaaa_query_drop   — AAAA query (type 28) → returns
 *                                     0 even for our hostname (we
 *                                     are IPv4-only per D008).
 *
 * Each test sets up net_hostname / net_hostname_len / net_our_ip
 * to known values, calls mdns_build_response, asserts on the
 * returned length and key bytes of the response. Saves and
 * restores those globals so downstream tests stay green.
 */

.include "net.inc"

.global test_mdns_a_query_match
.global test_mdns_a_query_no_match
.global test_mdns_aaaa_query_drop

.section .text

/* Set net_hostname to "qemu" / len 4 / net_our_ip to 10.0.2.15.
 * Caller must have already saved these via _mdns_test_save. */
_mdns_test_set_state:
    adrp    x0, net_hostname
    add     x0, x0, :lo12:net_hostname
    /* Zero 64 bytes via two stp xzr,xzr per 16. */
    stp     xzr, xzr, [x0, #0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]
    stp     xzr, xzr, [x0, #48]
    /* Write 'q','e','m','u'. */
    mov     w1, #'q'
    strb    w1, [x0, #0]
    mov     w1, #'e'
    strb    w1, [x0, #1]
    mov     w1, #'m'
    strb    w1, [x0, #2]
    mov     w1, #'u'
    strb    w1, [x0, #3]
    /* len = 4. */
    adrp    x0, net_hostname_len
    add     x0, x0, :lo12:net_hostname_len
    mov     w1, #4
    str     w1, [x0]
    /* IP = 10.0.2.15 = 0x0F02000A on little-endian-stored wire bytes
     * (.byte 0x0A, 0x00, 0x02, 0x0F per net_cfg.S). Already QEMU
     * default; this is a no-op write but keeps the test self-
     * contained. */
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

/* Save net_hostname / len / our_ip into _mdns_save_buf at known
 * offsets. Restore is the symmetric copy. */
_mdns_test_save:
    adrp    x10, _mdns_save_buf
    add     x10, x10, :lo12:_mdns_save_buf
    adrp    x11, net_hostname
    add     x11, x11, :lo12:net_hostname
    /* 64 bytes hostname. */
    ldp     x9, x12, [x11, #0];   stp x9, x12, [x10, #0]
    ldp     x9, x12, [x11, #16];  stp x9, x12, [x10, #16]
    ldp     x9, x12, [x11, #32];  stp x9, x12, [x10, #32]
    ldp     x9, x12, [x11, #48];  stp x9, x12, [x10, #48]
    /* 4 bytes len. */
    adrp    x11, net_hostname_len
    add     x11, x11, :lo12:net_hostname_len
    ldr     w9, [x11];  str w9, [x10, #64]
    /* 4 bytes IP. */
    adrp    x11, net_our_ip
    add     x11, x11, :lo12:net_our_ip
    ldr     w9, [x11];  str w9, [x10, #68]
    ret

_mdns_test_restore:
    adrp    x10, _mdns_save_buf
    add     x10, x10, :lo12:_mdns_save_buf
    adrp    x11, net_hostname
    add     x11, x11, :lo12:net_hostname
    ldp     x9, x12, [x10, #0];   stp x9, x12, [x11, #0]
    ldp     x9, x12, [x10, #16];  stp x9, x12, [x11, #16]
    ldp     x9, x12, [x10, #32];  stp x9, x12, [x11, #32]
    ldp     x9, x12, [x10, #48];  stp x9, x12, [x11, #48]
    adrp    x11, net_hostname_len
    add     x11, x11, :lo12:net_hostname_len
    ldr     w9, [x10, #64]; str w9, [x11]
    adrp    x11, net_our_ip
    add     x11, x11, :lo12:net_our_ip
    ldr     w9, [x10, #68]; str w9, [x11]
    ret


/* ========================================================================
 * test_mdns_a_query_match — A query for "qemu.local" matches and
 * returns a well-formed response.
 * ======================================================================== */
test_mdns_a_query_match:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_q_qemu_a
    mov     w1, #_mdns_q_qemu_a_len
    ldr     x2, =_mdns_resp_buf
    bl      mdns_build_response

    /* Expect non-zero response length. */
    cbz     w0, .Ltma_fail
    /* Expect length to be 12 (hdr) + question + 12 + 4 (answer)
     * = 12 + 16 + 16 = 44. */
    cmp     w0, #44
    b.ne    .Ltma_fail

    /* Header byte 2 (flags high) = 0x84. */
    ldr     x0, =_mdns_resp_buf
    ldrb    w1, [x0, #2]
    cmp     w1, #0x84
    b.ne    .Ltma_fail
    /* ANCOUNT (bytes 6..7) = 0x00 0x01. */
    ldrb    w1, [x0, #6]
    cbnz    w1, .Ltma_fail
    ldrb    w1, [x0, #7]
    cmp     w1, #1
    b.ne    .Ltma_fail
    /* Last 4 bytes = our IP (10, 0, 2, 15). */
    ldrb    w1, [x0, #40]
    cmp     w1, #10
    b.ne    .Ltma_fail
    ldrb    w1, [x0, #41]
    cbnz    w1, .Ltma_fail
    ldrb    w1, [x0, #42]
    cmp     w1, #2
    b.ne    .Ltma_fail
    ldrb    w1, [x0, #43]
    cmp     w1, #15
    b.ne    .Ltma_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_match
    bl      test_pass
    b       .Ltma_done
.Ltma_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_match
    bl      test_fail
.Ltma_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_a_query_no_match — A query for "other.local" doesn't
 * match our hostname → returns 0.
 * ======================================================================== */
test_mdns_a_query_no_match:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_q_other_a
    mov     w1, #_mdns_q_other_a_len
    ldr     x2, =_mdns_resp_buf
    bl      mdns_build_response

    cbnz    w0, .Ltmn_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_no_match
    bl      test_pass
    b       .Ltmn_done
.Ltmn_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_no_match
    bl      test_fail
.Ltmn_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_aaaa_query_drop — AAAA (type 28) query for our
 * hostname is rejected → returns 0 (we are IPv4-only per D008).
 * ======================================================================== */
test_mdns_aaaa_query_drop:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_q_qemu_aaaa
    mov     w1, #_mdns_q_qemu_aaaa_len
    ldr     x2, =_mdns_resp_buf
    bl      mdns_build_response

    cbnz    w0, .Ltad_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_aaaa_drop
    bl      test_pass
    b       .Ltad_done
.Ltad_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_aaaa_drop
    bl      test_fail
.Ltad_done:
    ldp     x29, x30, [sp], #16
    ret


.section .rodata

_mdns_name_match:
    .asciz "mdns_a_query_match"
_mdns_name_no_match:
    .asciz "mdns_a_query_no_match"
_mdns_name_aaaa_drop:
    .asciz "mdns_aaaa_query_drop"

/* Synthetic A query for "qemu.local". DNS header (12 bytes) +
 * question.
 *   id=0x1234, flags=0x0000, qd=1, an=ns=ar=0
 *   QNAME = [4]"qemu" [5]"local" [0] = 12 bytes
 *   QTYPE = 0x0001 (A)
 *   QCLASS = 0x0001 (IN)
 * Total = 12 + 12 + 4 = 28 bytes. */
.balign 4
_mdns_q_qemu_a:
    /* Header */
    .byte 0x12, 0x34       /* id */
    .byte 0x00, 0x00       /* flags */
    .byte 0x00, 0x01       /* qd */
    .byte 0x00, 0x00       /* an */
    .byte 0x00, 0x00       /* ns */
    .byte 0x00, 0x00       /* ar */
    /* QNAME */
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    /* QTYPE = A */
    .byte 0x00, 0x01
    /* QCLASS = IN */
    .byte 0x00, 0x01
.equ _mdns_q_qemu_a_len, (. - _mdns_q_qemu_a)

/* Synthetic A query for "other.local" — same shape, different name. */
.balign 4
_mdns_q_other_a:
    .byte 0x12, 0x34
    .byte 0x00, 0x00
    .byte 0x00, 0x01
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 5
    .ascii "other"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01
    .byte 0x00, 0x01
.equ _mdns_q_other_a_len, (. - _mdns_q_other_a)

/* AAAA query for "qemu.local" — type 28 (0x001C). */
.balign 4
_mdns_q_qemu_aaaa:
    .byte 0x12, 0x34
    .byte 0x00, 0x00
    .byte 0x00, 0x01
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x1C       /* QTYPE = AAAA */
    .byte 0x00, 0x01
.equ _mdns_q_qemu_aaaa_len, (. - _mdns_q_qemu_aaaa)


.section .bss
.balign 8
_mdns_resp_buf:
    .space 256

.balign 8
_mdns_save_buf:
    .space 80                   /* 64 hostname + 4 len + 4 ip + 8 pad */
