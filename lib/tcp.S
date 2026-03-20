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

.global tcp_checksum
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
    /* Exact match → dispatch by state (w0 still has state) */
    b       .Ltcp_conn_dispatch

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
    /* No exact match. Check LISTEN fallback. */
    cbz     x24, .Ltcp_no_conn
    /* Must be pure SYN (SYN=1, ACK=0) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    tst     w0, #TCP_SYN
    b.eq    .Ltcp_no_conn
    tst     w0, #TCP_ACK_FLAG
    b.ne    .Ltcp_no_conn
    b       .Ltcp_handle_listen_syn

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
    rev     w21, w4                 /* w21 = reply ACK (NBO) */

    mov     w20, #0                 /* w20 = reply SEQ = 0 */
    mov     w22, #TCP_RST_ACK       /* w22 = reply flags */
    mov     w23, #0                 /* w23 = window = 0 */
    b       .Ltcp_reply_common

.Ltcp_rst_has_ack:
    /* ACK set → RST, SEQ=SEG.ACK */
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    mov     w21, #0                 /* reply ACK = 0 */
    mov     w22, #TCP_RST           /* flags = RST only */
    mov     w23, #0                 /* window = 0 */
    b       .Ltcp_reply_common

/* --- State dispatch for exact-match connections --- */

.Ltcp_conn_dispatch:
    cmp     w0, #TCPS_SYN_RCVD
    b.eq    .Ltcp_handle_syn_rcvd
    cmp     w0, #TCPS_ESTABLISHED
    b.eq    .Ltcp_handle_established
    b       .Ltcp_no_conn           /* Unknown state → RST */

/* --- LISTEN + SYN → allocate connection, send SYN-ACK --- */

.Ltcp_handle_listen_syn:
    /* Scan table for free slot (state == CLOSED) */
    ldr     x23, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ltcp_alloc_scan:
    cbz     w3, .Ltcp_no_conn      /* no free slot → RST */
    sub     w3, w3, #1
    ldrb    w0, [x23, #TCONN_STATE]
    cbz     w0, .Ltcp_alloc_found
    add     x23, x23, #TCONN_SIZE
    b       .Ltcp_alloc_scan

.Ltcp_alloc_found:
    /* x23 = free slot, x24 = LISTEN slot */

    /* ISN from tcp_isn (weak — overridable for fuzz/test) */
    bl      tcp_isn
    mov     w7, w0                  /* w7 = ISN (lower 32 bits, host order) */

    /* Populate new connection */
    mov     w0, #TCPS_SYN_RCVD
    strb    w0, [x23, #TCONN_STATE]

    /* lport from LISTEN slot */
    ldrh    w0, [x24, #TCONN_LPORT]
    strh    w0, [x23, #TCONN_LPORT]

    /* rport from frame TCP_SPORT (NBO) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    strh    w0, [x23, #TCONN_RPORT]

    /* rip from frame IP_SRC (NBO) */
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_SRC)]
    str     w0, [x23, #TCONN_RIP]

    /* SND_UNA = ISN (host order) */
    str     w7, [x23, #TCONN_SND_UNA]

    /* SND_NXT = ISN + 1 (host order) */
    add     w0, w7, #1
    str     w0, [x23, #TCONN_SND_NXT]

    /* RCV_NXT = rev(SEG.SEQ) + 1 (host order) */
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w0, w0
    add     w0, w0, #1
    str     w0, [x23, #TCONN_RCV_NXT]

    /* Build SYN-ACK reply registers */
    rev     w20, w7                 /* w20 = reply SEQ = rev(ISN) (NBO) */
    ldr     w0, [x23, #TCONN_RCV_NXT]
    rev     w21, w0                 /* w21 = reply ACK = rev(RCV_NXT) (NBO) */
    mov     w22, #TCP_SYN_ACK       /* w22 = flags */
    mov     w23, #0xB405            /* w23 = window 1460 NBO as LE halfword */
    b       .Ltcp_reply_common

/* --- SYN_RCVD state handler --- */

.Ltcp_handle_syn_rcvd:
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    /* RST → close connection */
    tst     w0, #TCP_RST
    b.ne    .Ltcp_conn_close
    /* Must have ACK */
    tst     w0, #TCP_ACK_FLAG
    b.eq    .Ltcp_no_conn
    /* Verify: rev(SEG.ACK) == SND_NXT */
    ldr     w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w1, w1
    ldr     w2, [x23, #TCONN_SND_NXT]
    cmp     w1, w2
    b.ne    .Ltcp_no_conn           /* Bad ACK → RST */
    /* Transition to ESTABLISHED */
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x23, #TCONN_STATE]
    mov     w0, #0
    b       .Ltcp_done

/* --- ESTABLISHED state handler --- */

.Ltcp_handle_established:
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    tst     w0, #TCP_RST
    b.ne    .Ltcp_conn_close
    /* Phase 2: drop everything else (Phase 3 adds data handling) */
    mov     w0, #0
    b       .Ltcp_done

/* --- Close connection (RST received) --- */

.Ltcp_conn_close:
    strb    wzr, [x23, #TCONN_STATE]   /* TCPS_CLOSED = 0 */
    mov     w0, #0
    b       .Ltcp_done

/* --- Shared reply construction (RST and SYN-ACK) --- */
/* w20=SEQ(NBO), w21=ACK(NBO), w22=flags, w23=window(NBO LE halfword) */

.Ltcp_reply_common:
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

    /* 11. Window from w23, urgent = 0 */
    strh    w23, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_URGENT)]

    /* 12. Compute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #TCP_HDR_MIN
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* 13. Return 54 */
    mov     w0, #TCP_RST_FRAME_LEN
    b       .Ltcp_done

.Ltcp_drop:
    mov     w0, #0

.Ltcp_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
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

/* --- Connection table (BSS) --- */

.section .bss
.balign 16
tcp_conn_table:
    .space  TCP_CONN_TABLE_SIZE
