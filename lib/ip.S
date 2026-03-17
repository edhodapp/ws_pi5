/*
 * ip.S — IPv4 checksum and packet handler
 *
 * ip_checksum: ones' complement checksum (RFC 1071)
 * ip_handle:   IPv4 validation + protocol dispatch (added later)
 */

.include "net.inc"

.global ip_checksum
.global ip_handle

.section .text

/*
 * ip_checksum — Ones' complement checksum per RFC 1071
 *
 * x0: pointer to data
 * w1: length in bytes
 * Returns: w0 = 16-bit checksum (0 when verifying a valid header)
 * Clobbers: x0-x4
 *
 * Sums 16-bit LE halfwords — byte-order cancels per RFC 1071,
 * so no explicit swap is needed.
 */
ip_checksum:
    mov     w2, #0                  /* accumulator */

.Lcksum_loop:
    cmp     w1, #2
    b.lt    .Lcksum_odd
    ldrh    w3, [x0], #2            /* load LE halfword, advance */
    add     w2, w2, w3
    sub     w1, w1, #2
    b       .Lcksum_loop

.Lcksum_odd:
    cbz     w1, .Lcksum_fold
    ldrb    w3, [x0]                /* odd trailing byte as low byte */
    add     w2, w2, w3

.Lcksum_fold:
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
 * ip_handle — IPv4 packet handler
 *
 * x0: frame buffer pointer (Ethernet header + IP payload)
 * w1: frame length
 * Returns: w0 = reply length or 0 (dropped)
 * Clobbers: x0-x5, x19-x21, x30
 *
 * Validates IPv4 header then dispatches by protocol:
 *   ICMP(1) → icmp_handle, else → drop
 */
ip_handle:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x0                 /* x19 = frame */
    mov     w20, w1                 /* w20 = frame_len */

    /* 1. frame_len >= ETH_HDR_LEN + IP_HDR_MIN (34) */
    cmp     w20, #(ETH_HDR_LEN + IP_HDR_MIN)
    b.lt    .Lip_drop

    /* 2. VER_IHL == 0x45 (IPv4, 20-byte header, no options) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_VER_IHL)]
    cmp     w0, #0x45
    b.ne    .Lip_drop

    /* 3. IP TotalLength >= 20 (big-endian → host order) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]
    rev16   w0, w0
    uxth    w21, w0                 /* w21 = ip_total_length */
    cmp     w21, #IP_HDR_MIN
    b.lt    .Lip_drop

    /* 4. ETH_HDR_LEN + ip_total_length <= frame_len */
    add     w0, w21, #ETH_HDR_LEN
    cmp     w0, w20
    b.gt    .Lip_drop

    /* 5. ip_checksum(ip_header, 20) == 0 */
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lip_drop

    /* 6. IP.DST == net_our_ip (wire-format compare, no rev) */
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_DST)]
    ldr     x1, =net_our_ip
    ldr     w1, [x1]
    cmp     w0, w1
    b.ne    .Lip_drop

    /* 7. Dispatch on IP.Protocol */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_PROTO)]
    cmp     w0, #IP_PROTO_ICMP
    b.ne    .Lip_drop

    /* ICMP → icmp_handle(frame, ETH_HDR_LEN + ip_total_length) */
    mov     x0, x19
    add     w1, w21, #ETH_HDR_LEN
    bl      icmp_handle
    b       .Lip_done

.Lip_drop:
    mov     w0, #0

.Lip_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
