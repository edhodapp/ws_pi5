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

/* L2 multicast MAC for IPv4 mDNS, derived from group 224.0.0.251
 * per RFC 1112 §6.4. Originally lived in genet.S (I14) but moved
 * here so QEMU builds — which don't link genet.S — can still
 * resolve the symbol for unit tests of the responder. Same bytes,
 * same global symbol. */
.balign 2
.global mdns_mac
mdns_mac:
    .byte 0x01, 0x00, 0x5e, 0x00, 0x00, 0xfb


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


/* ===========================================================================
 * mdns_dispatch — UDP-port-5353 frame handler.
 *
 *   x0 = frame buffer (Eth + IP + UDP + DNS payload)
 *   w1 = frame length in bytes
 * Returns:
 *   w0 = total response frame length, or 0 if no reply
 *
 * Validates the UDP payload as an mDNS query for our hostname,
 * builds the response payload via mdns_build_response, then
 * rewrites the frame's Eth + IP + UDP headers in place to
 * become a multicast response to 224.0.0.251 / 01:00:5e:00:00:fb,
 * with our MAC + IP as source and TTL=255 per RFC 6762 §11.
 *
 * The response payload is built in a scratch BSS buffer first
 * (since it can be longer than the request) and copied into the
 * frame after the headers are rewritten.
 *
 * Register convention:
 *   x19 frame buffer (callee-saved)
 *   w20 input frame length / output cursor scratch
 *   w21 response payload length (callee-saved)
 *   x22 scratch ptr (callee-saved across bl)
 * =========================================================================== */

.equ MDNS_FRAME_PAYLOAD_OFF,    (14 + 20 + 8)   /* 42: ETH+IP+UDP */
.equ MDNS_PORT_NBO,             0xE914          /* 5353 in BE: 0x14 0xE9 */

.global mdns_dispatch
.global mdns_build_probe_payload
.global mdns_build_probe_frame

mdns_dispatch:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0
    mov     w20, w1

    /* Need at least ETH + IP + UDP headers. */
    cmp     w20, #MDNS_FRAME_PAYLOAD_OFF
    b.lt    .Lmd_drop

    /* Build the response payload in scratch. */
    add     x0, x19, #MDNS_FRAME_PAYLOAD_OFF
    sub     w1, w20, #MDNS_FRAME_PAYLOAD_OFF
    adrp    x2, _mdns_payload_scratch
    add     x2, x2, :lo12:_mdns_payload_scratch
    bl      mdns_build_response
    cbz     w0, .Lmd_drop
    mov     w21, w0                 /* response payload length */

    /* Wrap Eth+IP+UDP multicast headers around the (yet-to-be-copied)
     * payload at offset 42. The helper preserves x19..x22. */
    mov     x0, x19
    mov     w1, w21
    bl      _mdns_wrap_multicast_frame

    /* Copy response payload from scratch into frame[42..]. */
    adrp    x0, _mdns_payload_scratch
    add     x0, x0, :lo12:_mdns_payload_scratch
    add     x1, x19, #MDNS_FRAME_PAYLOAD_OFF
    mov     x2, x21
    bl      _mdns_memcpy

    /* Total response frame length = headers + payload. */
    add     w0, w21, #MDNS_FRAME_PAYLOAD_OFF
    b       .Lmd_done

.Lmd_drop:
    mov     w0, #0
.Lmd_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


/* ---------------------------------------------------------------------------
 * _mdns_wrap_multicast_frame — write the Eth+IP+UDP headers (offsets
 * 0..MDNS_FRAME_PAYLOAD_OFF) for an outbound mDNS multicast frame.
 *
 *   x0 = frame buffer
 *   w1 = payload length (DNS message length, will live at offset 42)
 *
 * Header values per RFC 6762 §3 / §11:
 *   Eth dst = mdns_mac (01:00:5e:00:00:fb)
 *   Eth src = net_our_mac
 *   Eth type = 0x0800 (IPv4)
 *   IP ver/IHL = 0x45, TOS = 0
 *   IP totlen = 20 + 8 + payload_len (big-endian)
 *   IP id/flags/frag = 0
 *   IP TTL = 255
 *   IP proto = 17 (UDP)
 *   IP checksum = ip_checksum over the 20-byte header
 *   IP src = net_our_ip
 *   IP dst = 224.0.0.251
 *   UDP sport = dport = 5353
 *   UDP length = 8 + payload_len
 *   UDP checksum = 0
 *
 * Caller is responsible for the payload at frame[42..42+payload_len].
 * Preserves x19..x22; clobbers x0/x1/x9/x30 (calls ip_checksum).
 * --------------------------------------------------------------------------- */
_mdns_wrap_multicast_frame:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x23, [sp, #16]
    str     x24, [sp, #24]

    mov     x23, x0                 /* frame buffer */
    mov     w24, w1                 /* payload length */

    /* --- Eth header. --- */
    adrp    x9, mdns_mac
    add     x9, x9, :lo12:mdns_mac
    ldrb    w0, [x9, #0];  strb w0, [x23, #0]
    ldrb    w0, [x9, #1];  strb w0, [x23, #1]
    ldrb    w0, [x9, #2];  strb w0, [x23, #2]
    ldrb    w0, [x9, #3];  strb w0, [x23, #3]
    ldrb    w0, [x9, #4];  strb w0, [x23, #4]
    ldrb    w0, [x9, #5];  strb w0, [x23, #5]
    adrp    x9, net_our_mac
    add     x9, x9, :lo12:net_our_mac
    ldrb    w0, [x9, #0];  strb w0, [x23, #6]
    ldrb    w0, [x9, #1];  strb w0, [x23, #7]
    ldrb    w0, [x9, #2];  strb w0, [x23, #8]
    ldrb    w0, [x9, #3];  strb w0, [x23, #9]
    ldrb    w0, [x9, #4];  strb w0, [x23, #10]
    ldrb    w0, [x9, #5];  strb w0, [x23, #11]
    mov     w0, #0x08
    strb    w0, [x23, #12]
    strb    wzr, [x23, #13]

    /* --- IP header. --- */
    mov     w0, #0x45
    strb    w0, [x23, #(14 + 0)]
    strb    wzr, [x23, #(14 + 1)]
    add     w0, w24, #(20 + 8)
    lsr     w1, w0, #8
    strb    w1, [x23, #(14 + 2)]
    strb    w0, [x23, #(14 + 3)]
    strb    wzr, [x23, #(14 + 4)]
    strb    wzr, [x23, #(14 + 5)]
    strb    wzr, [x23, #(14 + 6)]
    strb    wzr, [x23, #(14 + 7)]
    mov     w0, #255
    strb    w0, [x23, #(14 + 8)]
    mov     w0, #17
    strb    w0, [x23, #(14 + 9)]
    strb    wzr, [x23, #(14 + 10)]
    strb    wzr, [x23, #(14 + 11)]
    adrp    x9, net_our_ip
    add     x9, x9, :lo12:net_our_ip
    ldrb    w0, [x9, #0]; strb w0, [x23, #(14 + 12)]
    ldrb    w0, [x9, #1]; strb w0, [x23, #(14 + 13)]
    ldrb    w0, [x9, #2]; strb w0, [x23, #(14 + 14)]
    ldrb    w0, [x9, #3]; strb w0, [x23, #(14 + 15)]
    mov     w0, #0xE0
    strb    w0, [x23, #(14 + 16)]
    strb    wzr, [x23, #(14 + 17)]
    strb    wzr, [x23, #(14 + 18)]
    mov     w0, #0xFB
    strb    w0, [x23, #(14 + 19)]

    add     x0, x23, #14
    mov     w1, #20
    bl      ip_checksum
    lsr     w1, w0, #8
    strb    w0, [x23, #(14 + 10)]
    strb    w1, [x23, #(14 + 11)]

    /* --- UDP header. --- */
    mov     w0, #0x14
    strb    w0, [x23, #(14 + 20)]
    mov     w0, #0xE9
    strb    w0, [x23, #(14 + 21)]
    mov     w0, #0x14
    strb    w0, [x23, #(14 + 22)]
    mov     w0, #0xE9
    strb    w0, [x23, #(14 + 23)]
    add     w0, w24, #8
    lsr     w1, w0, #8
    strb    w1, [x23, #(14 + 24)]
    strb    w0, [x23, #(14 + 25)]
    strb    wzr, [x23, #(14 + 26)]
    strb    wzr, [x23, #(14 + 27)]

    ldr     x24, [sp, #24]
    ldr     x23, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* ===========================================================================
 * mdns_build_probe_frame — assemble a complete RFC 6762 §8.1 probe
 * frame ready for the L2 send path.
 *
 *   x0 = frame buffer (must be ≥ 70 bytes)
 * Returns:
 *   w0 = total frame length (Eth + IP + UDP + DNS payload), or 0
 *        if the hostname is unset.
 *
 * Builds the DNS probe payload via mdns_build_probe_payload directly
 * into frame[42..], then wraps Eth+IP+UDP multicast headers around
 * it via _mdns_wrap_multicast_frame.
 * =========================================================================== */
mdns_build_probe_frame:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     x19, x0                 /* frame buffer */

    /* Build payload directly into frame[42..]. */
    add     x0, x19, #MDNS_FRAME_PAYLOAD_OFF
    bl      mdns_build_probe_payload
    cbz     w0, .Lpf_drop
    mov     w20, w0                 /* payload length */

    /* Wrap multicast headers. */
    mov     x0, x19
    mov     w1, w20
    bl      _mdns_wrap_multicast_frame

    add     w0, w20, #MDNS_FRAME_PAYLOAD_OFF
    b       .Lpf_done

.Lpf_drop:
    mov     w0, #0
.Lpf_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


.section .bss
.balign 8
_mdns_payload_scratch:
    .space 256                      /* mDNS responses are tiny */


.section .text

/* ===========================================================================
 * mdns_build_probe_payload — build an RFC 6762 §8.1 boot-time
 * probe query for our own hostname.
 *
 *   x0 = output buffer
 * Returns:
 *   w0 = packet length (DNS hdr + question), or 0 if hostname is unset
 *
 * The probe is structurally a regular DNS query: id=0, flags=0
 * (QR=0, no AA), QDCOUNT=1, AN/NS/AR=0. The single question is
 * for "<net_hostname>.local" with QTYPE=ANY (255) and QCLASS=IN.
 * RFC 6762 §8.1 specifies QTYPE=ANY so any peer holding ANY record
 * type for the name will respond, surfacing a name conflict.
 *
 * This function builds only the DNS payload; the timer-driven
 * boot phase (4/N completion + 5/N) wraps it in Eth+IP+UDP
 * multicast headers and sends three copies 250 ms apart per
 * RFC 6762 §8.1, halting with panic_n on conflict per D008.
 *
 * Reads net_hostname / net_hostname_len. Returns 0 if length is
 * zero (unset hostname) — caller (boot ordering, future I5)
 * should panic_n on that case rather than send a meaningless
 * probe for the empty name.
 *
 * Register convention:
 *   x19 buffer cursor (callee-saved)
 *   w20 hostname length (callee-saved)
 *   x21 net_hostname pointer (callee-saved)
 * =========================================================================== */
mdns_build_probe_payload:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x0                 /* cursor at start of buffer */

    /* Read hostname length; bail if zero. */
    adrp    x21, net_hostname_len
    add     x21, x21, :lo12:net_hostname_len
    ldr     w20, [x21]
    cbz     w20, .Lpb_drop

    adrp    x21, net_hostname
    add     x21, x21, :lo12:net_hostname

    /* DNS header (12 bytes): id=0, flags=0, qd=1, an/ns/ar=0. */
    strb    wzr, [x19, #0]
    strb    wzr, [x19, #1]
    strb    wzr, [x19, #2]
    strb    wzr, [x19, #3]
    strb    wzr, [x19, #4]
    mov     w0, #1
    strb    w0, [x19, #5]
    strb    wzr, [x19, #6]
    strb    wzr, [x19, #7]
    strh    wzr, [x19, #8]
    strh    wzr, [x19, #10]
    add     x19, x19, #12

    /* QNAME label 1: [hostname_len] hostname-bytes. */
    strb    w20, [x19], #1
    mov     x9, x21                 /* src cursor over net_hostname */
    mov     w10, w20                /* count */
.Lpb_h_copy:
    cbz     w10, .Lpb_h_done
    ldrb    w11, [x9], #1
    strb    w11, [x19], #1
    sub     w10, w10, #1
    b       .Lpb_h_copy
.Lpb_h_done:

    /* QNAME label 2: [5] "local" + terminator [0]. */
    mov     w0, #5
    strb    w0, [x19], #1
    mov     w0, #'l'
    strb    w0, [x19], #1
    mov     w0, #'o'
    strb    w0, [x19], #1
    mov     w0, #'c'
    strb    w0, [x19], #1
    mov     w0, #'a'
    strb    w0, [x19], #1
    mov     w0, #'l'
    strb    w0, [x19], #1
    strb    wzr, [x19], #1

    /* QTYPE = ANY (0x00FF, big-endian). */
    strb    wzr, [x19], #1
    mov     w0, #0xff
    strb    w0, [x19], #1
    /* QCLASS = IN (0x0001, big-endian). */
    strb    wzr, [x19], #1
    mov     w0, #1
    strb    w0, [x19], #1

    /* Total length = cursor - original_buf. */
    mov     x0, x19
    /* Recover original buffer pointer from the saved x29 frame:
     * we no longer hold it in a reg; instead, recompute as
     * 12 (header) + 1 + hostname_len + 7 (5+"local"+0) + 4 (qtype+qclass)
     * = 24 + hostname_len. */
    add     w0, w20, #24
    b       .Lpb_done

.Lpb_drop:
    mov     w0, #0
.Lpb_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
