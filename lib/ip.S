/*
 * ip.S — IPv4 checksum and packet handler
 *
 * ip_checksum: ones' complement checksum (RFC 1071)
 * ip_handle:   IPv4 validation + protocol dispatch (added later)
 *
 * Under PERF_L3, ip_handle is instrumented with PROBE_L3_* macros
 * that accumulate ticks (PERF_L3_IP_TICKS) and bump u32 counters
 * for successful dispatches (PERF_L3_IP_COUNT) and validation drops
 * (PERF_L3_IP_DROPS). The probes are zero-overhead in default
 * builds (the macros expand to nothing).
 */

.include "net.inc"
.include "perf.inc"

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
.ifdef PERF_L3
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    /* [48..64] = pad/unused, keeps SP 16-aligned */
    PROBE_L3_ENTRY x22              /* x22 = entry CNTVCT tick */
.else
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]
.endif

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

    /* 6. TTL > 0 (RFC 1122 §3.2.1.7) */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_TTL)]
    cbz     w0, .Lip_drop

    /* 7. Martian source IP filter (RFC 1122 §3.2.1.3, RFC 6890).
     *    Drop packets whose source IP makes no physical sense on
     *    the wire:
     *      7a. src == 0.0.0.0          (never valid post-DHCP)
     *      7b. src in 127.0.0.0/8      (loopback)
     *      7c. src == net_our_ip       (self-spoof)
     *
     *    DELIBERATELY NOT FILTERED (scope decision, not oversight):
     *      * 0.0.0.0/8 (we only check the exact zero address, not
     *        0.1.2.3 etc. — the rest of 0/8 is theoretical)
     *      * 169.254.0.0/16 (link-local)
     *      * 240.0.0.0/4 (reserved / "Class E")
     *    The five checks below cover the most common attack
     *    vectors on a single-host direct-cable deployment. The
     *    remaining RFC 6890 ranges are increasingly exotic and
     *    each would add ~2 instructions. Derivatives targeting
     *    internet-facing deployments should expand the filter.
     *    See README "Design Decisions" for rationale.
     *
     *    w2 = src IP in wire (NBO) order, kept for the three tests.
     *    All comparisons are wire-format against NBO literals, no
     *    byte-swap required.
     *
     *    Runtime cost: measured at zero-to-negative in steady state.
     *    See hw_test/perf_history.md entry 2026-04-09. The 24-byte
     *    code footprint shifts icmp_handle into a cache-friendly
     *    alignment; removing it actually slows the hot path by
     *    ~21 ns per echo on the current tree.
     */
    ldr     w2, [x19, #(ETH_PAYLOAD + IP_SRC)]
    cbz     w2, .Lip_drop                  /* 7a: 0.0.0.0 */
    and     w3, w2, #0xFF                  /* low byte = first octet */
    cmp     w3, #127
    b.eq    .Lip_drop                      /* 7b: 127.0.0.0/8 */
    ldr     x3, =net_our_ip
    ldr     w3, [x3]
    cmp     w2, w3
    b.eq    .Lip_drop                      /* 7c: self-spoof */
    cmn     w2, #1
    b.eq    .Lip_drop                      /* 7d: broadcast (255.255.255.255) */
    and     w3, w2, #0xF0                  /* first octet high nibble (LE byte 0) */
    cmp     w3, #0xE0
    b.eq    .Lip_drop                      /* 7e: multicast (224.0.0.0/4) */

    /* 8. IP.DST must be one of:
     *      a) net_our_ip (unicast for us)
     *      b) 224.0.0.251 (the IPv4 mDNS multicast group,
     *         per RFC 6762 §3, supported per D008/D009)
     *    Both are wire-format compares (no rev needed —
     *    the constants are stored in the same byte order).
     *    Wire bytes 0xE0 0x00 0x00 0xFB → LE u32 0xFB0000E0. */
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_DST)]
    ldr     x3, =net_our_ip
    ldr     w3, [x3]
    cmp     w0, w3
    b.eq    .Lip_dst_ok
    /* Build 0xFB0000E0 in w3 via movz/movk (single immediate
     * doesn't reach the high half cleanly). */
    movz    w3, #0x00E0
    movk    w3, #0xFB00, lsl #16
    cmp     w0, w3
    b.ne    .Lip_drop
.Lip_dst_ok:

    /* 8. Check for IP fragments: MF flag or non-zero offset */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]
    rev16   w0, w0
    uxth    w0, w0
    and     w2, w0, #0x3FFF        /* MF + frag offset */
    cbz     w2, .Lip_dispatch

    /* Fragment → reassembly engine */
    mov     x0, x19
    mov     w1, w20
    bl      ip_reasm_input
    cbz     x0, .Lip_drop          /* incomplete or error */

    /* Reassembled: x0 = frame pointer (built in-place) */
    mov     x19, x0
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]
    rev16   w0, w0
    uxth    w21, w0

.Lip_dispatch:
    /* 9. Dispatch on IP.Protocol */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_PROTO)]
    cmp     w0, #IP_PROTO_ICMP
    b.eq    .Lip_icmp
    cmp     w0, #IP_PROTO_UDP
    b.eq    .Lip_udp
    cmp     w0, #IP_PROTO_TCP
    b.ne    .Lip_proto_unreach

    /* TCP → tcp_handle(frame, ETH_HDR_LEN + ip_total_length) */
    PROBE_L3_COUNT_INC PERF_L3_IP_COUNT, w0, x1
    mov     x0, x19
    add     w1, w21, #ETH_HDR_LEN
    bl      tcp_handle
    b       .Lip_done

.Lip_udp:
    /* UDP → udp_handle(frame, ETH_HDR_LEN + ip_total_length) */
    PROBE_L3_COUNT_INC PERF_L3_IP_COUNT, w0, x1
    mov     x0, x19
    add     w1, w21, #ETH_HDR_LEN
    bl      udp_handle
    b       .Lip_done

.Lip_icmp:
    /* ICMP → icmp_handle(frame, ETH_HDR_LEN + ip_total_length) */
    PROBE_L3_COUNT_INC PERF_L3_IP_COUNT, w0, x1
    mov     x0, x19
    add     w1, w21, #ETH_HDR_LEN
    bl      icmp_handle
    b       .Lip_done

.Lip_proto_unreach:
    /* ICMP Protocol Unreachable (type 3, code 2).
     *
     * Falls through to .Lip_drop so default builds keep the same
     * control flow they had pre-PERF_L3 (zero-overhead property).
     * Under PERF_L3 this means proto-unreach packets are counted
     * in both PERF_L3_IP_DROPS (via .Lip_drop) AND
     * PERF_L3_ICMP_ERR_GEN (inside icmp_send_error). That's
     * semantically consistent: ip_handle did NOT successfully
     * dispatch to a known L4 protocol, so from ip_handle's
     * perspective it IS a drop; the generated error is a separate,
     * orthogonal event counted in its own field. */
    mov     x0, x19
    mov     w1, w20
    mov     w2, #ICMP_DEST_UNREACHABLE
    mov     w3, #ICMP_CODE_PROTO_UNREACH
    bl      icmp_send_error

.Lip_drop:
    PROBE_L3_COUNT_INC PERF_L3_IP_DROPS, w0, x3
    mov     w0, #0

.Lip_done:
    PROBE_L3_EXIT x22, PERF_L3_IP_TICKS, x2, x3
.ifdef PERF_L3
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
.else
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
.endif
    ret
