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

.global tcp_checksum
.global tcp_build_reply
.global tcp_handle
.global tcp_init
.global tcp_conn_table

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
 * tcp_init — Initialize connection table, set slot 0 to LISTEN on port 80
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

    /* Set slot 0: state = LISTEN, lport = 80 (NBO) */
    ldr     x0, =tcp_conn_table
    mov     w1, #TCPS_LISTEN
    strb    w1, [x0, #TCONN_STATE]
    mov     w1, #0x5000             /* port 80 NBO as LE halfword */
    strh    w1, [x0, #TCONN_LPORT]
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

    ldrh    w0, [x20, #TCONN_LPORT]
    strh    w0, [x21, #TCONN_LPORT]

    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    strh    w0, [x21, #TCONN_RPORT]

    ldr     w0, [x19, #(ETH_PAYLOAD + IP_SRC)]
    str     w0, [x21, #TCONN_RIP]

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
    mov     w4, #0xB405             /* window 1460 NBO */
    bl      tcp_build_reply

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
    ldr     w4, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w4, w4
    ldr     w5, [x0, #TCONN_SND_NXT]
    cmp     w4, w5
    b.ne    .Lsra_bad_ack
    mov     w0, #0
    ret
.Lsra_bad_ack:
    mov     w4, #TCPS_SYN_RCVD
    strb    w4, [x0, #TCONN_STATE]
    mov     w0, #-1
    ret

/*
 * tcp_conn_close_handler — FSA already set state to CLOSED
 * Leaf function.
 */
tcp_conn_close_handler:
    mov     w0, #0
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
 * Otherwise: RCV_NXT += data_len, build ACK reply, return 54
 */
tcp_estab_ack_handler:
    sub     w4, w2, w3              /* w4 = data_len */
    cbz     w4, .Leak_pure_ack

    /* Verify SEQ == RCV_NXT */
    ldr     w5, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w5, w5                  /* SEG.SEQ in host order */
    ldr     w6, [x0, #TCONN_RCV_NXT]
    cmp     w5, w6
    b.ne    .Leak_pure_ack          /* out of order → drop */

    /* Accept data: RCV_NXT += data_len */
    add     w6, w6, w4
    str     w6, [x0, #TCONN_RCV_NXT]

    /* Build ACK reply: SEQ=SND_NXT(NBO), ACK=new_RCV_NXT(NBO) */
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    ldr     w19, [x0, #TCONN_SND_NXT]  /* SND_NXT (host order) */
    rev     w20, w6                     /* new RCV_NXT → NBO */

    mov     x0, x1                  /* frame */
    rev     w1, w19                 /* SEQ = rev(SND_NXT) (NBO) */
    mov     w2, w20                 /* ACK = rev(RCV_NXT) (NBO) */
    mov     w3, #TCP_ACK_FLAG      /* flags = ACK */
    mov     w4, #0xB405            /* window 1460 NBO */
    bl      tcp_build_reply

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

.Leak_pure_ack:
    mov     w0, #0
    ret

/*
 * tcp_estab_fin_handler — Handle FIN in ESTABLISHED state (passive close)
 *
 * FIN consumes one sequence number: RCV_NXT += 1
 * FSA already wrote CLOSE_WAIT to TCONN_STATE.
 * Build ACK reply: SEQ=SND_NXT(NBO), ACK=new_RCV_NXT(NBO)
 */
tcp_estab_fin_handler:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    /* RCV_NXT += 1 (FIN consumes one seq) */
    ldr     w5, [x0, #TCONN_RCV_NXT]
    add     w5, w5, #1
    str     w5, [x0, #TCONN_RCV_NXT]

    ldr     w19, [x0, #TCONN_SND_NXT]  /* SND_NXT (host order) */
    rev     w20, w5                     /* new RCV_NXT → NBO */

    mov     x0, x1                  /* frame */
    rev     w1, w19                 /* SEQ = rev(SND_NXT) (NBO) */
    mov     w2, w20                 /* ACK = rev(RCV_NXT) (NBO) */
    mov     w3, #TCP_ACK_FLAG      /* flags = ACK */
    mov     w4, #0xB405            /* window 1460 NBO */
    bl      tcp_build_reply

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
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

    /* State 5: LAST_ACK — not yet implemented */
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0

    /* State 6: FIN_WAIT_1 — not yet implemented */
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0

    /* State 7: FIN_WAIT_2 — not yet implemented */
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0

    /* State 8: TIME_WAIT — not yet implemented */
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0
    .word 0, 0; .xword 0

/* --- Connection table (BSS) --- */

.section .bss
.balign 16
tcp_conn_table:
    .space  TCP_CONN_TABLE_SIZE
