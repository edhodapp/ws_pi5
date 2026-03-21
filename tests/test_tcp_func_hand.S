/*
 * test_tcp_func_hand.S — Hand-crafted functional tests for TCP features
 *
 * These test integration paths that the table-driven harness cannot reach:
 *   1. Multi-port listen (SYN to port 8080)
 *   2. Outgoing timestamps (SYN-ACK with TSopt)
 *   3. PAWS rejection (stale TSval drops segment)
 *   4. ICMP Destination Unreachable tears down connection via net_recv_one
 *   5. Full 3-way handshake with timestamps
 *   6. ICMP teardown with active retransmit timer
 *   7. Data ACK with timestamp echo
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
    bl      test_func_handshake_ts
    bl      test_func_icmp_rtx_timer
    bl      test_func_data_ack_ts_echo
    bl      test_func_icmp_proto_unreach
    bl      test_func_icmp_port_unreach
    ldp     x29, x30, [sp], #16
    ret

/* ===========================================================================
 * test_func_multiport — SYN to port 8080 when both 80 and 8080 are listening
 *
 * Setup: tcp_init, tcp_listen(80), tcp_listen(8080)
 * Send:  SYN to dport=8080 via tcp_handle
 * Verify: return=54, reply flags=SYN-ACK, reply ports correct,
 *         SYN_RCVD conn exists for 8080, port 80 LISTEN preserved
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

    /* Verify return = 58 (SYN-ACK reply: 54 + 4 MSS option) */
    cmp     w0, #62
    b.ne    .Lfmp_fail

    /* Verify reply flags = SYN|ACK (0x12) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_SYN_ACK
    b.ne    .Lfmp_fail

    /* Verify reply sport = 8080 NBO (0x901F as LE halfword) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    mov     w1, #0x901F
    cmp     w0, w1
    b.ne    .Lfmp_fail

    /* Verify reply dport = 12345 NBO (0x3930 as LE halfword) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]
    mov     w1, #0x3930
    cmp     w0, w1
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

    /* Verify slot 0 (port 80) still LISTEN */
    ldr     x0, =tcp_conn_table
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_LISTEN
    b.ne    .Lfmp_fail

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
 * Verify: return=66, reply doff=0x80, reply TSecr=0x12345678,
 *         new conn has TS_ENABLED=1
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

    /* Verify return = 74 (SYN-ACK with TSopt + MSS + WSCALE: 54+12+4+4) */
    cmp     w0, #74
    b.ne    .Lfts_fail

    /* Verify reply flags = SYN|ACK */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_SYN_ACK
    b.ne    .Lfts_fail

    /* Verify reply doff = 0xA0 (40 bytes: 20 base + 12 TS + 4 MSS + 4 WSCALE) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    cmp     w0, #0xA0
    b.ne    .Lfts_fail

    /* Verify reply IP TotalLength = 60 (0x003C NBO = 0x3C00 LE) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]
    mov     w1, #0x3C00
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

    /* Verify new connection (slot 1) has TS_ENABLED = 1.
       Slot 0 was LISTEN(80) → consumed by FSA. Handler allocates slot 1. */
    ldr     x0, =tcp_conn_table
    add     x0, x0, #TCONN_SIZE       /* slot 1 */
    ldrb    w1, [x0, #TCONN_TS_ENABLED]
    cmp     w1, #1
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
 * Verify: return=0, RCV_NXT unchanged, TS_RECENT preserved, state preserved
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

    /* Verify return > 0 (PAWS drop sends ACK per RFC 7323 §4.2) */
    cbz     w0, .Lfpr_fail

    /* Verify RCV_NXT unchanged */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    cmp     w0, w20
    b.ne    .Lfpr_fail

    /* Verify TS_RECENT still 5000 (not updated to stale value) */
    ldr     w0, [x19, #TCONN_TS_RECENT]
    ldr     w1, =5000
    cmp     w0, w1
    b.ne    .Lfpr_fail

    /* Verify state still ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
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
 * Setup: tcp_init, tcp_listen(80), pre-seed SYN_RCVD conn in slot 1
 * Send:  ICMP type 3 frame matching the conn via net_recv_one
 * Verify: return=0, conn state=CLOSED, slot 0 LISTEN preserved
 * (RFC 5461: ICMP errors are hard errors for SYN_RCVD, soft for ESTABLISHED)
 * =========================================================================== */
test_func_icmp_teardown:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Pre-seed slot 1 as SYN_RCVD (ICMP hard error only for opening state) */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE

    mov     w0, #TCPS_SYN_RCVD
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

    /* Verify slot 0 (port 80 LISTEN) preserved */
    ldr     x0, =tcp_conn_table
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_LISTEN
    b.ne    .Lfic_fail

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
 * test_func_handshake_ts — Full 3-way handshake with timestamps
 *
 * Setup: tcp_init, tcp_listen(80)
 * Phase 1: SYN w/TSopt (TSval=0x12345678) → SYN-ACK (66 bytes)
 * Phase 2: ACK w/TSopt (TSval=0x22222222) → return 0 (pure ACK)
 * Verify: slot 1 state=ESTABLISHED, TS_ENABLED=1,
 *         TS_RECENT=0x12345678 (from SYN, not updated by handshake ACK)
 * =========================================================================== */
test_func_handshake_ts:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    ldr     x19, =fh_scratch

    /* === Phase 1: SYN w/TSopt === */

    /* Copy SYN template → scratch (54 bytes) */
    ldr     x0, =fh_syn_template
    mov     x1, x19
    mov     w2, #54
.Lfhts_syn_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lfhts_syn_copy

    /* Extend to 66 bytes: set doff=0x80, IP totlen=52, add TSopt */
    mov     w0, #0x80
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    mov     w0, #0x3400
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* TSopt: NOP NOP Kind=8 Len=10 TSval=0x12345678(NBO) TSecr=0 */
    mov     w0, #0x01
    strb    w0, [x19, #54]
    strb    w0, [x19, #55]
    mov     w0, #0x08
    strb    w0, [x19, #56]
    mov     w0, #0x0A
    strb    w0, [x19, #57]
    mov     w0, #0x12
    strb    w0, [x19, #58]
    mov     w0, #0x34
    strb    w0, [x19, #59]
    mov     w0, #0x56
    strb    w0, [x19, #60]
    mov     w0, #0x78
    strb    w0, [x19, #61]
    str     wzr, [x19, #62]

    /* Recompute checksums */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #32
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Send SYN */
    mov     x0, x19
    mov     w1, #66
    bl      tcp_handle

    /* Verify SYN-ACK returned (54 + 12 TS + 4 MSS + 4 WSCALE = 74) */
    cmp     w0, #74
    b.ne    .Lfhts_fail

    /* Extract server ISN from SYN-ACK SEQ field (NBO) */
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]

    /* === Phase 2: Build ACK to complete handshake === */

    /* Re-copy SYN template → scratch (54 bytes) */
    ldr     x0, =fh_syn_template
    mov     x1, x19
    mov     w2, #54
.Lfhts_ack_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lfhts_ack_copy

    /* Extend to 66 bytes with TSopt */
    mov     w0, #0x80
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    mov     w0, #0x3400
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Flags = ACK (0x10) */
    mov     w0, #TCP_ACK_FLAG
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]

    /* SEQ = 2 (NBO) — client's ISN(1) + 1 after SYN */
    mov     w0, #2
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]

    /* ACK = server ISN + 1 (NBO) */
    rev     w0, w20              /* ISN host order */
    add     w0, w0, #1          /* ISN+1 */
    rev     w0, w0              /* back to NBO */
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* TSopt: NOP NOP Kind=8 Len=10 TSval=0x22222222 TSecr=0 */
    mov     w0, #0x01
    strb    w0, [x19, #54]
    strb    w0, [x19, #55]
    mov     w0, #0x08
    strb    w0, [x19, #56]
    mov     w0, #0x0A
    strb    w0, [x19, #57]
    mov     w0, #0x22
    strb    w0, [x19, #58]
    strb    w0, [x19, #59]
    strb    w0, [x19, #60]
    strb    w0, [x19, #61]
    str     wzr, [x19, #62]

    /* Recompute checksums */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #32
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Send ACK (completes handshake) */
    mov     x0, x19
    mov     w1, #66
    bl      tcp_handle

    /* Verify return = 0 (pure ACK, no reply) */
    cbnz    w0, .Lfhts_fail

    /* Verify slot 1 state = ESTABLISHED */
    ldr     x21, =tcp_conn_table
    add     x21, x21, #TCONN_SIZE     /* slot 1 */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfhts_fail

    /* Verify TS_ENABLED = 1 */
    ldrb    w0, [x21, #TCONN_TS_ENABLED]
    cmp     w0, #1
    b.ne    .Lfhts_fail

    /* Verify TS_RECENT = 0x12345678 (from SYN, not updated by handshake ACK
       since tcp_synrcvd_ack_handler doesn't process timestamps) */
    ldr     w0, [x21, #TCONN_TS_RECENT]
    ldr     w1, =0x12345678
    cmp     w0, w1
    b.ne    .Lfhts_fail

    ldr     x0, =name_fhts
    bl      test_pass
    b       .Lfhts_done
.Lfhts_fail:
    ldr     x0, =name_fhts
    bl      test_fail
.Lfhts_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===========================================================================
 * test_func_icmp_rtx_timer — ICMP teardown cancels active retransmit timer
 *
 * Setup: tcp_init, tcp_listen(80), init timer pool, pre-seed SYN_RCVD
 *        conn with active timer (TIMER_SLOT=0, RTXLEN=54, RTXCOUNT=2)
 * Send:  ICMP type 3 via net_recv_one
 * Verify: state=CLOSED, TIMER_SLOT=-1, RTXLEN=0, RTXCOUNT=0,
 *         timer pool slot callback cleared
 * (RFC 5461: ICMP hard error only for SYN_RCVD)
 * =========================================================================== */
test_func_icmp_rtx_timer:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Initialize timer pool and register it with TCP */
    ldr     x0, =fh_timer_pool
    mov     w1, #1                  /* 1 slot */
    bl      timer_pool_init

    ldr     x0, =fh_timer_pool
    bl      tcp_set_timer_pool

    /* Pre-seed slot 1 as SYN_RCVD (ICMP hard error only for opening state) */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE

    mov     w0, #TCPS_SYN_RCVD
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]
    mov     w0, #0x3930
    strh    w0, [x19, #TCONN_RPORT]
    ldr     w0, =0x0202000A
    str     w0, [x19, #TCONN_RIP]

    /* Pre-seed retransmit state */
    mov     w0, #54
    strh    w0, [x19, #TCONN_RTXLEN]
    mov     w0, #2
    strb    w0, [x19, #TCONN_RTXCOUNT]

    /* Arm a timer (far-future expiry so it won't fire) */
    ldr     x0, =fh_timer_pool
    mvn     x1, xzr                /* expiry = 0xFFFF...FFFF */
    ldr     x2, =tcp_retransmit_cb
    mov     x3, x19                 /* context = conn */
    bl      timer_set
    str     w0, [x19, #TCONN_TIMER_SLOT]  /* should be 0 */

    /* Build ICMP type 3 frame — reuse same pattern as test_func_icmp_teardown */
    ldr     x21, =fh_scratch

    /* Zero 70 bytes */
    mov     x0, x21
    mov     w1, #70
.Lfirt_zero:
    strb    wzr, [x0], #1
    subs    w1, w1, #1
    b.ne    .Lfirt_zero

    /* ETH header */
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
    mov     w0, #0x0008
    strh    w0, [x21, #ETH_TYPE]

    /* Outer IP */
    mov     w0, #0x45
    strb    w0, [x21, #ETH_PAYLOAD]
    mov     w0, #0x3800
    strh    w0, [x21, #(ETH_PAYLOAD + IP_TOTLEN)]
    mov     w0, #64
    strb    w0, [x21, #(ETH_PAYLOAD + IP_TTL)]
    mov     w0, #IP_PROTO_ICMP
    strb    w0, [x21, #(ETH_PAYLOAD + IP_PROTO)]
    ldr     w0, =0x0202000A
    str     w0, [x21, #(ETH_PAYLOAD + IP_SRC)]
    ldr     w0, =0x0F02000A
    str     w0, [x21, #(ETH_PAYLOAD + IP_DST)]
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x21, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* ICMP type 3 */
    mov     w0, #ICMP_DEST_UNREACHABLE
    strb    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    mov     w0, #1
    strb    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]

    /* Encapsulated IP + TCP */
    mov     w0, #0x45
    strb    w0, [x21, #42]
    mov     w0, #6
    strb    w0, [x21, #(42 + IP_PROTO)]
    ldr     w0, =0x0F02000A
    str     w0, [x21, #(42 + IP_SRC)]
    ldr     w0, =0x0202000A
    str     w0, [x21, #(42 + IP_DST)]
    mov     w0, #0x5000
    strh    w0, [x21, #(62 + TCP_SPORT)]
    mov     w0, #0x3930
    strh    w0, [x21, #(62 + TCP_DPORT)]

    /* ICMP checksum */
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]
    add     x0, x21, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #36
    bl      ip_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]

    /* Send through full stack */
    mov     x0, x21
    mov     w1, #70
    bl      net_recv_one

    /* Verify return = 0 */
    cbnz    w0, .Lfirt_fail

    /* Verify state = CLOSED */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfirt_fail

    /* Verify TIMER_SLOT = -1 (timer cancelled) */
    ldr     w0, [x19, #TCONN_TIMER_SLOT]
    cmn     w0, #1
    b.ne    .Lfirt_fail

    /* Verify RTXLEN = 0 */
    ldrh    w0, [x19, #TCONN_RTXLEN]
    cbnz    w0, .Lfirt_fail

    /* Verify RTXCOUNT = 0 */
    ldrb    w0, [x19, #TCONN_RTXCOUNT]
    cbnz    w0, .Lfirt_fail

    /* Verify timer pool slot 0 callback cleared (inactive) */
    ldr     x0, =fh_timer_pool
    ldr     x1, [x0, #(TPOOL_SLOTS + SLOT_CALLBACK)]
    cbnz    x1, .Lfirt_fail

    ldr     x0, =name_firt
    bl      test_pass
    b       .Lfirt_done
.Lfirt_fail:
    ldr     x0, =name_firt
    bl      test_fail
.Lfirt_done:
    /* Clean up: reset timer pool pointer to avoid affecting other tests */
    mov     x0, #0
    bl      tcp_set_timer_pool

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===========================================================================
 * test_func_data_ack_ts_echo — Data ACK echoes peer's TSval
 *
 * Setup: tcp_init, tcp_listen(80), pre-seed ESTABLISHED conn with
 *        TS_ENABLED=1, TS_RECENT=5000
 * Send:  71-byte data frame with TSval=6000 (> 5000, passes PAWS)
 * Verify: return=66 (ACK with TSopt), reply TSecr echoes 6000,
 *         TS_RECENT updated to 6000, RCV_NXT advanced by 5
 * =========================================================================== */
test_func_data_ack_ts_echo:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Pre-seed slot 1 as ESTABLISHED with timestamps */
    ldr     x20, =tcp_conn_table
    add     x20, x20, #TCONN_SIZE  /* slot 1 = conn pointer */

    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x20, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x20, #TCONN_LPORT]
    mov     w0, #0x3930
    strh    w0, [x20, #TCONN_RPORT]
    ldr     w0, =0x0202000A
    str     w0, [x20, #TCONN_RIP]
    ldr     w0, =0x41424345
    str     w0, [x20, #TCONN_SND_NXT]
    str     w0, [x20, #TCONN_SND_UNA]
    mov     w0, #2
    str     w0, [x20, #TCONN_RCV_NXT]
    mov     w0, #1
    strb    w0, [x20, #TCONN_TS_ENABLED]
    ldr     w0, =5000
    str     w0, [x20, #TCONN_TS_RECENT]
    mov     w0, #-1
    str     w0, [x20, #TCONN_TIMER_SLOT]
    strh    wzr, [x20, #TCONN_RXLEN]

    /* Copy peer MAC from template */
    ldr     x0, =fh_syn_template
    add     x0, x0, #ETH_SRC
    ldr     w1, [x0]
    str     w1, [x20, #TCONN_RMAC]
    ldrh    w1, [x0, #4]
    strh    w1, [x20, #(TCONN_RMAC + 4)]

    /* Build 71-byte data frame with TSopt, TSval=6000 (passes PAWS) */
    ldr     x0, =fh_data_ts_template
    ldr     x1, =fh_scratch
    mov     w2, #71
.Lfdae_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lfdae_copy

    ldr     x19, =fh_scratch

    /* SEQ = 2 (matches RCV_NXT), ACK = SND_NXT */
    mov     w0, #2
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    ldr     w0, =0x41424345
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* TSval = 6000 (host order) → rev for NBO at frame offset 58
       6000 = 0x1770, rev(0x00001770) = 0x70170000 */
    ldr     w0, =6000
    rev     w0, w0
    str     w0, [x19, #58]

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum (32 + 5 = 37 bytes) */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #37
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Call tcp_handle */
    mov     x0, x19
    mov     w1, #71
    bl      tcp_handle

    /* Verify return = 66 (ACK with TSopt) */
    cmp     w0, #66
    b.ne    .Lfdae_fail

    /* Verify reply flags = ACK */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_ACK_FLAG
    b.ne    .Lfdae_fail

    /* Verify reply doff = 0x80 (timestamps included) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    cmp     w0, #0x80
    b.ne    .Lfdae_fail

    /* Verify reply TSecr at frame offset 62 echoes TSval=6000 (NBO).
       6000 = 0x1770. NBO bytes: 00 00 17 70 */
    ldrb    w0, [x19, #62]
    cbnz    w0, .Lfdae_fail
    ldrb    w0, [x19, #63]
    cbnz    w0, .Lfdae_fail
    ldrb    w0, [x19, #64]
    cmp     w0, #0x17
    b.ne    .Lfdae_fail
    ldrb    w0, [x19, #65]
    cmp     w0, #0x70
    b.ne    .Lfdae_fail

    /* Verify TS_RECENT updated to 6000 */
    ldr     w0, [x20, #TCONN_TS_RECENT]
    ldr     w1, =6000
    cmp     w0, w1
    b.ne    .Lfdae_fail

    /* Verify RCV_NXT advanced by 5 (from 2 to 7) */
    ldr     w0, [x20, #TCONN_RCV_NXT]
    cmp     w0, #7
    b.ne    .Lfdae_fail

    ldr     x0, =name_fdae
    bl      test_pass
    b       .Lfdae_done
.Lfdae_fail:
    ldr     x0, =name_fdae
    bl      test_fail
.Lfdae_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===========================================================================
 * test_func_icmp_proto_unreach — unknown IP protocol through net_recv_one
 *   triggers ICMP Protocol Unreachable via icmp_send_error
 *
 * Setup: icmp_init, install fake send_fn in icmp_send_ctx
 * Send:  42-byte frame with IP proto=99 via ip_handle
 * Verify: fake send_fn called, tx_buf has type=3 code=2
 * =========================================================================== */
test_func_icmp_proto_unreach:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      icmp_init

    /* Install fake send function in icmp_send_ctx */
    ldr     x19, =icmp_send_ctx
    ldr     x0, =fh_icmp_tx_buf
    str     x0, [x19, #ICMPC_TX_BUF]
    ldr     x0, =fh_fake_icmp_send
    str     x0, [x19, #ICMPC_SEND_FN]
    str     xzr, [x19, #ICMPC_DWC2_BASE]
    str     xzr, [x19, #ICMPC_ECM_STATE]

    ldr     x0, =fh_icmp_send_count
    str     wzr, [x0]

    /* Build frame with unknown IP proto=99 in scratch buf */
    ldr     x19, =fh_scratch

    /* Zero 42 bytes */
    mov     x0, x19
    mov     w1, #42
.Lfpu_zero:
    strb    wzr, [x0], #1
    subs    w1, w1, #1
    b.ne    .Lfpu_zero

    /* ETH: dst=our MAC, src=peer, type=IPv4 */
    mov     w0, #0x02
    strb    w0, [x19, #ETH_DST]
    mov     w0, #0x01
    strb    w0, [x19, #(ETH_DST + 5)]
    mov     w0, #0xAA
    strb    w0, [x19, #ETH_SRC]
    mov     w0, #0x0008
    strh    w0, [x19, #ETH_TYPE]

    /* IP: ver/ihl=0x45, totlen=28, TTL=64, proto=99 */
    mov     w0, #0x45
    strb    w0, [x19, #ETH_PAYLOAD]
    mov     w0, #0x1C00
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]
    mov     w0, #64
    strb    w0, [x19, #(ETH_PAYLOAD + IP_TTL)]
    mov     w0, #99
    strb    w0, [x19, #(ETH_PAYLOAD + IP_PROTO)]
    ldr     w0, =0x0202000A
    str     w0, [x19, #(ETH_PAYLOAD + IP_SRC)]
    ldr     w0, =0x0F02000A
    str     w0, [x19, #(ETH_PAYLOAD + IP_DST)]

    /* Compute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Call ip_handle (not net_recv_one, to avoid MAC filter on zeroed MACs) */
    mov     x0, x19
    mov     w1, #42
    bl      ip_handle

    /* ip_handle returns 0 (dropped, but ICMP error was sent out-of-band) */
    cbnz    w0, .Lfpu_fail

    /* Verify fake send was called */
    ldr     x0, =fh_icmp_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfpu_fail

    /* Verify tx_buf has ICMP type=3, code=2 */
    ldr     x0, =fh_icmp_tx_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cmp     w1, #ICMP_DEST_UNREACHABLE
    b.ne    .Lfpu_fail
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]
    cmp     w1, #ICMP_CODE_PROTO_UNREACH
    b.ne    .Lfpu_fail

    ldr     x0, =name_fpu
    bl      test_pass
    b       .Lfpu_done
.Lfpu_fail:
    ldr     x0, =name_fpu
    bl      test_fail
.Lfpu_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ===========================================================================
 * test_func_icmp_port_unreach — unknown UDP port through ip_handle
 *   triggers ICMP Port Unreachable
 *
 * Send: valid UDP frame with dport=9999 (not echo/NTP)
 * Verify: fake send called with type=3 code=3
 * =========================================================================== */
test_func_icmp_port_unreach:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      icmp_init

    ldr     x19, =icmp_send_ctx
    ldr     x0, =fh_icmp_tx_buf
    str     x0, [x19, #ICMPC_TX_BUF]
    ldr     x0, =fh_fake_icmp_send
    str     x0, [x19, #ICMPC_SEND_FN]
    str     xzr, [x19, #ICMPC_DWC2_BASE]
    str     xzr, [x19, #ICMPC_ECM_STATE]

    ldr     x0, =fh_icmp_send_count
    str     wzr, [x0]

    /* Copy UDP-to-unknown-port template to scratch */
    ldr     x0, =fh_udp_unknown_port
    ldr     x1, =fh_scratch
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    /* Call ip_handle */
    ldr     x0, =fh_scratch
    mov     w1, #42
    bl      ip_handle

    /* Returns 0 */
    cbnz    w0, .Lfptu_fail

    /* Verify send called */
    ldr     x0, =fh_icmp_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfptu_fail

    /* Verify type=3, code=3 */
    ldr     x0, =fh_icmp_tx_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cmp     w1, #ICMP_DEST_UNREACHABLE
    b.ne    .Lfptu_fail
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]
    cmp     w1, #ICMP_CODE_PORT_UNREACH
    b.ne    .Lfptu_fail

    ldr     x0, =name_fptu
    bl      test_pass
    b       .Lfptu_done
.Lfptu_fail:
    ldr     x0, =name_fptu
    bl      test_fail
.Lfptu_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* Fake ICMP send function for functional tests */
fh_fake_icmp_send:
    ldr     x9, =fh_icmp_send_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]
    mov     w0, #0
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
name_fhts:  .asciz "func_handshake_ts"
name_firt:  .asciz "func_icmp_rtx_timer"
name_fdae:  .asciz "func_data_ack_ts_echo"
name_fpu:   .asciz "func_icmp_proto_unreach"
name_fptu:  .asciz "func_icmp_port_unreach"

/*
 * 42-byte UDP frame to port 9999 (unknown) from 10.0.2.2
 * ETH(14) + IP(20, proto=UDP, totlen=28) + UDP(8, dport=9999)
 */
.balign 4
fh_udp_unknown_port:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: peer */
    .byte   0x08, 0x00                               /* IPv4 */
    .byte   0x45, 0x00, 0x00, 0x1C                   /* ver, totlen=28 */
    .byte   0x12, 0x34, 0x00, 0x00                   /* id, flags */
    .byte   0x40, 0x11, 0x50, 0x8D                   /* TTL=64, proto=UDP, cksum */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src IP */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst IP */
    .byte   0x27, 0x0F, 0x27, 0x0F                   /* sport=9999, dport=9999 */
    .byte   0x00, 0x08, 0x99, 0xAF                   /* len=8, cksum=0xAF99 */

.section .bss
.balign 16
fh_scratch:
    .space  256

.balign 8
fh_timer_pool:
    .space  40              /* 8 header + 1×32 slot */

.balign 16
fh_icmp_tx_buf:
    .space  ICMP_ERROR_FRAME_LEN

.balign 4
fh_icmp_send_count:
    .word   0
