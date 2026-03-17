/*
 * test_icmp.S — Tests for ICMP echo reply handler
 *
 * Tests:
 *   1. test_icmp_echo_reply — Valid echo request → reply built in-place
 *   2. test_icmp_not_echo   — ICMP type=3 (dest unreachable) → returns 0
 *   3. test_icmp_short      — frame_len implies ICMP length < 8 → returns 0
 */

.include "net.inc"

.global test_icmp_echo_reply
.global test_icmp_not_echo
.global test_icmp_short

.section .text

/* ========================================================================
 * test_icmp_echo_reply — Full validation of in-place reply
 * ======================================================================== */
test_icmp_echo_reply:
    stp     x29, x30, [sp, #-16]!

    /* Copy 42-byte template to mutable buffer */
    ldr     x0, =icmp_echo_template
    ldr     x1, =icmp_echo_buf
    ldp     x2, x3, [x0]           /* 16 bytes */
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]      /* 16 bytes */
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]          /* 8 bytes */
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]          /* 2 bytes */
    strh    w2, [x1, #40]

    /* Call icmp_handle(buf, 42) */
    ldr     x0, =icmp_echo_buf
    mov     w1, #42
    bl      icmp_handle

    /* Should return 42 */
    cmp     w0, #42
    b.ne    .Lfail_icmp_echo

    /* Check ETH dst == original src (sender MAC: AA:BB:CC:DD:EE:FF) */
    ldr     x0, =icmp_echo_buf
    add     x0, x0, #ETH_DST
    ldr     x1, =icmp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_icmp_echo

    /* Check ETH src == our MAC (02:00:00:00:00:01) */
    ldr     x0, =icmp_echo_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_icmp_echo

    /* Check IP src == our IP (0A 00 02 0F) */
    ldr     x0, =icmp_echo_buf
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_SRC)]
    ldr     x2, =net_our_ip
    ldr     w2, [x2]
    cmp     w1, w2
    b.ne    .Lfail_icmp_echo

    /* Check IP dst == sender IP (0A 00 02 02) */
    ldr     x0, =icmp_echo_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST)]
    cmp     w1, #0x0A
    b.ne    .Lfail_icmp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 1)]
    cbnz    w1, .Lfail_icmp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 2)]
    cmp     w1, #0x02
    b.ne    .Lfail_icmp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 3)]
    cmp     w1, #0x02
    b.ne    .Lfail_icmp_echo

    /* Check TTL == 64 */
    ldr     x0, =icmp_echo_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_TTL)]
    cmp     w1, #64
    b.ne    .Lfail_icmp_echo

    /* Check ICMP type == 0 (echo reply) */
    ldr     x0, =icmp_echo_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cbnz    w1, .Lfail_icmp_echo

    /* Verify ICMP checksum valid (ip_checksum returns 0) */
    ldr     x0, =icmp_echo_buf
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #8                  /* ICMP len = 42 - 14 - 20 */
    bl      ip_checksum
    cbnz    w0, .Lfail_icmp_echo

    /* Verify IP checksum valid (ip_checksum returns 0) */
    ldr     x0, =icmp_echo_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #20
    bl      ip_checksum
    cbnz    w0, .Lfail_icmp_echo

    ldr     x0, =name_icmp_echo
    bl      test_pass
    b       .Ldone_icmp_echo

.Lfail_icmp_echo:
    ldr     x0, =name_icmp_echo
    bl      test_fail

.Ldone_icmp_echo:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_not_echo — ICMP type=3 → returns 0 (rejected before writing)
 * ======================================================================== */
test_icmp_not_echo:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =icmp_not_echo_frame
    mov     w1, #42
    bl      icmp_handle

    cbnz    w0, .Lfail_icmp_not_echo

    ldr     x0, =name_icmp_not_echo
    bl      test_pass
    b       .Ldone_icmp_not_echo

.Lfail_icmp_not_echo:
    ldr     x0, =name_icmp_not_echo
    bl      test_fail

.Ldone_icmp_not_echo:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_short — frame_len=41 → ICMP length 7 < 8 → returns 0
 * ======================================================================== */
test_icmp_short:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =icmp_echo_template
    mov     w1, #41                 /* ICMP len = 41 - 14 - 20 = 7 < 8 */
    bl      icmp_handle

    cbnz    w0, .Lfail_icmp_short

    ldr     x0, =name_icmp_short
    bl      test_pass
    b       .Ldone_icmp_short

.Lfail_icmp_short:
    ldr     x0, =name_icmp_short
    bl      test_fail

.Ldone_icmp_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* Sender MAC for verification */
icmp_sender_mac:
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF

/*
 * 42-byte ICMP echo request: who has 10.0.2.15? From 10.0.2.2
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=001C id=1234 flags=0000
 *                ttl=40 proto=01 cksum=509D src=0A000202 dst=0A00020F
 * ICMP (8):      type=08 code=00 cksum=F7FD id=0001 seq=0001
 */
.balign 4
icmp_echo_template:
    /* Ethernet header (14 bytes) */
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    /* IP header (20 bytes) */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x1C                               /* totlen: 28 */
    .byte   0x12, 0x34                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x01                               /* ttl=64, proto=ICMP */
    .byte   0x50, 0x9D                               /* checksum */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    /* ICMP (8 bytes) */
    .byte   0x08, 0x00                               /* type=echo request, code=0 */
    .byte   0xF7, 0xFD                               /* checksum */
    .byte   0x00, 0x01                               /* id */
    .byte   0x00, 0x01                               /* seq */

/* ICMP frame with type=3 (dest unreachable) — rejected before writing */
.balign 4
icmp_not_echo_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x03, 0x00, 0x00, 0x00                   /* type=3, code=0 */
    .byte   0x00, 0x01, 0x00, 0x01

name_icmp_echo:       .asciz "icmp_echo_reply"
name_icmp_not_echo:   .asciz "icmp_not_echo"
name_icmp_short:      .asciz "icmp_short"

.section .data
/* Mutable buffer for in-place reply test */
.balign 4
icmp_echo_buf:
    .space  42
