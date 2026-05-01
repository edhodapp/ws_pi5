/*
 * lib/mdns.S — mDNS responder per D008 (RFC 6762 subset).
 *
 * Subset (deliberate, per D008):
 *   - Answers A and ANY queries for our hostname (net_hostname.local).
 *   - No AAAA (IPv4 only), PTR, SRV, or TXT records.
 *   - No service discovery beyond our own A record.
 *
 * This commit lands the core query→response building. UDP wiring
 * and the boot-time probe / announce phases come in follow-ups.
 *
 * Public entry:
 *
 *   mdns_build_response(x0=query_payload, w1=query_len, x2=resp_buf)
 *     → w0 = response payload length, or 0 if no reply
 *
 * Reads net_hostname / net_hostname_len / net_our_ip via the
 * globals defined in lib/net_cfg.S.
 *
 * Wire format (RFC 1035 + RFC 6762 deltas):
 *
 *   Header (12 bytes, all u16 big-endian):
 *     +0  ID      — echoed in response
 *     +2  Flags   — query: 0x0000; response: 0x8400 (QR | AA)
 *     +4  QDCOUNT — number of questions (we require 1)
 *     +6  ANCOUNT — number of answer RRs
 *     +8  NSCOUNT — authority RRs
 *    +10  ARCOUNT — additional RRs
 *
 *   Question:
 *     QNAME   — sequence of length-prefixed labels, terminator 0x00
 *     QTYPE   — u16 (1=A, 255=ANY)
 *     QCLASS  — u16 (1=IN; bit 0x8000 = "unicast response please";
 *               we ignore the bit and always multicast in v1)
 *
 *   Answer (RFC 6762 §10.2 — authoritative records SHOULD set
 *   the cache-flush bit on RR.CLASS):
 *     NAME      — name compression: 0xC00C points back to QNAME
 *                 at offset 12 from message start
 *     TYPE      — u16 (1=A)
 *     CLASS     — u16 (0x8001 = IN with cache-flush)
 *     TTL       — u32 (120 seconds, conservative for v1)
 *     RDLENGTH  — u16 (4 for an A record)
 *     RDATA     — our IPv4 address, wire-order 4 bytes
 *
 * Register convention inside mdns_build_response:
 *   x19  query payload pointer
 *   w20  query length
 *   x21  response buffer pointer
 *   x23  qname start offset within query (always 12)
 *   x24  qname end offset (the 0x00 terminator's position)
 *
 * Helper subroutines preserve x19..x28 by convention; cross-bl
 * state in the main function therefore lives in callee-saved regs.
 * Inline case-folding (the TOLOWER macro) keeps the hostname-
 * compare loop body free of `bl` entirely.
 */

.include "net.inc"

.equ DNS_HDR_LEN,           12
.equ DNS_TYPE_A,            1
.equ DNS_TYPE_ANY,          255
.equ DNS_CLASS_IN,          1
.equ MAX_LABEL_LEN,         63

/* ".local" suffix as length-prefixed labels: [5] "local" [0]. */
.section .rodata
.balign 4
_local_label:
    .byte 5
    .ascii "local"
    .byte 0
.equ _LOCAL_LABEL_LEN, 7

/* In-response constant: lowercase "local" for case-insensitive
 * compare against the query's [5]"<l>...". */
_local_str:
    .ascii "local"


.section .text

/* TOLOWER reg — fold an ASCII byte register down to lowercase
 * (in-place). Bytes outside [A-Z] pass through unchanged. */
.macro TOLOWER reg
    cmp     \reg, #'A'
    b.lo    9990f
    cmp     \reg, #'Z'
    b.hi    9990f
    add     \reg, \reg, #('a' - 'A')
9990:
.endm

.global mdns_build_response

mdns_build_response:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0
    mov     w20, w1
    mov     x21, x2

    /* Need at least DNS header. */
    cmp     w20, #DNS_HDR_LEN
    b.lt    .Lmb_drop

    /* Reject responses (QR=1) — we only answer queries.
     * Wire byte 0 of flags has the QR bit (high bit). */
    ldrb    w0, [x19, #2]
    tst     w0, #0x80
    b.ne    .Lmb_drop

    /* Require QDCOUNT == 1. Wire bytes [4..5] big-endian. */
    ldrb    w0, [x19, #4]
    cbnz    w0, .Lmb_drop           /* high byte must be 0 */
    ldrb    w0, [x19, #5]
    cmp     w0, #1
    b.ne    .Lmb_drop

    /* Walk QNAME labels starting at offset 12. Reject any byte
     * with the top bits set (would be a compressed pointer or an
     * extended-label type — invalid in a question per RFC 1035). */
    mov     x23, #DNS_HDR_LEN
    mov     x22, x23                /* cursor */
.Lmb_label:
    cmp     w22, w20
    b.hs    .Lmb_drop
    ldrb    w0, [x19, x22]
    cbz     w0, .Lmb_qname_end
    tst     w0, #0xC0
    b.ne    .Lmb_drop
    cmp     w0, #MAX_LABEL_LEN
    b.hi    .Lmb_drop
    add     x22, x22, #1
    add     x22, x22, x0
    b       .Lmb_label

.Lmb_qname_end:
    /* x22 is the terminator position. Need 4 more bytes (QTYPE+QCLASS). */
    mov     x24, x22
    add     w0, w22, #5
    cmp     w0, w20
    b.hi    .Lmb_drop

    /* Read QTYPE / QCLASS from offsets x24+1 and x24+3. */
    add     x0, x24, #1
    ldrb    w1, [x19, x0]           /* QTYPE high */
    add     x0, x24, #2
    ldrb    w2, [x19, x0]           /* QTYPE low */
    cbnz    w1, .Lmb_drop           /* type must fit in low byte */
    cmp     w2, #DNS_TYPE_A
    b.eq    .Lmb_type_ok
    cmp     w2, #DNS_TYPE_ANY
    b.eq    .Lmb_type_ok
    b       .Lmb_drop
.Lmb_type_ok:

    add     x0, x24, #3
    ldrb    w1, [x19, x0]           /* QCLASS high */
    add     x0, x24, #4
    ldrb    w2, [x19, x0]           /* QCLASS low */
    /* High byte may have cache-flush bit (0x80); mask it. */
    and     w1, w1, #0x7F
    cbnz    w1, .Lmb_drop
    cmp     w2, #DNS_CLASS_IN
    b.ne    .Lmb_drop

    /* Compare QNAME against "<net_hostname>.local" (case-insensitive). */
    bl      _qname_eq_hostname_local
    cbz     w0, .Lmb_drop

    /* --- Build response into x21. --- */

    /* Header: ID echoed, flags=0x8400, QDCOUNT=1, ANCOUNT=1. */
    ldrb    w0, [x19, #0]
    strb    w0, [x21, #0]
    ldrb    w0, [x19, #1]
    strb    w0, [x21, #1]
    mov     w0, #0x84
    strb    w0, [x21, #2]
    strb    wzr, [x21, #3]
    strb    wzr, [x21, #4]
    mov     w0, #1
    strb    w0, [x21, #5]
    strb    wzr, [x21, #6]
    strb    w0, [x21, #7]
    strh    wzr, [x21, #8]
    strh    wzr, [x21, #10]

    /* Question section: copy [12, qclass_end) from query.
     * qclass_end = x24 + 5 (terminator + QTYPE 2 + QCLASS 2).
     * _mdns_memcpy clobbers x0/x1/x2/x3, so we re-derive
     * question_len from x24 (callee-saved) afterwards instead of
     * trusting x2. */
    add     x0, x19, #DNS_HDR_LEN
    add     x1, x21, #DNS_HDR_LEN
    add     x2, x24, #5
    sub     x2, x2, #DNS_HDR_LEN    /* question section length */
    bl      _mdns_memcpy
    /* question_len = x24 + 5 - DNS_HDR_LEN = x24 - 7. */
    sub     x0, x24, #7
    add     x22, x21, #DNS_HDR_LEN
    add     x22, x22, x0

    /* Answer section.
     * NAME: pointer 0xC0 0x0C (offset 12). */
    mov     w0, #0xC0
    strb    w0, [x22], #1
    mov     w0, #0x0C
    strb    w0, [x22], #1
    /* TYPE: 0x00 0x01 (A). */
    strb    wzr, [x22], #1
    mov     w0, #1
    strb    w0, [x22], #1
    /* CLASS: 0x80 0x01 (IN | cache-flush). */
    mov     w0, #0x80
    strb    w0, [x22], #1
    mov     w0, #1
    strb    w0, [x22], #1
    /* TTL: 0x00 0x00 0x00 0x78 (120s). */
    strb    wzr, [x22], #1
    strb    wzr, [x22], #1
    strb    wzr, [x22], #1
    mov     w0, #0x78
    strb    w0, [x22], #1
    /* RDLENGTH: 0x00 0x04. */
    strb    wzr, [x22], #1
    mov     w0, #4
    strb    w0, [x22], #1
    /* RDATA: our IPv4 (wire-order, already correct in net_our_ip). */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    ldr     w0, [x0]
    str     w0, [x22], #4

    /* Total response length = x22 - x21. */
    sub     x0, x22, x21
    b       .Lmb_done

.Lmb_drop:
    mov     w0, #0
.Lmb_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


/* ---------------------------------------------------------------------------
 * _qname_eq_hostname_local — case-insensitive compare of the
 * query's QNAME at [x19+x23, x19+x24) (excluding the terminator)
 * against "<net_hostname>.local".
 *
 * Returns w0 = 1 on match, 0 on mismatch.
 * Reads net_hostname (64-byte buffer) and net_hostname_len.
 * Preserves x19..x28; uses x9..x16 as scratch. No `bl` calls.
 * --------------------------------------------------------------------------- */
_qname_eq_hostname_local:
    /* Load hostname + length. */
    adrp    x9, net_hostname
    add     x9, x9, :lo12:net_hostname
    adrp    x10, net_hostname_len
    add     x10, x10, :lo12:net_hostname_len
    ldr     w10, [x10]
    cbz     w10, .Lqe_no

    /* Length check: bytes from x23 to x24 (excluding terminator)
     * must equal 1 + hostname_len + 6 (the [5]"local" labels). */
    sub     w11, w24, w23
    add     w12, w10, #7
    cmp     w11, w12
    b.ne    .Lqe_no

    /* x13 = cursor into the query at QNAME start. */
    add     x13, x19, x23
    /* Hostname-label length byte must equal hostname_len. */
    ldrb    w0, [x13], #1
    cmp     w0, w10
    b.ne    .Lqe_no

    /* Compare hostname bytes case-insensitively. */
    mov     x14, x9
    mov     w15, w10
.Lqe_h_loop:
    cbz     w15, .Lqe_h_done
    ldrb    w0, [x13], #1
    ldrb    w1, [x14], #1
    TOLOWER w0
    TOLOWER w1
    cmp     w0, w1
    b.ne    .Lqe_no
    sub     w15, w15, #1
    b       .Lqe_h_loop
.Lqe_h_done:

    /* Next byte must be 5 (length of "local"). */
    ldrb    w0, [x13], #1
    cmp     w0, #5
    b.ne    .Lqe_no

    /* Compare the next 5 bytes case-insensitively against "local". */
    adrp    x14, _local_str
    add     x14, x14, :lo12:_local_str
    mov     w15, #5
.Lqe_l_loop:
    cbz     w15, .Lqe_yes
    ldrb    w0, [x13], #1
    ldrb    w1, [x14], #1
    TOLOWER w0
    /* w1 is already lowercase ("local"); skip TOLOWER on it. */
    cmp     w0, w1
    b.ne    .Lqe_no
    sub     w15, w15, #1
    b       .Lqe_l_loop

.Lqe_yes:
    mov     w0, #1
    ret
.Lqe_no:
    mov     w0, #0
    ret


/* ---------------------------------------------------------------------------
 * _mdns_memcpy — bytewise copy of x2 bytes from x0 to x1.
 * Returns nothing meaningful; preserves x19..x28. */
_mdns_memcpy:
    cbz     x2, 9f
1:  ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    sub     x2, x2, #1
    cbnz    x2, 1b
9:  ret
