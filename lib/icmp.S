/*
 * icmp.S — ICMP echo reply handler
 *
 * Called by ip_handle after IP validation. Builds echo reply
 * in-place in the frame buffer.
 */

.include "net.inc"

.global icmp_handle

.section .text

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

    /* Check ICMP type == echo request (8) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cmp     w0, #ICMP_ECHO_REQUEST
    b.ne    .Licmp_ignore

    /* === Build reply in-place === */

    /* 1. Swap ETH dst ↔ src (4+2 byte pattern) */
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

.Licmp_ignore:
    mov     w0, #0

.Licmp_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
