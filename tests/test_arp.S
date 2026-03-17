/*
 * test_arp.S — Tests for ARP handler
 *
 * Tests:
 *   1. test_arp_request_for_us  — ARP request for 10.0.2.15 → returns 42, reply correct
 *   2. test_arp_request_other_ip — ARP request for 10.0.2.99 → returns 0
 *   3. test_arp_reply_ignored   — ARP reply (OPER=2) → returns 0
 *   4. test_arp_truncated       — 41-byte frame → returns 0
 */

.include "net.inc"

.global test_arp_request_for_us
.global test_arp_request_other_ip
.global test_arp_reply_ignored
.global test_arp_truncated

.section .text

/* ========================================================================
 * test_arp_request_for_us — full validation of in-place reply
 * ======================================================================== */
test_arp_request_for_us:
    stp     x29, x30, [sp, #-16]!

    /* Copy template to mutable buffer (42 bytes, word at a time + remainder) */
    ldr     x0, =arp_req_template
    ldr     x1, =arp_req_buf
    /* 40 bytes = 5 doublewords */
    ldr     x2, [x0, #0]
    str     x2, [x1, #0]
    ldr     x2, [x0, #8]
    str     x2, [x1, #8]
    ldr     x2, [x0, #16]
    str     x2, [x1, #16]
    ldr     x2, [x0, #24]
    str     x2, [x1, #24]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    /* Last 2 bytes */
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    /* Call arp_handle */
    ldr     x0, =arp_req_buf
    mov     w1, #42
    bl      arp_handle

    /* Should return 42 */
    cmp     w0, #42
    b.ne    .Lfail_arp_for_us

    /* Check ETH dst == sender MAC (AA:BB:CC:DD:EE:FF) */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_DST
    ldr     x1, =arp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_for_us

    /* Check ETH src == our MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_for_us

    /* Check ARP OPER == reply (0x00 0x02 on wire) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_OPER]
    cbnz    w1, .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_OPER + 1]
    cmp     w1, #2
    b.ne    .Lfail_arp_for_us

    /* Check ARP SHA == our MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_PAYLOAD + ARP_SHA
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_for_us

    /* Check ARP SPA == our IP (wire bytes: 0A 00 02 0F) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_SPA]
    cmp     w1, #0x0A
    b.ne    .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_SPA + 1]
    cbnz    w1, .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_SPA + 2]
    cmp     w1, #0x02
    b.ne    .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_SPA + 3]
    cmp     w1, #0x0F
    b.ne    .Lfail_arp_for_us

    /* Check ARP THA == sender MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_PAYLOAD + ARP_THA
    ldr     x1, =arp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_for_us

    /* Check ARP TPA == sender IP (wire bytes: 0A 00 02 02) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_TPA]
    cmp     w1, #0x0A
    b.ne    .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_TPA + 1]
    cbnz    w1, .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_TPA + 2]
    cmp     w1, #0x02
    b.ne    .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_TPA + 3]
    cmp     w1, #0x02
    b.ne    .Lfail_arp_for_us

    ldr     x0, =name_arp_for_us
    bl      test_pass
    b       .Ldone_arp_for_us

.Lfail_arp_for_us:
    ldr     x0, =name_arp_for_us
    bl      test_fail

.Ldone_arp_for_us:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_request_other_ip — ARP request for 10.0.2.99 → returns 0
 * ======================================================================== */
test_arp_request_other_ip:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_req_other_ip
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_arp_other_ip

    ldr     x0, =name_arp_other_ip
    bl      test_pass
    b       .Ldone_arp_other_ip

.Lfail_arp_other_ip:
    ldr     x0, =name_arp_other_ip
    bl      test_fail

.Ldone_arp_other_ip:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_reply_ignored — ARP reply (OPER=2) → returns 0
 * ======================================================================== */
test_arp_reply_ignored:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_reply_frame
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_arp_reply

    ldr     x0, =name_arp_reply
    bl      test_pass
    b       .Ldone_arp_reply

.Lfail_arp_reply:
    ldr     x0, =name_arp_reply
    bl      test_fail

.Ldone_arp_reply:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_truncated — 41-byte frame → returns 0
 * ======================================================================== */
test_arp_truncated:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_req_template
    mov     w1, #41
    bl      arp_handle

    cbnz    w0, .Lfail_arp_trunc

    ldr     x0, =name_arp_trunc
    bl      test_pass
    b       .Ldone_arp_trunc

.Lfail_arp_trunc:
    ldr     x0, =name_arp_trunc
    bl      test_fail

.Ldone_arp_trunc:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* Sender MAC used in templates */
arp_sender_mac:
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF

/*
 * 42-byte ARP request template: who has 10.0.2.15? Tell 10.0.2.2
 * Sender MAC: AA:BB:CC:DD:EE:FF
 */
.balign 4
arp_req_template:
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

/* ARP request for 10.0.2.99 (not our IP) — passed from .rodata, never written */
.balign 4
arp_req_other_ip:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x63                   /* TPA: 10.0.2.99 */

/* ARP reply frame (OPER=2) — should be ignored */
.balign 4
arp_reply_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04
    .byte   0x00, 0x02                               /* OPER: reply */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0x0A, 0x00, 0x02, 0x0F

name_arp_for_us:    .asciz "arp_request_for_us"
name_arp_other_ip:  .asciz "arp_request_other_ip"
name_arp_reply:     .asciz "arp_reply_ignored"
name_arp_trunc:     .asciz "arp_truncated"

.section .data
/* Mutable buffer for in-place reply test */
.balign 4
arp_req_buf:
    .space  42
