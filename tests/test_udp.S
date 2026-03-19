/*
 * test_udp.S — Tests for UDP handler
 *
 * Tests:
 *   1. test_udp_echo          — Valid echo request to port 7 → reply, returns 46
 *   2. test_udp_checksum_zero — UDP checksum=0, accepted (skip verify), returns 46
 *   3. test_udp_short         — Frame too short for UDP header → returns 0
 *   4. test_udp_wrong_port    — Valid UDP to port 53 → returns 0
 *   5. test_udp_bad_checksum  — Corrupted UDP checksum → returns 0
 *   6. test_udp_len_mismatch  — UDP Length != actual frame → returns 0
 *   7. test_udp_echo_empty    — Echo with zero payload → returns 42
 *   8. test_udp_echo_odd      — Echo with 3-byte payload → odd-byte checksum path
 */

.include "net.inc"

.global test_udp

.section .text

/*
 * test_udp — Run all UDP tests
 */
test_udp:
    stp     x29, x30, [sp, #-16]!
    bl      test_udp_echo
    bl      test_udp_checksum_zero
    bl      test_udp_short
    bl      test_udp_wrong_port
    bl      test_udp_bad_checksum
    bl      test_udp_len_mismatch
    bl      test_udp_echo_empty
    bl      test_udp_echo_odd
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_udp_echo — Valid echo to port 7 with 4-byte payload "ABCD"
 *
 * Verify: MACs swapped, IPs swapped, ports swapped, payload preserved,
 * both checksums valid, returns 46.
 * ======================================================================== */
test_udp_echo:
    stp     x29, x30, [sp, #-16]!

    /* Copy 46-byte template to mutable buffer */
    ldr     x0, =udp_echo_template
    ldr     x1, =udp_echo_buf
    mov     w2, #46
.Lcopy_udp_echo:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_udp_echo

    /* Call udp_handle(buf, 46) */
    ldr     x0, =udp_echo_buf
    mov     w1, #46
    bl      udp_handle

    /* Should return 46 */
    cmp     w0, #46
    b.ne    .Lfail_udp_echo

    /* Check ETH dst == sender MAC (AA:BB:CC:DD:EE:FF) */
    ldr     x0, =udp_echo_buf
    add     x0, x0, #ETH_DST
    ldr     x1, =udp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_udp_echo

    /* Check ETH src == our MAC */
    ldr     x0, =udp_echo_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_udp_echo

    /* Check IP src == our IP */
    ldr     x0, =udp_echo_buf
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_SRC)]
    ldr     x2, =net_our_ip
    ldr     w2, [x2]
    cmp     w1, w2
    b.ne    .Lfail_udp_echo

    /* Check IP dst == sender IP (10.0.2.2) */
    ldr     x0, =udp_echo_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST)]
    cmp     w1, #0x0A
    b.ne    .Lfail_udp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 1)]
    cbnz    w1, .Lfail_udp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 2)]
    cmp     w1, #0x02
    b.ne    .Lfail_udp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 3)]
    cmp     w1, #0x02
    b.ne    .Lfail_udp_echo

    /* Check ports swapped: sport=7 (BE: 00 07), dport=12345 (BE: 30 39) */
    ldr     x0, =udp_echo_buf
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_SPORT)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #7
    b.ne    .Lfail_udp_echo

    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_DPORT)]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #12345
    cmp     w1, w2
    b.ne    .Lfail_udp_echo

    /* Check payload preserved: "ABCD" */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN)]
    cmp     w1, #0x41               /* 'A' */
    b.ne    .Lfail_udp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + 1)]
    cmp     w1, #0x42               /* 'B' */
    b.ne    .Lfail_udp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + 2)]
    cmp     w1, #0x43               /* 'C' */
    b.ne    .Lfail_udp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + 3)]
    cmp     w1, #0x44               /* 'D' */
    b.ne    .Lfail_udp_echo

    /* Verify UDP checksum valid (udp_checksum returns 0) */
    ldr     x0, =udp_echo_buf
    mov     w1, #12                 /* UDP length: 8 header + 4 payload */
    bl      udp_checksum
    cbnz    w0, .Lfail_udp_echo

    /* Verify IP checksum valid */
    ldr     x0, =udp_echo_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_udp_echo

    ldr     x0, =name_udp_echo
    bl      test_pass
    b       .Ldone_udp_echo

.Lfail_udp_echo:
    ldr     x0, =name_udp_echo
    bl      test_fail

.Ldone_udp_echo:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_udp_checksum_zero — UDP checksum=0, validation skipped, returns 46
 * ======================================================================== */
test_udp_checksum_zero:
    stp     x29, x30, [sp, #-16]!

    /* Copy 46-byte template to mutable buffer */
    ldr     x0, =udp_echo_template
    ldr     x1, =udp_cksum_zero_buf
    mov     w2, #46
.Lcopy_udp_ckzero:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_udp_ckzero

    /* Zero the UDP checksum field */
    ldr     x0, =udp_cksum_zero_buf
    strh    wzr, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_CHECKSUM)]

    /* Call udp_handle(buf, 46) */
    ldr     x0, =udp_cksum_zero_buf
    mov     w1, #46
    bl      udp_handle

    /* Should return 46 (accepted, echo reply built) */
    cmp     w0, #46
    b.ne    .Lfail_udp_ckzero

    ldr     x0, =name_udp_ckzero
    bl      test_pass
    b       .Ldone_udp_ckzero

.Lfail_udp_ckzero:
    ldr     x0, =name_udp_ckzero
    bl      test_fail

.Ldone_udp_ckzero:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_udp_short — Frame too short (udp_section < 8) → returns 0
 * ======================================================================== */
test_udp_short:
    stp     x29, x30, [sp, #-16]!

    /* Use template but pass frame_len=41 → udp_section = 41 - 14 - 20 = 7 */
    ldr     x0, =udp_echo_template
    mov     w1, #41
    bl      udp_handle

    cbnz    w0, .Lfail_udp_short

    ldr     x0, =name_udp_short
    bl      test_pass
    b       .Ldone_udp_short

.Lfail_udp_short:
    ldr     x0, =name_udp_short
    bl      test_fail

.Ldone_udp_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_udp_wrong_port — Valid UDP to port 53 (DNS) → returns 0
 * ======================================================================== */
test_udp_wrong_port:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =udp_wrong_port_template
    mov     w1, #46
    bl      udp_handle

    cbnz    w0, .Lfail_udp_wport

    ldr     x0, =name_udp_wport
    bl      test_pass
    b       .Ldone_udp_wport

.Lfail_udp_wport:
    ldr     x0, =name_udp_wport
    bl      test_fail

.Ldone_udp_wport:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_udp_bad_checksum — Corrupted UDP checksum → returns 0
 * ======================================================================== */
test_udp_bad_checksum:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =udp_bad_cksum_template
    mov     w1, #46
    bl      udp_handle

    cbnz    w0, .Lfail_udp_badck

    ldr     x0, =name_udp_badck
    bl      test_pass
    b       .Ldone_udp_badck

.Lfail_udp_badck:
    ldr     x0, =name_udp_badck
    bl      test_fail

.Ldone_udp_badck:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_udp_len_mismatch — UDP Length != actual frame → returns 0
 * ======================================================================== */
test_udp_len_mismatch:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =udp_len_mismatch_template
    mov     w1, #46
    bl      udp_handle

    cbnz    w0, .Lfail_udp_lenmis

    ldr     x0, =name_udp_lenmis
    bl      test_pass
    b       .Ldone_udp_lenmis

.Lfail_udp_lenmis:
    ldr     x0, =name_udp_lenmis
    bl      test_fail

.Ldone_udp_lenmis:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_udp_echo_empty — Echo with zero payload (just 8-byte header)
 * Returns 42.
 * ======================================================================== */
test_udp_echo_empty:
    stp     x29, x30, [sp, #-16]!

    /* Copy 42-byte template to mutable buffer */
    ldr     x0, =udp_echo_empty_template
    ldr     x1, =udp_echo_empty_buf
    ldp     x2, x3, [x0]           /* 16 bytes */
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]      /* 16 bytes */
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]          /* 8 bytes */
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]          /* 2 bytes */
    strh    w2, [x1, #40]

    /* Call udp_handle(buf, 42) */
    ldr     x0, =udp_echo_empty_buf
    mov     w1, #42
    bl      udp_handle

    /* Should return 42 */
    cmp     w0, #42
    b.ne    .Lfail_udp_empty

    /* Verify ports swapped */
    ldr     x0, =udp_echo_empty_buf
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_SPORT)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #7
    b.ne    .Lfail_udp_empty

    /* Verify UDP checksum valid */
    ldr     x0, =udp_echo_empty_buf
    mov     w1, #8
    bl      udp_checksum
    cbnz    w0, .Lfail_udp_empty

    /* Verify IP checksum valid */
    ldr     x0, =udp_echo_empty_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_udp_empty

    ldr     x0, =name_udp_empty
    bl      test_pass
    b       .Ldone_udp_empty

.Lfail_udp_empty:
    ldr     x0, =name_udp_empty
    bl      test_fail

.Ldone_udp_empty:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_udp_echo_odd — Echo with 3-byte payload "ABC" (odd-length UDP)
 *
 * The 11-byte UDP segment exercises udp_checksum's trailing-byte path
 * during both inbound verification and outbound checksum computation.
 * ======================================================================== */
test_udp_echo_odd:
    stp     x29, x30, [sp, #-16]!

    /* Copy 45-byte template to mutable buffer */
    ldr     x0, =udp_echo_odd_template
    ldr     x1, =udp_echo_odd_buf
    mov     w2, #45
.Lcopy_udp_odd:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_udp_odd

    /* Call udp_handle(buf, 45) */
    ldr     x0, =udp_echo_odd_buf
    mov     w1, #45
    bl      udp_handle

    /* Should return 45 */
    cmp     w0, #45
    b.ne    .Lfail_udp_odd

    /* Check payload preserved: "ABC" */
    ldr     x0, =udp_echo_odd_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN)]
    cmp     w1, #0x41               /* 'A' */
    b.ne    .Lfail_udp_odd
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + 1)]
    cmp     w1, #0x42               /* 'B' */
    b.ne    .Lfail_udp_odd
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + 2)]
    cmp     w1, #0x43               /* 'C' */
    b.ne    .Lfail_udp_odd

    /* Verify UDP checksum valid (11-byte odd-length segment) */
    ldr     x0, =udp_echo_odd_buf
    mov     w1, #11
    bl      udp_checksum
    cbnz    w0, .Lfail_udp_odd

    /* Verify IP checksum valid */
    ldr     x0, =udp_echo_odd_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_udp_odd

    ldr     x0, =name_udp_odd
    bl      test_pass
    b       .Ldone_udp_odd

.Lfail_udp_odd:
    ldr     x0, =name_udp_odd
    bl      test_fail

.Ldone_udp_odd:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* Sender MAC for verification */
udp_sender_mac:
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF

/*
 * 46-byte UDP echo request: sport=12345 dport=7 payload="ABCD"
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=0020 id=1234 flags=0000
 *                ttl=40 proto=11 cksum=5089 src=0A000202 dst=0A00020F
 * UDP (12):      sport=3039 dport=0007 len=000C cksum=32FF
 * Payload (4):   41424344 ("ABCD")
 */
.balign 4
udp_echo_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x20                               /* totlen: 32 */
    .byte   0x12, 0x34                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x11                               /* ttl=64, proto=UDP */
    .byte   0x50, 0x89                               /* IP checksum */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x07                               /* dport: 7 (echo) */
    .byte   0x00, 0x0C                               /* length: 12 */
    .byte   0x32, 0xFF                               /* UDP checksum */
    .byte   0x41, 0x42, 0x43, 0x44                   /* "ABCD" */

/*
 * 46-byte UDP to port 53 (DNS) — valid checksum, wrong port
 * Same as echo template but dport=0035, UDP cksum recomputed: D132
 */
.balign 4
udp_wrong_port_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x20
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x11, 0x50, 0x89
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x35                               /* dport: 53 (DNS) */
    .byte   0x00, 0x0C                               /* length: 12 */
    .byte   0x32, 0xD1                               /* UDP checksum */
    .byte   0x41, 0x42, 0x43, 0x44                   /* "ABCD" */

/*
 * 46-byte UDP echo with corrupted checksum (33 FF instead of 32 FF)
 */
.balign 4
udp_bad_cksum_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x20
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x11, 0x50, 0x89
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39
    .byte   0x00, 0x07
    .byte   0x00, 0x0C
    .byte   0x33, 0xFF                               /* corrupted checksum */
    .byte   0x41, 0x42, 0x43, 0x44

/*
 * 46-byte UDP with length mismatch: UDP Length=14 but actual=12
 */
.balign 4
udp_len_mismatch_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x20
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x11, 0x50, 0x89
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39
    .byte   0x00, 0x07
    .byte   0x00, 0x0E                               /* length: 14 (wrong) */
    .byte   0x32, 0xFF
    .byte   0x41, 0x42, 0x43, 0x44

/*
 * 42-byte UDP echo with zero payload (just 8-byte UDP header)
 *
 * IP totlen=001C (28), IP cksum=508D
 * UDP: sport=3039 dport=0007 len=0008 cksum=B78D
 */
.balign 4
udp_echo_empty_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x11, 0x50, 0x8D                   /* IP checksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x07                               /* dport: 7 */
    .byte   0x00, 0x08                               /* length: 8 */
    .byte   0xB7, 0x8D                               /* UDP checksum */

/*
 * 45-byte UDP echo with 3-byte payload "ABC" (odd-length UDP segment)
 *
 * IP totlen=001F (31), IP cksum=508A
 * UDP: sport=3039 dport=0007 len=000B cksum=3345
 * The 11-byte UDP segment exercises the odd trailing byte path.
 */
.balign 4
udp_echo_odd_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1F
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x11, 0x50, 0x8A                   /* IP checksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x07                               /* dport: 7 */
    .byte   0x00, 0x0B                               /* length: 11 */
    .byte   0x33, 0x45                               /* UDP checksum */
    .byte   0x41, 0x42, 0x43                         /* "ABC" */

name_udp_echo:      .asciz "udp_echo"
name_udp_ckzero:    .asciz "udp_checksum_zero"
name_udp_short:     .asciz "udp_short"
name_udp_wport:     .asciz "udp_wrong_port"
name_udp_badck:     .asciz "udp_bad_checksum"
name_udp_lenmis:    .asciz "udp_len_mismatch"
name_udp_empty:     .asciz "udp_echo_empty"
name_udp_odd:       .asciz "udp_echo_odd"

.section .data
.balign 4
udp_echo_buf:
    .space  46

.balign 4
udp_cksum_zero_buf:
    .space  46

.balign 4
udp_echo_empty_buf:
    .space  42

.balign 4
udp_echo_odd_buf:
    .space  46
