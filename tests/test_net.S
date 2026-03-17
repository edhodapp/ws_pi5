/*
 * test_net.S — Tests for net_recv_one dispatch
 *
 * Tests:
 *   1. test_net_recv_arp     — ARP request for us → returns 42
 *   2. test_net_recv_icmp    — ICMP echo request for us → returns 42
 *   3. test_net_recv_unknown — EtherType=0x86DD (IPv6) → returns 0
 *   4. test_net_recv_short   — 13-byte frame → returns 0
 */

.include "net.inc"

.global test_net_recv_arp
.global test_net_recv_icmp
.global test_net_recv_unknown
.global test_net_recv_short

.section .text

/* ========================================================================
 * test_net_recv_arp — ARP request dispatched correctly
 * ======================================================================== */
test_net_recv_arp:
    stp     x29, x30, [sp, #-16]!

    /* Copy 42-byte ARP template to mutable buffer */
    ldr     x0, =net_arp_template
    ldr     x1, =net_arp_buf
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    /* net_recv_one(buf, 42) */
    ldr     x0, =net_arp_buf
    mov     w1, #42
    bl      net_recv_one

    cmp     w0, #42
    b.ne    .Lfail_net_arp

    ldr     x0, =name_net_arp
    bl      test_pass
    b       .Ldone_net_arp

.Lfail_net_arp:
    ldr     x0, =name_net_arp
    bl      test_fail

.Ldone_net_arp:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_net_recv_icmp — ICMP echo request dispatched correctly
 * ======================================================================== */
test_net_recv_icmp:
    stp     x29, x30, [sp, #-16]!

    /* Copy 42-byte ICMP template to mutable buffer */
    ldr     x0, =net_icmp_template
    ldr     x1, =net_icmp_buf
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    /* net_recv_one(buf, 42) */
    ldr     x0, =net_icmp_buf
    mov     w1, #42
    bl      net_recv_one

    cmp     w0, #42
    b.ne    .Lfail_net_icmp

    ldr     x0, =name_net_icmp
    bl      test_pass
    b       .Ldone_net_icmp

.Lfail_net_icmp:
    ldr     x0, =name_net_icmp
    bl      test_fail

.Ldone_net_icmp:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_net_recv_unknown — IPv6 EtherType → returns 0
 * ======================================================================== */
test_net_recv_unknown:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =net_ipv6_frame
    mov     w1, #ETH_HDR_LEN
    bl      net_recv_one

    cbnz    w0, .Lfail_net_unknown

    ldr     x0, =name_net_unknown
    bl      test_pass
    b       .Ldone_net_unknown

.Lfail_net_unknown:
    ldr     x0, =name_net_unknown
    bl      test_fail

.Ldone_net_unknown:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_net_recv_short — 13-byte frame → returns 0
 * ======================================================================== */
test_net_recv_short:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =net_short_frame
    mov     w1, #13
    bl      net_recv_one

    cbnz    w0, .Lfail_net_short

    ldr     x0, =name_net_short
    bl      test_pass
    b       .Ldone_net_short

.Lfail_net_short:
    ldr     x0, =name_net_short
    bl      test_fail

.Ldone_net_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/*
 * 42-byte ARP request: who has 10.0.2.15? Tell 10.0.2.2
 * Sender MAC: AA:BB:CC:DD:EE:FF
 */
.balign 4
net_arp_template:
    /* Ethernet header (14 bytes) */
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF     /* dst: broadcast */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x06                               /* EtherType: ARP */
    /* ARP payload (28 bytes) */
    .byte   0x00, 0x01                               /* HTYPE: Ethernet */
    .byte   0x08, 0x00                               /* PTYPE: IPv4 */
    .byte   0x06                                     /* HLEN: 6 */
    .byte   0x04                                     /* PLEN: 4 */
    .byte   0x00, 0x01                               /* OPER: request */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* SHA: sender MAC */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* SPA: 10.0.2.2 */
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00     /* THA: unknown */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* TPA: 10.0.2.15 */

/*
 * 42-byte ICMP echo request for 10.0.2.15 from 10.0.2.2
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=001C id=1234 flags=0000
 *                ttl=40 proto=01 cksum=509D src=0A000202 dst=0A00020F
 * ICMP (8):      type=08 code=00 cksum=F7FD id=0001 seq=0001
 */
.balign 4
net_icmp_template:
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

/* 14-byte frame with IPv6 EtherType — rejected before any write */
.balign 4
net_ipv6_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src */
    .byte   0x86, 0xDD                               /* EtherType: IPv6 */

/* 13-byte short frame — too short for Ethernet header */
.balign 4
net_short_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08

name_net_arp:       .asciz "net_recv_arp"
name_net_icmp:      .asciz "net_recv_icmp"
name_net_unknown:   .asciz "net_recv_unknown"
name_net_short:     .asciz "net_recv_short"

.section .data
/* Mutable buffers for in-place handler tests */
.balign 4
net_arp_buf:
    .space  42

.balign 4
net_icmp_buf:
    .space  42
