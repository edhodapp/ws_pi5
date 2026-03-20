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
.global tcp_rtxbuf_pool
.global tcp_send_ctx

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
    /* Zero all 1024 bytes (64 iterations of 16 bytes) */
    ldr     x0, =tcp_conn_table
    mov     w1, #64
.Ltcp_init_zero:
    stp     xzr, xzr, [x0], #16
    subs    w1, w1, #1
    b.ne    .Ltcp_init_zero

    /* Initialize ISN secret from hardware counter */
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

    /* Return slot index: (addr - table_base) >> 6 */
    ldr     x0, =tcp_conn_table
    sub     x0, x1, x0
    lsr     w0, w0, #6
    ret

.Ltl_full:
    mov     w0, #-1
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

    /* Compute slot index: (conn - tcp_conn_table) >> 6 */
    ldr     x3, =tcp_conn_table
    sub     x3, x19, x3
    lsr     x3, x3, #6

    /* Dest = tcp_rtxbuf_pool + (slot << TCP_RXBUF_SHIFT) */
    ldr     x4, =tcp_rtxbuf_pool
    add     x4, x4, x3, lsl #TCP_RXBUF_SHIFT

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
tcp_rtx_arm:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    mov     x19, x0                 /* conn */

    /* Guard: skip if no timer pool */
    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    cbz     x0, .Lrtxa_done
    mov     x20, x0                 /* x20 = timer pool */

    /* Compute RTO: 1 << min(RTXCOUNT, 5) seconds, capped at 60 */
    ldrb    w1, [x19, #TCONN_RTXCOUNT]
    cmp     w1, #TCP_RTO_SHIFT_CAP
    csel    w1, w1, w2, lo
    mov     w2, #TCP_RTO_SHIFT_CAP
    csel    w1, w1, w2, lo          /* w1 = min(count, 5) */
    mov     w3, #1
    lsl     w3, w3, w1              /* w3 = 1 << shift */
    cmp     w3, #60
    csel    w3, w3, w4, lo
    mov     w4, #60
    csel    w3, w3, w4, lo          /* w3 = min(shifted, 60) */

    /* Convert to ticks: rto_ticks = rto_secs × CNTFRQ */
    mrs     x0, CNTFRQ_EL0
    mul     x1, x0, x3             /* x1 = rto_ticks */
    mrs     x0, CNTPCT_EL0
    add     x1, x0, x1             /* x1 = expiry tick */

    /* timer_set(pool, expiry, callback, conn) */
    mov     x0, x20
    /* x1 = expiry */
    ldr     x2, =tcp_retransmit_cb
    mov     x3, x19
    bl      timer_set
    str     w0, [x19, #TCONN_TIMER_SLOT]

.Lrtxa_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
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

    /* Load send context */
    ldr     x20, =tcp_send_ctx
    ldr     x1, [x20, #TSCTX_SEND_FN]
    cbz     x1, .Lrtxcb_done       /* send_fn not set up → return */

    /* Compute slot index: (conn - tcp_conn_table) >> 6 */
    ldr     x2, =tcp_conn_table
    sub     x2, x19, x2
    lsr     x2, x2, #6

    /* Copy rtxbuf → tx_buf (RTXLEN bytes) */
    ldr     x3, =tcp_rtxbuf_pool
    add     x3, x3, x2, lsl #TCP_RXBUF_SHIFT   /* src */
    ldr     x4, [x20, #TSCTX_TX_BUF]            /* dst */
    ldrh    w21, [x19, #TCONN_RTXLEN]
    mov     w5, w21
.Lrtxcb_copy:
    cbz     w5, .Lrtxcb_send
    ldrb    w6, [x3], #1
    strb    w6, [x4], #1
    sub     w5, w5, #1
    b       .Lrtxcb_copy

.Lrtxcb_send:
    /* Call send_fn(dwc2_base, ecm_state, tx_buf, frame_len) */
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
 * Returns: w0 = 54
 * Clobbers: x0-x6, x19-x22, x30
 */
tcp_build_reply:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* x19 = frame */
    mov     w20, w1                 /* w20 = SEQ (NBO) */
    mov     w21, w2                 /* w21 = ACK (NBO) */
    mov     w22, w3                 /* w22 = flags */

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

    /* 4. IP TotalLength = 40 (0x0028 BE → 0x2800 LE halfword) */
    mov     w3, #0x2800
    strh    w3, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* 5. Zero IP ID */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_ID)]

    /* 6. Zero IP flags/frag */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]

    /* 7. Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* 8. Swap TCP sport ↔ dport */
    ldrh    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    ldrh    w4, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]
    strh    w4, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    strh    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]

    /* 9. Write SEQ, ACK */
    str     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    str     w21, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* 10. Data offset = 0x50 (5 words), flags */
    mov     w3, #0x50
    strb    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    strb    w22, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]

    /* 11. Urgent = 0 (window already stored) */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_URGENT)]

    /* 12. Compute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #TCP_HDR_MIN
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Return 54 */
    mov     w0, #TCP_RST_FRAME_LEN

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
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

    /* Table lookup: index = state * TCP_N_EVENTS + evt */
    mov     w1, #TCP_N_EVENTS
    madd    w0, w20, w1, w0         /* state * 5 + evt */
    lsl     x0, x0, #4             /* * TRANS_SIZE (16) */
    ldr     x1, =tcp_fsa_table
    add     x1, x1, x0

    ldr     x16, [x1, #TRANS_HANDLER]
    cbz     x16, .Ltcp_no_conn     /* no handler → RST */
    ldr     w3, [x1, #TRANS_NEXT]

    /* Write next_state before calling handler */
    strb    w3, [x23, #TCONN_STATE]

    /* handler(conn, frame, section_len, header_len) */
    mov     x0, x23
    mov     x1, x19
    mov     w2, w21
    mov     w3, w22
    blr     x16

    cmn     w0, #1
    b.eq    .Ltcp_no_conn
    b       .Ltcp_done

.Ltcp_no_conn:
    /* --- RST generation (RFC 793 §3.4, Phase 1 behavior) --- */
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
    bl      tcp_build_reply
    b       .Ltcp_done

.Ltcp_rst_has_ack:
    /* ACK set → RST, SEQ=SEG.ACK */
    mov     x0, x19                 /* frame */
    ldr     w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]  /* SEQ = SEG.ACK */
    mov     w2, #0                  /* ACK = 0 */
    mov     w3, #TCP_RST            /* flags */
    mov     w4, #0                  /* window */
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
    mov     w0, #-1                 /* signal RST */
    b       .Llsyn_done

.Llsyn_alloc_found:
    /* x21 = free slot */
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
    strh    w0, [x21, #TCONN_SND_WND]

    str     w22, [x21, #TCONN_SND_UNA]

    add     w0, w22, #1
    str     w0, [x21, #TCONN_SND_NXT]

    ldr     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w0, w0
    add     w0, w0, #1
    str     w0, [x21, #TCONN_RCV_NXT]

    /* Build SYN-ACK reply */
    mov     x0, x19                 /* frame */
    rev     w1, w22                 /* SEQ = rev(ISN) (NBO) */
    ldr     w2, [x21, #TCONN_RCV_NXT]
    rev     w2, w2                  /* ACK = rev(RCV_NXT) (NBO) */
    mov     w3, #TCP_SYN_ACK
    /* Dynamic window from TCONN_RXLEN (just zeroed → window = TCP_RXBUF_SIZE) */
    ldrh    w4, [x21, #TCONN_RXLEN]
    mov     w5, #TCP_RXBUF_SIZE
    sub     w4, w5, w4
    rev16   w4, w4
    uxth    w4, w4
    bl      tcp_build_reply

    /* Save SYN-ACK to retransmit buffer */
    mov     x0, x21                 /* conn */
    mov     x1, x19                 /* frame */
    mov     w2, #54                 /* frame_len */
    bl      tcp_rtx_save

    mov     w0, #54                 /* restore return value */

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
    strh    w4, [x19, #TCONN_SND_WND]

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
    /* If SND_UNA == SND_NXT, all data ACKed → clear retransmit */
    cmp     w4, w6
    b.ne    .Leak_una_done
    mov     x0, x19
    bl      tcp_rtx_clear
.Leak_una_done:

    sub     w4, w21, w22            /* w4 = data_len */
    cbz     w4, .Leak_pure_ack

    /* Verify SEQ == RCV_NXT */
    ldr     w5, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w5, w5                  /* SEG.SEQ in host order */
    ldr     w6, [x19, #TCONN_RCV_NXT]
    cmp     w5, w6
    b.eq    .Leak_seq_ok
    b.lo    .Leak_dup_data          /* SEQ < RCV_NXT → duplicate, re-ACK */
    b       .Leak_pure_ack          /* SEQ > RCV_NXT → future, drop */
.Leak_seq_ok:

    /* Check rx buffer overflow */
    ldrh    w5, [x19, #TCONN_RXLEN]
    add     w7, w5, w4              /* new_rxlen = rxlen + data_len */
    cmp     w7, #TCP_RXBUF_SIZE
    b.hi    .Leak_pure_ack          /* would overflow → drop */

    /* Accept data: copy to rx buffer */

    /* Compute slot index: (conn - tcp_conn_table) >> 6 */
    ldr     x2, =tcp_conn_table
    sub     x2, x19, x2
    lsr     x2, x2, #6             /* slot index */

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
    bl      tcp_build_reply

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

.Leak_dup_data:
    /* Duplicate data: build ACK with current RCV_NXT (re-ACK for peer) */
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
    bl      tcp_build_reply
    /* Returns 54 */

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

.Leak_pure_ack:
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
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x21, x0                 /* x21 = conn (save for window) */

    /* RCV_NXT += 1 (FIN consumes one seq) */
    ldr     w5, [x0, #TCONN_RCV_NXT]
    add     w5, w5, #1
    str     w5, [x0, #TCONN_RCV_NXT]

    ldr     w19, [x0, #TCONN_SND_NXT]  /* SND_NXT (host order) */
    rev     w20, w5                     /* new RCV_NXT → NBO */

    /* Dynamic window */
    ldrh    w4, [x21, #TCONN_RXLEN]
    mov     w5, #TCP_RXBUF_SIZE
    sub     w4, w5, w4
    rev16   w4, w4
    uxth    w4, w4

    mov     x0, x1                  /* frame */
    rev     w1, w19                 /* SEQ = rev(SND_NXT) (NBO) */
    mov     w2, w20                 /* ACK = rev(RCV_NXT) (NBO) */
    mov     w3, #TCP_ACK_FLAG      /* flags = ACK */
    /* w4 = window already set */
    bl      tcp_build_reply

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
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
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* x19 = conn */
    mov     x20, x1                 /* x20 = frame buf */
    mov     w21, w2                 /* w21 = flags */
    mov     x22, x3                 /* x22 = payload ptr */
    mov     w23, w4                 /* w23 = payload len */

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

    /* totlen = 40 + payload_len (NBO via rev16) */
    add     w0, w23, #40
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x20, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* id = 0 */
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_ID)]

    /* flags/frag = 0 */
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]

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

    /* data offset=0x50, flags */
    mov     w0, #0x50
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

    /* Copy payload if present */
    cbz     w23, .Lbf_no_payload
    add     x0, x20, #54           /* dest = frame + 54 */
    mov     x1, x22                /* src = payload ptr */
    mov     w2, w23
.Lbf_copy:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lbf_copy

.Lbf_no_payload:
    /* TCP checksum over 20 + payload_len bytes */
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x20
    add     w1, w23, #TCP_HDR_MIN
    bl      tcp_checksum
    strh    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Return 54 + payload_len */
    add     w0, w23, #54

    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * tcp_close — Initiate active close on a connection
 *
 * x0: connection pointer
 * x1: frame buffer (54 bytes written if successful)
 * Returns: w0 = 54 (FIN+ACK sent) or 0 (invalid state)
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

    /* SND_NXT += 1 (FIN consumes one seq) */
    ldr     w22, [x19, #TCONN_SND_NXT]
    add     w22, w22, #1
    str     w22, [x19, #TCONN_SND_NXT]

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
    mov     w2, #54                 /* frame_len */
    bl      tcp_rtx_save

    mov     w0, #54

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
 * w3: payload length (1..1460)
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

    /* Gate: retransmit pending → can't send new data */
    ldrh    w0, [x19, #TCONN_RTXLEN]
    cbnz    w0, .Lts_err

    /* Check 1 <= payload_len <= 1460 */
    cbz     w21, .Lts_err
    cmp     w21, #1460
    b.hi    .Lts_err

    /* Check payload_len <= SND_WND */
    ldrh    w0, [x19, #TCONN_SND_WND]
    cmp     w21, w0
    b.hi    .Lts_err

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
    ldrh    w0, [x19, #TCONN_SND_WND]
    sub     w0, w0, w21
    strh    w0, [x19, #TCONN_SND_WND]

    /* Save frame to retransmit buffer */
    mov     x0, x19                 /* conn */
    mov     x1, x23                 /* frame */
    mov     w2, w22                 /* frame_len */
    bl      tcp_rtx_save

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
    /* Compute slot index: (conn - tcp_conn_table) >> 6 */
    ldr     x1, =tcp_conn_table
    sub     x1, x0, x1
    lsr     x1, x1, #6             /* slot index */

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
    /* Gate: retransmit pending → not ready */
    ldrh    w1, [x0, #TCONN_RTXLEN]
    cbnz    w1, .Ltsr_zero
    ldrh    w0, [x0, #TCONN_SND_WND]
    mov     w1, #1460
    cmp     w0, w1
    csel    w0, w0, w1, lo          /* min(SND_WND, 1460) */
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
    mov     w5, #TCP_RXBUF_SIZE
    sub     w4, w5, w4
    rev16   w4, w4
    uxth    w4, w4

    mov     x0, x1                  /* frame */
    rev     w1, w19                 /* SEQ = rev(SND_NXT) (NBO) */
    mov     w2, w20                 /* ACK = rev(RCV_NXT) (NBO) */
    mov     w3, #TCP_ACK_FLAG
    /* w4 = window already set */
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
    mov     w5, #TCP_RXBUF_SIZE
    sub     w4, w5, w4
    rev16   w4, w4
    uxth    w4, w4
    bl      tcp_build_reply
    mov     w22, w0                 /* save return value (54) */

    /* Arm 2MSL timer (60 seconds) */
    mrs     x0, CNTFRQ_EL0
    mov     x1, #60
    mul     x1, x0, x1             /* x1 = 60 * freq = expiry delta */
    mrs     x0, CNTPCT_EL0
    add     x1, x0, x1             /* x1 = now + 60s = expiry tick */

    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]               /* x0 = timer pool */
    /* x1 = expiry tick */
    ldr     x2, =tcp_timewait_cb   /* callback */
    mov     x3, x21                 /* context = conn ptr */
    bl      timer_set
    str     w0, [x21, #TCONN_TIMER_SLOT]

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

    /* Arm 2MSL timer (60 seconds) */
    mrs     x0, CNTFRQ_EL0
    mov     x1, #60
    mul     x1, x0, x1
    mrs     x0, CNTPCT_EL0
    add     x1, x0, x1

    ldr     x0, =tcp_timer_pool_ptr
    ldr     x0, [x0]
    ldr     x2, =tcp_timewait_cb
    mov     x3, x19
    bl      timer_set
    str     w0, [x19, #TCONN_TIMER_SLOT]

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
 * tcp_isn — Generate initial sequence number (weak, overridable)
 *
 * Returns: w0 = 32-bit ISN
 * Clobbers: x0
 *
 * Default: hardware counter. Override in fuzz harness for user-mode QEMU.
 */
.weak tcp_isn
tcp_isn:
    mrs     x0, CNTPCT_EL0
    ret

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
    .word TCPS_TIME_WAIT, 0; .xword tcp_drop_handler             /* FIN → TIME_WAIT */
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

.balign 8
tcp_send_ctx:
    .space  TSCTX_SIZE

.balign 8
tcp_isn_secret:
    .space  TCP_ISN_SECRET_SIZE
