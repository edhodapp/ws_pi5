/*
 * tcp.S — TCP checksum and packet handler (Phase 1: RST only)
 *
 * tcp_checksum: ones' complement checksum with pseudo-header (RFC 793)
 * tcp_handle:   validation + RST generation (no connection table)
 */

.include "net.inc"
.include "tcp.inc"

.global tcp_checksum
.global tcp_handle

.section .text

/*
 * tcp_checksum — TCP ones' complement checksum with IPv4 pseudo-header
 *
 * x0: frame buffer pointer (Ethernet + IP + TCP)
 * w1: TCP segment length in bytes (header + data)
 * Returns: w0 = 16-bit checksum (0 when verifying a valid segment)
 * Clobbers: x0-x3
 *
 * Structurally identical to udp_checksum. Differences:
 *   1. Protocol constant: 0x0600 (TCP) instead of 0x1100 (UDP)
 *   2. Length: from parameter, not from a header field
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
 * tcp_handle — TCP packet handler (Phase 1: RST for all segments)
 *
 * x0: frame buffer pointer (Ethernet + IP + TCP)
 * w1: frame length (ETH_HDR_LEN + IP.TotalLength)
 * Returns: w0 = reply length (54 for RST) or 0 (dropped)
 * Clobbers: x0-x6, x19-x22, x30
 *
 * Validates TCP header then generates RST per RFC 793 §3.4:
 *   - ACK set → RST with SEQ=SEG.ACK
 *   - No ACK  → RST+ACK with SEQ=0, ACK=SEG.SEQ+SEG.LEN
 */
tcp_handle:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

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

    /* --- RST generation (RFC 793 §3.4) --- */

    /* Read incoming flags */
    ldrb    w2, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]

    /* Branch on ACK flag */
    tst     w2, #TCP_ACK_FLAG
    b.ne    .Ltcp_rst_has_ack

    /* No ACK → RST+ACK, SEQ=0, ACK=SEG.SEQ+SEG.LEN */
    /* SEG.LEN = data_bytes + (SYN?1:0) + (FIN?1:0) */
    sub     w3, w21, w22            /* data_bytes */
    tst     w2, #TCP_SYN
    cinc    w3, w3, ne
    tst     w2, #TCP_FIN
    cinc    w3, w3, ne

    /* ACK = rev(rev(SEG.SEQ) + SEG.LEN) — big-endian arithmetic */
    ldr     w4, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w4, w4
    add     w4, w4, w3
    rev     w21, w4                 /* w21 = reply ACK (NBO) */

    mov     w20, #0                 /* w20 = reply SEQ = 0 */
    mov     w22, #TCP_RST_ACK       /* w22 = reply flags */
    b       .Ltcp_rst_common

.Ltcp_rst_has_ack:
    /* ACK set → RST, SEQ=SEG.ACK */
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    mov     w21, #0                 /* reply ACK = 0 */
    mov     w22, #TCP_RST           /* flags = RST only */

.Ltcp_rst_common:
    /* w20=reply_seq(NBO), w21=reply_ack(NBO), w22=reply_flags */

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

    /* 11. Window = 0, urgent = 0 */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_URGENT)]

    /* 12. Compute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #TCP_HDR_MIN        /* RST has no payload: 20 bytes */
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* 13. Return 54 */
    mov     w0, #TCP_RST_FRAME_LEN
    b       .Ltcp_done

.Ltcp_drop:
    mov     w0, #0

.Ltcp_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
