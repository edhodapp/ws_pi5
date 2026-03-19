/*
 * test_ntp.S — Tests for NTP client and gateway MAC caching
 *
 * Tests:
 *   1. test_ntp_build_request   — verify built frame fields + checksums
 *   2. test_ntp_handle_valid    — valid NTP response → synced
 *   3. test_ntp_handle_wrong_mode — mode=3 → ignored
 *   4. test_ntp_handle_kod      — stratum=0 → ignored
 *   5. test_ntp_handle_short    — payload < 48 → ignored
 *   6. test_ntp_time_synced     — known state → correct wall time
 *   7. test_ntp_time_not_synced — synced=0 → returns 0
 *   8. test_arp_gw_mac_cache    — ARP from gateway → MAC cached
 *   9. test_arp_non_gw_no_cache — ARP from non-gateway → not cached
 *  10. test_udp_ntp_dispatch    — UDP port 123 → ntp_handle called, synced
 */

.include "net.inc"
.include "ntp.inc"

.global test_ntp

.section .text

test_ntp:
    stp     x29, x30, [sp, #-16]!
    bl      test_ntp_build_request
    bl      test_ntp_handle_valid
    bl      test_ntp_handle_wrong_mode
    bl      test_ntp_handle_kod
    bl      test_ntp_handle_short
    bl      test_ntp_time_synced
    bl      test_ntp_time_not_synced
    bl      test_arp_gw_mac_cache
    bl      test_arp_non_gw_no_cache
    bl      test_udp_ntp_dispatch
    ldp     x29, x30, [sp], #16
    ret

/* ---- Helper: zero ntp_state ---- */
tntp_reset_state:
    ldr     x0, =ntp_state
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    ret

/* ---- Helper: zero net_gw_mac_valid ---- */
tntp_reset_gw:
    ldr     x0, =net_gw_mac_valid
    str     wzr, [x0]
    ldr     x0, =net_gw_mac
    strh    wzr, [x0]
    str     wzr, [x0, #2]
    ret

/* ========================================================================
 * 1. test_ntp_build_request
 * ======================================================================== */
test_ntp_build_request:
    stp     x29, x30, [sp, #-16]!

    /* Build request into tntp_frame_buf using test gateway MAC */
    ldr     x0, =tntp_frame_buf
    ldr     x1, =tntp_gw_mac
    bl      ntp_build_request

    /* Returns 90 */
    cmp     w0, #NTP_FRAME_LEN
    b.ne    .Lfail_nbr

    /* Check ETH dst == gateway MAC */
    ldr     x0, =tntp_frame_buf
    add     x0, x0, #ETH_DST
    ldr     x1, =tntp_gw_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_nbr

    /* Check ETH src == our MAC */
    ldr     x0, =tntp_frame_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_nbr

    /* Check EtherType == 0x0800 (big-endian on wire: 08 00) */
    ldr     x0, =tntp_frame_buf
    ldrb    w1, [x0, #ETH_TYPE]
    cmp     w1, #0x08
    b.ne    .Lfail_nbr
    ldrb    w1, [x0, #ETH_TYPE + 1]
    cbnz    w1, .Lfail_nbr

    /* Check IP proto == UDP (17) */
    ldr     x0, =tntp_frame_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_PROTO)]
    cmp     w1, #IP_PROTO_UDP
    b.ne    .Lfail_nbr

    /* Check IP dst == net_ntp_ip */
    ldr     x0, =tntp_frame_buf
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_DST)]
    ldr     x2, =net_ntp_ip
    ldr     w2, [x2]
    cmp     w1, w2
    b.ne    .Lfail_nbr

    /* Check UDP dport == 123 (big-endian: 00 7B) */
    ldr     x0, =tntp_frame_buf
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_DPORT)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #NTP_PORT
    b.ne    .Lfail_nbr

    /* Check UDP sport == 12345 */
    ldr     x0, =tntp_frame_buf
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_SPORT)]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #NTP_SPORT
    cmp     w1, w2
    b.ne    .Lfail_nbr

    /* Check NTP flags byte == 0x23 */
    ldr     x0, =tntp_frame_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + NTP_FLAGS)]
    cmp     w1, #NTP_CLIENT_FLAGS
    b.ne    .Lfail_nbr

    /* Verify IP checksum (returns 0 on valid) */
    ldr     x0, =tntp_frame_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_nbr

    /* Verify UDP checksum (returns 0 on valid) */
    ldr     x0, =tntp_frame_buf
    mov     w1, #56                     /* UDP segment length */
    bl      udp_checksum
    cbnz    w0, .Lfail_nbr

    ldr     x0, =name_nbr
    bl      test_pass
    b       .Ldone_nbr
.Lfail_nbr:
    ldr     x0, =name_nbr
    bl      test_fail
.Ldone_nbr:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 2. test_ntp_handle_valid — mode=4, stratum=1, known TX timestamp
 *
 * TX timestamp seconds (BE) = 0x83AA7E80 + 1000000 = 0x83BDD100
 * → Unix seconds = 1000000 = 0x000F4240
 * ======================================================================== */
test_ntp_handle_valid:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_valid
    mov     w1, #NTP_PKT_LEN
    mov     x2, #5000                   /* current_ticks = 5000 */
    bl      ntp_handle

    /* Should return 1 */
    cmp     w0, #1
    b.ne    .Lfail_nhv

    /* Check ntp_state.synced == 1 */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cmp     w1, #1
    b.ne    .Lfail_nhv

    /* Check sync_secs == 1000000 (0xF4240) */
    ldr     x1, [x0, #NTPS_SYNC_SECS]
    ldr     x2, =1000000
    cmp     x1, x2
    b.ne    .Lfail_nhv

    /* Check sync_ticks == 5000 */
    ldr     x1, [x0, #NTPS_SYNC_TICKS]
    mov     x2, #5000
    cmp     x1, x2
    b.ne    .Lfail_nhv

    ldr     x0, =name_nhv
    bl      test_pass
    b       .Ldone_nhv
.Lfail_nhv:
    ldr     x0, =name_nhv
    bl      test_fail
.Ldone_nhv:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 3. test_ntp_handle_wrong_mode — mode=3 (client) → returns 0
 * ======================================================================== */
test_ntp_handle_wrong_mode:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_wrong_mode
    mov     w1, #NTP_PKT_LEN
    mov     x2, #1000
    bl      ntp_handle

    /* Should return 0 */
    cbnz    w0, .Lfail_nhwm

    /* synced should still be 0 */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cbnz    w1, .Lfail_nhwm

    ldr     x0, =name_nhwm
    bl      test_pass
    b       .Ldone_nhwm
.Lfail_nhwm:
    ldr     x0, =name_nhwm
    bl      test_fail
.Ldone_nhwm:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 4. test_ntp_handle_kod — stratum=0 (Kiss of Death) → returns 0
 * ======================================================================== */
test_ntp_handle_kod:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_kod
    mov     w1, #NTP_PKT_LEN
    mov     x2, #1000
    bl      ntp_handle

    cbnz    w0, .Lfail_nhk

    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cbnz    w1, .Lfail_nhk

    ldr     x0, =name_nhk
    bl      test_pass
    b       .Ldone_nhk
.Lfail_nhk:
    ldr     x0, =name_nhk
    bl      test_fail
.Ldone_nhk:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 5. test_ntp_handle_short — payload < 48 → returns 0
 * ======================================================================== */
test_ntp_handle_short:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_valid
    mov     w1, #47                     /* one byte short */
    mov     x2, #1000
    bl      ntp_handle

    cbnz    w0, .Lfail_nhs

    ldr     x0, =name_nhs
    bl      test_pass
    b       .Ldone_nhs
.Lfail_nhs:
    ldr     x0, =name_nhs
    bl      test_fail
.Ldone_nhs:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 6. test_ntp_time_synced — known state → correct wall time
 *
 * sync_secs=1000000, sync_ticks=100, freq=100
 * current_ticks=200 → elapsed=100/100=1 → wall=1000001
 * ======================================================================== */
test_ntp_time_synced:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    /* Set up known state */
    ldr     x0, =ntp_state
    ldr     x1, =1000000
    str     x1, [x0, #NTPS_SYNC_SECS]
    mov     x1, #100
    str     x1, [x0, #NTPS_SYNC_TICKS]
    mov     x1, #100
    str     x1, [x0, #NTPS_TIMER_FREQ]
    mov     w1, #1
    str     w1, [x0, #NTPS_SYNCED]

    /* Call ntp_time(200) */
    mov     x0, #200
    bl      ntp_time

    /* Expect 1000001 */
    ldr     x1, =1000001
    cmp     x0, x1
    b.ne    .Lfail_nts

    ldr     x0, =name_nts
    bl      test_pass
    b       .Ldone_nts
.Lfail_nts:
    ldr     x0, =name_nts
    bl      test_fail
.Ldone_nts:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 7. test_ntp_time_not_synced — synced=0 → returns 0
 * ======================================================================== */
test_ntp_time_not_synced:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    mov     x0, #9999
    bl      ntp_time

    cbnz    x0, .Lfail_ntns

    ldr     x0, =name_ntns
    bl      test_pass
    b       .Ldone_ntns
.Lfail_ntns:
    ldr     x0, =name_ntns
    bl      test_fail
.Ldone_ntns:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 8. test_arp_gw_mac_cache — ARP from gateway (10.0.2.2) → MAC cached
 * ======================================================================== */
test_arp_gw_mac_cache:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_gw

    /* Copy ARP template (gateway SPA=10.0.2.2) to mutable buffer */
    ldr     x0, =tntp_arp_gw_template
    ldr     x1, =tntp_arp_buf
    /* 42 bytes: 5 doublewords + 2 bytes */
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    /* Call arp_handle — this is the same template as the existing
     * arp_req_template (SPA=10.0.2.2, TPA=10.0.2.15) */
    ldr     x0, =tntp_arp_buf
    mov     w1, #ARP_FRAME_LEN
    bl      arp_handle

    /* Should return 42 (reply built) */
    cmp     w0, #ARP_FRAME_LEN
    b.ne    .Lfail_agc

    /* Check net_gw_mac_valid == 1 */
    ldr     x0, =net_gw_mac_valid
    ldr     w1, [x0]
    cmp     w1, #1
    b.ne    .Lfail_agc

    /* Check net_gw_mac == sender MAC (AA:BB:CC:DD:EE:FF) */
    ldr     x0, =net_gw_mac
    ldr     x1, =tntp_gw_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_agc

    ldr     x0, =name_agc
    bl      test_pass
    b       .Ldone_agc
.Lfail_agc:
    ldr     x0, =name_agc
    bl      test_fail
.Ldone_agc:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 9. test_arp_non_gw_no_cache — ARP from 192.168.0.1 → not cached
 * ======================================================================== */
test_arp_non_gw_no_cache:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_gw

    /* This ARP is for a different TPA (10.0.2.99) so arp_handle returns 0.
     * Even if we changed SPA, the gateway cache only runs after a
     * successful reply. Use a valid ARP (TPA=our IP) but SPA=192.168.0.1 */
    ldr     x0, =tntp_arp_nongw_template
    ldr     x1, =tntp_arp_buf2
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    ldr     x0, =tntp_arp_buf2
    mov     w1, #ARP_FRAME_LEN
    bl      arp_handle

    /* Should return 42 (reply built — TPA matches our IP) */
    cmp     w0, #ARP_FRAME_LEN
    b.ne    .Lfail_angc

    /* But net_gw_mac_valid should still be 0 (SPA != gateway) */
    ldr     x0, =net_gw_mac_valid
    ldr     w1, [x0]
    cbnz    w1, .Lfail_angc

    ldr     x0, =name_angc
    bl      test_pass
    b       .Ldone_angc
.Lfail_angc:
    ldr     x0, =name_angc
    bl      test_fail
.Ldone_angc:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 10. test_udp_ntp_dispatch — UDP port 123 with valid NTP → synced
 *
 * Full frame: ETH(14) + IP(20) + UDP(8) + NTP(48) = 90 bytes
 * ======================================================================== */
test_udp_ntp_dispatch:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    /* Copy 90-byte template to mutable buffer */
    ldr     x0, =tntp_udp_ntp_template
    ldr     x1, =tntp_udp_ntp_buf
    mov     w2, #90
.Lcopy_udp_ntp:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_udp_ntp

    /* Call udp_handle(buf, 90) */
    ldr     x0, =tntp_udp_ntp_buf
    mov     w1, #NTP_FRAME_LEN
    bl      udp_handle

    /* Should return 0 (no reply frame) */
    cbnz    w0, .Lfail_und

    /* ntp_state.synced should be 1 */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cmp     w1, #1
    b.ne    .Lfail_und

    ldr     x0, =name_und
    bl      test_pass
    b       .Ldone_und
.Lfail_und:
    ldr     x0, =name_und
    bl      test_fail
.Ldone_und:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* Gateway MAC for build_request test */
tntp_gw_mac:
    .byte   0x52, 0x55, 0x0A, 0x00, 0x02, 0x02

/* Sender MAC in ARP gateway test */
tntp_gw_sender_mac:
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF

/*
 * Valid NTP server response (48 bytes)
 * Byte 0: flags = 0x24 (LI=0, VN=4, Mode=4=server)
 * Byte 1: stratum = 1
 * Byte 40-43: TX timestamp seconds (BE) = 0x83BDD100
 *   = 0x83AA7E80 + 1000000 = NTP_UNIX_OFFSET + 1000000
 *   → Unix seconds = 1000000
 */
.balign 4
tntp_ntp_valid:
    .byte   0x24                        /* flags: LI=0, VN=4, Mode=4 */
    .byte   0x01                        /* stratum: 1 */
    .byte   0x06                        /* poll */
    .byte   0xEC                        /* precision */
    .space  36                          /* root delay thru receive TS */
    .byte   0x83, 0xB9, 0xC0, 0xC0     /* TX timestamp seconds (BE) */
    .byte   0x00, 0x00, 0x00, 0x00     /* TX timestamp fraction */

/* NTP response with wrong mode (mode=3 = client) */
.balign 4
tntp_ntp_wrong_mode:
    .byte   0x23                        /* flags: LI=0, VN=4, Mode=3 */
    .byte   0x01                        /* stratum: 1 */
    .space  46                          /* rest doesn't matter */

/* NTP response with stratum=0 (Kiss of Death) */
.balign 4
tntp_ntp_kod:
    .byte   0x24                        /* flags: LI=0, VN=4, Mode=4 */
    .byte   0x00                        /* stratum: 0 (KoD) */
    .space  46

/*
 * ARP request template — gateway SPA=10.0.2.2, TPA=10.0.2.15
 * (same as existing arp_req_template but we need our own copy)
 */
.balign 4
tntp_arp_gw_template:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF     /* dst: broadcast */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x06                               /* EtherType: ARP */
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* SHA */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* SPA: 10.0.2.2 (gateway) */
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00     /* THA */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* TPA: 10.0.2.15 (us) */

/*
 * ARP request — non-gateway SPA=192.168.0.1 (0xC0A80001), TPA=10.0.2.15
 */
.balign 4
tntp_arp_nongw_template:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66     /* src: some other MAC */
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66     /* SHA */
    .byte   0xC0, 0xA8, 0x00, 0x01                   /* SPA: 192.168.0.1 */
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* TPA: 10.0.2.15 (us) */

/*
 * Full 90-byte UDP frame with NTP response on port 123
 *
 * ETH: dst=02:00:00:00:00:01 src=52:55:0A:00:02:02 type=0800
 * IP:  ver/ihl=45 dscp=00 totlen=004C id=0000 flags=0000
 *      ttl=40 proto=11(UDP) cksum=TBD src=D8EF2300 dst=0A00020F
 * UDP: sport=007B(123) dport=007B(123) len=0038(56) cksum=0000(skip)
 * NTP: flags=0x24(server) stratum=1 ... TX_TS_secs=0x83BDD100
 *
 * IP checksum computed over the header:
 *   4500 004C 0000 0000 4011 xxxx D8EF 2300 0A00 020F
 *   sum without cksum = 4500+004C+0000+0000+4011+0000+D8EF+2300+0A00+020F
 *   = 4500+004C+4011+D8EF+2300+0A00+020F
 *   = 4500+004C = 454C
 *   +4011 = 855D
 *   +D8EF = 15E4C → carry: 5E4D
 *   +2300 = 814D
 *   +0A00 = 8B4D
 *   +020F = 8D5C
 *   ~8D5C = 72A3
 */
.balign 4
tntp_udp_ntp_template:
    /* Ethernet header (14 bytes) */
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0x52, 0x55, 0x0A, 0x00, 0x02, 0x02     /* src */
    .byte   0x08, 0x00                               /* IPv4 */
    /* IP header (20 bytes) */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x4C                               /* totlen: 76 */
    .byte   0x00, 0x00                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x11                               /* ttl=64, proto=UDP */
    .byte   0x72, 0xA3                               /* IP checksum */
    .byte   0xD8, 0xEF, 0x23, 0x00                   /* src: 216.239.35.0 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    /* UDP header (8 bytes) */
    .byte   0x00, 0x7B                               /* sport: 123 */
    .byte   0x00, 0x7B                               /* dport: 123 */
    .byte   0x00, 0x38                               /* length: 56 */
    .byte   0x00, 0x00                               /* checksum: 0 (skip) */
    /* NTP payload (48 bytes) */
    .byte   0x24                                     /* flags: server mode */
    .byte   0x01                                     /* stratum: 1 */
    .byte   0x06                                     /* poll */
    .byte   0xEC                                     /* precision */
    .space  36                                       /* root delay thru recv TS */
    .byte   0x83, 0xB9, 0xC0, 0xC0                   /* TX timestamp secs (BE) */
    .byte   0x00, 0x00, 0x00, 0x00                   /* TX timestamp frac */

name_nbr:   .asciz "ntp_build_request"
name_nhv:   .asciz "ntp_handle_valid"
name_nhwm:  .asciz "ntp_handle_wrong_mode"
name_nhk:   .asciz "ntp_handle_kod"
name_nhs:   .asciz "ntp_handle_short"
name_nts:   .asciz "ntp_time_synced"
name_ntns:  .asciz "ntp_time_not_synced"
name_agc:   .asciz "arp_gw_mac_cache"
name_angc:  .asciz "arp_non_gw_no_cache"
name_und:   .asciz "udp_ntp_dispatch"

.section .data
.balign 16
tntp_frame_buf:
    .space  90

.balign 4
tntp_arp_buf:
    .space  42

.balign 4
tntp_arp_buf2:
    .space  42

.balign 4
tntp_udp_ntp_buf:
    .space  90
