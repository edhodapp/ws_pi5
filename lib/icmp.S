/*
 * icmp.S — ICMP echo reply handler + error generation
 *
 * icmp_handle:     echo reply, dest-unreachable routing, checksum validation
 * icmp_send_error: build and send ICMP error messages (rate-limited)
 * icmp_init:       initialize rate limiter state
 * icmp_set_send_ctx: store send context for error generation
 */

.include "net.inc"
.include "timer.inc"

.global icmp_handle
.global icmp_init
.global icmp_set_send_ctx
.global icmp_send_error
.global icmp_err_allow
.global icmp_send_ctx
.global icmp_err_tokens

.section .text

/*
 * icmp_init — Initialize ICMP rate limiter
 * Clobbers: x0-x1
 */
icmp_init:
    ldr     x0, =icmp_err_tokens
    mov     w1, #ICMP_ERR_BURST
    str     w1, [x0]
    ldr     x0, =icmp_err_last_tick
    str     xzr, [x0]
    ret

/*
 * icmp_set_send_ctx — Store I/O context for ICMP error generation
 *
 * x0: DWC2 base, x1: ecm_state, x2: tx_buf, x3: send_fn
 * Clobbers: x4
 */
icmp_set_send_ctx:
    ldr     x4, =icmp_send_ctx
    str     x0, [x4, #ICMPC_DWC2_BASE]
    str     x1, [x4, #ICMPC_ECM_STATE]
    str     x2, [x4, #ICMPC_TX_BUF]
    str     x3, [x4, #ICMPC_SEND_FN]
    ret

/*
 * icmp_err_allow — Token bucket rate limiter for ICMP errors
 *
 * Returns: w0 = 1 (allow) or 0 (deny)
 * Clobbers: x0-x4, x30
 */
icmp_err_allow:
    stp     x19, x30, [sp, #-16]!

    bl      timer_now
    mov     x1, x0                      /* x1 = now */

    ldr     x2, =icmp_err_last_tick
    ldr     x3, [x2]                    /* x3 = last_tick */

    /* Compute elapsed ticks */
    sub     x0, x1, x3

    /* Refill if >= 1 second elapsed */
    bl      timer_freq
    /* x0 = freq (ticks per second) */
    sub     x4, x1, x3                  /* elapsed */
    cmp     x4, x0
    b.lo    .Liea_no_refill

    /* Refill tokens */
    ldr     x3, =icmp_err_tokens
    mov     w4, #ICMP_ERR_BURST
    str     w4, [x3]
    ldr     x3, =icmp_err_last_tick
    str     x1, [x3]

.Liea_no_refill:
    /* Try to consume a token */
    ldr     x2, =icmp_err_tokens
    ldr     w3, [x2]
    cbz     w3, .Liea_deny

    sub     w3, w3, #1
    str     w3, [x2]
    mov     w0, #1
    b       .Liea_done

.Liea_deny:
    mov     w0, #0

.Liea_done:
    ldp     x19, x30, [sp], #16
    ret

/*
 * icmp_send_error — Build and send an ICMP error message
 *
 * Guards: loop suppression (no error on ICMP errors), rate limit, ctx check.
 * Frame: ETH(14) + IP(20) + ICMP(8) + orig_IP(20) + orig_payload(8) = 70 bytes.
 *
 * x0: original frame pointer
 * w1: original frame length
 * w2: ICMP type
 * w3: ICMP code
 * Returns: w0 = 0 (always)
 * Clobbers: x0-x6, x19-x24, x30
 */
icmp_send_error:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    mov     x29, sp

    mov     x19, x0                     /* x19 = original frame */
    mov     w20, w1                     /* w20 = original frame_len */
    mov     w21, w2                     /* w21 = ICMP type */
    mov     w22, w3                     /* w22 = ICMP code */

    /* Guard 1: Don't send ICMP errors in response to ICMP errors */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_PROTO)]
    cmp     w0, #IP_PROTO_ICMP
    b.ne    .Lise_not_icmp

    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cmp     w0, #ICMP_DEST_UNREACHABLE
    b.eq    .Lise_ret
    cmp     w0, #ICMP_REDIRECT
    b.eq    .Lise_ret
    cmp     w0, #ICMP_TIME_EXCEEDED
    b.eq    .Lise_ret
    cmp     w0, #ICMP_PARAM_PROBLEM
    b.eq    .Lise_ret

.Lise_not_icmp:
    /* Guard 2: Rate limit */
    bl      icmp_err_allow
    cbz     w0, .Lise_ret

    /* Guard 3: Send context initialized */
    ldr     x23, =icmp_send_ctx
    ldr     x24, [x23, #ICMPC_TX_BUF]
    ldr     x5, [x23, #ICMPC_SEND_FN]
    cbz     x5, .Lise_ret

    /* === Build 70-byte ICMP error frame in tx_buf (x24) === */

    /* ETH header: dst = original sender's MAC, src = ours */
    mov     x0, x24
    add     x1, x19, #ETH_SRC          /* dst = original frame's src MAC */
    mov     w2, #ETHERTYPE_IPV4
    bl      eth_build_hdr

    /* IP header at tx_buf + ETH_PAYLOAD */
    add     x0, x24, #ETH_PAYLOAD

    mov     w1, #0x45
    strb    w1, [x0, #IP_VER_IHL]
    strb    wzr, [x0, #IP_DSCP_ECN]

    /* totlen = 56 (IP(20) + ICMP(8) + orig(28)) → NBO 0x0038 → LE 0x3800 */
    mov     w1, #0x3800
    strh    w1, [x0, #IP_TOTLEN]

    strh    wzr, [x0, #IP_ID]
    strh    wzr, [x0, #IP_FLAGS_FRAG]

    mov     w1, #IP_DEFAULT_TTL
    strb    w1, [x0, #IP_TTL]
    mov     w1, #IP_PROTO_ICMP
    strb    w1, [x0, #IP_PROTO]
    strh    wzr, [x0, #IP_CHECKSUM]

    /* src = our IP */
    ldr     x1, =net_our_ip
    ldr     w1, [x1]
    str     w1, [x0, #IP_SRC]

    /* dst = original packet's source IP */
    ldr     w1, [x19, #(ETH_PAYLOAD + IP_SRC)]
    str     w1, [x0, #IP_DST]

    /* Compute IP checksum */
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x24, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* ICMP header at tx_buf + ETH_PAYLOAD + IP_HDR_MIN */
    add     x0, x24, #(ETH_PAYLOAD + IP_HDR_MIN)
    strb    w21, [x0, #ICMP_TYPE]
    strb    w22, [x0, #ICMP_CODE]
    strh    wzr, [x0, #ICMP_CHECKSUM]
    str     wzr, [x0, #ICMP_ID]        /* "unused" 4 bytes = 0 */

    /* ICMP payload: copy original IP header (20 bytes) + first 8 bytes of payload.
     * Total = 28 bytes. Guard: copy min(frame_len - ETH_HDR_LEN, 28). */
    add     x0, x24, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_HDR_LEN)
    add     x1, x19, #ETH_PAYLOAD      /* src = original IP header */
    sub     w2, w20, #ETH_HDR_LEN      /* available = frame_len - 14 */
    cmp     w2, #28
    csel    w2, w2, w4, lo             /* min(available, 28) */
    mov     w4, #28
    cmp     w2, #28
    csel    w2, w2, w4, lo

    /* Zero destination first (in case available < 28) */
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]

    /* Copy available bytes */
    mov     w3, #0
.Lise_copy:
    cmp     w3, w2
    b.hs    .Lise_copy_done
    ldrb    w5, [x1, x3]
    strb    w5, [x0, x3]
    add     w3, w3, #1
    b       .Lise_copy
.Lise_copy_done:

    /* Compute ICMP checksum over 36 bytes (8 hdr + 28 payload) */
    add     x0, x24, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #36
    bl      ip_checksum
    strh    w0, [x24, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]

    /* Send: send_fn(dwc2_base, ecm_state, tx_buf, 70) */
    ldr     x5, [x23, #ICMPC_SEND_FN]
    ldr     x0, [x23, #ICMPC_DWC2_BASE]
    ldr     x1, [x23, #ICMPC_ECM_STATE]
    mov     x2, x24
    mov     w3, #ICMP_ERROR_FRAME_LEN
    blr     x5

.Lise_ret:
    mov     w0, #0
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * icmp_handle — Process ICMP echo request, build reply in-place
 *
 * x0: frame buffer pointer (Ethernet + IP + ICMP)
 * w1: frame length (ETH_HDR_LEN + IP.TotalLength)
 * Returns: w0 = frame length (reply built) or 0 (ignored)
 * Clobbers: x0-x5, x19-x21, x30
 */
icmp_handle:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x0                 /* x19 = frame */
    mov     w20, w1                 /* w20 = frame_len */

    /* Compute ICMP length */
    sub     w21, w20, #(ETH_HDR_LEN + IP_HDR_MIN)
    cmp     w21, #ICMP_HDR_LEN
    b.lt    .Licmp_ignore

    /* Verify ICMP checksum */
    add     x0, x19, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, w21
    bl      ip_checksum
    cbnz    w0, .Licmp_ignore

    /* Check ICMP type */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cmp     w0, #ICMP_DEST_UNREACHABLE
    b.eq    .Licmp_dest_unreach
    cmp     w0, #ICMP_ECHO_REQUEST
    b.ne    .Licmp_ignore

    /* === Build echo reply in-place === */

    /* 1. Swap ETH dst ↔ src */
    ldr     w2, [x19, #ETH_DST]
    ldrh    w3, [x19, #(ETH_DST + 4)]
    ldr     w4, [x19, #ETH_SRC]
    ldrh    w5, [x19, #(ETH_SRC + 4)]
    str     w4, [x19, #ETH_DST]
    strh    w5, [x19, #(ETH_DST + 4)]
    str     w2, [x19, #ETH_SRC]
    strh    w3, [x19, #(ETH_SRC + 4)]

    /* 2. Swap IP src ↔ dst */
    ldr     w2, [x19, #(ETH_PAYLOAD + IP_SRC)]
    ldr     w3, [x19, #(ETH_PAYLOAD + IP_DST)]
    str     w3, [x19, #(ETH_PAYLOAD + IP_SRC)]
    str     w2, [x19, #(ETH_PAYLOAD + IP_DST)]

    /* 3. Set IP TTL = 64 */
    mov     w2, #IP_DEFAULT_TTL
    strb    w2, [x19, #(ETH_PAYLOAD + IP_TTL)]

    /* 4. Set ICMP type = echo reply (0) */
    strb    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]

    /* 5. Recompute ICMP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]
    add     x0, x19, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, w21
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]

    /* 6. Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Return frame length */
    mov     w0, w20
    b       .Licmp_done

.Licmp_dest_unreach:
    mov     x0, x19                 /* frame */
    mov     w1, w20                 /* frame_len */
    bl      tcp_icmp_err
    b       .Licmp_done

.Licmp_ignore:
    mov     w0, #0

.Licmp_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===================================================================
 * Data
 * =================================================================== */
.section .data
.balign 8
icmp_send_ctx:
    .space  ICMPC_SIZE

.balign 4
icmp_err_tokens:
    .word   0

.balign 8
icmp_err_last_tick:
    .space  8
