/*
 * test_ip.S — Tests for IP checksum and IPv4 handler
 *
 * Commit 1 tests:
 *   1. test_ip_checksum       — Round-trip: compute, fill, verify returns 0
 *   2. test_ip_checksum_carry — 3-byte input forces carry folding + odd byte
 */

.include "net.inc"

.global test_ip_checksum
.global test_ip_checksum_carry

.section .text

/* ========================================================================
 * test_ip_checksum — Compute checksum on zeroed header, store, verify
 * ======================================================================== */
test_ip_checksum:
    stp     x29, x30, [sp, #-16]!

    /* Copy 20-byte IP header template to mutable buffer */
    ldr     x0, =ip_cksum_template
    ldr     x1, =ip_cksum_buf
    ldp     x2, x3, [x0]           /* 16 bytes */
    stp     x2, x3, [x1]
    ldr     w2, [x0, #16]          /* 4 bytes */
    str     w2, [x1, #16]

    /* Compute checksum (checksum field is zero in template) */
    ldr     x0, =ip_cksum_buf
    mov     w1, #20
    bl      ip_checksum

    /* Should be non-zero */
    cbz     w0, .Lfail_ip_cksum

    /* Store computed checksum into header */
    ldr     x1, =ip_cksum_buf
    strh    w0, [x1, #IP_CHECKSUM]

    /* Verify: checksum of complete header should be 0 */
    ldr     x0, =ip_cksum_buf
    mov     w1, #20
    bl      ip_checksum

    cbnz    w0, .Lfail_ip_cksum

    ldr     x0, =name_ip_cksum
    bl      test_pass
    b       .Ldone_ip_cksum

.Lfail_ip_cksum:
    ldr     x0, =name_ip_cksum
    bl      test_fail

.Ldone_ip_cksum:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_checksum_carry — {0xFF, 0xFF, 0x03} forces carry + odd byte
 * ======================================================================== */
test_ip_checksum_carry:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =carry_test_data
    mov     w1, #3
    bl      ip_checksum

    /* Expected: 0xFFFC */
    mov     w1, #0xFFFC
    cmp     w0, w1
    b.ne    .Lfail_ip_carry

    ldr     x0, =name_ip_carry
    bl      test_pass
    b       .Ldone_ip_carry

.Lfail_ip_carry:
    ldr     x0, =name_ip_carry
    bl      test_fail

.Ldone_ip_carry:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* 3-byte input that forces carry folding and odd-byte handling */
.balign 4
carry_test_data:
    .byte   0xFF, 0xFF, 0x03

/*
 * 20-byte IP header with checksum field zeroed.
 * src=10.0.2.2, dst=10.0.2.15, proto=ICMP, TTL=64, totlen=28
 */
.balign 4
ip_cksum_template:
    .byte   0x45, 0x00, 0x00, 0x1C     /* ver/ihl, dscp, totlen */
    .byte   0x12, 0x34, 0x00, 0x00     /* id, flags/frag */
    .byte   0x40, 0x01, 0x00, 0x00     /* ttl=64, proto=ICMP, checksum=0 */
    .byte   0x0A, 0x00, 0x02, 0x02     /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F     /* dst: 10.0.2.15 */

name_ip_cksum:      .asciz "ip_checksum"
name_ip_carry:      .asciz "ip_checksum_carry"

.section .data
.balign 4
ip_cksum_buf:
    .space  20
