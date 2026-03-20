/*
 * test_tcp_func_hand.S — Hand-crafted functional tests for TCP features
 *
 * These test integration paths that the table-driven harness cannot reach:
 *   1. Multi-port listen (SYN to port 8080)
 *   2. Outgoing timestamps (SYN-ACK with TSopt)
 *   3. PAWS rejection (stale TSval drops segment)
 *   4. ICMP Destination Unreachable tears down connection via net_recv_one
 */

.include "net.inc"
.include "tcp.inc"
.include "timer.inc"

.global test_tcp_func_handcrafted

.section .text

/* ===========================================================================
 * test_tcp_func_handcrafted — Entry point, calls each sub-test
 * =========================================================================== */
test_tcp_func_handcrafted:
    stp     x29, x30, [sp, #-16]!
    bl      test_func_multiport
    bl      test_func_ts_synack
    bl      test_func_paws_reject
    bl      test_func_icmp_teardown
    ldp     x29, x30, [sp], #16
    ret

/* ===========================================================================
 * test_func_multiport — SYN to port 8080 when both 80 and 8080 are listening
 *
 * Setup: tcp_init, tcp_listen(80), tcp_listen(8080)
 * Send:  SYN to dport=8080 via tcp_handle
 * Verify: return=54, reply flags=SYN-ACK, a SYN_RCVD conn exists for port 8080
 * =========================================================================== */
test_func_multiport:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen
    mov     w0, #8080
    bl      tcp_listen

    /* Build SYN to port 8080 in scratch buf.
       Copy 54-byte SYN template, then patch dport to 8080. */
    ldr     x0, =fh_syn_template
    ldr     x1, =fh_scratch
    mov     w2, #54
.Lfmp_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lfmp_copy

    ldr     x19, =fh_scratch

    /* Patch dport to 8080 (NBO: 0x1F90) */
    mov     w0, #0x1F90
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]

    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Call tcp_handle */
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify return = 54 (SYN-ACK reply) */
    cmp     w0, #54
    b.ne    .Lfmp_fail

    /* Verify reply flags = SYN|ACK (0x12) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_SYN_ACK
    b.ne    .Lfmp_fail

    /* Verify a SYN_RCVD connection exists with lport=8080 NBO */
    ldr     x0, =tcp_conn_table
    mov     w2, #TCP_MAX_CONNS
    mov     w3, #0x901F             /* 8080 in NBO stored as LE halfword */
.Lfmp_scan:
    cbz     w2, .Lfmp_fail
    sub     w2, w2, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.ne    .Lfmp_next
    ldrh    w1, [x0, #TCONN_LPORT]
    cmp     w1, w3
    b.eq    .Lfmp_found
.Lfmp_next:
    add     x0, x0, #TCONN_SIZE
    b       .Lfmp_scan
.Lfmp_found:

    ldr     x0, =name_fmp
    bl      test_pass
    b       .Lfmp_done
.Lfmp_fail:
    ldr     x0, =name_fmp
    bl      test_fail
.Lfmp_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===========================================================================
 * test_func_ts_synack — SYN with TSopt → SYN-ACK with TSopt (66 bytes)
 *
 * Setup: tcp_init, tcp_listen(80)
 * Send:  66-byte SYN with TSopt (TSval=0x12345678) via tcp_handle
 * Verify: return=66, reply doff=0x80, reply TSecr=0x12345678
 * =========================================================================== */
test_func_ts_synack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Build 66-byte SYN with TSopt.
       Copy 54-byte template, extend to 66 with options. */
    ldr     x0, =fh_syn_template
    ldr     x1, =fh_scratch
    mov     w2, #54
.Lfts_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lfts_copy

    ldr     x19, =fh_scratch

    /* Set doff = 0x80 (32 bytes) */
    mov     w0, #0x80
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* IP TotalLength = 52 (0x0034 NBO) */
    mov     w0, #0x3400
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Write TSopt at frame offset 54: NOP NOP Kind=8 Len=10 TSval TSecr */
    mov     w0, #0x01
    strb    w0, [x19, #54]         /* NOP */
    strb    w0, [x19, #55]         /* NOP */
    mov     w0, #0x08
    strb    w0, [x19, #56]         /* Kind = Timestamps */
    mov     w0, #0x0A
    strb    w0, [x19, #57]         /* Length = 10 */
    /* TSval = 0x12345678 (NBO) */
    mov     w0, #0x12
    strb    w0, [x19, #58]
    mov     w0, #0x34
    strb    w0, [x19, #59]
    mov     w0, #0x56
    strb    w0, [x19, #60]
    mov     w0, #0x78
    strb    w0, [x19, #61]
    /* TSecr = 0 */
    str     wzr, [x19, #62]

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum over 32 bytes */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #32
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Call tcp_handle */
    mov     x0, x19
    mov     w1, #66
    bl      tcp_handle

    /* Verify return = 66 (SYN-ACK with TSopt) */
    cmp     w0, #66
    b.ne    .Lfts_fail

    /* Verify reply flags = SYN|ACK */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_SYN_ACK
    b.ne    .Lfts_fail

    /* Verify reply doff = 0x80 (32 bytes) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    cmp     w0, #0x80
    b.ne    .Lfts_fail

    /* Verify reply IP TotalLength = 52 (0x0034 NBO = 0x3400 LE) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]
    mov     w1, #0x3400
    cmp     w0, w1
    b.ne    .Lfts_fail

    /* Verify reply has TSopt structure at TCP+20 (frame offset 54):
       NOP(01) NOP(01) Kind(08) Len(0A) */
    ldrb    w0, [x19, #54]
    cmp     w0, #0x01
    b.ne    .Lfts_fail
    ldrb    w0, [x19, #55]
    cmp     w0, #0x01
    b.ne    .Lfts_fail
    ldrb    w0, [x19, #56]
    cmp     w0, #0x08
    b.ne    .Lfts_fail
    ldrb    w0, [x19, #57]
    cmp     w0, #0x0A
    b.ne    .Lfts_fail

    /* Verify TSecr at frame offset 62 echoes our TSval (0x12345678 NBO) */
    ldrb    w0, [x19, #62]
    cmp     w0, #0x12
    b.ne    .Lfts_fail
    ldrb    w0, [x19, #63]
    cmp     w0, #0x34
    b.ne    .Lfts_fail
    ldrb    w0, [x19, #64]
    cmp     w0, #0x56
    b.ne    .Lfts_fail
    ldrb    w0, [x19, #65]
    cmp     w0, #0x78
    b.ne    .Lfts_fail

    ldr     x0, =name_fts
    bl      test_pass
    b       .Lfts_done
.Lfts_fail:
    ldr     x0, =name_fts
    bl      test_fail
.Lfts_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===========================================================================
 * test_func_paws_reject — PAWS drops segment with stale TSval
 *
 * Setup: tcp_init, tcp_listen(80), pre-seed ESTABLISHED conn with
 *        TS_ENABLED=1, TS_RECENT=5000
 * Send:  71-byte data frame (5 bytes "Hello") with TSval=1000 (< 5000)
 * Verify: return=0 (dropped), RCV_NXT unchanged
 * =========================================================================== */
test_func_paws_reject:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Pre-seed slot 1 as ESTABLISHED with timestamps */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE  /* slot 1 */

    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]

    /* lport = 80 NBO (0x0050) */
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    /* rport = 12345 NBO (0x3039) */
    mov     w0, #0x3930
    strh    w0, [x19, #TCONN_RPORT]

    /* rip = 10.0.2.2 — ldr from frame IP_SRC bytes 0A 00 02 02 reads 0x0202000A */
    ldr     w0, =0x0202000A
    str     w0, [x19, #TCONN_RIP]

    /* SND_NXT = ISN+1 = 0x41424345 */
    ldr     w0, =0x41424345
    str     w0, [x19, #TCONN_SND_NXT]
    str     w0, [x19, #TCONN_SND_UNA]

    /* RCV_NXT = 2 (after SYN consumed) */
    mov     w0, #2
    str     w0, [x19, #TCONN_RCV_NXT]

    /* TS_ENABLED = 1, TS_RECENT = 5000 */
    mov     w0, #1
    strb    w0, [x19, #TCONN_TS_ENABLED]
    ldr     w0, =5000
    str     w0, [x19, #TCONN_TS_RECENT]

    /* Timer slot = -1 (no pending timer) */
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    /* Peer MAC — copy from SYN template src MAC */
    ldr     x0, =fh_syn_template
    add     x0, x0, #ETH_SRC
    ldrb    w1, [x0]
    strb    w1, [x19, #TCONN_RMAC]
    ldrb    w1, [x0, #1]
    strb    w1, [x19, #(TCONN_RMAC + 1)]
    ldrb    w1, [x0, #2]
    strb    w1, [x19, #(TCONN_RMAC + 2)]
    ldrb    w1, [x0, #3]
    strb    w1, [x19, #(TCONN_RMAC + 3)]
    ldrb    w1, [x0, #4]
    strb    w1, [x19, #(TCONN_RMAC + 4)]
    ldrb    w1, [x0, #5]
    strb    w1, [x19, #(TCONN_RMAC + 5)]

    /* Save RCV_NXT for later comparison */
    ldr     w20, [x19, #TCONN_RCV_NXT]

    /* Build 71-byte data frame with TSopt (TSval=1000, stale).
       ETH(14) + IP(20) + TCP(32) + payload(5) = 71 */
    ldr     x0, =fh_data_ts_template
    ldr     x1, =fh_scratch
    mov     w2, #71
.Lfpr_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lfpr_copy

    ldr     x21, =fh_scratch

    /* Patch SEQ = 2 (matches RCV_NXT), ACK = ISN+1 */
    mov     w0, #2
    rev     w0, w0
    str     w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    ldr     w0, =0x41424345
    rev     w0, w0
    str     w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* Patch TSval = 1000 (NBO) at frame offset 58 */
    mov     w0, #1000
    rev     w0, w0
    str     w0, [x21, #58]

    /* Recompute IP checksum */
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x21, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum (section_len = 32 + 5 = 37) */
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x21
    mov     w1, #37
    bl      tcp_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Call tcp_handle */
    mov     x0, x21
    mov     w1, #71
    bl      tcp_handle

    /* Verify return = 0 (dropped by PAWS) */
    cbnz    w0, .Lfpr_fail

    /* Verify RCV_NXT unchanged */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    cmp     w0, w20
    b.ne    .Lfpr_fail

    ldr     x0, =name_fpr
    bl      test_pass
    b       .Lfpr_done
.Lfpr_fail:
    ldr     x0, =name_fpr
    bl      test_fail
.Lfpr_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===========================================================================
 * test_func_icmp_teardown — ICMP Dest Unreachable through full stack
 *
 * Setup: tcp_init, tcp_listen(80), pre-seed ESTABLISHED conn in slot 1
 * Send:  ICMP type 3 frame matching the conn via net_recv_one
 * Verify: return=0, conn state=CLOSED
 * =========================================================================== */
test_func_icmp_teardown:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Pre-seed slot 1 as ESTABLISHED */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE

    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]

    mov     w0, #0x5000             /* lport = 80 NBO */
    strh    w0, [x19, #TCONN_LPORT]
    mov     w0, #0x3930             /* rport = 12345 NBO */
    strh    w0, [x19, #TCONN_RPORT]
    ldr     w0, =0x0202000A        /* rip = 10.0.2.2 (bytes 0A 00 02 02, ldr reads as LE) */
    str     w0, [x19, #TCONN_RIP]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    /* Build ICMP Destination Unreachable (70 bytes) in scratch.
       ETH(14) + IP(20) + ICMP(8) + encap_IP(20) + encap_TCP(8) = 70

       Outer IP: src=10.0.2.2 (router), dst=10.0.2.15 (us), proto=ICMP
       ICMP: type=3, code=1
       Encap IP: src=10.0.2.15 (us), dst=10.0.2.2 (peer), proto=TCP
       Encap TCP: sport=80, dport=12345 */
    ldr     x21, =fh_scratch

    /* Zero 70 bytes */
    mov     x0, x21
    mov     w1, #70
.Lfic_zero:
    strb    wzr, [x0], #1
    subs    w1, w1, #1
    b.ne    .Lfic_zero

    /* ETH: dst = our MAC, src = peer MAC, type = IPv4 */
    mov     w0, #0x02
    strb    w0, [x21, #ETH_DST]
    mov     w0, #0x01
    strb    w0, [x21, #(ETH_DST + 5)]
    mov     w0, #0xAA
    strb    w0, [x21, #ETH_SRC]
    mov     w0, #0xBB
    strb    w0, [x21, #(ETH_SRC + 1)]
    mov     w0, #0xCC
    strb    w0, [x21, #(ETH_SRC + 2)]
    mov     w0, #0xDD
    strb    w0, [x21, #(ETH_SRC + 3)]
    mov     w0, #0xEE
    strb    w0, [x21, #(ETH_SRC + 4)]
    mov     w0, #0xFF
    strb    w0, [x21, #(ETH_SRC + 5)]
    mov     w0, #0x0008             /* 0x0800 NBO as LE halfword */
    strh    w0, [x21, #ETH_TYPE]

    /* Outer IP header */
    mov     w0, #0x45
    strb    w0, [x21, #ETH_PAYLOAD]
    /* totlen = 56 (20 IP + 8 ICMP + 20 encap IP + 8 encap TCP) = 0x0038 NBO */
    mov     w0, #0x3800
    strh    w0, [x21, #(ETH_PAYLOAD + IP_TOTLEN)]
    mov     w0, #64
    strb    w0, [x21, #(ETH_PAYLOAD + IP_TTL)]
    mov     w0, #IP_PROTO_ICMP
    strb    w0, [x21, #(ETH_PAYLOAD + IP_PROTO)]
    /* src = 10.0.2.2 (router sending ICMP)
       bytes 0A 00 02 02 → ldr reads 0x0202000A on LE */
    ldr     w0, =0x0202000A
    str     w0, [x21, #(ETH_PAYLOAD + IP_SRC)]
    /* dst = 10.0.2.15 (us)
       bytes 0A 00 02 0F → ldr reads 0x0F02000A on LE */
    ldr     w0, =0x0F02000A
    str     w0, [x21, #(ETH_PAYLOAD + IP_DST)]
    /* IP checksum */
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x21, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* ICMP header: type=3, code=1 */
    mov     w0, #ICMP_DEST_UNREACHABLE
    strb    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    mov     w0, #1
    strb    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]
    /* ICMP checksum — compute over 36 bytes (8 ICMP hdr + 28 encap) */
    /* First fill encap headers, then compute */

    /* Encapsulated IP at offset 42 (ETH+IP+ICMP_HDR = 14+20+8) */
    mov     w0, #0x45
    strb    w0, [x21, #42]
    mov     w0, #6                  /* proto = TCP */
    strb    w0, [x21, #(42 + IP_PROTO)]
    /* Encap IP src = our IP 10.0.2.15 (we sent the original)
       bytes 0A 00 02 0F → str needs 0x0F02000A on LE */
    ldr     w0, =0x0F02000A
    str     w0, [x21, #(42 + IP_SRC)]
    /* Encap IP dst = peer IP 10.0.2.2
       bytes 0A 00 02 02 → str needs 0x0202000A on LE */
    ldr     w0, =0x0202000A
    str     w0, [x21, #(42 + IP_DST)]

    /* Encapsulated TCP at offset 62: sport=80(NBO), dport=12345(NBO) */
    mov     w0, #0x5000             /* 80 NBO as LE halfword */
    strh    w0, [x21, #(62 + TCP_SPORT)]
    mov     w0, #0x3930             /* 12345 NBO as LE halfword */
    strh    w0, [x21, #(62 + TCP_DPORT)]

    /* Compute ICMP checksum over 36 bytes (offset 34..69) */
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]
    add     x0, x21, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #36
    bl      ip_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]

    /* Call net_recv_one (full stack: ETH → IP → ICMP → tcp_icmp_err) */
    mov     x0, x21
    mov     w1, #70
    bl      net_recv_one

    /* Verify return = 0 */
    cbnz    w0, .Lfic_fail

    /* Verify conn state = CLOSED */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfic_fail

    ldr     x0, =name_fic
    bl      test_pass
    b       .Lfic_done
.Lfic_fail:
    ldr     x0, =name_fic
    bl      test_fail
.Lfic_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===========================================================================
 * Test data
 * =========================================================================== */
.section .rodata

/*
 * 54-byte TCP SYN to port 80 from 10.0.2.2:12345, SEQ=1, checksum=0
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=0028 id=1234 flags=0000
 *                ttl=40 proto=06 cksum=0000 src=0A000202 dst=0A00020F
 * TCP (20):      sport=12345(3039) dport=80(0050) seq=1 ack=0
 *                doff=5 flags=SYN(02) window=FFFF cksum=0000
 */
.balign 4
fh_syn_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x28                               /* totlen: 40 */
    .byte   0x12, 0x34                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x06                               /* ttl=64, proto=TCP */
    .byte   0x00, 0x00                               /* IP checksum (filled at runtime) */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x01                   /* seq: 1 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 (20 bytes) */
    .byte   0x02                                     /* flags: SYN */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 (filled at runtime) */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 71-byte data frame with TSopt (5-byte payload "Hello")
 *
 * ETH(14) + IP(20) + TCP(32) + data(5) = 71
 * TCP options: NOP NOP Kind=8 Len=10 TSval(0) TSecr(0) — patched at runtime
 * IP totlen=57 (0x0039), doff=0x80, flags=ACK+PSH
 */
.balign 4
fh_data_ts_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x39                               /* totlen: 57 */
    .byte   0x12, 0x34                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x06                               /* ttl=64, proto=TCP */
    .byte   0x00, 0x00                               /* IP checksum (runtime) */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x02                   /* seq: 2 (runtime patched) */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 (runtime patched) */
    .byte   0x80                                     /* data offset: 8 (32 bytes) */
    .byte   0x18                                     /* flags: ACK+PSH */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 (runtime) */
    .byte   0x00, 0x00                               /* urgent: 0 */
    /* TCP options (12 bytes) */
    .byte   0x01, 0x01                               /* NOP, NOP */
    .byte   0x08, 0x0A                               /* Kind=8, Len=10 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* TSval (runtime) */
    .byte   0x00, 0x00, 0x00, 0x00                   /* TSecr */
    /* Payload (5 bytes) */
    .byte   0x48, 0x65, 0x6C, 0x6C, 0x6F            /* "Hello" */

name_fmp:   .asciz "func_multiport_listen"
name_fts:   .asciz "func_ts_synack"
name_fpr:   .asciz "func_paws_reject"
name_fic:   .asciz "func_icmp_teardown"

.section .bss
.balign 16
fh_scratch:
    .space  256
