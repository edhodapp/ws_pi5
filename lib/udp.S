/*
 * udp.S — UDP checksum and packet handler
 *
 * udp_checksum: ones' complement checksum with pseudo-header (RFC 768)
 * udp_handle:   validation + port dispatch (echo on port 7)
 */

.include "net.inc"
.include "ntp.inc"

.global udp_checksum
.global udp_handle

.section .text

/*
 * udp_checksum — UDP ones' complement checksum with IPv4 pseudo-header
 *
 * x0: frame buffer pointer (Ethernet + IP + UDP)
 * w1: UDP segment length in bytes (header + data)
 * Returns: w0 = 16-bit checksum (0 when verifying a valid segment)
 * Clobbers: x0-x3
 *
 * Accumulates pseudo-header fields (IP src, dst, protocol, UDP length)
 * directly from their frame positions, then sums the UDP segment.
 * No temp buffer needed.
 */
udp_checksum:
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

    /* Pseudo-header: zero + protocol (UDP=17, LE halfword of 00 11) */
    mov     w3, #0x1100
    add     w2, w2, w3

    /* Pseudo-header: UDP length */
    ldrh    w3, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_LENGTH)]
    add     w2, w2, w3

    /* Point to UDP section for linear sum */
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN)

.Ludp_cksum_loop:
    cmp     w1, #2
    b.lt    .Ludp_cksum_odd
    ldrh    w3, [x0], #2
    add     w2, w2, w3
    sub     w1, w1, #2
    b       .Ludp_cksum_loop

.Ludp_cksum_odd:
    cbz     w1, .Ludp_cksum_fold
    ldrb    w3, [x0]
    add     w2, w2, w3

.Ludp_cksum_fold:
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
 * udp_handle — UDP packet handler
 *
 * x0: frame buffer pointer (Ethernet + IP + UDP)
 * w1: frame length (ETH_HDR_LEN + IP.TotalLength)
 * Returns: w0 = reply length or 0 (dropped)
 * Clobbers: x0-x5, x19-x21, x30
 *
 * Validates UDP header then dispatches by destination port:
 *   port 7 (echo) → echo reply, else → drop
 */
udp_handle:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x0                 /* x19 = frame */
    mov     w20, w1                 /* w20 = frame_len */

    /* 1. udp_section_len = frame_len - ETH_HDR_LEN - IP_HDR_MIN */
    sub     w21, w20, #(ETH_HDR_LEN + IP_HDR_MIN)

    /* 2. udp_section_len >= UDP_HDR_LEN (8) */
    cmp     w21, #UDP_HDR_LEN
    b.lt    .Ludp_drop

    /* 3. UDP Length field == udp_section_len */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_LENGTH)]
    rev16   w0, w0
    uxth    w0, w0
    cmp     w0, w21
    b.ne    .Ludp_drop

    /* 4. If UDP checksum != 0, verify checksum */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_CHECKSUM)]
    cbz     w0, .Ludp_cksum_ok

    mov     x0, x19
    mov     w1, w21
    bl      udp_checksum
    cbnz    w0, .Ludp_drop

.Ludp_cksum_ok:
    /* 5. Port dispatch */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_DPORT)]
    rev16   w0, w0
    uxth    w0, w0
    cmp     w0, #UDP_ECHO_PORT
    b.eq    .Ludp_echo
    cmp     w0, #NTP_PORT
    b.eq    .Ludp_ntp

    /* Unknown port → ICMP Port Unreachable (type 3, code 3) */
    mov     x0, x19
    mov     w1, w20
    mov     w2, #ICMP_DEST_UNREACHABLE
    mov     w3, #ICMP_CODE_PORT_UNREACH
    bl      icmp_send_error
    b       .Ludp_drop

.Ludp_ntp:
    /* NTP response: get current ticks, extract NTP payload, call ntp_handle */
    bl      timer_now
    mov     x2, x0                          /* x2 = current_ticks */
    add     x0, x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN)
    sub     w1, w21, #UDP_HDR_LEN           /* payload len = udp_section - 8 */
    bl      ntp_handle
    mov     w0, #0                          /* no reply frame */
    b       .Ludp_done

.Ludp_echo:

    /* === Echo reply (RFC 862) === */

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

    /* 4. Swap UDP sport ↔ dport */
    ldrh    w2, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_SPORT)]
    ldrh    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_DPORT)]
    strh    w3, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_SPORT)]
    strh    w2, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_DPORT)]

    /* 5. Recompute UDP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_CHECKSUM)]
    mov     x0, x19
    mov     w1, w21
    bl      udp_checksum
    /* RFC 768: if computed == 0, store 0xFFFF (0 means "not computed") */
    cmp     w0, #0
    csinv   w0, w0, wzr, ne
    uxth    w0, w0
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_CHECKSUM)]

    /* 6. Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Return frame_len */
    mov     w0, w20
    b       .Ludp_done

.Ludp_drop:
    mov     w0, #0

.Ludp_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
