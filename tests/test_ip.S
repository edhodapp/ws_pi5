/*
 * test_ip.S — Tests for IP checksum and IPv4 handler
 *
 * Checksum tests:
 *   1. test_ip_checksum         — Round-trip: compute, fill, verify returns 0
 *   2. test_ip_checksum_carry   — 3-byte input forces carry folding + odd byte
 *
 * ip_handle tests:
 *   3. test_ip_handle_icmp      — Valid ICMP echo request → returns 42
 *   4. test_ip_handle_short     — 33-byte frame → returns 0
 *   5. test_ip_handle_bad_cksum — Corrupted IP checksum → returns 0
 *   6. test_ip_handle_not_ours  — Dest IP = 10.0.2.99 → returns 0
 *   7. test_ip_handle_unknown_proto — Protocol = 255 → returns 0
 */

.include "net.inc"

.global test_ip_checksum
.global test_ip_checksum_carry
.global test_ip_handle_icmp
.global test_ip_handle_short
.global test_ip_handle_bad_cksum
.global test_ip_handle_not_ours
.global test_ip_handle_unknown_proto
.global test_ip_handle_bad_ver
.global test_ip_handle_totlen_short
.global test_ip_handle_totlen_overrun

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
 * test_ip_handle_icmp — Valid ICMP echo request → returns 42
 * ======================================================================== */
test_ip_handle_icmp:
    stp     x29, x30, [sp, #-16]!

    /* Copy 42-byte template to mutable buffer */
    ldr     x0, =ip_icmp_template
    ldr     x1, =ip_handle_buf
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    ldr     x0, =ip_handle_buf
    mov     w1, #42
    bl      ip_handle

    cmp     w0, #42
    b.ne    .Lfail_ip_icmp

    ldr     x0, =name_ip_icmp
    bl      test_pass
    b       .Ldone_ip_icmp

.Lfail_ip_icmp:
    ldr     x0, =name_ip_icmp
    bl      test_fail

.Ldone_ip_icmp:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_short — 33-byte frame → returns 0
 * ======================================================================== */
test_ip_handle_short:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_icmp_template
    mov     w1, #33
    bl      ip_handle

    cbnz    w0, .Lfail_ip_short

    ldr     x0, =name_ip_short
    bl      test_pass
    b       .Ldone_ip_short

.Lfail_ip_short:
    ldr     x0, =name_ip_short
    bl      test_fail

.Ldone_ip_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_bad_cksum — Corrupted IP checksum → returns 0
 * ======================================================================== */
test_ip_handle_bad_cksum:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_bad_cksum_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_bad_cksum

    ldr     x0, =name_ip_bad_cksum
    bl      test_pass
    b       .Ldone_ip_bad_cksum

.Lfail_ip_bad_cksum:
    ldr     x0, =name_ip_bad_cksum
    bl      test_fail

.Ldone_ip_bad_cksum:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_not_ours — Dest IP = 10.0.2.99 → returns 0
 * ======================================================================== */
test_ip_handle_not_ours:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_not_ours_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_not_ours

    ldr     x0, =name_ip_not_ours
    bl      test_pass
    b       .Ldone_ip_not_ours

.Lfail_ip_not_ours:
    ldr     x0, =name_ip_not_ours
    bl      test_fail

.Ldone_ip_not_ours:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_unknown_proto — Protocol = UDP (17) → returns 0
 * ======================================================================== */
test_ip_handle_unknown_proto:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_unknown_proto_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_unknown

    ldr     x0, =name_ip_unknown
    bl      test_pass
    b       .Ldone_ip_unknown

.Lfail_ip_unknown:
    ldr     x0, =name_ip_unknown
    bl      test_fail

.Ldone_ip_unknown:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_bad_ver — VER_IHL=0x46 (options present) → returns 0
 * ======================================================================== */
test_ip_handle_bad_ver:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_bad_ver_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_bad_ver

    ldr     x0, =name_ip_bad_ver
    bl      test_pass
    b       .Ldone_ip_bad_ver

.Lfail_ip_bad_ver:
    ldr     x0, =name_ip_bad_ver
    bl      test_fail

.Ldone_ip_bad_ver:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_totlen_short — TotalLength=19 (< 20 minimum) → returns 0
 * ======================================================================== */
test_ip_handle_totlen_short:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_totlen_short_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_totlen_short

    ldr     x0, =name_ip_totlen_short
    bl      test_pass
    b       .Ldone_ip_totlen_short

.Lfail_ip_totlen_short:
    ldr     x0, =name_ip_totlen_short
    bl      test_fail

.Ldone_ip_totlen_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_totlen_overrun — TotalLength=29, frame=42 → 14+29=43>42 → 0
 * ======================================================================== */
test_ip_handle_totlen_overrun:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_totlen_overrun_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_totlen_overrun

    ldr     x0, =name_ip_totlen_overrun
    bl      test_pass
    b       .Ldone_ip_totlen_overrun

.Lfail_ip_totlen_overrun:
    ldr     x0, =name_ip_totlen_overrun
    bl      test_fail

.Ldone_ip_totlen_overrun:
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
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x00, 0x00     /* checksum=0 */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F

/*
 * 42-byte ICMP echo request template (valid, for 10.0.2.15)
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=001C id=1234 flags=0000
 *                ttl=40 proto=01 cksum=509D src=0A000202 dst=0A00020F
 * ICMP (8):      type=08 code=00 cksum=F7FD id=0001 seq=0001
 */
.balign 4
ip_icmp_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D                   /* ttl=64, proto=ICMP, cksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD                   /* ICMP echo request */
    .byte   0x00, 0x01, 0x00, 0x01

/* Same frame but with corrupted IP checksum (0x519D instead of 0x509D) */
.balign 4
ip_bad_cksum_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x51, 0x9D                   /* bad checksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* Valid frame but dest IP = 10.0.2.99 (cksum recomputed: 0x5049) */
.balign 4
ip_not_ours_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x49                   /* cksum for dst=10.0.2.99 */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x63                   /* dst: 10.0.2.99 */
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* Valid IP header but protocol = 255 (truly unknown), cksum recomputed */
.balign 4
ip_unknown_proto_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0xFF, 0x4F, 0x9F                   /* proto=255, cksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x00, 0x00, 0x00, 0x00                   /* dummy payload */
    .byte   0x00, 0x00, 0x00, 0x00

/* VER_IHL=0x46 — rejected at check #2 before checksum, no valid cksum needed */
.balign 4
ip_bad_ver_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x46, 0x00, 0x00, 0x1C                   /* ver/ihl=0x46 */
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* TotalLength=19 (0x0013) — rejected at check #3, no valid cksum needed */
.balign 4
ip_totlen_short_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x13                   /* totlen=19 */
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* TotalLength=29 (0x001D) in 42-byte frame: 14+29=43>42 — rejected at check #4 */
.balign 4
ip_totlen_overrun_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1D                   /* totlen=29 */
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

name_ip_cksum:      .asciz "ip_checksum"
name_ip_carry:      .asciz "ip_checksum_carry"
name_ip_icmp:       .asciz "ip_handle_icmp"
name_ip_short:      .asciz "ip_handle_short"
name_ip_bad_cksum:  .asciz "ip_handle_bad_cksum"
name_ip_not_ours:   .asciz "ip_handle_not_ours"
name_ip_unknown:    .asciz "ip_handle_unknown_proto"
name_ip_bad_ver:    .asciz "ip_handle_bad_ver"
name_ip_totlen_short:   .asciz "ip_handle_totlen_short"
name_ip_totlen_overrun: .asciz "ip_handle_totlen_overrun"

.section .data
.balign 4
ip_cksum_buf:
    .space  20

.balign 4
ip_handle_buf:
    .space  42
