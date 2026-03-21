/*
 * tcp.S — TCP checksum, connection table, and packet handler
 *
 * Phase 1: validation + RST for unmatched segments
 * Phase 2: connection table, three-way handshake (LISTEN → SYN_RCVD → ESTABLISHED)
 *
 * tcp_checksum: ones' complement checksum with pseudo-header (RFC 793)
 * tcp_init:     zero connection table, set slot 0 to LISTEN on port 80
 * tcp_handle:   validation + connection lookup + state machine + RST fallback
 */

.include "net.inc"
.include "tcp.inc"
.include "vmio.inc"
.include "timer.inc"

.global tcp_checksum
.global tcp_build_reply
.global tcp_handle
.global tcp_init
.global tcp_conn_table
.global tcp_close
.global tcp_listen
.global tcp_send
.global tcp_rx_peek
.global tcp_rx_flush
.global tcp_set_timer_pool
.global tcp_timewait_cb
.global tcp_rxbuf_pool
.global tcp_window_update
.global tcp_send_ready
.global tcp_set_send_ctx
.global tcp_retransmit_cb
.global tcp_rtx_clear
.global tcp_icmp_err
.global tcp_rtxbuf_pool
.global tcp_send_ctx
.global tcp_parse_tsopt
.global tcp_build_frame
.global tcp_rst_allow
.global tcp_rst_tokens
.global tcp_rst_last_tick
.global tcp_fast_retransmit
.global tcp_idle_reaper_cb
.global tcp_start_reaper
.global tcp_persist_arm
.global tcp_persist_cb
.global tcp_timewait_fin_handler
.global tcp_timer_pool_ptr

.section .text

/*
 * tcp_checksum — TCP ones' complement checksum with IPv4 pseudo-header
 *
 * x0: frame buffer pointer (Ethernet + IP + TCP)
 * w1: TCP segment length in bytes (header + data)
 * Returns: w0 = 16-bit checksum (0 when verifying a valid segment)
 * Clobbers: x0-x3
 */
tcp_checksum:
    mov     w2, #0                  /* accumulator */

    /* Pseudo-header: IP src (2 halfwords) */
    ldrh    w3, [x0, #(ETH_PAYLOAD + IP_SRC)]
    add     w2, w2, w3
    ldrh    w3, [x0, #(ETH_PAYLOAD + IP_SRC + 2)]
    add     w2, w2, w3

    /* Pseudo-header: IP dst (2 halfwords) */
    ldrh    w3, [x0, #(ETH_PAYLOAD + IP_DST)]
    add     w2, w2, w3
    ldrh    w3, [x0, #(ETH_PAYLOAD + IP_DST + 2)]
    add     w2, w2, w3

    /* Pseudo-header: zero + protocol (TCP=6, LE halfword of 00 06) */
    mov     w3, #TCP_PROTO_LE
    add     w2, w2, w3

    /* Pseudo-header: TCP length (parameter → NBO LE halfword) */
    rev16   w3, w1
    uxth    w3, w3
    add     w2, w2, w3

    /* Point to TCP section for linear sum */
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN)

.Ltcp_cksum_loop:
    cmp     w1, #2
    b.lt    .Ltcp_cksum_odd
    ldrh    w3, [x0], #2
    add     w2, w2, w3
    sub     w1, w1, #2
    b       .Ltcp_cksum_loop

.Ltcp_cksum_odd:
    cbz     w1, .Ltcp_cksum_fold
    ldrb    w3, [x0]
    add     w2, w2, w3

.Ltcp_cksum_fold:
    /* Two-pass carry fold (32→16) */
    lsr     w3, w2, #16
    uxth    w2, w2
    add     w2, w2, w3
    lsr     w3, w2, #16
    add     w2, w2, w3

    /* Ones' complement */
    mvn     w0, w2
    uxth    w0, w0
    ret

/*
 * tcp_init — Zero connection table and initialize ISN secret
 *
 * No parameters, no return value.
 * Clobbers: x0-x2
 */
tcp_init:
    stp     x29, x30, [sp, #-16]!

    /* Zero connection table: TCP_CONN_TABLE_SIZE / 16 iterations */
    ldr     x0, =tcp_conn_table
    mov     w1, #(TCP_CONN_TABLE_SIZE / 16)
.Ltcp_init_zero:
    stp     xzr, xzr, [x0], #16
    subs    w1, w1, #1
    b.ne    .Ltcp_init_zero

    /* Initialize RST rate limiter */
    ldr     x0, =tcp_rst_tokens
    mov     w1, #TCP_RST_BURST
    str     w1, [x0]
    ldr     x0, =tcp_rst_last_tick
    str     xzr, [x0]

    bl      tcp_init_secret

    ldp     x29, x30, [sp], #16
    ret

/* Weak ISN secret seeder — overridden in fuzz harnesses */
.weak tcp_init_secret
tcp_init_secret:
    mrs     x0, CNTPCT_EL0
    ldr     x1, =tcp_isn_secret
    str     x0, [x1]
    ret

/*
 * tcp_listen — Start listening on a port
 *
 * w0: port number (host byte order)
 * Returns: w0 = slot index (0..15), or -1 if no free slots
 * Clobbers: x0-x3
 */
tcp_listen:
    rev16   w2, w0                  /* port → NBO */
    uxth    w2, w2

    /* Scan table for free slot (state == CLOSED) */
    ldr     x1, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ltl_scan:
    cbz     w3, .Ltl_full
    sub     w3, w3, #1
    ldrb    w0, [x1, #TCONN_STATE]
    cbz     w0, .Ltl_found
    add     x1, x1, #TCONN_SIZE
    b       .Ltl_scan

.Ltl_found:
    mov     w0, #TCPS_LISTEN
    strb    w0, [x1, #TCONN_STATE]
    strh    w2, [x1, #TCONN_LPORT]

    /* Return slot index: (addr - table_base) >> TCONN_SHIFT */
    ldr     x0, =tcp_conn_table
    sub     x0, x1, x0
    lsr     w0, w0, #TCONN_SHIFT
    ret

.Ltl_full:
    mov     w0, #-1
    ret

/*
 * tcp_rst_allow — Token bucket gate for RST generation
 *
 * Returns: w0 = 1 (allow) or 0 (deny)
 * Clobbers: x0-x4, x19-x20, x30
 *
 * Tokens refill to TCP_RST_BURST once per second (timer_freq ticks).
 * Each allowed RST consumes one token.
 */
tcp_rst_allow:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    /* Get current time and frequency */
    bl      timer_now
    mov     x19, x0                 /* x19 = now */
    bl      timer_freq
    mov     x20, x0                 /* x20 = freq */

    /* Check if refill needed: elapsed >= freq → refill */
    ldr     x0, =tcp_rst_last_tick
    ldr     x1, [x0]               /* last_tick */
    sub     x2, x19, x1            /* elapsed = now - last_tick */
    cmp     x2, x20                /* elapsed >= freq? */
    b.lo    .Lrst_no_refill

    /* Refill tokens */
    ldr     x1, =tcp_rst_tokens
    mov     w2, #TCP_RST_BURST
    str     w2, [x1]
    str     x19, [x0]              /* last_tick = now */

.Lrst_no_refill:
    ldr     x0, =tcp_rst_tokens
    ldr     w1, [x0]
    cbz     w1, .Lrst_deny
    sub     w1, w1, #1
    str     w1, [x0]
    mov     w0, #1
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

.Lrst_deny:
    mov     w0, #0
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * tcp_set_timer_pool — Store timer pool pointer for TCP use
 *
 * x0: timer pool pointer
 * Clobbers: x1
 */
tcp_set_timer_pool:
    ldr     x1, =tcp_timer_pool_ptr
    str     x0, [x1]
    ret

/*
 * tcp_set_send_ctx — Store I/O context for retransmit callback
 *
 * x0: dwc2_base, x1: ecm_state, x2: tx_buf, x3: send_fn
 * Clobbers: x4
 */
tcp_set_send_ctx:
    ldr     x4, =tcp_send_ctx
    str     x0, [x4, #TSCTX_DWC2_BASE]
    str     x1, [x4, #TSCTX_ECM_STATE]
    str     x2, [x4, #TSCTX_TX_BUF]
    str     x3, [x4, #TSCTX_SEND_FN]
    ret

/*
 * tcp_rtx_save — Save frame to retransmit buffer and arm timer
 *
 * x0: connection pointer
 * x1: frame pointer
 * w2: frame length
 * Clobbers: x0-x6, x19-x22, x30
 */
tcp_rtx_save:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* conn */
    mov     x20, x1                 /* frame src */
    mov     w21, w2                 /* frame_len */

    /* Compute slot index: (conn - tcp_conn_table) >> 7 */
    ldr     x3, =tcp_conn_table
    sub     x3, x19, x3
    lsr     x3, x3, #TCONN_SHIFT

    /* Dest = tcp_rtxbuf_pool + (slot << TCP_RTXBUF_SHIFT) */
    ldr     x4, =tcp_rtxbuf_pool
    add     x4, x4, x3, lsl #TCP_RTXBUF_SHIFT

    /* Byte-copy frame → rtxbuf */
    mov     x0, x4
    mov     x1, x20
    mov     w2, w21
.Lrtxs_copy:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lrtxs_copy

    /* Set RTXLEN, RTXCOUNT = 0 */
    strh    w21, [x19, #TCONN_RTXLEN]
    strb    wzr, [x19, #TCONN_RTXCOUNT]

    /* Arm retransmit timer */
    mov     x0, x19
    bl      tcp_rtx_arm

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_rtx_arm — Arm retransmit timer with exponential backoff
 *
 * x0: connection pointer
 * RTO = min(1 << min(RTXCOUNT, TCP_RTO_SHIFT_CAP), 60) seconds × CNTFRQ
 * Guard: skip if tcp_timer_pool_ptr == 0 (tests without timer pool)
 * Clobbers: x0-x6, x30
 */
/*
 * tcp_rtt_update — Update SRTT/RTTVAR/RTO per RFC 6298
 *
 * w0: measured RTT (R) in timer ticks
 * x1: connection pointer
 * Clobbers: w0-w5
 *
 * First sample:  SRTT = R, RTTVAR = R/2, RTO = SRTT + 4*RTTVAR
 * Subsequent:    RTTVAR = (3/4)*RTTVAR + (1/4)*|SRTT - R|
 *                SRTT = (7/8)*SRTT + (1/8)*R
 *                RTO = SRTT + 4*RTTVAR
 * Minimum RTO = freq (1 second in ticks)
 */
.global tcp_rtt_update
tcp_rtt_update:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x1                 /* x19 = conn */
    mov     w2, w0                  /* w2 = R */

    ldr     w3, [x19, #TCONN_SRTT]
    cbnz    w3, .Lrtt_subsequent

    /* First sample: SRTT = R, RTTVAR = R/2 */
    str     w2, [x19, #TCONN_SRTT]
    lsr     w0, w2, #1
    str     w0, [x19, #TCONN_RTTVAR]
    b       .Lrtt_compute_rto

.Lrtt_subsequent:
    /* |SRTT - R| */
    subs    w4, w3, w2
    cneg    w4, w4, mi              /* w4 = abs(SRTT - R) */

    /* RTTVAR = (3/4)*RTTVAR + (1/4)*|SRTT - R| */
    ldr     w5, [x19, #TCONN_RTTVAR]
    lsr     w0, w5, #2             /* RTTVAR/4 */
    sub     w5, w5, w0             /* 3/4 * RTTVAR */
    lsr     w4, w4, #2             /* |SRTT - R| / 4 */
    add     w5, w5, w4
    str     w5, [x19, #TCONN_RTTVAR]

    /* SRTT = (7/8)*SRTT + (1/8)*R */
    lsr     w0, w3, #3             /* SRTT/8 */
    sub     w3, w3, w0             /* 7/8 * SRTT */
    lsr     w2, w2, #3             /* R/8 */
    add     w3, w3, w2
    str     w3, [x19, #TCONN_SRTT]

.Lrtt_compute_rto:
    /* RTO = SRTT + 4*RTTVAR, minimum 1 second */
    ldr     w3, [x19, #TCONN_SRTT]
    ldr     w4, [x19, #TCONN_RTTVAR]
    lsl     w4, w4, #2             /* 4 * RTTVAR */
    add     w0, w3, w4             /* RTO = SRTT + 4*RTTVAR */

    /* Minimum RTO = 1 second = timer_freq ticks */
    bl      timer_freq
    cmp     w0, w0                 /* need to compare RTO vs freq... */
    /* w0 was clobbered by timer_freq. Recompute. */
    ldr     w3, [x19, #TCONN_SRTT]
    ldr     w4, [x19, #TCONN_RTTVAR]
    lsl     w4, w4, #2
    add     w3, w3, w4             /* w3 = RTO */
    cmp     w3, w0                 /* compare RTO vs freq (1 sec) */
    csel    w3, w3, w0, hs         /* max(RTO, 1 sec) */
    str     w3, [x19, #TCONN_RTO]

    ldp     x19, x30, [sp], #16
    ret

/*
 * tcp_sndbuf_build_frame — Build a TCP frame from circular send buffer data
 *
 * Reads up to MSS bytes starting from the tail of the send buffer
 * (the oldest unACKed data) and builds a PSH+ACK frame.
 *
 * x0: connection pointer
 * x1: frame buffer (output)
 * Returns: w0 = frame length, or 0 if no data to send
 * Clobbers: x0-x6, x19-x24, x30
 */
.global tcp_sndbuf_build_frame
tcp_sndbuf_build_frame:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* conn */
    mov     x23, x1                 /* frame buf */

    /* How much data is in flight? */
    ldr     w0, [x19, #TCONN_SND_NXT]
    ldr     w1, [x19, #TCONN_SND_UNA]
    sub     w21, w0, w1             /* w21 = in_flight */
    cbz     w21, .Lsbf_none

    /* Segment size = min(in_flight, MSS) */
    ldrh    w0, [x19, #TCONN_PEER_MSS]
    cmp     w21, w0
    csel    w21, w21, w0, lo        /* w21 = segment size */

    /* Copy from send buffer to a temp area on stack */
    sub     sp, sp, w21, uxtw       /* allocate stack space for payload */
    mov     x22, sp                 /* x22 = payload temp */

    /* Compute send buffer base + tail */
    ldr     x0, =tcp_conn_table
    sub     x0, x19, x0
    lsr     x0, x0, #TCONN_SHIFT
    ldr     x1, =tcp_sndbuf_pool
    add     x1, x1, x0, lsl #TCP_SNDBUF_SHIFT  /* buf base */
    ldr     w2, [x19, #TCONN_SND_BUF_TAIL]

    /* Circular copy: tail to temp */
    mov     w3, #0
.Lsbf_copy:
    cmp     w3, w21
    b.hs    .Lsbf_copy_done
    add     w4, w2, w3
    and     w4, w4, #TCP_SNDBUF_MASK
    ldrb    w5, [x1, x4]
    strb    w5, [x22, x3]
    add     w3, w3, #1
    b       .Lsbf_copy
.Lsbf_copy_done:

    /* Temporarily set SND_NXT = SND_UNA (so tcp_build_frame uses UNA as SEQ) */
    ldr     w24, [x19, #TCONN_SND_NXT]  /* save real SND_NXT */
    ldr     w0, [x19, #TCONN_SND_UNA]
    str     w0, [x19, #TCONN_SND_NXT]

    /* Build frame: tcp_build_frame(conn, frame, PSH+ACK, payload, len) */
    mov     x0, x19
    mov     x1, x23
    mov     w2, #TCP_PSH_ACK
    mov     x3, x22
    mov     w4, w21
    bl      tcp_build_frame

    mov     w22, w0                 /* frame_len */

    /* Restore SND_NXT */
    str     w24, [x19, #TCONN_SND_NXT]

    /* Deallocate stack payload temp */
    add     sp, sp, w21, uxtw

    mov     w0, w22
    b       .Lsbf_done

.Lsbf_none:
    mov     w0, #0

.Lsbf_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

tcp_rtx_arm:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x0                 /* conn */

    /* Guard: skip if no timer pool */
    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Lrtxa_done
    mov     x20, x0                 /* x20 = timer pool */

    /* Use RTO from TCONN (RFC 6298). If RTO == 0, use initial 1 second. */
    ldr     w21, [x19, #TCONN_RTO]
    cbnz    w21, .Lrtxa_have_rto
    bl      timer_freq
    mov     w21, w0                 /* initial RTO = 1 second in ticks */
    str     w21, [x19, #TCONN_RTO]
.Lrtxa_have_rto:

    /* Record send timestamp for RTT measurement */
    bl      timer_now
    str     x0, [x19, #TCONN_SEND_TICK]
    add     x1, x0, x21            /* x1 = expiry = now + RTO */

    /* timer_set(pool, expiry, callback, conn) */
    mov     x0, x20
    /* x1 = expiry */
    ldr     x2, =tcp_retransmit_cb
    mov     x3, x19
    bl      timer_set
    str     w0, [x19, #TCONN_TIMER_SLOT]

.Lrtxa_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_rtx_clear — Cancel retransmit timer and clear state
 *
 * x0: connection pointer
 * Clobbers: x0-x3, x19-x20, x30
 */
tcp_rtx_clear:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    mov     x19, x0

    /* Cancel timer if armed */
    ldr     w1, [x19, #TCONN_TIMER_SLOT]
    cmn     w1, #1
    b.eq    .Lrtxc_no_timer

    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Lrtxc_no_timer
    /* w1 = slot index, x0 = pool */
    bl      timer_cancel

.Lrtxc_no_timer:
    /* Clear retransmit state */
    strh    wzr, [x19, #TCONN_RTXLEN]
    strb    wzr, [x19, #TCONN_RTXCOUNT]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * tcp_icmp_err — Handle ICMP Destination Unreachable for TCP connections
 *
 * x0: frame pointer (full Ethernet frame with ICMP type 3)
 * w1: frame length
 * Returns: w0 = 0 (never generates a reply)
 * Clobbers: x0-x6, x19-x22, x30
 *
 * Extracts the encapsulated TCP 4-tuple from the ICMP payload,
 * scans the connection table for a match, and tears down the connection.
 * Minimum frame: ETH(14) + IP(20) + ICMP(8) + encap_IP(20) + encap_TCP(8) = 70
 */
tcp_icmp_err:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    /* Minimum length check */
    cmp     w1, #70
    b.lt    .Licmpe_done

    /* Encapsulated headers start at ETH(14) + IP(20) + ICMP_HDR(8) = 42 */
    /* Encap IP src = our IP (we sent the original packet) */
    /* Encap IP dst = peer IP */
    /* Encap TCP sport = our port (offset 42+20=62) */
    /* Encap TCP dport = peer port (offset 42+22=64) */
    ldr     w19, [x0, #(42 + IP_SRC)]          /* encap IP src = our IP */
    ldr     w20, [x0, #(42 + IP_DST)]          /* encap IP dst = peer IP */
    ldrh    w21, [x0, #(42 + IP_HDR_MIN + TCP_SPORT)]  /* encap TCP sport = our port */
    ldrh    w22, [x0, #(42 + IP_HDR_MIN + TCP_DPORT)]  /* encap TCP dport = peer port */

    /* Scan connection table for match */
    ldr     x2, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Licmpe_scan:
    cbz     w3, .Licmpe_done
    sub     w3, w3, #1
    ldrb    w4, [x2, #TCONN_STATE]
    cbz     w4, .Licmpe_next        /* CLOSED → skip */
    cmp     w4, #TCPS_LISTEN
    b.eq    .Licmpe_next            /* LISTEN → skip */

    /* Match lport, rport, rip */
    ldrh    w4, [x2, #TCONN_LPORT]
    cmp     w4, w21
    b.ne    .Licmpe_next
    ldrh    w4, [x2, #TCONN_RPORT]
    cmp     w4, w22
    b.ne    .Licmpe_next
    ldr     w4, [x2, #TCONN_RIP]
    cmp     w4, w20
    b.ne    .Licmpe_next

    /* Match found — extract ICMP code to decide hard vs soft error */
    ldrb    w5, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]

    /* Codes 2 (Protocol) and 3 (Port Unreachable): hard error for all states */
    cmp     w5, #ICMP_CODE_PROTO_UNREACH
    b.eq    .Licmpe_hard_close
    cmp     w5, #ICMP_CODE_PORT_UNREACH
    b.eq    .Licmpe_hard_close

    /* All other codes: soft error per RFC 5461 — only hard-close SYN_RCVD */
    ldrb    w4, [x2, #TCONN_STATE]
    cmp     w4, #TCPS_SYN_RCVD
    b.ne    .Licmpe_done

.Licmpe_hard_close:
    mov     x19, x2
    mov     x0, x2
    bl      tcp_rtx_clear
    strb    wzr, [x19, #TCONN_STATE]
    b       .Licmpe_done

.Licmpe_next:
    add     x2, x2, #TCONN_SIZE
    b       .Licmpe_scan

.Licmpe_done:
    mov     w0, #0
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_retransmit_cb — Timer callback: retransmit saved frame
 *
 * x0: connection pointer (timer context)
 * Loads send context, copies saved frame to tx_buf, calls send_fn,
 * increments retry count, re-arms with backoff.
 * Max retries → set CLOSED.
 * Clobbers: x0-x6, x19-x24, x30
 */
tcp_retransmit_cb:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* x19 = conn */

    /* Guard: if state is CLOSED or LISTEN, stale timer — return */
    ldrb    w0, [x19, #TCONN_STATE]
    cbz     w0, .Lrtxcb_done        /* CLOSED */
    cmp     w0, #TCPS_LISTEN
    b.eq    .Lrtxcb_done

    /* Check retry count */
    ldrb    w0, [x19, #TCONN_RTXCOUNT]
    cmp     w0, #TCP_MAX_RETRIES
    b.hs    .Lrtxcb_giveup

    /* Multiplicative decrease: ssthresh = max(cwnd/2, 2*MSS), cwnd = MSS */
    ldr     w0, [x19, #TCONN_CWND]
    lsr     w0, w0, #1              /* cwnd / 2 */
    ldrh    w1, [x19, #TCONN_PEER_MSS]
    lsl     w2, w1, #1              /* 2 * MSS */
    cmp     w0, w2
    csel    w0, w0, w2, hs          /* max(cwnd/2, 2*MSS) */
    str     w0, [x19, #TCONN_SSTHRESH]
    str     w1, [x19, #TCONN_CWND]  /* restart slow start */
    strb    wzr, [x19, #TCONN_DUP_ACK_CNT] /* reset dup ACK count */

    /* Double RTO on timeout (RFC 6298 §5.5), cap at 60 seconds */
    ldr     w21, [x19, #TCONN_RTO]
    lsl     w21, w21, #1           /* doubled RTO */
    bl      timer_freq
    mov     x1, #60
    mul     x1, x0, x1             /* max_rto = 60 * freq */
    cmp     w21, w1
    csel    w21, w21, w1, lo       /* min(doubled, max) */
    str     w21, [x19, #TCONN_RTO]

    /* Load send context */
    ldr     x20, =tcp_send_ctx
    ldr     x1, [x20, #TSCTX_SEND_FN]
    cbz     x1, .Lrtxcb_done       /* send_fn not set up → return */

    /* Try send buffer first (data segments) */
    mov     x0, x19
    ldr     x1, [x20, #TSCTX_TX_BUF]
    bl      tcp_sndbuf_build_frame
    cbnz    w0, .Lrtxcb_have_frame

    /* No data in send buffer — fall back to rtxbuf (SYN-ACK/FIN) */
    ldrh    w0, [x19, #TCONN_RTXLEN]
    cbz     w0, .Lrtxcb_done       /* nothing to retransmit */

    ldr     x2, =tcp_conn_table
    sub     x2, x19, x2
    lsr     x2, x2, #TCONN_SHIFT
    ldr     x3, =tcp_rtxbuf_pool
    add     x3, x3, x2, lsl #TCP_RTXBUF_SHIFT
    ldr     x4, [x20, #TSCTX_TX_BUF]
    mov     w5, w0
.Lrtxcb_rtxcopy:
    cbz     w5, .Lrtxcb_have_frame_w0
    ldrb    w6, [x3], #1
    strb    w6, [x4], #1
    sub     w5, w5, #1
    b       .Lrtxcb_rtxcopy
.Lrtxcb_have_frame_w0:
    /* w0 still has RTXLEN = frame_len */

.Lrtxcb_have_frame:
    mov     w21, w0                 /* frame_len */

    /* Send */
    ldr     x0, [x20, #TSCTX_DWC2_BASE]
    ldr     x1, [x20, #TSCTX_ECM_STATE]
    ldr     x2, [x20, #TSCTX_TX_BUF]
    mov     w3, w21
    ldr     x4, [x20, #TSCTX_SEND_FN]
    blr     x4

    /* Increment RTXCOUNT */
    ldrb    w0, [x19, #TCONN_RTXCOUNT]
    add     w0, w0, #1
    strb    w0, [x19, #TCONN_RTXCOUNT]

    /* Re-arm timer with backoff */
    mov     x0, x19
    bl      tcp_rtx_arm

    b       .Lrtxcb_done

.Lrtxcb_giveup:
    /* Max retries exceeded → close connection */
    strb    wzr, [x19, #TCONN_STATE]
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

.Lrtxcb_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_build_reply — Build a TCP reply by swapping addresses and setting fields
 *
 * x0: frame buffer pointer
 * w1: SEQ (NBO), w2: ACK (NBO), w3: flags, w4: window (NBO LE halfword)
 * x5: connection pointer (0 = no timestamps)
 * Returns: w0 = 54 (no TS) or 66 (with TS)
 * Clobbers: x0-x6, x19-x23, x30
 */
tcp_build_reply:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    str     x23, [sp, #48]

    mov     x19, x0                 /* x19 = frame */
    mov     w20, w1                 /* w20 = SEQ (NBO) */
    mov     w21, w2                 /* w21 = ACK (NBO) */
    mov     w22, w3                 /* w22 = flags */
    mov     x23, x5                 /* x23 = conn (may be 0) */

    /* Store window early (TCP_WINDOW unaffected by ETH/IP ops) */
    strh    w4, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]

    /* 1. Swap ETH dst ↔ src (4+2 byte pattern) */
    ldr     w3, [x19, #ETH_DST]
    ldrh    w4, [x19, #(ETH_DST + 4)]
    ldr     w5, [x19, #ETH_SRC]
    ldrh    w6, [x19, #(ETH_SRC + 4)]
    str     w5, [x19, #ETH_DST]
    strh    w6, [x19, #(ETH_DST + 4)]
    str     w3, [x19, #ETH_SRC]
    strh    w4, [x19, #(ETH_SRC + 4)]

    /* 2. Swap IP src ↔ dst */
    ldr     w3, [x19, #(ETH_PAYLOAD + IP_SRC)]
    ldr     w4, [x19, #(ETH_PAYLOAD + IP_DST)]
    str     w4, [x19, #(ETH_PAYLOAD + IP_SRC)]
    str     w3, [x19, #(ETH_PAYLOAD + IP_DST)]

    /* 3. IP TTL = 64 */
    mov     w3, #IP_DEFAULT_TTL
    strb    w3, [x19, #(ETH_PAYLOAD + IP_TTL)]

    /* 5. Zero IP ID */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_ID)]

    /* 6. IP flags/frag: DF bit set (0x4000 NBO = 0x0040 LE) */
    mov     w3, #0x0040
    strh    w3, [x19, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]

    /* 8. Swap TCP sport ↔ dport */
    ldrh    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    ldrh    w4, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]
    strh    w4, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    strh    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]

    /* 9. Write SEQ, ACK */
    str     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    str     w21, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* 10. Flags */
    strb    w22, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]

    /* 11. Urgent = 0 (window already stored) */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_URGENT)]

    /* Decide timestamps: x23 != 0 && TS_ENABLED != 0 */
    cbz     x23, .Lbr_no_ts
    ldrb    w3, [x23, #TCONN_TS_ENABLED]
    cbz     w3, .Lbr_no_ts

    /* --- Timestamps enabled path --- */

    /* Data offset = 0x80 (8 words = 32 bytes) */
    mov     w3, #0x80
    strb    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* IP TotalLength = 52 (0x0034 BE → 0x3400 LE) */
    mov     w3, #0x3400
    strh    w3, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Insert TSopt at TCP offset 20: NOP NOP Kind=8 Len=10 TSval TSecr */
    mov     w3, #0x01
    strb    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + 20)]     /* NOP */
    strb    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + 21)]     /* NOP */
    mov     w3, #TCP_OPT_TIMESTAMPS
    strb    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + 22)]     /* Kind=8 */
    mov     w3, #TCP_OPT_TS_LEN
    strb    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + 23)]     /* Len=10 */

    /* TSval = timer_now() >> 16, then rev to NBO */
    bl      timer_now
    lsr     x3, x0, #16
    rev     w3, w3
    str     w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + 24)]     /* TSval (NBO) */

    /* TSecr = rev(TS_RECENT) to NBO */
    ldr     w3, [x23, #TCONN_TS_RECENT]
    rev     w3, w3
    str     w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + 28)]     /* TSecr (NBO) */

    /* IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* TCP checksum over 32 bytes */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #32
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     w0, #TCP_TS_FRAME_LEN   /* 66 */
    b       .Lbr_done

.Lbr_no_ts:
    /* --- No timestamps path --- */

    /* Data offset = 0x50 (5 words = 20 bytes) */
    mov     w3, #0x50
    strb    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* IP TotalLength = 40 (0x0028 BE → 0x2800 LE) */
    mov     w3, #0x2800
    strh    w3, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* TCP checksum over 20 bytes */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #TCP_HDR_MIN
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     w0, #TCP_RST_FRAME_LEN  /* 54 */

.Lbr_done:
    ldr     x23, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * tcp_classify_event — Map TCP flags to FSA event code
 *
 * w0: TCP flags byte
 * Returns: w0 = event code (TCP_EVT_*) or -1 if unclassifiable
 * Clobbers: w0-w1
 * Leaf function, no stack frame.
 */
tcp_classify_event:
    /* Priority: RST > SYN > FIN > ACK */
    tst     w0, #TCP_RST
    b.ne    .Lcls_rst
    tst     w0, #TCP_SYN
    b.ne    .Lcls_syn
    tst     w0, #TCP_FIN
    b.ne    .Lcls_fin
    tst     w0, #TCP_ACK_FLAG
    b.ne    .Lcls_ack
    /* No recognized flag → -1 */
    mov     w0, #-1
    ret
.Lcls_rst:
    mov     w0, #TCP_EVT_RST
    ret
.Lcls_syn:
    /* SYN set — check ACK to distinguish SYN vs SYNACK */
    tst     w0, #TCP_ACK_FLAG
    b.ne    .Lcls_synack
    mov     w0, #TCP_EVT_SYN
    ret
.Lcls_synack:
    mov     w0, #TCP_EVT_SYNACK
    ret
.Lcls_fin:
    mov     w0, #TCP_EVT_FIN
    ret
.Lcls_ack:
    mov     w0, #TCP_EVT_ACK
    ret

/*
 * tcp_handle — TCP packet handler with connection state machine
 *
 * x0: frame buffer pointer (Ethernet + IP + TCP)
 * w1: frame length (ETH_HDR_LEN + IP.TotalLength)
 * Returns: w0 = reply length (54 for RST/SYN-ACK) or 0 (dropped)
 * Clobbers: x0-x6, x19-x24, x30
 *
 * Flow:
 *   1. Validate TCP header (length, data offset, checksum)
 *   2. Scan connection table for exact match or LISTEN fallback
 *   3. Dispatch by state: LISTEN→SYN-ACK, SYN_RCVD→ESTABLISHED, etc.
 *   4. Unmatched → RST (Phase 1 behavior preserved)
 */
tcp_handle:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* x19 = frame */
    mov     w20, w1                 /* w20 = frame_len */

    /* 1. tcp_section_len = frame_len - 34; must be >= 20 */
    sub     w21, w20, #(ETH_HDR_LEN + IP_HDR_MIN)
    cmp     w21, #TCP_HDR_MIN
    b.lt    .Ltcp_drop

    /* 2. Data offset: high nibble of byte 12, in 32-bit words */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    lsr     w22, w0, #4             /* words */
    lsl     w22, w22, #2            /* w22 = header_len bytes */
    cmp     w22, #TCP_HDR_MIN
    b.lt    .Ltcp_drop
    cmp     w22, w21
    b.gt    .Ltcp_drop

    /* 3. Checksum verification */
    mov     x0, x19
    mov     w1, w21
    bl      tcp_checksum
    cbnz    w0, .Ltcp_drop

    /* --- Connection table lookup --- */

    /* Pre-load match keys from frame */
    ldr     w4, [x19, #(ETH_PAYLOAD + IP_SRC)]                  /* rip (NBO) */
    ldrh    w5, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]  /* rport (NBO) */
    ldrh    w6, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]  /* lport (NBO) */

    /* Single-pass scan: exact match takes priority, track LISTEN fallback */
    ldr     x23, =tcp_conn_table
    mov     x24, #0                 /* listen_match = NULL */
    mov     w3, #TCP_MAX_CONNS

.Ltcp_scan:
    cbz     w3, .Ltcp_scan_done
    sub     w3, w3, #1
    ldrb    w0, [x23, #TCONN_STATE]
    cbz     w0, .Ltcp_scan_next     /* CLOSED → skip */
    cmp     w0, #TCPS_LISTEN
    b.eq    .Ltcp_check_listen
    /* Exact match: all three fields must match */
    ldrh    w1, [x23, #TCONN_LPORT]
    cmp     w1, w6
    b.ne    .Ltcp_scan_next
    ldrh    w1, [x23, #TCONN_RPORT]
    cmp     w1, w5
    b.ne    .Ltcp_scan_next
    ldr     w1, [x23, #TCONN_RIP]
    cmp     w1, w4
    b.ne    .Ltcp_scan_next
    /* Exact match → FSA dispatch (w0 = state) */
    b       .Ltcp_fsa_dispatch

.Ltcp_check_listen:
    ldrh    w1, [x23, #TCONN_LPORT]
    cmp     w1, w6
    b.ne    .Ltcp_scan_next
    mov     x24, x23               /* remember LISTEN slot */
    /* fall through — keep scanning for exact matches */

.Ltcp_scan_next:
    add     x23, x23, #TCONN_SIZE
    b       .Ltcp_scan

.Ltcp_scan_done:
    /* No exact match — use LISTEN fallback if present */
    cbz     x24, .Ltcp_no_conn
    mov     x23, x24                /* conn = LISTEN slot */
    mov     w20, #TCPS_LISTEN
    b       .Ltcp_fsa_classify

.Ltcp_fsa_dispatch:
    /* Exact match: w0 = state from scan */
    mov     w20, w0

.Ltcp_fsa_classify:
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    bl      tcp_classify_event
    cmn     w0, #1
    b.eq    .Ltcp_no_conn

    /* RST SEQ validation (RFC 5961) — only for connected states */
    cmp     w0, #TCP_EVT_RST
    b.ne    .Ltcp_fsa_lookup

    /* Check: (SEG.SEQ - RCV_NXT) < RCV_WND (unsigned) */
    ldr     w4, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w4, w4
    ldr     w5, [x23, #TCONN_RCV_NXT]
    /* Compute dynamic RCV_WND = RXBUF_SIZE - RXLEN */
    ldrh    w6, [x23, #TCONN_RXLEN]
    mov     w7, #TCP_RXBUF_SIZE
    sub     w6, w7, w6
    sub     w4, w4, w5
    cmp     w4, w6
    b.hs    .Ltcp_drop              /* out of window → silently drop */

.Ltcp_fsa_lookup:
    /* Table lookup: index = state * TCP_N_EVENTS + evt */
    mov     w1, #TCP_N_EVENTS
    madd    w0, w20, w1, w0         /* state * 5 + evt */
    lsl     x0, x0, #4             /* * TRANS_SIZE (16) */
    ldr     x1, =tcp_fsa_table
    add     x1, x1, x0

    ldr     x16, [x1, #TRANS_HANDLER]
    cbz     x16, .Ltcp_no_conn     /* no handler → RST */
    ldr     w3, [x1, #TRANS_NEXT]

    /* Write next_state (rollback if handler fails) */
    strb    w3, [x23, #TCONN_STATE]

    /* handler(conn, frame, section_len, header_len) */
    mov     x0, x23
    mov     x1, x19
    mov     w2, w21
    mov     w3, w22
    blr     x16

    cmn     w0, #1
    b.ne    .Ltcp_handler_ok

    /* Handler failed: rollback state, then generate RST */
    strb    w20, [x23, #TCONN_STATE]
    b       .Ltcp_no_conn

.Ltcp_handler_ok:

    /* Update activity timestamp after successful handler */
    mov     w24, w0                 /* save handler return value */
    bl      timer_now
    str     x0, [x23, #TCONN_LAST_ACTIVE]
    mov     w0, w24                 /* restore return value */
    b       .Ltcp_done

.Ltcp_no_conn:
    /* --- RST generation (RFC 793 §3.4, Phase 1 behavior) --- */
    ldrb    w2, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]

    /* RFC 793 §3.4: never send RST in response to RST */
    tst     w2, #TCP_RST
    b.ne    .Ltcp_drop

    /* Rate limit RST replies */
    bl      tcp_rst_allow
    cbz     w0, .Ltcp_drop

    /* Re-load flags (clobbered by call) */
    ldrb    w2, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]

    tst     w2, #TCP_ACK_FLAG
    b.ne    .Ltcp_rst_has_ack

    /* No ACK → RST+ACK, SEQ=0, ACK=SEG.SEQ+SEG.LEN */
    sub     w3, w21, w22            /* data_bytes */
    tst     w2, #TCP_SYN
    cinc    w3, w3, ne
    tst     w2, #TCP_FIN
    cinc    w3, w3, ne

    /* ACK = rev(rev(SEG.SEQ) + SEG.LEN) */
    ldr     w4, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w4, w4
    add     w4, w4, w3
    rev     w2, w4                  /* w2 = reply ACK (NBO) */

    mov     x0, x19                 /* frame */
    mov     w1, #0                  /* SEQ = 0 */
    /* w2 = ACK */
    mov     w3, #TCP_RST_ACK        /* flags */
    mov     w4, #0                  /* window */
    mov     x5, #0                  /* no conn → no timestamps */
    bl      tcp_build_reply
    b       .Ltcp_done

.Ltcp_rst_has_ack:
    /* ACK set → RST, SEQ=SEG.ACK */
    mov     x0, x19                 /* frame */
    ldr     w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]  /* SEQ = SEG.ACK */
    mov     w2, #0                  /* ACK = 0 */
    mov     w3, #TCP_RST            /* flags */
    mov     w4, #0                  /* window */
    mov     x5, #0                  /* no conn → no timestamps */
    bl      tcp_build_reply
    b       .Ltcp_done

.Ltcp_drop:
    mov     w0, #0

.Ltcp_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* --- FSA handler functions ---
 *
 * Handler interface:
 *   x0: connection entry pointer
 *   x1: frame pointer
 *   w2: tcp_section_len
 *   w3: tcp_header_len
 *   Returns: w0 = reply frame length, 0 = no reply, -1 = generate RST
 */

/*
 * tcp_listen_syn_handler — Allocate connection, send SYN-ACK
 *
 * x0 = LISTEN slot (for lport), x1 = frame
 * Scans for free slot, populates connection, builds SYN-ACK reply.
 * Returns: 54 (SYN-ACK), or -1 (no free slot → RST)
 */
tcp_listen_syn_handler:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x1                 /* frame */
    mov     x20, x0                 /* LISTEN slot */

    /* Scan table for free slot (state == CLOSED) */
    ldr     x21, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Llsyn_alloc_scan:
    cbz     w3, .Llsyn_no_slot
    sub     w3, w3, #1
    ldrb    w0, [x21, #TCONN_STATE]
    cbz     w0, .Llsyn_alloc_found
    add     x21, x21, #TCONN_SIZE
    b       .Llsyn_alloc_scan

.Llsyn_no_slot:
    /* Second pass: evict oldest SYN_RCVD (likely from SYN flood) */
    ldr     x21, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Llsyn_evict_scan:
    cbz     w3, .Llsyn_really_full
    sub     w3, w3, #1
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_SYN_RCVD
    b.eq    .Llsyn_evict_found
    add     x21, x21, #TCONN_SIZE
    b       .Llsyn_evict_scan

.Llsyn_really_full:
    /* No SYN_RCVD to evict — truly full */
    mov     w0, #-1
    b       .Llsyn_done

.Llsyn_evict_found:
    /* Clean up evicted connection */
    mov     x0, x21
    bl      tcp_rtx_clear
    strb    wzr, [x21, #TCONN_STATE]  /* mark CLOSED */
    b       .Llsyn_alloc_found        /* reuse x21 as free slot */

.Llsyn_alloc_found:
    /* x21 = free slot */
    /* tcp_isn(lport, rport, lip, rip) — all NBO */
    ldrh    w0, [x20, #TCONN_LPORT]                              /* our port */
    ldrh    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]   /* peer port */
    ldr     w2, [x19, #(ETH_PAYLOAD + IP_DST)]                   /* our IP */
    ldr     w3, [x19, #(ETH_PAYLOAD + IP_SRC)]                   /* peer IP */
    bl      tcp_isn
    mov     w22, w0                 /* w22 = ISN */

    /* Populate new connection */
    mov     w0, #TCPS_SYN_RCVD
    strb    w0, [x21, #TCONN_STATE]
    strh    wzr, [x21, #TCONN_RXLEN]
    strh    wzr, [x21, #TCONN_RTXLEN]
    strb    wzr, [x21, #TCONN_RTXCOUNT]
    mov     w0, #-1
    str     w0, [x21, #TCONN_TIMER_SLOT]

    /* Initialize MSS/congestion/OOO fields */
    mov     w0, #TCP_DEFAULT_MSS        /* RFC 1122 default MSS = 536 */
    strh    w0, [x21, #TCONN_PEER_MSS]
    str     w0, [x21, #TCONN_CWND]      /* initial cwnd = 1 MSS */
    mov     w0, #0x40000                /* 256 KB = initial ssthresh */
    str     w0, [x21, #TCONN_SSTHRESH]
    strb    wzr, [x21, #TCONN_DUP_ACK_CNT]
    strb    wzr, [x21, #TCONN_OOO_COUNT]

    ldrh    w0, [x20, #TCONN_LPORT]
    strh    w0, [x21, #TCONN_LPORT]

    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    strh    w0, [x21, #TCONN_RPORT]

    ldr     w0, [x19, #(ETH_PAYLOAD + IP_SRC)]
    str     w0, [x21, #TCONN_RIP]

    /* Capture peer MAC from ETH_SRC (6 bytes: 4 + 2) */
    ldr     w0, [x19, #ETH_SRC]
    str     w0, [x21, #TCONN_RMAC]
    ldrh    w0, [x19, #(ETH_SRC + 4)]
    strh    w0, [x21, #(TCONN_RMAC + 4)]

    /* Capture peer's window → SND_WND */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    rev16   w0, w0
    uxth    w0, w0
    str     w0, [x21, #TCONN_SND_WND]

    str     w22, [x21, #TCONN_SND_UNA]

    /* SND_NXT = ISN (tcp_build_frame reads SND_NXT as SEQ) */
    str     w22, [x21, #TCONN_SND_NXT]

    ldr     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w0, w0
    add     w0, w0, #1
    str     w0, [x21, #TCONN_RCV_NXT]

    /* TSopt negotiation: parse incoming SYN for timestamps */
    ldrb    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    lsr     w1, w1, #4
    lsl     w1, w1, #2             /* w1 = tcp_header_len bytes */
    mov     x0, x19                 /* frame */
    bl      tcp_parse_tsopt
    cbz     w1, .Llsyn_no_ts
    /* TSopt found: w0 = TSval (NBO) — save before clobbering */
    rev     w0, w0                  /* TSval → host order */
    str     w0, [x21, #TCONN_TS_RECENT]
    mov     w0, #1
    strb    w0, [x21, #TCONN_TS_ENABLED]
    b       .Llsyn_ts_done
.Llsyn_no_ts:
    strb    wzr, [x21, #TCONN_TS_ENABLED]
.Llsyn_ts_done:

    /* Parse MSS option from incoming SYN */
    ldrb    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    lsr     w1, w1, #4
    lsl     w1, w1, #2             /* tcp_header_len bytes */
    mov     x0, x19
    bl      tcp_parse_mss
    cbz     w0, .Llsyn_mss_done
    strh    w0, [x21, #TCONN_PEER_MSS]
    str     w0, [x21, #TCONN_CWND]
.Llsyn_mss_done:

    /* Parse WSCALE option from incoming SYN */
    ldrb    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    lsr     w1, w1, #4
    lsl     w1, w1, #2
    mov     x0, x19
    bl      tcp_parse_wscale
    cmn     w0, #1
    b.eq    .Llsyn_no_wscale

    /* Store peer's WSCALE and our WSCALE */
    strb    w0, [x21, #TCONN_SND_WSCALE]
    mov     w1, #TCP_OUR_WSCALE
    strb    w1, [x21, #TCONN_RCV_WSCALE]

    /* Apply WSCALE to the already-stored SND_WND */
    ldr     w1, [x21, #TCONN_SND_WND]
    lsl     w1, w1, w0
    str     w1, [x21, #TCONN_SND_WND]
    b       .Llsyn_wscale_done

.Llsyn_no_wscale:
    strb    wzr, [x21, #TCONN_SND_WSCALE]
    strb    wzr, [x21, #TCONN_RCV_WSCALE]
.Llsyn_wscale_done:

    /* Parse SACK-Permitted option from incoming SYN */
    ldrb    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    lsr     w1, w1, #4
    lsl     w1, w1, #2
    mov     x0, x19
    bl      tcp_parse_sack_permitted
    strb    w0, [x21, #TCONN_SACK_ENABLED]

    /* Initialize activity timestamp */
    bl      timer_now
    str     x0, [x21, #TCONN_LAST_ACTIVE]
    /* Initialize persist shift */
    strb    wzr, [x21, #TCONN_PERSIST_SHIFT]

    /* Build SYN-ACK via tcp_build_frame (includes MSS option) */
    mov     x0, x21                 /* conn */
    mov     x1, x19                 /* frame buf */
    mov     w2, #TCP_SYN_ACK        /* flags (SYN set → triggers MSS option) */
    mov     x3, #0                  /* no payload */
    mov     w4, #0
    bl      tcp_build_frame
    mov     w22, w0                 /* save frame length */

    /* Advance SND_NXT past SYN */
    ldr     w0, [x21, #TCONN_SND_NXT]
    add     w0, w0, #1
    str     w0, [x21, #TCONN_SND_NXT]

    /* Save SYN-ACK to retransmit buffer */
    mov     x0, x21                 /* conn */
    mov     x1, x19                 /* frame */
    mov     w2, w22                 /* frame_len */
    bl      tcp_rtx_save

    mov     w0, w22                 /* restore return value */

.Llsyn_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/*
 * tcp_synrcvd_ack_handler — Verify ACK completes handshake
 *
 * FSA already wrote ESTABLISHED to TCONN_STATE.
 * Verify SEG.ACK == SND_NXT; if bad, restore SYN_RCVD and return -1 (RST).
 * Leaf function.
 */
tcp_synrcvd_ack_handler:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    mov     x19, x0                 /* conn */

    ldr     w4, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w4, w4
    ldr     w5, [x19, #TCONN_SND_NXT]
    cmp     w4, w5
    b.ne    .Lsra_bad_ack
    /* SYN-ACK is now ACKed: advance SND_UNA and clear retransmit */
    str     w5, [x19, #TCONN_SND_UNA]
    mov     x0, x19
    bl      tcp_rtx_clear
    mov     w0, #0
    b       .Lsra_done
.Lsra_bad_ack:
    mov     w4, #TCPS_SYN_RCVD
    strb    w4, [x19, #TCONN_STATE]
    mov     w0, #-1
.Lsra_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * tcp_conn_close_handler — FSA already set state to CLOSED
 * Leaf function.
 */
tcp_conn_close_handler:
    stp     x29, x30, [sp, #-16]!
    bl      tcp_rtx_clear
    mov     w0, #0
    ldp     x29, x30, [sp], #16
    ret

/*
 * tcp_drop_handler — Absorb packet, no reply
 * Leaf function.
 */
tcp_drop_handler:
    mov     w0, #0
    ret

/*
 * tcp_estab_ack_handler — Handle ACK in ESTABLISHED state (data transfer)
 *
 * x0: connection, x1: frame, w2: tcp_section_len, w3: tcp_header_len
 *
 * data_len = section_len - header_len
 * If data_len == 0 → pure ACK, return 0
 * If SEG.SEQ != RCV_NXT → out of order, drop (return 0)
 * If rx buffer would overflow → drop (return 0, peer retransmits)
 * Otherwise: copy data to rx buffer, RCV_NXT += data_len, build ACK reply
 */
tcp_estab_ack_handler:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* x19 = conn */
    mov     x20, x1                 /* x20 = frame */
    mov     w21, w2                 /* w21 = tcp_section_len */
    mov     w22, w3                 /* w22 = tcp_header_len */

    /* Update SND_WND from incoming ACK */
    ldrh    w4, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    rev16   w4, w4
    uxth    w4, w4
    /* Apply WSCALE (RFC 7323): SND_WND = raw_window << peer_shift */
    ldrb    w5, [x19, #TCONN_SND_WSCALE]
    lsl     w4, w4, w5
    cbz     w4, .Leak_zero_window
    str     w4, [x19, #TCONN_SND_WND]
    /* Non-zero window: cancel persist if active */
    ldrb    w5, [x19, #TCONN_PERSIST_SHIFT]
    cbz     w5, .Leak_wnd_done
    strb    wzr, [x19, #TCONN_PERSIST_SHIFT]
    b       .Leak_wnd_done

.Leak_zero_window:
    str     wzr, [x19, #TCONN_SND_WND]    /* store window=0 */
    ldrb    w5, [x19, #TCONN_PERSIST_SHIFT]
    cbnz    w5, .Leak_wnd_done             /* already armed */
    mov     w5, #1
    strb    w5, [x19, #TCONN_PERSIST_SHIFT]
    /* Arm persist timer */
    mov     x0, x19
    bl      tcp_persist_arm

.Leak_wnd_done:
    /* Advance SND_UNA: if SND_UNA < seg_ack <= SND_NXT, set SND_UNA = seg_ack */
    ldr     w4, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w4, w4                  /* w4 = seg_ack (host order) */
    ldr     w5, [x19, #TCONN_SND_UNA]
    ldr     w6, [x19, #TCONN_SND_NXT]
    cmp     w4, w5
    b.ls    .Leak_una_done          /* seg_ack <= SND_UNA → no advance */
    cmp     w4, w6
    b.hi    .Leak_una_done          /* seg_ack > SND_NXT → invalid, ignore */
    str     w4, [x19, #TCONN_SND_UNA]

    /* Advance send buffer tail by acked bytes */
    sub     w0, w4, w5             /* acked = new_UNA - old_UNA */
    ldr     w1, [x19, #TCONN_SND_BUF_TAIL]
    add     w1, w1, w0
    and     w1, w1, #TCP_SNDBUF_MASK
    str     w1, [x19, #TCONN_SND_BUF_TAIL]
    ldr     w1, [x19, #TCONN_SND_BUF_USED]
    sub     w1, w1, w0
    str     w1, [x19, #TCONN_SND_BUF_USED]

    /* RTT measurement (RFC 6298, Karn's algorithm) */
    ldrb    w0, [x19, #TCONN_RTXCOUNT]
    cbnz    w0, .Leak_no_rtt            /* retransmitted → skip sample */
    ldr     x0, [x19, #TCONN_SEND_TICK]
    cbz     x0, .Leak_no_rtt            /* no timestamp → skip */
    stp     x4, x5, [sp, #-16]!        /* save seg_ack, SND_UNA */
    str     x6, [sp, #-8]!             /* save SND_NXT */
    bl      timer_now
    ldr     x1, [x19, #TCONN_SEND_TICK]
    sub     w0, w0, w1                  /* R = now - send_tick (ticks) */
    mov     x1, x19
    bl      tcp_rtt_update
    str     xzr, [x19, #TCONN_SEND_TICK]
    ldr     x6, [sp], #8
    ldp     x4, x5, [sp], #16
.Leak_no_rtt:

    /* Congestion control: grow cwnd on new ACK (RFC 5681) */
    ldr     w7, [x19, #TCONN_CWND]
    ldr     w8, [x19, #TCONN_SSTHRESH]
    ldrh    w9, [x19, #TCONN_PEER_MSS]
    cmp     w7, w8
    b.hs    .Leak_cong_avoid
    /* Slow start: cwnd += MSS */
    add     w7, w7, w9
    b       .Leak_cwnd_store
.Leak_cong_avoid:
    /* Congestion avoidance: cwnd += MSS * MSS / cwnd */
    mul     w10, w9, w9
    udiv    w10, w10, w7
    /* Ensure at least +1 so cwnd always grows */
    cmp     w10, #0
    cinc    w10, w10, eq
    add     w7, w7, w10
.Leak_cwnd_store:
    mov     w10, #0x40000               /* 256 KB cap */
    cmp     w7, w10
    csel    w7, w7, w10, lo
    str     w7, [x19, #TCONN_CWND]
    strb    wzr, [x19, #TCONN_DUP_ACK_CNT]

    /* If SND_UNA == SND_NXT, all data ACKed → clear retransmit */
    cmp     w4, w6
    b.ne    .Leak_una_done
    mov     x0, x19
    bl      tcp_rtx_clear
.Leak_una_done:

    /* PAWS check (RFC 7323 §4.2) — before SEQ validation */
    ldrb    w0, [x19, #TCONN_TS_ENABLED]
    cbz     w0, .Leak_paws_done
    mov     x0, x20                 /* frame */
    mov     w1, w22                 /* tcp_header_len */
    bl      tcp_parse_tsopt
    cbz     w1, .Leak_paws_done     /* no TSopt → skip PAWS */
    rev     w0, w0                  /* TSval NBO → host order */
    ldr     w2, [x19, #TCONN_TS_RECENT]
    sub     w3, w0, w2              /* signed diff */
    tbnz    w3, #31, .Leak_paws_drop /* TSval < TS_RECENT → PAWS drop */
    str     w0, [x19, #TCONN_TS_RECENT] /* update TS_RECENT */
.Leak_paws_done:

    sub     w4, w21, w22            /* w4 = data_len */
    cbz     w4, .Leak_pure_ack

    /* Verify SEQ == RCV_NXT */
    ldr     w5, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w5, w5                  /* SEG.SEQ in host order */
    ldr     w6, [x19, #TCONN_RCV_NXT]
    cmp     w5, w6
    b.eq    .Leak_seq_ok
    b.lo    .Leak_dup_data          /* SEQ < RCV_NXT → duplicate, re-ACK */

    /* SEQ > RCV_NXT → out-of-order segment, try to buffer */

    /* Window check: (SEQ - RCV_NXT) must be < RCV_WND (RFC 9293 §3.3.7) */
    sub     w8, w5, w6              /* gap = SEQ - RCV_NXT (unsigned) */
    ldrh    w9, [x19, #TCONN_RXLEN]
    mov     w10, #TCP_RXBUF_SIZE
    sub     w10, w10, w9            /* RCV_WND = RXBUF_SIZE - RXLEN */
    cmp     w8, w10
    b.hs    .Leak_dup_data          /* outside window → dup ACK */

    ldrb    w7, [x19, #TCONN_OOO_COUNT]
    cmp     w7, #4
    b.hs    .Leak_dup_data          /* OOO slots full → dup ACK */

    /* Check rx buffer room: RXLEN + gap + data_len <= RXBUF_SIZE */
    ldrh    w9, [x19, #TCONN_RXLEN]
    add     w10, w9, w8
    add     w10, w10, w4            /* end offset = RXLEN + gap + data_len */
    cmp     w10, #TCP_RXBUF_SIZE
    b.hi    .Leak_dup_data          /* won't fit → dup ACK */

    /* Copy data to rxbuf at offset RXLEN + gap */
    ldr     x2, =tcp_conn_table
    sub     x2, x19, x2
    lsr     x2, x2, #TCONN_SHIFT             /* slot index */
    ldr     x0, =tcp_rxbuf_pool
    add     x0, x0, x2, lsl #TCP_RXBUF_SHIFT
    add     x0, x0, w9, uxtw       /* + RXLEN */
    add     x0, x0, w8, uxtw       /* + gap */
    add     x1, x20, #(ETH_PAYLOAD + IP_HDR_MIN)
    add     x1, x1, x22            /* skip TCP header */
    mov     w2, w4
.Leak_ooo_copy:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Leak_ooo_copy

    /* Record in OOO slot[ooo_count] */
    add     x0, x19, #TCONN_OOO_SLOTS
    add     x0, x0, x7, lsl #3     /* slot[ooo_count], 8 bytes each */
    str     w5, [x0]               /* SEQ */
    strh    w4, [x0, #4]           /* LEN */
    add     w7, w7, #1
    strb    w7, [x19, #TCONN_OOO_COUNT]

    b       .Leak_dup_data          /* send dup ACK */
.Leak_seq_ok:

    /* Check rx buffer overflow */
    ldrh    w5, [x19, #TCONN_RXLEN]
    add     w7, w5, w4              /* new_rxlen = rxlen + data_len */
    cmp     w7, #TCP_RXBUF_SIZE
    b.hi    .Leak_pure_ack          /* would overflow → drop */

    /* Accept data: copy to rx buffer */

    /* Compute slot index: (conn - tcp_conn_table) >> 7 */
    ldr     x2, =tcp_conn_table
    sub     x2, x19, x2
    lsr     x2, x2, #TCONN_SHIFT             /* slot index */

    /* Dest = tcp_rxbuf_pool + (slot << 11) + rxlen */
    ldr     x0, =tcp_rxbuf_pool
    add     x0, x0, x2, lsl #TCP_RXBUF_SHIFT
    add     x0, x0, x5             /* + rxlen (w5 from above) */

    /* Src = frame + ETH_PAYLOAD + IP_HDR_MIN + header_len */
    add     x1, x20, #(ETH_PAYLOAD + IP_HDR_MIN)
    add     x1, x1, x22            /* skip TCP header */

    /* Byte-copy data_len bytes */
    mov     w2, w4
.Leak_rxcopy:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Leak_rxcopy

    /* Update RXLEN */
    ldrh    w0, [x19, #TCONN_RXLEN]
    add     w0, w0, w4
    strh    w0, [x19, #TCONN_RXLEN]
    mov     w5, w0                  /* w5 = new RXLEN for window calc */

    /* RCV_NXT += data_len */
    ldr     w6, [x19, #TCONN_RCV_NXT]
    add     w6, w6, w4
    str     w6, [x19, #TCONN_RCV_NXT]

    /* OOO merge: check if buffered segments are now contiguous */
    ldrb    w8, [x19, #TCONN_OOO_COUNT]
    cbz     w8, .Leak_ooo_done
.Leak_ooo_scan:
    /* Scan OOO slots for SEQ == new RCV_NXT (w6) */
    add     x0, x19, #TCONN_OOO_SLOTS
    mov     w9, #0                  /* index */
.Leak_ooo_check:
    cmp     w9, w8
    b.hs    .Leak_ooo_done          /* scanned all, no match */
    ldr     w10, [x0]              /* slot[i].SEQ */
    cmp     w10, w6
    b.eq    .Leak_ooo_merge
    add     x0, x0, #8
    add     w9, w9, #1
    b       .Leak_ooo_check
.Leak_ooo_merge:
    /* Match: advance RCV_NXT by slot[i].LEN, advance RXLEN */
    ldrh    w10, [x0, #4]          /* slot[i].LEN */
    add     w6, w6, w10
    str     w6, [x19, #TCONN_RCV_NXT]
    ldrh    w5, [x19, #TCONN_RXLEN]
    add     w5, w5, w10
    strh    w5, [x19, #TCONN_RXLEN]
    /* Remove slot[i]: copy last slot over it, decrement count */
    sub     w8, w8, #1
    strb    w8, [x19, #TCONN_OOO_COUNT]
    cbz     w8, .Leak_ooo_scan     /* was last slot, nothing to copy */
    /* If i != new count, copy slot[count] → slot[i] */
    cmp     w9, w8
    b.eq    .Leak_ooo_scan          /* removed last, no copy needed */
    add     x1, x19, #TCONN_OOO_SLOTS
    add     x1, x1, x8, lsl #3     /* slot[new_count] (the old last) */
    ldr     x2, [x1]               /* 8-byte copy */
    str     x2, [x0]
    b       .Leak_ooo_scan          /* rescan with updated count */
.Leak_ooo_done:

    /* Build ACK reply: SEQ=SND_NXT(NBO), ACK=new_RCV_NXT(NBO) */
    ldr     w0, [x19, #TCONN_SND_NXT]
    rev     w1, w0                      /* SEQ NBO */
    rev     w2, w6                      /* ACK NBO */

    /* Dynamic window from new RXLEN */
    mov     w4, #TCP_RXBUF_SIZE
    sub     w4, w4, w5             /* available = size - used */
    rev16   w4, w4
    uxth    w4, w4                  /* NBO halfword */

    mov     x0, x20                 /* frame */
    /* w1 = SEQ, w2 = ACK already set */
    mov     w3, #TCP_ACK_FLAG      /* flags = ACK */
    /* w4 = window already set */
    mov     x5, x19                 /* conn */
    bl      tcp_build_reply

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

.Leak_paws_drop:
    /* PAWS failed: send ACK per RFC 7323 §4.2 but do not process segment */
.Leak_dup_data:
    /* Duplicate/PAWS-failed: build ACK with current RCV_NXT */
    ldr     w0, [x19, #TCONN_SND_NXT]
    rev     w1, w0                      /* SEQ NBO */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    rev     w2, w0                      /* ACK NBO */

    /* Dynamic window */
    ldrh    w5, [x19, #TCONN_RXLEN]
    mov     w4, #TCP_RXBUF_SIZE
    sub     w4, w4, w5
    rev16   w4, w4
    uxth    w4, w4

    mov     x0, x20                 /* frame */
    mov     w3, #TCP_ACK_FLAG
    mov     x5, x19                 /* conn */
    bl      tcp_build_reply

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

.Leak_pure_ack:
    /* Check for duplicate ACK: seg_ack == SND_UNA and data in flight */
    ldr     w4, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w4, w4                  /* seg_ack host order */
    ldr     w5, [x19, #TCONN_SND_UNA]
    cmp     w4, w5
    b.ne    .Leak_not_dup
    ldr     w6, [x19, #TCONN_SND_NXT]
    cmp     w6, w5
    b.eq    .Leak_not_dup           /* SND_NXT == SND_UNA → no data in flight */

    /* Increment DUP_ACK_CNT */
    ldrb    w7, [x19, #TCONN_DUP_ACK_CNT]
    add     w7, w7, #1
    strb    w7, [x19, #TCONN_DUP_ACK_CNT]
    cmp     w7, #TCP_DUPACK_THRESH
    b.ne    .Leak_not_dup           /* not at threshold yet */

    /* Fast retransmit: retransmit immediately */
    mov     x0, x19
    bl      tcp_fast_retransmit
    strb    wzr, [x19, #TCONN_DUP_ACK_CNT]  /* reset counter */

.Leak_not_dup:
    mov     w0, #0
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_estab_fin_handler — Handle FIN in ESTABLISHED state (passive close)
 *
 * FIN consumes one sequence number: RCV_NXT += 1
 * FSA already wrote CLOSE_WAIT to TCONN_STATE.
 * Build ACK reply: SEQ=SND_NXT(NBO), ACK=new_RCV_NXT(NBO)
 */
tcp_estab_fin_handler:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x21, x0                 /* x21 = conn */
    mov     x22, x1                 /* x22 = frame */
    sub     w23, w2, w3             /* w23 = data_len */
    mov     w24, w3                 /* w24 = header_len */

    /* If data_len > 0, accept data before handling FIN */
    cbz     w23, .Lefin_no_data

    /* Verify SEQ == RCV_NXT (in-order) */
    ldr     w5, [x22, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w5, w5
    ldr     w6, [x21, #TCONN_RCV_NXT]
    cmp     w5, w6
    b.ne    .Lefin_no_data          /* out of order → skip data */

    /* Check rx buffer overflow */
    ldrh    w5, [x21, #TCONN_RXLEN]
    add     w7, w5, w23
    cmp     w7, #TCP_RXBUF_SIZE
    b.hi    .Lefin_no_data          /* overflow → skip data */

    /* Copy data to rxbuf */
    ldr     x2, =tcp_conn_table
    sub     x2, x21, x2
    lsr     x2, x2, #TCONN_SHIFT             /* slot index */
    ldr     x0, =tcp_rxbuf_pool
    add     x0, x0, x2, lsl #TCP_RXBUF_SHIFT
    add     x0, x0, x5             /* + current RXLEN */
    add     x1, x22, #(ETH_PAYLOAD + IP_HDR_MIN)
    add     x1, x1, x24            /* skip TCP header */
    mov     w2, w23
.Lefin_dcopy:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lefin_dcopy

    /* Update RXLEN and RCV_NXT */
    strh    w7, [x21, #TCONN_RXLEN]
    ldr     w6, [x21, #TCONN_RCV_NXT]
    add     w6, w6, w23
    str     w6, [x21, #TCONN_RCV_NXT]

.Lefin_no_data:
    /* RCV_NXT += 1 (FIN consumes one seq) */
    ldr     w5, [x21, #TCONN_RCV_NXT]
    add     w5, w5, #1
    str     w5, [x21, #TCONN_RCV_NXT]

    ldr     w19, [x21, #TCONN_SND_NXT]  /* SND_NXT (host order) */
    rev     w20, w5                     /* new RCV_NXT → NBO */

    /* Dynamic window */
    ldrh    w4, [x21, #TCONN_RXLEN]
    mov     w6, #TCP_RXBUF_SIZE
    sub     w4, w6, w4
    rev16   w4, w4
    uxth    w4, w4

    mov     x0, x22                 /* frame */
    rev     w1, w19                 /* SEQ = rev(SND_NXT) (NBO) */
    mov     w2, w20                 /* ACK = rev(RCV_NXT) (NBO) */
    mov     w3, #TCP_ACK_FLAG      /* flags = ACK */
    /* w4 = window already set */
    mov     x5, x21                 /* conn */
    bl      tcp_build_reply

    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * tcp_build_frame — Build ETH+IP+TCP frame from scratch using connection fields
 *
 * x0: connection pointer
 * x1: frame buffer
 * w2: TCP flags
 * x3: payload pointer (0 = no payload)
 * w4: payload length (0 = no payload)
 * Returns: w0 = frame length (54 + payload_len)
 * Clobbers: x0-x6, x19-x25, x30
 *
 * Does NOT update SND_NXT or change state — caller's responsibility.
 */
tcp_build_frame:
    stp     x29, x30, [sp, #-80]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    mov     x19, x0                 /* x19 = conn */
    mov     x20, x1                 /* x20 = frame buf */
    mov     w21, w2                 /* w21 = flags */
    mov     x22, x3                 /* x22 = payload ptr */
    mov     w23, w4                 /* w23 = payload len */

    /* Determine if timestamps enabled: w25 = 0 or 12 (TCP option size) */
    ldrb    w25, [x19, #TCONN_TS_ENABLED]
    cmp     w25, #0
    mov     w25, #0                 /* default: no TS overhead */
    b.eq    .Lbf_ts_decided
    mov     w25, #TCP_TSOPT_SIZE    /* 12 bytes overhead */
.Lbf_ts_decided:

    /* Determine if SYN options needed: MSS(4) + WSCALE(4) + optional SACK-Perm(4) */
    mov     w26, #0
    tst     w21, #TCP_SYN
    b.eq    .Lbf_syn_opts_decided
    mov     w26, #(TCP_OPT_MSS_LEN + 4) /* MSS(4) + NOP+WSCALE(4) = 8 */
    ldrb    w0, [x19, #TCONN_SACK_ENABLED]
    cbz     w0, .Lbf_syn_opts_decided
    add     w26, w26, #4                 /* + NOP+NOP+SACK-Perm(4) = 12 */
.Lbf_syn_opts_decided:

    /* 1. Build Ethernet header: dst=RMAC, src=net_our_mac, type=0x0800 */
    mov     x0, x20                 /* frame */
    add     x1, x19, #TCONN_RMAC   /* dst = peer MAC from conn */
    mov     w2, #0x0800             /* EtherType IPv4 */
    bl      eth_build_hdr

    /* 2. Build IP header */
    /* ver/ihl=0x45, dscp=0x00 */
    mov     w0, #0x45
    strb    w0, [x20, #ETH_PAYLOAD]
    strb    wzr, [x20, #(ETH_PAYLOAD + 1)]

    /* totlen = 40 + ts_overhead + mss_overhead + payload_len (NBO via rev16) */
    add     w0, w23, #40
    add     w0, w0, w25
    add     w0, w0, w26
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x20, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* id = 0 */
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_ID)]

    /* flags/frag: DF bit set (0x4000 NBO = 0x0040 LE) */
    mov     w0, #0x0040
    strh    w0, [x20, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]

    /* ttl=64, proto=TCP(6) */
    mov     w0, #IP_DEFAULT_TTL
    strb    w0, [x20, #(ETH_PAYLOAD + IP_TTL)]
    mov     w0, #6
    strb    w0, [x20, #(ETH_PAYLOAD + IP_PROTO)]

    /* IP src = net_our_ip */
    ldr     x0, =net_our_ip
    ldr     w0, [x0]
    str     w0, [x20, #(ETH_PAYLOAD + IP_SRC)]

    /* IP dst = conn RIP */
    ldr     w0, [x19, #TCONN_RIP]
    str     w0, [x20, #(ETH_PAYLOAD + IP_DST)]

    /* IP checksum */
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x20, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x20, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* 3. Build TCP header */
    /* sport = conn LPORT, dport = conn RPORT */
    ldrh    w0, [x19, #TCONN_LPORT]
    strh    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    ldrh    w0, [x19, #TCONN_RPORT]
    strh    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]

    /* SEQ = rev(SND_NXT) (NBO) */
    ldr     w24, [x19, #TCONN_SND_NXT]
    rev     w0, w24
    str     w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]

    /* ACK = rev(RCV_NXT) (NBO) */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    rev     w0, w0
    str     w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* data offset: (20 + ts_overhead + mss_overhead) / 4 words, high nibble */
    add     w0, w25, w26           /* total option bytes */
    lsr     w0, w0, #2             /* option words */
    add     w0, w0, #5             /* + 5 base header words */
    lsl     w0, w0, #4             /* shift to high nibble */
    strb    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    strb    w21, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]

    /* Dynamic window from TCONN_RXLEN */
    ldrh    w0, [x19, #TCONN_RXLEN]
    mov     w1, #TCP_RXBUF_SIZE
    sub     w0, w1, w0             /* available = size - used */
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]

    /* urgent = 0 */
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_URGENT)]

    /* Insert TSopt if enabled */
    cbz     w25, .Lbf_no_tsopt
    mov     w0, #0x01
    strb    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + 20)]     /* NOP */
    strb    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + 21)]     /* NOP */
    mov     w0, #TCP_OPT_TIMESTAMPS
    strb    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + 22)]     /* Kind=8 */
    mov     w0, #TCP_OPT_TS_LEN
    strb    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + 23)]     /* Len=10 */
    bl      timer_now               /* x0 = counter */
    lsr     x0, x0, #16
    rev     w0, w0
    str     w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + 24)]     /* TSval (NBO) */
    ldr     w0, [x19, #TCONN_TS_RECENT]
    rev     w0, w0
    str     w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + 28)]     /* TSecr (NBO) */
.Lbf_no_tsopt:

    /* Insert MSS option if SYN (w26 != 0) */
    cbz     w26, .Lbf_no_mss
    add     x0, x20, #(ETH_PAYLOAD + IP_HDR_MIN + 20)
    add     x0, x0, x25           /* skip TS options if present */
    mov     w1, #TCP_OPT_MSS      /* Kind=2 */
    strb    w1, [x0]
    mov     w1, #TCP_OPT_MSS_LEN  /* Len=4 */
    strb    w1, [x0, #1]
    mov     w1, #TCP_OUR_MSS       /* 1460 */
    rev16   w1, w1
    uxth    w1, w1
    strh    w1, [x0, #2]          /* MSS value (NBO) */

    /* WSCALE option: NOP(1) + Kind=3(1) + Len=3(1) + Shift(1) = 4 bytes */
    mov     w1, #TCP_OPT_NOP
    strb    w1, [x0, #4]
    mov     w1, #TCP_OPT_WSCALE
    strb    w1, [x0, #5]
    mov     w1, #TCP_OPT_WSCALE_LEN
    strb    w1, [x0, #6]
    ldrb    w1, [x19, #TCONN_RCV_WSCALE]
    strb    w1, [x0, #7]

    /* SACK-Permitted option if negotiated: NOP+NOP+Kind=4+Len=2 = 4 bytes */
    ldrb    w1, [x19, #TCONN_SACK_ENABLED]
    cbz     w1, .Lbf_no_mss
    mov     w1, #TCP_OPT_NOP
    strb    w1, [x0, #8]
    strb    w1, [x0, #9]
    mov     w1, #TCP_OPT_SACK_PERM
    strb    w1, [x0, #10]
    mov     w1, #TCP_OPT_SACK_PERM_LEN
    strb    w1, [x0, #11]
.Lbf_no_mss:

    /* Copy payload if present */
    cbz     w23, .Lbf_no_payload
    add     x0, x20, #54           /* dest = frame + 54 + ts_overhead + mss_overhead */
    add     x0, x0, x25
    add     x0, x0, x26
    mov     x1, x22                /* src = payload ptr */
    mov     w2, w23
.Lbf_copy:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lbf_copy

.Lbf_no_payload:
    /* TCP checksum over (20 + ts_overhead + mss_overhead + payload_len) bytes */
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x20
    add     w1, w23, #TCP_HDR_MIN
    add     w1, w1, w25
    add     w1, w1, w26
    bl      tcp_checksum
    strh    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Return 54 + ts_overhead + mss_overhead + payload_len */
    add     w0, w23, #54
    add     w0, w0, w25
    add     w0, w0, w26

    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret

/*
 * tcp_close — Initiate active close on a connection
 *
 * x0: connection pointer
 * x1: frame buffer (54 or 66 bytes written if successful)
 * Returns: w0 = frame length (54 or 66) or 0 (invalid state)
 * Clobbers: x0-x6, x19-x25, x30
 *
 * Valid from ESTABLISHED → FIN_WAIT_1, or CLOSE_WAIT → LAST_ACK.
 * Builds ETH+IP+TCP frame from scratch using connection fields.
 */
tcp_close:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* x19 = conn */
    mov     x20, x1                 /* x20 = frame buf */

    /* Check state: must be ESTABLISHED or CLOSE_WAIT */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.eq    .Ltc_valid
    cmp     w0, #TCPS_CLOSE_WAIT
    b.eq    .Ltc_valid

    /* Invalid state */
    mov     w0, #0
    b       .Ltc_done

.Ltc_valid:
    mov     w21, w0                 /* w21 = old state */

    /* Build FIN+ACK frame via tcp_build_frame */
    mov     x0, x19                 /* conn */
    mov     x1, x20                 /* frame */
    mov     w2, #TCP_FIN_ACK        /* flags */
    mov     x3, #0                  /* no payload */
    mov     w4, #0                  /* payload_len = 0 */
    bl      tcp_build_frame
    mov     w22, w0                 /* save frame_len (54 or 66) */

    /* SND_NXT += 1 (FIN consumes one seq) */
    ldr     w0, [x19, #TCONN_SND_NXT]
    add     w0, w0, #1
    str     w0, [x19, #TCONN_SND_NXT]

    /* State transition */
    cmp     w21, #TCPS_ESTABLISHED
    b.ne    .Ltc_closewait
    mov     w0, #TCPS_FIN_WAIT_1
    b       .Ltc_set_state
.Ltc_closewait:
    mov     w0, #TCPS_LAST_ACK
.Ltc_set_state:
    strb    w0, [x19, #TCONN_STATE]

    /* Save FIN frame to retransmit buffer */
    mov     x0, x19                 /* conn */
    mov     x1, x20                 /* frame */
    mov     w2, w22                 /* frame_len */
    bl      tcp_rtx_save

    mov     w0, w22                 /* return frame_len */

.Ltc_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_send — Send application data on an ESTABLISHED connection
 *
 * x0: connection pointer
 * x1: frame buffer (1514 bytes available)
 * x2: payload pointer
 * w3: payload length (1..peer_mss)
 * Returns: w0 = frame length (54 + payload_len), or 0 on error
 * Clobbers: x0-x6, x19-x25, x30
 */
tcp_send:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* x19 = conn */
    mov     x23, x1                 /* x23 = frame buf */
    mov     x20, x2                 /* x20 = payload ptr (save before clobber) */
    mov     w21, w3                 /* w21 = payload_len */

    /* Check state == ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lts_err

    /* Check 1 <= payload_len <= peer MSS */
    cbz     w21, .Lts_err
    ldrh    w0, [x19, #TCONN_PEER_MSS]
    cmp     w21, w0
    b.hi    .Lts_err

    /* Check payload_len <= available_window - in_flight */
    ldr     w0, [x19, #TCONN_SND_WND]
    ldr     w1, [x19, #TCONN_CWND]
    cmp     w0, w1
    csel    w0, w0, w1, lo          /* min(SND_WND, cwnd) */
    ldr     w1, [x19, #TCONN_SND_NXT]
    ldr     w2, [x19, #TCONN_SND_UNA]
    sub     w1, w1, w2              /* in_flight */
    subs    w0, w0, w1              /* available = window - in_flight */
    b.ls    .Lts_err                /* no room */
    cmp     w21, w0
    b.hi    .Lts_err

    /* Write payload to circular send buffer */
    ldr     x0, =tcp_conn_table
    sub     x0, x19, x0
    lsr     x0, x0, #TCONN_SHIFT           /* slot index */
    ldr     x1, =tcp_sndbuf_pool
    add     x1, x1, x0, lsl #TCP_SNDBUF_SHIFT  /* buf base */
    ldr     w2, [x19, #TCONN_SND_BUF_HEAD]
    mov     w3, #0
.Lts_sndbuf_copy:
    cmp     w3, w21
    b.hs    .Lts_sndbuf_done
    and     w4, w2, #TCP_SNDBUF_MASK
    ldrb    w5, [x20, x3]
    strb    w5, [x1, x4]
    add     w2, w2, #1
    add     w3, w3, #1
    b       .Lts_sndbuf_copy
.Lts_sndbuf_done:
    and     w2, w2, #TCP_SNDBUF_MASK
    str     w2, [x19, #TCONN_SND_BUF_HEAD]
    ldr     w0, [x19, #TCONN_SND_BUF_USED]
    add     w0, w0, w21
    str     w0, [x19, #TCONN_SND_BUF_USED]

    /* Build PSH+ACK frame via tcp_build_frame */
    mov     x0, x19                 /* conn */
    mov     x1, x23                 /* frame */
    mov     w2, #TCP_PSH_ACK        /* flags */
    mov     x3, x20                 /* payload */
    mov     w4, w21                 /* payload_len */
    bl      tcp_build_frame

    mov     w22, w0                 /* save frame length */

    /* SND_NXT += payload_len */
    ldr     w0, [x19, #TCONN_SND_NXT]
    add     w0, w0, w21
    str     w0, [x19, #TCONN_SND_NXT]

    /* SND_WND -= payload_len */
    ldr     w0, [x19, #TCONN_SND_WND]
    sub     w0, w0, w21
    str     w0, [x19, #TCONN_SND_WND]

    /* Arm retransmit timer (data is in send buffer, no rtxbuf copy) */
    mov     x0, x19
    bl      tcp_rtx_arm

    mov     w0, w22                 /* return frame length */

    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

.Lts_err:
    mov     w0, #0
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * tcp_rx_peek — Get pointer and length of received data
 *
 * x0: connection pointer
 * Returns: x0 = buffer pointer, w1 = byte count
 * Leaf function, clobbers x0-x3
 */
tcp_rx_peek:
    /* Compute slot index: (conn - tcp_conn_table) >> 7 */
    ldr     x1, =tcp_conn_table
    sub     x1, x0, x1
    lsr     x1, x1, #TCONN_SHIFT   /* slot index */

    /* Buffer = tcp_rxbuf_pool + (slot << 11) */
    ldr     x2, =tcp_rxbuf_pool
    add     x2, x2, x1, lsl #TCP_RXBUF_SHIFT

    /* Length = TCONN_RXLEN */
    ldrh    w1, [x0, #TCONN_RXLEN]
    mov     x0, x2
    ret

/*
 * tcp_rx_flush — Clear receive buffer
 *
 * x0: connection pointer
 * Clears TCONN_RXLEN to 0.
 * Leaf function, clobbers none.
 */
tcp_rx_flush:
    strh    wzr, [x0, #TCONN_RXLEN]
    strb    wzr, [x0, #TCONN_OOO_COUNT]
    ret

/*
 * tcp_window_update — Send a bare ACK to advertise current window
 *
 * x0: connection pointer
 * x1: frame buffer (>= 54 bytes)
 * Returns: w0 = 54 (frame length), or 0 if state invalid
 * Valid in ESTABLISHED or CLOSE_WAIT.
 */
tcp_window_update:
    ldrb    w2, [x0, #TCONN_STATE]
    cmp     w2, #TCPS_ESTABLISHED
    b.eq    .Ltwu_valid
    cmp     w2, #TCPS_CLOSE_WAIT
    b.eq    .Ltwu_valid
    mov     w0, #0
    ret
.Ltwu_valid:
    mov     w2, #TCP_ACK_FLAG
    mov     x3, #0
    mov     w4, #0
    b       tcp_build_frame         /* tail call, returns 54 */

/*
 * tcp_send_ready — Query available send window
 *
 * x0: connection pointer
 * Returns: w0 = min(SND_WND, 1460), or 0 if state != ESTABLISHED
 * Leaf function, clobbers w0-w2
 */
tcp_send_ready:
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.ne    .Ltsr_zero
    /* Compute available = min(SND_WND, CWND) - in_flight */
    ldr     w2, [x0, #TCONN_SND_WND]
    ldr     w3, [x0, #TCONN_CWND]
    cmp     w2, w3
    csel    w2, w2, w3, lo          /* min(SND_WND, cwnd) */
    ldr     w3, [x0, #TCONN_SND_NXT]
    ldr     w4, [x0, #TCONN_SND_UNA]
    sub     w3, w3, w4              /* in_flight */
    subs    w1, w2, w3              /* available */
    b.ls    .Ltsr_zero
    /* Cap at peer MSS */
    ldrh    w2, [x0, #TCONN_PEER_MSS]
    cmp     w1, w2
    csel    w0, w1, w2, lo
    ret
.Ltsr_zero:
    mov     w0, #0
    ret

/*
 * tcp_lastack_ack_handler — LAST_ACK + ACK → CLOSED
 *
 * Verify SEG.ACK == SND_NXT. Bad → restore LAST_ACK, return -1.
 * Good → return 0 (FSA already wrote CLOSED).
 * Leaf function.
 */
tcp_lastack_ack_handler:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    mov     x19, x0                 /* conn */

    ldr     w4, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w4, w4
    ldr     w5, [x19, #TCONN_SND_NXT]
    cmp     w4, w5
    b.ne    .Llaa_bad
    /* FIN ACKed: clear retransmit */
    mov     x0, x19
    bl      tcp_rtx_clear
    mov     w0, #0
    b       .Llaa_done
.Llaa_bad:
    mov     w4, #TCPS_LAST_ACK
    strb    w4, [x19, #TCONN_STATE]
    mov     w0, #-1
.Llaa_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * tcp_finwait1_ack_handler — FIN_WAIT_1 + ACK → FIN_WAIT_2
 *
 * Verify SEG.ACK == SND_NXT. Bad → restore FIN_WAIT_1, return -1.
 * Good → return 0 (FSA already wrote FIN_WAIT_2).
 * Leaf function.
 */
tcp_finwait1_ack_handler:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    mov     x19, x0                 /* conn */

    ldr     w4, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w4, w4
    ldr     w5, [x19, #TCONN_SND_NXT]
    cmp     w4, w5
    b.ne    .Lfw1a_bad
    /* FIN ACKed: clear retransmit */
    mov     x0, x19
    bl      tcp_rtx_clear
    mov     w0, #0
    b       .Lfw1a_done
.Lfw1a_bad:
    mov     w4, #TCPS_FIN_WAIT_1
    strb    w4, [x19, #TCONN_STATE]
    mov     w0, #-1
.Lfw1a_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * tcp_finwait1_fin_handler — FIN_WAIT_1 + FIN → CLOSING (simultaneous close)
 *
 * RCV_NXT += 1, build ACK reply. Return 54.
 * Same pattern as tcp_estab_fin_handler.
 */
tcp_finwait1_fin_handler:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x21, x0                 /* x21 = conn (save for window) */

    /* RCV_NXT += 1 (FIN consumes one seq) */
    ldr     w5, [x0, #TCONN_RCV_NXT]
    add     w5, w5, #1
    str     w5, [x0, #TCONN_RCV_NXT]

    ldr     w19, [x0, #TCONN_SND_NXT]
    rev     w20, w5                     /* new RCV_NXT → NBO */

    /* Dynamic window */
    ldrh    w4, [x21, #TCONN_RXLEN]
    mov     w6, #TCP_RXBUF_SIZE
    sub     w4, w6, w4
    rev16   w4, w4
    uxth    w4, w4

    mov     x0, x1                  /* frame */
    rev     w1, w19                 /* SEQ = rev(SND_NXT) (NBO) */
    mov     w2, w20                 /* ACK = rev(RCV_NXT) (NBO) */
    mov     w3, #TCP_ACK_FLAG
    /* w4 = window already set */
    mov     x5, x21                 /* conn */
    bl      tcp_build_reply

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_finwait2_fin_handler — FIN_WAIT_2 + FIN → TIME_WAIT
 *
 * RCV_NXT += 1, arm 2MSL timer, build ACK reply. Return 54.
 */
tcp_finwait2_fin_handler:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x21, x0                 /* x21 = conn */

    /* RCV_NXT += 1 (FIN consumes one seq) */
    ldr     w5, [x21, #TCONN_RCV_NXT]
    add     w5, w5, #1
    str     w5, [x21, #TCONN_RCV_NXT]

    ldr     w19, [x21, #TCONN_SND_NXT]
    rev     w20, w5                     /* new RCV_NXT → NBO */

    /* Build ACK reply first (clobbers frame) */
    mov     x0, x1                  /* frame */
    rev     w1, w19                 /* SEQ = rev(SND_NXT) (NBO) */
    mov     w2, w20                 /* ACK = rev(RCV_NXT) (NBO) */
    mov     w3, #TCP_ACK_FLAG
    /* Dynamic window */
    ldrh    w4, [x21, #TCONN_RXLEN]
    mov     w6, #TCP_RXBUF_SIZE
    sub     w4, w6, w4
    rev16   w4, w4
    uxth    w4, w4
    mov     x5, x21                 /* conn */
    bl      tcp_build_reply
    mov     w22, w0                 /* save return value (54 or 66) */

    /* Guard: skip timer if no pool */
    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Lfw2f_skip_timer
    mov     x19, x0                 /* x19 = pool (free after build_reply) */

    /* Arm 2MSL timer (60 seconds) */
    bl      timer_freq
    mov     x1, #60
    mul     x20, x0, x1            /* x20 = delta ticks */
    bl      timer_now
    add     x1, x0, x20            /* x1 = expiry */

    mov     x0, x19                 /* pool */
    ldr     x2, =tcp_timewait_cb   /* callback */
    mov     x3, x21                 /* context = conn ptr */
    bl      timer_set
    str     w0, [x21, #TCONN_TIMER_SLOT]

.Lfw2f_skip_timer:
    mov     w0, w22                 /* restore return value */

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_closing_ack_handler — CLOSING + ACK → TIME_WAIT
 *
 * Verify SEG.ACK == SND_NXT. Bad → restore CLOSING, return -1.
 * Good → arm 2MSL timer, return 0 (FSA already wrote TIME_WAIT).
 * Note: non-leaf due to timer_set call.
 */
tcp_closing_ack_handler:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    mov     x19, x0                 /* conn */

    ldr     w4, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w4, w4
    ldr     w5, [x19, #TCONN_SND_NXT]
    cmp     w4, w5
    b.ne    .Lcla_bad

    /* Guard: skip timer if no pool */
    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Lcla_skip_timer

    /* Arm 2MSL timer (60 seconds) */
    bl      timer_freq
    mov     x1, #60
    mul     x20, x0, x1            /* x20 = delta ticks */
    bl      timer_now
    add     x1, x0, x20            /* x1 = expiry */

    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]               /* reload pool */
    ldr     x2, =tcp_timewait_cb
    mov     x3, x19
    bl      timer_set
    str     w0, [x19, #TCONN_TIMER_SLOT]

.Lcla_skip_timer:
    mov     w0, #0
    b       .Lcla_done

.Lcla_bad:
    mov     w4, #TCPS_CLOSING
    strb    w4, [x19, #TCONN_STATE]
    mov     w0, #-1

.Lcla_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * tcp_timewait_cb — Timer callback for TIME_WAIT expiry
 *
 * x0: connection pointer (passed as context)
 * Sets state=CLOSED, TIMER_SLOT=-1.
 * Leaf function.
 */
tcp_timewait_cb:
    strb    wzr, [x0, #TCONN_STATE]
    mov     w1, #-1
    str     w1, [x0, #TCONN_TIMER_SLOT]
    ret

/*
 * tcp_parse_mss — Parse MSS option from TCP header
 *
 * x0: frame pointer (Ethernet + IP + TCP)
 * w1: tcp_header_len (bytes, from data offset field)
 * Returns: w0 = MSS value (host order), or 0 if not found
 * Clobbers: x0-x4
 */
tcp_parse_mss:
    cmp     w1, #TCP_HDR_MIN
    b.le    .Lmss_not_found

    add     x2, x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_HDR_MIN)
    add     x3, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    add     x3, x3, x1

.Lmss_loop:
    cmp     x2, x3
    b.hs    .Lmss_not_found

    ldrb    w4, [x2]
    cbz     w4, .Lmss_not_found     /* Kind 0 = EOL */
    cmp     w4, #TCP_OPT_NOP
    b.eq    .Lmss_nop

    /* Variable-length option: need kind + length */
    add     x0, x2, #1
    cmp     x0, x3
    b.hs    .Lmss_not_found

    ldrb    w0, [x2, #1]           /* length byte */
    cmp     w0, #2
    b.lt    .Lmss_not_found        /* malformed */

    cmp     w4, #TCP_OPT_MSS
    b.ne    .Lmss_skip

    cmp     w0, #TCP_OPT_MSS_LEN
    b.ne    .Lmss_skip

    /* Verify enough bytes remain */
    add     x0, x2, #TCP_OPT_MSS_LEN
    cmp     x0, x3
    b.hi    .Lmss_not_found

    /* MSS value at offset +2 (2 bytes, NBO) */
    ldrh    w0, [x2, #2]
    rev16   w0, w0
    uxth    w0, w0
    ret

.Lmss_nop:
    add     x2, x2, #1
    b       .Lmss_loop

.Lmss_skip:
    ldrb    w0, [x2, #1]
    add     x2, x2, x0
    b       .Lmss_loop

.Lmss_not_found:
    mov     w0, #0
    ret

/*
 * tcp_parse_wscale — Parse Window Scale option from TCP header
 *
 * x0: frame buffer pointer
 * w1: TCP header length (bytes)
 * Returns: w0 = shift count (0-14), or -1 if not found
 * Clobbers: x0-x4
 */
.global tcp_parse_wscale
tcp_parse_wscale:
    cmp     w1, #TCP_HDR_MIN
    b.le    .Lwsc_not_found

    add     x2, x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_HDR_MIN)
    add     x3, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    add     x3, x3, x1

.Lwsc_loop:
    cmp     x2, x3
    b.hs    .Lwsc_not_found
    ldrb    w4, [x2]
    cbz     w4, .Lwsc_not_found     /* EOL */
    cmp     w4, #TCP_OPT_NOP
    b.eq    .Lwsc_nop

    add     x0, x2, #1
    cmp     x0, x3
    b.hs    .Lwsc_not_found
    ldrb    w0, [x2, #1]           /* length */
    cmp     w0, #2
    b.lt    .Lwsc_not_found

    cmp     w4, #TCP_OPT_WSCALE
    b.ne    .Lwsc_skip
    cmp     w0, #TCP_OPT_WSCALE_LEN
    b.ne    .Lwsc_skip

    add     x0, x2, #TCP_OPT_WSCALE_LEN
    cmp     x0, x3
    b.hi    .Lwsc_not_found

    /* Shift count at offset +2, capped at 14 (RFC 7323 §2.3) */
    ldrb    w0, [x2, #2]
    cmp     w0, #14
    csel    w0, w0, w4, lo
    mov     w4, #14
    csel    w0, w0, w4, lo
    ret

.Lwsc_nop:
    add     x2, x2, #1
    b       .Lwsc_loop
.Lwsc_skip:
    add     x2, x2, x0
    b       .Lwsc_loop
.Lwsc_not_found:
    mov     w0, #-1
    ret

/*
 * tcp_parse_tsopt — Parse TCP Timestamps option from frame
 *
 * x0: frame pointer (Ethernet + IP + TCP)
 * w1: tcp_header_len (bytes, from data offset field)
 * Returns: w0 = TSval (NBO), w1 = 1 if found, 0 if not found
 * Clobbers: x0-x4
 * Leaf function.
 */
/*
 * tcp_parse_sack_permitted — Check for SACK-Permitted option (Kind=4, Len=2)
 *
 * x0: frame pointer, w1: tcp_header_len
 * Returns: w0 = 1 if found, 0 if not
 * Clobbers: x0-x4
 */
.global tcp_parse_sack_permitted
tcp_parse_sack_permitted:
    cmp     w1, #TCP_HDR_MIN
    b.le    .Lsp_not_found
    add     x2, x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_HDR_MIN)
    add     x3, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    add     x3, x3, x1
.Lsp_loop:
    cmp     x2, x3
    b.hs    .Lsp_not_found
    ldrb    w4, [x2]
    cbz     w4, .Lsp_not_found
    cmp     w4, #TCP_OPT_NOP
    b.eq    .Lsp_nop
    add     x0, x2, #1
    cmp     x0, x3
    b.hs    .Lsp_not_found
    ldrb    w0, [x2, #1]
    cmp     w0, #2
    b.lt    .Lsp_not_found
    cmp     w4, #TCP_OPT_SACK_PERM
    b.ne    .Lsp_skip
    cmp     w0, #TCP_OPT_SACK_PERM_LEN
    b.ne    .Lsp_skip
    mov     w0, #1
    ret
.Lsp_nop:
    add     x2, x2, #1
    b       .Lsp_loop
.Lsp_skip:
    add     x2, x2, x0
    b       .Lsp_loop
.Lsp_not_found:
    mov     w0, #0
    ret

tcp_parse_tsopt:
    /* If header_len <= 20, no options */
    cmp     w1, #TCP_HDR_MIN
    b.le    .Ltso_not_found

    /* x2 = pointer to first option byte */
    add     x2, x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_HDR_MIN)
    /* x3 = end of options */
    add     x3, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    add     x3, x3, x1

.Ltso_loop:
    cmp     x2, x3
    b.hs    .Ltso_not_found

    ldrb    w4, [x2]
    cbz     w4, .Ltso_not_found     /* Kind 0 = EOL */
    cmp     w4, #TCP_OPT_NOP
    b.eq    .Ltso_nop

    /* Kind != 0, != 1 → variable-length option */
    /* Need at least 2 bytes (kind + length) */
    add     x0, x2, #1
    cmp     x0, x3
    b.hs    .Ltso_not_found

    ldrb    w0, [x2, #1]           /* length byte */
    cmp     w0, #2
    b.lt    .Ltso_not_found        /* malformed */

    /* Check for Kind=8 (Timestamps), Length=10 */
    cmp     w4, #TCP_OPT_TIMESTAMPS
    b.ne    .Ltso_skip

    cmp     w0, #TCP_OPT_TS_LEN
    b.ne    .Ltso_skip

    /* Verify enough bytes remain */
    add     x0, x2, #TCP_OPT_TS_LEN
    cmp     x0, x3
    b.hi    .Ltso_not_found

    /* Found! TSval at offset +2, TSecr at offset +6 */
    ldr     w0, [x2, #2]           /* TSval (NBO) */
    mov     w1, #1
    ret

.Ltso_nop:
    add     x2, x2, #1
    b       .Ltso_loop

.Ltso_skip:
    ldrb    w0, [x2, #1]           /* length */
    add     x2, x2, x0             /* skip this option */
    b       .Ltso_loop

.Ltso_not_found:
    mov     w0, #0
    mov     w1, #0
    ret

/*
 * tcp_isn — Generate initial sequence number (weak, overridable)
 *
 * w0: lport (NBO), w1: rport (NBO), w2: lip (NBO), w3: rip (NBO)
 * Returns: w0 = 32-bit ISN
 * Clobbers: x0-x6
 *
 * Hash 4-tuple with secret, multiply by golden-ratio constant,
 * fold to 32 bits, add time component.
 * Override in fuzz harness for user-mode QEMU.
 */
.weak tcp_isn
tcp_isn:
    /* Pack 4-tuple: x4 = lport | (rport << 16), x5 = lip | (rip << 32) */
    orr     x4, x0, x1, lsl #16
    orr     x5, x2, x3, lsl #32
    eor     x4, x4, x5

    /* XOR with ISN secret */
    ldr     x5, =tcp_isn_secret
    ldr     x5, [x5]
    eor     x4, x4, x5

    /* Multiply by golden-ratio constant */
    ldr     x5, =0x517cc1b727220a95
    mul     x4, x4, x5

    /* Fold 64→32 */
    eor     x4, x4, x4, lsr #32

    /* Add time component (~4ms granularity at 19.2 MHz: shift right 2) */
    mrs     x5, CNTPCT_EL0
    lsr     x5, x5, #2
    add     w0, w4, w5
    ret

/*
 * tcp_fast_retransmit — Retransmit immediately on 3 duplicate ACKs
 *
 * x0: connection pointer
 * Performs: multiplicative decrease (cwnd halved + 3*MSS inflate),
 *           copy rtxbuf → tx_buf, send, reset RTO timer.
 * Clobbers: x0-x6, x19-x22, x30
 */
tcp_fast_retransmit:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x19, x0

    /* Multiplicative decrease: ssthresh = max(cwnd/2, 2*MSS) */
    ldr     w0, [x19, #TCONN_CWND]
    lsr     w0, w0, #1              /* cwnd / 2 */
    ldrh    w1, [x19, #TCONN_PEER_MSS]
    lsl     w2, w1, #1              /* 2 * MSS */
    cmp     w0, w2
    csel    w0, w0, w2, hs          /* max(cwnd/2, 2*MSS) */
    str     w0, [x19, #TCONN_SSTHRESH]
    /* cwnd = ssthresh + 3*MSS (RFC 5681: inflate for 3 dup ACKs in flight) */
    mov     w2, #3
    mul     w2, w1, w2
    add     w0, w0, w2
    mov     w3, #0x40000                /* 256 KB cap */
    cmp     w0, w3
    csel    w0, w0, w3, lo
    str     w0, [x19, #TCONN_CWND]

    /* Rebuild and send from send buffer */
    ldr     x20, =tcp_send_ctx
    ldr     x1, [x20, #TSCTX_SEND_FN]
    cbz     x1, .Lfrtx_done

    mov     x0, x19
    ldr     x1, [x20, #TSCTX_TX_BUF]
    bl      tcp_sndbuf_build_frame
    cbz     w0, .Lfrtx_done
    mov     w21, w0

    ldr     x0, [x20, #TSCTX_DWC2_BASE]
    ldr     x1, [x20, #TSCTX_ECM_STATE]
    ldr     x2, [x20, #TSCTX_TX_BUF]
    mov     w3, w21
    ldr     x4, [x20, #TSCTX_SEND_FN]
    blr     x4

    /* Reset RTO timer (restart from 1 second) */
    strb    wzr, [x19, #TCONN_RTXCOUNT]
    mov     x0, x19
    bl      tcp_rtx_arm

.Lfrtx_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_idle_reaper_cb — Periodic timer callback to close idle connections
 *
 * x0: context (unused)
 * Scans all 16 connection slots. For non-CLOSED/LISTEN/TIME_WAIT slots,
 * computes elapsed = timer_now() - LAST_ACTIVE and compares against
 * per-state timeout thresholds.
 * Re-arms itself for the next interval.
 * Clobbers: x0-x6, x19-x22, x30
 */
tcp_idle_reaper_cb:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      timer_now
    mov     x20, x0                 /* x20 = now */
    bl      timer_freq
    mov     x22, x0                 /* x22 = freq */

    ldr     x19, =tcp_conn_table
    mov     w21, #TCP_MAX_CONNS
.Lreap_loop:
    cbz     w21, .Lreap_rearm
    sub     w21, w21, #1

    ldrb    w0, [x19, #TCONN_STATE]
    /* Skip CLOSED, LISTEN, TIME_WAIT */
    cbz     w0, .Lreap_next         /* CLOSED */
    cmp     w0, #TCPS_LISTEN
    b.eq    .Lreap_next
    cmp     w0, #TCPS_TIME_WAIT
    b.eq    .Lreap_next

    /* Compute elapsed seconds: (now - LAST_ACTIVE) / freq */
    ldr     x1, [x19, #TCONN_LAST_ACTIVE]
    sub     x1, x20, x1             /* elapsed ticks */
    udiv    x1, x1, x22             /* elapsed seconds */

    /* Select timeout threshold by state */
    cmp     w0, #TCPS_ESTABLISHED
    b.eq    .Lreap_estab
    cmp     w0, #TCPS_SYN_RCVD
    b.eq    .Lreap_synrcvd
    cmp     w0, #TCPS_FIN_WAIT_1
    b.eq    .Lreap_finwait
    cmp     w0, #TCPS_FIN_WAIT_2
    b.eq    .Lreap_finwait
    /* CLOSE_WAIT, LAST_ACK, CLOSING */
    mov     x2, #TCP_IDLE_CLOSEWAIT
    b       .Lreap_check

.Lreap_synrcvd:
    mov     x2, #TCP_IDLE_SYNRCVD
    b       .Lreap_check
.Lreap_estab:
    mov     x2, #TCP_IDLE_ESTAB
    b       .Lreap_check
.Lreap_finwait:
    mov     x2, #TCP_IDLE_FINWAIT2
.Lreap_check:
    cmp     x1, x2
    b.lo    .Lreap_next

    /* Timeout exceeded: tear down connection */
    mov     x0, x19
    bl      tcp_rtx_clear
    strb    wzr, [x19, #TCONN_STATE]

.Lreap_next:
    add     x19, x19, #TCONN_SIZE
    b       .Lreap_loop

.Lreap_rearm:
    /* Re-arm reaper timer for next interval */
    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Lreap_done
    mov     x19, x0                 /* pool */
    mov     x1, #TCP_REAPER_INTERVAL
    mul     x1, x22, x1
    add     x1, x20, x1             /* expiry = now + interval*freq */
    mov     x0, x19
    ldr     x2, =tcp_idle_reaper_cb
    mov     x3, xzr
    bl      timer_set
    ldr     x1, =tcp_reaper_slot
    str     w0, [x1]

.Lreap_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_start_reaper — Arm the idle connection reaper timer
 *
 * Call after tcp_set_timer_pool.
 * Clobbers: x0-x3, x19-x21, x30
 */
tcp_start_reaper:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Lsr_done
    mov     x19, x0                 /* pool */
    bl      timer_freq
    mov     x20, x0                 /* freq */
    mov     x1, #TCP_REAPER_INTERVAL
    mul     x20, x20, x1            /* interval ticks */
    bl      timer_now
    add     x1, x0, x20             /* expiry */
    mov     x0, x19
    ldr     x2, =tcp_idle_reaper_cb
    mov     x3, xzr
    bl      timer_set
    ldr     x1, =tcp_reaper_slot
    str     w0, [x1]
.Lsr_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_persist_arm — Arm persist timer with exponential backoff
 *
 * x0: connection pointer
 * timeout = min(TCP_PERSIST_INITIAL << (shift-1), TCP_PERSIST_MAX) seconds
 * Clobbers: x0-x3, x19-x21, x30
 */
tcp_persist_arm:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x0                 /* conn */

    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Lparm_done
    mov     x20, x0                 /* pool */

    /* Compute timeout: TCP_PERSIST_INITIAL << (shift-1), capped at TCP_PERSIST_MAX */
    ldrb    w1, [x19, #TCONN_PERSIST_SHIFT]
    sub     w1, w1, #1
    mov     w2, #TCP_PERSIST_INITIAL
    lsl     w2, w2, w1              /* 5 << (shift-1) */
    cmp     w2, #TCP_PERSIST_MAX
    mov     w3, #TCP_PERSIST_MAX
    csel    w21, w2, w3, lo         /* min(shifted, 60) */

    bl      timer_freq
    mul     x21, x0, x21            /* timeout ticks */
    bl      timer_now
    add     x1, x0, x21             /* expiry */
    mov     x0, x20                 /* pool */
    ldr     x2, =tcp_persist_cb
    mov     x3, x19                 /* context = conn */
    bl      timer_set
    /* (We don't track persist slot — it auto-cancels on window open) */

.Lparm_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * tcp_persist_cb — Timer callback for zero-window probing
 *
 * x0: connection pointer (context)
 * Sends a window probe (zero-length ACK with SEQ=SND_UNA) to nudge
 * the peer into sending a window update.
 * Increments PERSIST_SHIFT (backoff), re-arms timer.
 * Clobbers: x0-x6, x19-x22, x30
 */
tcp_persist_cb:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* conn */

    /* Guard: if state != ESTABLISHED or SND_WND != 0, stale — return */
    ldrb    w1, [x19, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.ne    .Lpersist_done
    ldr     w1, [x19, #TCONN_SND_WND]
    cbnz    w1, .Lpersist_done

    /* Build window probe using tcp_build_frame: zero-length ACK */
    ldr     x20, =tcp_send_ctx
    ldr     x1, [x20, #TSCTX_SEND_FN]
    cbz     x1, .Lpersist_done
    ldr     x21, [x20, #TSCTX_TX_BUF]

    mov     x0, x19                 /* conn */
    mov     x1, x21                 /* frame buf (tx_buf) */
    mov     w2, #TCP_ACK_FLAG       /* flags */
    mov     x3, #0                  /* no payload */
    mov     w4, #0
    bl      tcp_build_frame
    mov     w22, w0                 /* frame_len */

    /* Send the probe */
    ldr     x0, [x20, #TSCTX_DWC2_BASE]
    ldr     x1, [x20, #TSCTX_ECM_STATE]
    mov     x2, x21                 /* tx_buf */
    mov     w3, w22                 /* frame_len */
    ldr     x4, [x20, #TSCTX_SEND_FN]
    blr     x4

    /* Increase PERSIST_SHIFT (backoff) */
    ldrb    w0, [x19, #TCONN_PERSIST_SHIFT]
    add     w0, w0, #1
    cmp     w0, #5                  /* cap shift so timeout doesn't exceed PERSIST_MAX */
    mov     w1, #5
    csel    w0, w0, w1, lo
    strb    w0, [x19, #TCONN_PERSIST_SHIFT]

    /* Re-arm persist timer */
    mov     x0, x19
    bl      tcp_persist_arm

.Lpersist_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/*
 * tcp_timewait_fin_handler — Re-ACK retransmitted FIN in TIME_WAIT
 *
 * x0: connection, x1: frame
 * Rebuilds ACK reply with current SEQ/ACK, restarts 2MSL timer.
 * Returns: w0 = 54 or 66 (frame length)
 */
tcp_timewait_fin_handler:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* x19 = conn */

    /* Build ACK: SEQ=SND_NXT(NBO), ACK=RCV_NXT(NBO) */
    ldr     w20, [x19, #TCONN_SND_NXT]
    ldr     w21, [x19, #TCONN_RCV_NXT]

    /* Dynamic window */
    ldrh    w4, [x19, #TCONN_RXLEN]
    mov     w6, #TCP_RXBUF_SIZE
    sub     w4, w6, w4
    rev16   w4, w4
    uxth    w4, w4

    mov     x0, x1                  /* frame */
    rev     w1, w20                 /* SEQ NBO */
    rev     w2, w21                 /* ACK NBO */
    mov     w3, #TCP_ACK_FLAG
    mov     x5, x19                 /* conn */
    bl      tcp_build_reply
    mov     w22, w0                 /* save frame len */

    /* Restart 2MSL timer: cancel old if active */
    ldr     w1, [x19, #TCONN_TIMER_SLOT]
    cmn     w1, #1
    b.eq    .Ltwfin_arm
    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Ltwfin_done
    bl      timer_cancel

.Ltwfin_arm:
    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Ltwfin_done
    mov     x20, x0                 /* pool */
    bl      timer_freq
    mov     x1, #60
    mul     x21, x0, x1             /* 60s ticks */
    bl      timer_now
    add     x1, x0, x21             /* expiry */
    mov     x0, x20                 /* pool */
    ldr     x2, =tcp_timewait_cb
    mov     x3, x19                 /* context = conn */
    bl      timer_set
    str     w0, [x19, #TCONN_TIMER_SLOT]

.Ltwfin_done:
    mov     w0, w22                 /* return frame len */
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* --- FSA transition table (9 states × 5 events = 45 entries × 16 bytes) ---
 *
 * Entry layout (matches vmio.inc TRANS_*):
 *   [0..3]  TRANS_NEXT    u32 — next state
 *   [4..7]  TRANS_PAD     u32 — padding
 *   [8..15] TRANS_HANDLER u64 — handler fn ptr (0 = no transition → RST)
 *
 * Index = state * TCP_N_EVENTS + evt_code
 *
 * Handler interface:
 *   x0: connection entry pointer
 *   x1: frame pointer
 *   w2: tcp_section_len
 *   w3: tcp_header_len
 *   Returns: w0 = reply frame length, 0 = no reply, -1 = generate RST
 *
 * FSA dispatch writes next_state BEFORE calling handler.
 */
.section .rodata
.balign 8
tcp_fsa_table:
    /* State 0: CLOSED — all events → no handler (RST) */
    .word 0, 0; .xword 0                                       /* RST */
    .word 0, 0; .xword 0                                       /* SYN */
    .word 0, 0; .xword 0                                       /* SYNACK */
    .word 0, 0; .xword 0                                       /* FIN */
    .word 0, 0; .xword 0                                       /* ACK */

    /* State 1: LISTEN */
    .word 0, 0; .xword 0                                       /* RST → drop (no handler) */
    .word TCPS_LISTEN, 0; .xword tcp_listen_syn_handler         /* SYN → LISTEN (handler allocates new conn as SYN_RCVD) */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word 0, 0; .xword 0                                       /* FIN → RST */
    .word 0, 0; .xword 0                                       /* ACK → RST */

    /* State 2: SYN_RCVD */
    .word TCPS_CLOSED, 0; .xword tcp_conn_close_handler         /* RST → CLOSED */
    .word 0, 0; .xword 0                                       /* SYN → RST */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word 0, 0; .xword 0                                       /* FIN → RST */
    .word TCPS_ESTABLISHED, 0; .xword tcp_synrcvd_ack_handler   /* ACK → ESTABLISHED */

    /* State 3: ESTABLISHED */
    .word TCPS_CLOSED, 0; .xword tcp_conn_close_handler         /* RST → CLOSED */
    .word 0, 0; .xword 0                                       /* SYN → RST */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word TCPS_CLOSE_WAIT, 0; .xword tcp_estab_fin_handler      /* FIN → CLOSE_WAIT */
    .word TCPS_ESTABLISHED, 0; .xword tcp_estab_ack_handler     /* ACK → ESTABLISHED */

    /* State 4: CLOSE_WAIT */
    .word TCPS_CLOSED, 0; .xword tcp_conn_close_handler         /* RST → CLOSED */
    .word 0, 0; .xword 0                                       /* SYN → RST */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word 0, 0; .xword 0                                       /* FIN → RST */
    .word TCPS_CLOSE_WAIT, 0; .xword tcp_drop_handler           /* ACK → CLOSE_WAIT (absorb) */

    /* State 5: LAST_ACK */
    .word TCPS_CLOSED, 0; .xword tcp_conn_close_handler         /* RST → CLOSED */
    .word 0, 0; .xword 0                                       /* SYN → RST */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word 0, 0; .xword 0                                       /* FIN → RST */
    .word TCPS_CLOSED, 0; .xword tcp_lastack_ack_handler         /* ACK → CLOSED */

    /* State 6: FIN_WAIT_1 */
    .word TCPS_CLOSED, 0; .xword tcp_conn_close_handler         /* RST → CLOSED */
    .word 0, 0; .xword 0                                       /* SYN → RST */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word TCPS_CLOSING, 0; .xword tcp_finwait1_fin_handler       /* FIN → CLOSING */
    .word TCPS_FIN_WAIT_2, 0; .xword tcp_finwait1_ack_handler   /* ACK → FIN_WAIT_2 */

    /* State 7: FIN_WAIT_2 */
    .word TCPS_CLOSED, 0; .xword tcp_conn_close_handler         /* RST → CLOSED */
    .word 0, 0; .xword 0                                       /* SYN → RST */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word TCPS_TIME_WAIT, 0; .xword tcp_finwait2_fin_handler     /* FIN → TIME_WAIT */
    .word TCPS_FIN_WAIT_2, 0; .xword tcp_drop_handler           /* ACK → FIN_WAIT_2 */

    /* State 8: TIME_WAIT */
    .word TCPS_CLOSED, 0; .xword tcp_conn_close_handler         /* RST → CLOSED */
    .word 0, 0; .xword 0                                       /* SYN → RST */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word TCPS_TIME_WAIT, 0; .xword tcp_timewait_fin_handler       /* FIN → TIME_WAIT (re-ACK) */
    .word TCPS_TIME_WAIT, 0; .xword tcp_drop_handler             /* ACK → TIME_WAIT */

    /* State 9: CLOSING */
    .word TCPS_CLOSED, 0; .xword tcp_conn_close_handler         /* RST → CLOSED */
    .word 0, 0; .xword 0                                       /* SYN → RST */
    .word 0, 0; .xword 0                                       /* SYNACK → RST */
    .word 0, 0; .xword 0                                       /* FIN → RST */
    .word TCPS_TIME_WAIT, 0; .xword tcp_closing_ack_handler     /* ACK → TIME_WAIT */

/* --- Connection table and TCP state (BSS) --- */

.section .bss
.balign 16
tcp_conn_table:
    .space  TCP_CONN_TABLE_SIZE

.balign 8
tcp_timer_pool_ptr:
    .space  8

.balign 16
tcp_rxbuf_pool:
    .space  TCP_RXBUF_POOL_SIZE

.balign 16
tcp_rtxbuf_pool:
    .space  TCP_RTXBUF_POOL_SIZE

.balign 16
.global tcp_sndbuf_pool
tcp_sndbuf_pool:
    .space  TCP_SNDBUF_POOL_SIZE

.balign 8
tcp_send_ctx:
    .space  TSCTX_SIZE

.balign 8
tcp_isn_secret:
    .space  TCP_ISN_SECRET_SIZE

.balign 4
tcp_rst_tokens:
    .word   0

.balign 8
tcp_rst_last_tick:
    .space  8

.balign 4
tcp_reaper_slot:
    .space  4                       /* 0 = no active reaper slot */
