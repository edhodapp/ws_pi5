/*
 * test_eth.S — Tests for Ethernet frame utilities
 *
 * Tests:
 *   1. test_eth_type_arp     — valid 42-byte ARP frame → returns 0x0806
 *   2. test_eth_type_short   — 13-byte frame → returns -1
 *   3. test_eth_build_hdr    — dst MAC, src MAC, EtherType all correct
 *   4. test_eth_mac_eq       — same MACs → 1, different → 0
 */

.include "net.inc"

.global test_eth_type_arp
.global test_eth_type_short
.global test_eth_build_hdr
.global test_eth_mac_eq

.section .text

/* ========================================================================
 * test_eth_type_arp — 42-byte ARP frame → EtherType 0x0806
 * ======================================================================== */
test_eth_type_arp:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =fake_arp_frame
    mov     w1, #42
    bl      eth_type

    /* Should return ETHERTYPE_ARP (0x0806) */
    mov     w1, #ETHERTYPE_ARP
    cmp     w0, w1
    b.ne    .Lfail_type_arp

    ldr     x0, =name_type_arp
    bl      test_pass
    b       .Ldone_type_arp

.Lfail_type_arp:
    ldr     x0, =name_type_arp
    bl      test_fail

.Ldone_type_arp:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_eth_type_short — 13-byte frame → returns -1
 * ======================================================================== */
test_eth_type_short:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =fake_arp_frame
    mov     w1, #13
    bl      eth_type

    /* Should return -1 (0xFFFFFFFF) */
    cmn     w0, #1
    b.ne    .Lfail_type_short

    ldr     x0, =name_type_short
    bl      test_pass
    b       .Ldone_type_short

.Lfail_type_short:
    ldr     x0, =name_type_short
    bl      test_fail

.Ldone_type_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_eth_build_hdr — verify dst MAC, src MAC, EtherType
 * ======================================================================== */
test_eth_build_hdr:
    stp     x29, x30, [sp, #-16]!

    /* Build a header with broadcast dst and ARP ethertype */
    ldr     x0, =build_hdr_buf
    ldr     x1, =test_dst_mac
    mov     w2, #ETHERTYPE_ARP
    bl      eth_build_hdr

    /* Check dst MAC == test_dst_mac */
    ldr     x0, =build_hdr_buf
    ldr     x1, =test_dst_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_build_hdr

    /* Check src MAC == net_our_mac */
    ldr     x0, =build_hdr_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_build_hdr

    /* Check EtherType: should be 0x08 0x06 (big-endian) */
    ldr     x0, =build_hdr_buf
    ldrb    w1, [x0, #ETH_TYPE]
    cmp     w1, #0x08
    b.ne    .Lfail_build_hdr
    ldrb    w1, [x0, #ETH_TYPE + 1]
    cmp     w1, #0x06
    b.ne    .Lfail_build_hdr

    ldr     x0, =name_build_hdr
    bl      test_pass
    b       .Ldone_build_hdr

.Lfail_build_hdr:
    ldr     x0, =name_build_hdr
    bl      test_fail

.Ldone_build_hdr:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_eth_mac_eq — same MACs → 1, different → 0
 * ======================================================================== */
test_eth_mac_eq:
    stp     x29, x30, [sp, #-16]!

    /* Same MACs should return 1 */
    ldr     x0, =test_dst_mac
    ldr     x1, =test_dst_mac
    bl      eth_mac_eq
    cmp     w0, #1
    b.ne    .Lfail_mac_eq

    /* Different first 4 bytes should return 0 */
    ldr     x0, =test_dst_mac
    ldr     x1, =test_other_mac
    bl      eth_mac_eq
    cbnz    w0, .Lfail_mac_eq

    /* Same first 4 bytes, different last 2 should return 0 */
    ldr     x0, =test_dst_mac
    ldr     x1, =test_tail_diff_mac
    bl      eth_mac_eq
    cbnz    w0, .Lfail_mac_eq

    ldr     x0, =name_mac_eq
    bl      test_pass
    b       .Ldone_mac_eq

.Lfail_mac_eq:
    ldr     x0, =name_mac_eq
    bl      test_fail

.Ldone_mac_eq:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* 42-byte ARP frame: dst(6) + src(6) + ethertype(2) + ARP payload(28) */
.balign 4
fake_arp_frame:
    /* Ethernet header */
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF     /* dst: broadcast */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: some sender */
    .byte   0x08, 0x06                               /* EtherType: ARP (big-endian) */
    /* ARP payload (28 bytes) — content doesn't matter for eth_type test */
    .fill   28, 1, 0

test_dst_mac:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

test_other_mac:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x99

/* First 4 bytes match test_dst_mac, last 2 differ */
test_tail_diff_mac:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01

name_type_arp:      .asciz "eth_type_arp"
name_type_short:    .asciz "eth_type_short"
name_build_hdr:     .asciz "eth_build_hdr"
name_mac_eq:        .asciz "eth_mac_eq"

.section .data
.balign 4
build_hdr_buf:
    .space  ETH_HDR_LEN
