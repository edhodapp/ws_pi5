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

.section .rodata
/* In-response constant: lowercase "local" for case-insensitive
 * compare against the query's [5]"<l>...". */
.balign 4
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
    /*
     * RFC 6762 §6.7: "Multicast DNS responses MUST NOT contain any
     * questions in the Question Section."
     *
     * Implementation: delegate to mdns_build_announce_payload, which
     * already produces the right shape (QDCOUNT=0, ANCOUNT=1, full
     * inline NAME, no compression — there's no question to point at).
     * Then overwrite bytes [0..1] with the query's transaction ID per
     * RFC 6762 §18.1 (legacy clients echo the ID; modern mDNS uses 0
     * either way, so the echo is harmless).
     *
     * The validation logic above (length, QR, QDCOUNT==1, QNAME walk,
     * QTYPE/QCLASS, hostname match) still gates this branch — only a
     * well-formed query for our hostname reaches here.
     */
    mov     x0, x21
    bl      mdns_build_announce_payload
    cbz     w0, .Lmb_drop           /* defensive: hostname unset */

    ldrb    w1, [x19, #0]
    strb    w1, [x21, #0]
    ldrb    w1, [x19, #1]
    strb    w1, [x21, #1]
    /* w0 = response length from announce builder; pass through. */
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


/* ---------------------------------------------------------------------------
 * _mdns_skip_name — advance past a DNS name in a packet.
 *
 *   x0 = packet pointer
 *   w1 = packet length
 *   w2 = current byte offset
 *
 * Returns:
 *   w0 = offset past the name (past terminator OR past 2-byte pointer),
 *        or -1 on overflow / malformed length byte.
 *
 * A name is either a sequence of length-prefixed labels ending in 0x00,
 * or terminates in a 2-byte compression pointer (top two bits 11). Either
 * way, after this call the cursor sits on the byte following the name.
 * Uses x9..x10 as scratch; preserves x19..x28.
 * --------------------------------------------------------------------------- */
_mdns_skip_name:
    mov     w9, w2
.Lsn_loop:
    cmp     w9, w1
    b.hs    .Lsn_err
    ldrb    w10, [x0, x9]
    cbz     w10, .Lsn_term
    tst     w10, #0xC0
    b.ne    .Lsn_ptr
    cmp     w10, #MAX_LABEL_LEN
    b.hi    .Lsn_err
    add     w9, w9, #1
    add     w9, w9, w10
    b       .Lsn_loop
.Lsn_term:
    add     w0, w9, #1
    cmp     w0, w1
    b.hi    .Lsn_err
    ret
.Lsn_ptr:
    add     w0, w9, #2
    cmp     w0, w1
    b.hi    .Lsn_err
    ret
.Lsn_err:
    mov     w0, #-1
    ret


/* ===========================================================================
 * mdns_check_conflict — RFC 6762 §8.1/§8.2 conflict detection.
 *
 *   x0 = DNS payload pointer (just the message, no Eth/IP/UDP)
 *   w1 = payload length
 *
 * Returns:
 *   w0 = 1 if the packet is an authoritative response (QR=1) advertising
 *        our hostname.local in any answer, else 0.
 *
 * Walks the answer section. For each answer whose NAME is direct labels
 * (not a compression pointer) matching "<net_hostname>.local"
 * case-insensitively, returns 1. The probe phase QTYPE=ANY means ANY
 * record type for the name is a conflict, so this function does not
 * filter on the answer's TYPE.
 *
 * Limitations (deliberate, per D008 v1 scope):
 *   - Compressed top-level names (NAME starts with a 0xC0 byte) are
 *     skipped without comparison. Real-world unsolicited mDNS announces
 *     inline names because there's no question section to point to;
 *     responses to queries can use compression but those aren't probe
 *     conflicts in any case (we don't probe-by-query, we probe-by-probe).
 *   - Compression pointers in the middle of an otherwise direct name
 *     are also skipped without comparison.
 *
 * Register convention:
 *   x19 payload pointer (callee-saved)
 *   w20 payload length (callee-saved)
 *   w21 cursor offset (callee-saved)
 *   w22 remaining ANCOUNT (callee-saved)
 *   x23 name-start offset for the active answer (callee-saved)
 *   x24 name-terminator offset for the active answer (callee-saved)
 * =========================================================================== */
.global mdns_check_conflict

mdns_check_conflict:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0
    mov     w20, w1

    cmp     w20, #DNS_HDR_LEN
    b.lt    .Lcc_no

    /* QR bit must be set (this is a response). */
    ldrb    w0, [x19, #2]
    tst     w0, #0x80
    b.eq    .Lcc_no

    /* ANCOUNT (BE bytes 6..7) — bail if zero. */
    ldrb    w0, [x19, #6]
    ldrb    w1, [x19, #7]
    add     w0, w1, w0, lsl #8
    cbz     w0, .Lcc_no
    mov     w22, w0                     /* w22 = ancount, used after Q skip */

    /* QDCOUNT (BE bytes 4..5). */
    ldrb    w0, [x19, #4]
    ldrb    w1, [x19, #5]
    add     w0, w1, w0, lsl #8

    mov     w21, #DNS_HDR_LEN
    /* Skip QDCOUNT questions: name + 4 bytes (qtype+qclass). */
.Lcc_q_loop:
    cbz     w0, .Lcc_q_done
    sub     w0, w0, #1
    /* Save remaining qdcount in a callee-saved spot — x24 is unused
     * until we start scanning answers. */
    mov     x24, x0
    mov     x0, x19
    mov     w1, w20
    mov     w2, w21
    bl      _mdns_skip_name
    cmn     w0, #1
    b.eq    .Lcc_no
    add     w21, w0, #4
    cmp     w21, w20
    b.hi    .Lcc_no
    mov     x0, x24
    b       .Lcc_q_loop
.Lcc_q_done:

.Lcc_an_loop:
    cbz     w22, .Lcc_no
    cmp     w21, w20
    b.hs    .Lcc_no

    /* If first byte of NAME has the compression bits, skip without
     * comparing (v1 limitation). */
    ldrb    w0, [x19, x21]
    tst     w0, #0xC0
    b.ne    .Lcc_skip_an

    /* Walk forward to find the terminator → x24, while bailing on any
     * mid-name compression pointer (also skipped without compare). */
    mov     x23, x21
    mov     x24, x21
.Lcc_term_loop:
    cmp     w24, w20
    b.hs    .Lcc_no
    ldrb    w0, [x19, x24]
    cbz     w0, .Lcc_term_found
    tst     w0, #0xC0
    b.ne    .Lcc_skip_an
    cmp     w0, #MAX_LABEL_LEN
    b.hi    .Lcc_no
    add     x24, x24, #1
    add     x24, x24, x0
    b       .Lcc_term_loop
.Lcc_term_found:

    /* Compare NAME against our hostname.local. Helper preserves
     * x19..x28 and uses x23/x24 as set above. */
    bl      _qname_eq_hostname_local
    cbnz    w0, .Lcc_yes

.Lcc_skip_an:
    /* Advance past NAME, then 10 bytes (TYPE 2 + CLASS 2 + TTL 4 +
     * RDLENGTH 2) plus the variable RDATA. */
    mov     x0, x19
    mov     w1, w20
    mov     w2, w21
    bl      _mdns_skip_name
    cmn     w0, #1
    b.eq    .Lcc_no
    /* w0 = offset past NAME. Need at least 10 more bytes for the fixed
     * RR fields. */
    add     w1, w0, #10
    cmp     w1, w20
    b.hi    .Lcc_no
    /* RDLENGTH is at offset (w0 + 8) .. (w0 + 9), big-endian. */
    add     w2, w0, #8
    ldrb    w3, [x19, x2]
    add     w2, w0, #9
    ldrb    w4, [x19, x2]
    add     w3, w4, w3, lsl #8
    add     w21, w1, w3                 /* cursor past TYPE/CLASS/TTL/RDLEN/RDATA */
    cmp     w21, w20
    b.hi    .Lcc_no
    sub     w22, w22, #1
    b       .Lcc_an_loop

.Lcc_yes:
    /* Conflict candidate: a peer claims our hostname. Before
     * declaring it a real conflict, check whether the response's
     * RDATA matches our PRIOR_ANNOUNCED_IP. If yes, the peer is
     * just echoing the IP we announced before our most recent
     * arm-with-new-IP — its cache hasn't yet processed the new
     * announce. Treat that as not-a-conflict so we don't panic
     * during the post-DHCP-rebind probe phase.
     *
     * Only suppress for TYPE=A records (the only type a peer cache
     * could plausibly echo for our hostname). Bounds-check the RR
     * fixed fields (TYPE+CLASS+TTL+RDLEN+RDATA) before reading. */
    add     w0, w24, #15                    /* x24 = name term offset */
    cmp     w0, w20
    b.hi    .Lcc_yes_real                   /* truncated — true conflict */

    /* TYPE big-endian at [x24+1, x24+2]. */
    add     x0, x24, #1
    ldrb    w1, [x19, x0]
    add     x0, x24, #2
    ldrb    w2, [x19, x0]
    add     w1, w2, w1, lsl #8
    cmp     w1, #DNS_TYPE_A
    b.ne    .Lcc_yes_real                   /* non-A → true conflict */

    /* PRIOR_ANNOUNCED_IP from ctx; 0 means "no prior announce", so
     * don't suppress (the kick path that sets PRIOR hasn't run, or
     * we already cleared it post-LIVE). */
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    ldr     w1, [x0, #MDNSC_PRIOR_ANNOUNCED_IP]
    cbz     w1, .Lcc_yes_real

    /* Read RDATA (4 wire-order bytes at x24+11) into a u32 with
     * the same byte ordering as net_our_ip, so a u32 compare
     * against PRIOR matches whenever the IPs are equal. */
    add     x0, x24, #11
    ldrb    w2, [x19, x0]
    add     x0, x24, #12
    ldrb    w3, [x19, x0]
    add     x0, x24, #13
    ldrb    w4, [x19, x0]
    add     x0, x24, #14
    ldrb    w5, [x19, x0]
    orr     w2, w2, w3, lsl #8
    orr     w2, w2, w4, lsl #16
    orr     w2, w2, w5, lsl #24
    cmp     w2, w1
    b.ne    .Lcc_yes_real                   /* different IP → real conflict */

    /* Self-echo: RDATA matches our PRIOR. Not a conflict. */
    mov     w0, #0
    b       .Lcc_done
.Lcc_yes_real:
    mov     w0, #1
    b       .Lcc_done
.Lcc_no:
    mov     w0, #0
.Lcc_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


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

    /* State-gate (D008, RFC 6762 §8). The state machine determines
     * what we do with this frame:
     *   IDLE                    → drop (responder not started)
     *   PROBE_1..PROBE_3        → conflict-check; panic on conflict,
     *                              else drop (haven't claimed name)
     *   ANNOUNCE_1..LIVE        → respond to queries normally
     */
    bl      mdns_get_state
    cmp     w0, #MDNS_STATE_PROBE_3
    b.gt    .Lmd_normal
    cmp     w0, #MDNS_STATE_PROBE_1
    b.lt    .Lmd_drop                   /* IDLE */

    /* PROBE_*: scan for conflict. */
    add     x0, x19, #MDNS_FRAME_PAYLOAD_OFF
    sub     w1, w20, #MDNS_FRAME_PAYLOAD_OFF
    bl      mdns_check_conflict
    cbz     w0, .Lmd_drop               /* probing, no conflict — drop silently */

    /* Conflict during probe → invoke panic handler. mdns_panic_fn is
     * a function pointer initialized to panic_n in .data, so the
     * production path is `blr panic_n` (never returns). Tests
     * overwrite mdns_panic_fn with a capture stub that records the
     * call and returns; the trailing branch falls through to drop. */
    adrp    x0, mdns_panic_fn
    add     x0, x0, :lo12:mdns_panic_fn
    ldr     x0, [x0]
    blr     x0
    b       .Lmd_drop                   /* unreachable in production */

.Lmd_normal:
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


/* ===========================================================================
 * mdns_build_announce_payload — build an RFC 6762 §8.3 unsolicited
 * response advertising our hostname.local as an A record.
 *
 *   x0 = output buffer (>= 38 bytes for hostname_len=4; up to
 *        12 + 12 + 1 + 64 + 7 + 14 = 110 bytes worst-case at
 *        hostname_len=64)
 * Returns:
 *   w0 = packet length, or 0 if hostname is unset.
 *
 * Wire format:
 *   Header (12 bytes): id=0, flags=0x8400 (QR=1, AA=1), QDCOUNT=0,
 *                      ANCOUNT=1, NSCOUNT=0, ARCOUNT=0.
 *   Answer:
 *     NAME  = [hostname_len]hostname[5]"local"[0]   (full inline; no
 *             compression pointer because there is no question section
 *             to point at)
 *     TYPE  = 0x0001 (A)
 *     CLASS = 0x8001 (IN | cache-flush, RFC 6762 §10.2)
 *     TTL   = 120 (0x00000078)
 *     RDLEN = 4
 *     RDATA = net_our_ip (wire bytes)
 *   Total = 34 + hostname_len.
 *
 * Reads net_hostname / net_hostname_len / net_our_ip. Reuses
 * register conventions from mdns_build_probe_payload:
 *   x19 = output cursor
 *   w20 = hostname length
 *   x21 = net_hostname pointer
 * =========================================================================== */
.global mdns_build_announce_payload
.global mdns_build_announce_frame

mdns_build_announce_payload:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x0

    adrp    x21, net_hostname_len
    add     x21, x21, :lo12:net_hostname_len
    ldr     w20, [x21]
    cbz     w20, .Lpa_drop

    adrp    x21, net_hostname
    add     x21, x21, :lo12:net_hostname

    /* Header: id=0, flags=0x8400, qd=0, an=1, ns=0, ar=0. */
    strb    wzr, [x19, #0]
    strb    wzr, [x19, #1]
    mov     w0, #0x84
    strb    w0, [x19, #2]
    strb    wzr, [x19, #3]
    strb    wzr, [x19, #4]
    strb    wzr, [x19, #5]
    strb    wzr, [x19, #6]
    mov     w0, #1
    strb    w0, [x19, #7]
    strh    wzr, [x19, #8]
    strh    wzr, [x19, #10]
    add     x19, x19, #12

    /* NAME label 1: [hostname_len] + hostname bytes. */
    strb    w20, [x19], #1
    mov     x9, x21
    mov     w10, w20
.Lpa_h_copy:
    cbz     w10, .Lpa_h_done
    ldrb    w11, [x9], #1
    strb    w11, [x19], #1
    sub     w10, w10, #1
    b       .Lpa_h_copy
.Lpa_h_done:

    /* NAME label 2: [5]"local" + terminator. */
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

    /* TYPE = 0x0001 (A). */
    strb    wzr, [x19], #1
    mov     w0, #1
    strb    w0, [x19], #1
    /* CLASS = 0x8001 (IN | cache-flush). */
    mov     w0, #0x80
    strb    w0, [x19], #1
    mov     w0, #1
    strb    w0, [x19], #1
    /* TTL = 0x00000078 (120 sec). */
    strb    wzr, [x19], #1
    strb    wzr, [x19], #1
    strb    wzr, [x19], #1
    mov     w0, #0x78
    strb    w0, [x19], #1
    /* RDLENGTH = 4. */
    strb    wzr, [x19], #1
    mov     w0, #4
    strb    w0, [x19], #1
    /* RDATA = net_our_ip (wire bytes; little-endian u32 store works
     * because the field is already in wire order). */
    adrp    x9, net_our_ip
    add     x9, x9, :lo12:net_our_ip
    ldr     w0, [x9]
    str     w0, [x19], #4

    add     w0, w20, #34                /* total length */
    b       .Lpa_done

.Lpa_drop:
    mov     w0, #0
.Lpa_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


/* ===========================================================================
 * mdns_build_announce_frame — assemble a complete RFC 6762 §8.3
 * unsolicited-response frame ready for the L2 send path.
 *
 *   x0 = frame buffer (must be ≥ 42 + 34 + hostname_len bytes; e.g.,
 *        ≥ 80 for hostname_len=4, ≥ 140 worst-case at len=64)
 * Returns:
 *   w0 = total frame length, or 0 if hostname is unset.
 *
 * Builds the announce payload directly into frame[42..] then wraps
 * Eth+IP+UDP multicast headers via _mdns_wrap_multicast_frame.
 * =========================================================================== */
mdns_build_announce_frame:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     x19, x0

    /* Build payload directly into frame[42..]. */
    add     x0, x19, #MDNS_FRAME_PAYLOAD_OFF
    bl      mdns_build_announce_payload
    cbz     w0, .Laf_drop
    mov     w20, w0

    /* Wrap multicast headers. */
    mov     x0, x19
    mov     w1, w20
    bl      _mdns_wrap_multicast_frame

    add     w0, w20, #MDNS_FRAME_PAYLOAD_OFF
    b       .Laf_done

.Laf_drop:
    mov     w0, #0
.Laf_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* ===========================================================================
 * State machine — RFC 6762 §8.1 probe + §8.3 announce phases (D008).
 *
 * Lifecycle (each transition is driven by a timer callback firing,
 * not a wallclock loop):
 *
 *   IDLE        → mdns_start sets state = PROBE_1, arms timer at +0
 *   PROBE_1     → send probe, advance to PROBE_2,    re-arm at +250 ms
 *   PROBE_2     → send probe, advance to PROBE_3,    re-arm at +250 ms
 *   PROBE_3     → send probe, advance to ANNOUNCE_1, re-arm at +250 ms
 *   ANNOUNCE_1  → send announce, advance to ANNOUNCE_2, re-arm at +1 s
 *   ANNOUNCE_2  → send announce, advance to LIVE, no re-arm
 *   LIVE        → no-op (defensive; the timer is no longer armed)
 *
 * Conflict detection lives in mdns_dispatch (8/N follow-up wires it
 * up). For now this commit only owns the time/state side.
 *
 * The send_fn signature mirrors arp.S:
 *   send_fn(x0=dwc2_base, x1=ecm_state, x2=frame_ptr, w3=frame_len)
 *
 * Context layout (mdns_send_ctx in BSS, 64 bytes):
 *   +0  DWC2_BASE         u64
 *   +8  ECM_STATE         u64
 *   +16 TX_BUF            u64  scratch frame buffer (≥ 140 bytes)
 *   +24 TIMER_POOL        u64
 *   +32 TIMER_FREQ        u64  cached at start
 *   +40 SEND_FN           u64  function pointer
 *   +48 STATE             u32  one of MDNS_STATE_*
 *   +52 TIMER_SLOT        s32  timer pool slot index, -1 if unarmed
 *   +56 ANNOUNCED_IP      u32  net_our_ip captured at most-recent
 *                              arm, wire-order bytes — used by
 *                              mdns_kick to detect DHCP-rebind to a
 *                              different IP and restart the probe
 *                              cycle on the new value.
 *   +60 PRIOR_ANNOUNCED_IP u32 the IP we announced *before* the
 *                              current ANNOUNCED_IP. Populated when
 *                              mdns_kick detects an IP change and
 *                              restarts the probe cycle for the new
 *                              IP. mdns_check_conflict treats a
 *                              response carrying RDATA equal to this
 *                              value as a peer cache echoing our own
 *                              old data, NOT a conflict — without
 *                              that suppression, our laptop's avahi
 *                              would still have wspi5.local cached
 *                              at the prior IP and answer our probe
 *                              with it, triggering a self-conflict
 *                              panic. Cleared (set to 0) when the
 *                              probe + announce cycle reaches LIVE.
 * =========================================================================== */

.equ MDNSC_DWC2_BASE,         0
.equ MDNSC_ECM_STATE,         8
.equ MDNSC_TX_BUF,            16
.equ MDNSC_TIMER_POOL,        24
.equ MDNSC_TIMER_FREQ,        32
.equ MDNSC_SEND_FN,           40
.equ MDNSC_STATE,             48
.equ MDNSC_TIMER_SLOT,        52
.equ MDNSC_ANNOUNCED_IP,      56
.equ MDNSC_PRIOR_ANNOUNCED_IP, 60
.equ MDNSC_SIZE,              64

.equ MDNS_STATE_IDLE,        0
.equ MDNS_STATE_PROBE_1,     1
.equ MDNS_STATE_PROBE_2,     2
.equ MDNS_STATE_PROBE_3,     3
.equ MDNS_STATE_ANNOUNCE_1,  4
.equ MDNS_STATE_ANNOUNCE_2,  5
.equ MDNS_STATE_LIVE,        6


/* ---------------------------------------------------------------------------
 * mdns_get_state — return the current state (read of mdns_send_ctx
 * +MDNSC_STATE). Used by mdns_dispatch (in 8/N follow-up) to gate
 * conflict detection on the probe window, and by tests.
 *
 * Returns: w0 = state (MDNS_STATE_*).
 * --------------------------------------------------------------------------- */
.global mdns_get_state
mdns_get_state:
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    ldr     w0, [x0, #MDNSC_STATE]
    ret


/* ---------------------------------------------------------------------------
 * mdns_start — initialize the responder context and try to arm the
 * first probe timer.
 *
 *   x0 = DWC2 base address (or 0 in tests)
 *   x1 = ECM state pointer (or 0 in tests)
 *   x2 = TX buffer pointer (≥ 140 bytes)
 *   x3 = timer pool pointer
 *   x4 = send function pointer
 *
 * Returns: nothing.
 *
 * Refuses to arm (state stays IDLE, no timer armed) if hostname is
 * empty or net_our_ip is 0. The IP guard exists for DHCP mode:
 * main.S calls mdns_start unconditionally right after dhcp_start, so
 * net_our_ip is still 0 when this runs. In that case the context is
 * stored but the timer is deferred; h_commit_lease_arm_timers calls
 * mdns_kick once the lease commits to perform the actual arm. Static
 * mode populates net_our_ip during config_parse, before mdns_start,
 * so the arm fires on the first attempt with no kick needed.
 * --------------------------------------------------------------------------- */
.global mdns_start
mdns_start:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    adrp    x5, mdns_send_ctx
    add     x5, x5, :lo12:mdns_send_ctx
    str     x0, [x5, #MDNSC_DWC2_BASE]
    str     x1, [x5, #MDNSC_ECM_STATE]
    str     x2, [x5, #MDNSC_TX_BUF]
    str     x3, [x5, #MDNSC_TIMER_POOL]
    str     x4, [x5, #MDNSC_SEND_FN]

    /* Reset state to IDLE so a re-init (test harness, recovery flash)
     * starts a fresh probe cycle rather than inheriting a stale
     * MDNS_STATE_LIVE from a prior run. */
    str     wzr, [x5, #MDNSC_STATE]

    /* TIMER_SLOT = -1 sentinel — _mdns_try_arm cancels any prior
     * slot before re-arming, and the cancel is a silent no-op when
     * the index is out of bounds (timer_pool: w1 >= TPOOL_CAP). */
    mov     w0, #-1
    str     w0, [x5, #MDNSC_TIMER_SLOT]

    /* ANNOUNCED_IP = 0 so the first compare in mdns_kick (after a
     * later DHCP commit) treats anything as "different" if state is
     * non-IDLE. (In practice, _mdns_try_arm sets ANNOUNCED_IP to
     * the current net_our_ip on a successful arm, so the IDLE-path
     * sets it before kick ever compares.) */
    str     wzr, [x5, #MDNSC_ANNOUNCED_IP]

    bl      _mdns_try_arm

    ldp     x29, x30, [sp], #16
    ret


/* ---------------------------------------------------------------------------
 * mdns_kick — re-attempt to arm the probe cycle. Called by
 * h_commit_lease_arm_timers (lib/dhcp_fsa.S) after a DHCP lease
 * commits and net_our_ip is updated, so the deferred arm from
 * mdns_start can complete.
 *
 * Three cases by current state:
 *
 *   IDLE — no cycle has run yet (mdns_start ran with net_our_ip == 0
 *     and deferred). Call _mdns_try_arm to start the probe cycle
 *     with the now-committed IP.
 *
 *   non-IDLE, ANNOUNCED_IP == net_our_ip — DHCP renewed on the same
 *     lease; no-op. The cycle in flight (or LIVE responder) is
 *     already announcing the right IP.
 *
 *   non-IDLE, ANNOUNCED_IP != net_our_ip — DHCP rebound to a
 *     different IP. The responder is currently announcing a stale
 *     value; peers' caches will eventually expire it (default mDNS
 *     TTL 120 s) but we want to replace it now. _mdns_try_arm
 *     cancels the existing timer slot, resets state to PROBE_1, and
 *     arms a fresh cycle with the new IP. The new probe + announce
 *     each carry the cache-flush bit (RFC 6762 §10.2), so peers
 *     replace the stale A record on receipt without us needing to
 *     send an explicit goodbye for the old IP.
 * --------------------------------------------------------------------------- */
.global mdns_kick
mdns_kick:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    adrp    x5, mdns_send_ctx
    add     x5, x5, :lo12:mdns_send_ctx
    ldr     w6, [x5, #MDNSC_STATE]
    cbz     w6, .Lkick_arm          /* IDLE — defer-arm path */

    /* Non-IDLE: compare ANNOUNCED_IP with net_our_ip. */
    ldr     w0, [x5, #MDNSC_ANNOUNCED_IP]
    adrp    x1, net_our_ip
    add     x1, x1, :lo12:net_our_ip
    ldr     w1, [x1]
    cmp     w0, w1
    b.eq    .Lkick_done             /* same IP — no-op */

    /* IP changed. Stash the OLD ANNOUNCED_IP in PRIOR_ANNOUNCED_IP
     * before _mdns_try_arm overwrites ANNOUNCED_IP with net_our_ip.
     * mdns_check_conflict reads PRIOR during the new probe cycle and
     * suppresses conflict-panic for responses whose RDATA matches —
     * those are peers' caches echoing our own old announce, not a
     * true peer claim. mdns_timer_cb clears PRIOR back to 0 once
     * the new ANNOUNCE_2 lands and state goes LIVE. */
    str     w0, [x5, #MDNSC_PRIOR_ANNOUNCED_IP]

.Lkick_arm:
    bl      _mdns_try_arm

.Lkick_done:
    ldp     x29, x30, [sp], #16
    ret


/* ---------------------------------------------------------------------------
 * _mdns_try_arm — internal: arm PROBE_1 if all preconditions hold.
 *
 * Preconditions:
 *   - mdns_send_ctx.MDNSC_TIMER_POOL != 0 (mdns_start was called)
 *   - net_hostname_len != 0
 *   - net_our_ip != 0.0.0.0 (probe + announce RDATA must be valid)
 *
 * On success: caches timer_freq, sets state = PROBE_1, arms a timer
 * at expiry = now so the next timer_check fires PROBE_1.
 *
 * On any guard failure: leaves state untouched (caller is responsible
 * for setting state = IDLE if needed). Trashes x0-x6 only.
 * --------------------------------------------------------------------------- */
_mdns_try_arm:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    adrp    x5, mdns_send_ctx
    add     x5, x5, :lo12:mdns_send_ctx
    ldr     x6, [x5, #MDNSC_TIMER_POOL]
    cbz     x6, .Larm_done

    adrp    x6, net_hostname_len
    add     x6, x6, :lo12:net_hostname_len
    ldr     w6, [x6]
    cbz     w6, .Larm_done

    /* net_our_ip is 4 wire-order bytes; read as a 32-bit word and
     * test for any non-zero byte. Endianness doesn't matter — we
     * only care about the all-zeros case. */
    adrp    x6, net_our_ip
    add     x6, x6, :lo12:net_our_ip
    ldr     w6, [x6]
    cbz     w6, .Larm_done

    /* Cancel any prior timer slot before arming a new one. The
     * IP-changed branch in mdns_kick lands here while state is
     * non-IDLE and a slot is already in-flight; without this cancel
     * we'd leave two slots pointing at this same context, both
     * firing mdns_timer_cb and racing on state advancement.
     * timer_cancel ignores the -1 sentinel (silent no-op for
     * out-of-range indices) so the first-arm path is also safe. */
    ldr     x0, [x5, #MDNSC_TIMER_POOL]
    ldr     w1, [x5, #MDNSC_TIMER_SLOT]
    bl      timer_cancel
    adrp    x5, mdns_send_ctx
    add     x5, x5, :lo12:mdns_send_ctx

    /* Cache timer frequency. */
    bl      timer_freq
    adrp    x5, mdns_send_ctx
    add     x5, x5, :lo12:mdns_send_ctx
    str     x0, [x5, #MDNSC_TIMER_FREQ]

    /* Cache the IP this cycle is announcing. mdns_kick reads this
     * to detect a DHCP rebind to a different IP. */
    adrp    x6, net_our_ip
    add     x6, x6, :lo12:net_our_ip
    ldr     w6, [x6]
    str     w6, [x5, #MDNSC_ANNOUNCED_IP]

    /* state = PROBE_1. */
    mov     w0, #MDNS_STATE_PROBE_1
    str     w0, [x5, #MDNSC_STATE]

    /* Arm timer at expiry = now (fires immediately under timer_check). */
    bl      timer_now
    mov     x1, x0
    adrp    x5, mdns_send_ctx
    add     x5, x5, :lo12:mdns_send_ctx
    ldr     x0, [x5, #MDNSC_TIMER_POOL]
    ldr     x2, =mdns_timer_cb
    adrp    x3, mdns_send_ctx
    add     x3, x3, :lo12:mdns_send_ctx
    bl      timer_set
    /* Capture returned slot index (or -1 on full pool) so a future
     * mdns_kick triggered by an IP change can cancel cleanly. */
    adrp    x5, mdns_send_ctx
    add     x5, x5, :lo12:mdns_send_ctx
    str     w0, [x5, #MDNSC_TIMER_SLOT]

.Larm_done:
    ldp     x29, x30, [sp], #16
    ret


/* ---------------------------------------------------------------------------
 * mdns_timer_cb — fire one step of the state machine.
 *
 *   x0 = ctx pointer (= &mdns_send_ctx in production)
 *
 * Branches on current state:
 *   PROBE_*    → build_probe_frame, send, advance, re-arm at +250 ms
 *   ANNOUNCE_1 → build_announce_frame, send, advance to ANNOUNCE_2,
 *                re-arm at +1 s
 *   ANNOUNCE_2 → build_announce_frame, send, advance to LIVE, no re-arm
 *   IDLE/LIVE  → no-op (defensive; should not be entered in practice)
 *
 * Register convention:
 *   x19 ctx pointer (callee-saved)
 *   w20 current state (callee-saved)
 *   w21 send-frame length (callee-saved)
 * --------------------------------------------------------------------------- */
.global mdns_timer_cb
mdns_timer_cb:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x0
    ldr     w20, [x19, #MDNSC_STATE]

    /* IDLE (0) or LIVE (6+) → no-op. */
    cmp     w20, #MDNS_STATE_PROBE_1
    b.lt    .Ltcb_done
    cmp     w20, #MDNS_STATE_ANNOUNCE_2
    b.gt    .Ltcb_done

    /* Build the appropriate frame into ctx.TX_BUF. */
    ldr     x0, [x19, #MDNSC_TX_BUF]
    cmp     w20, #MDNS_STATE_PROBE_3
    b.le    .Ltcb_build_probe
    /* ANNOUNCE_1 or ANNOUNCE_2 */
    bl      mdns_build_announce_frame
    b       .Ltcb_built
.Ltcb_build_probe:
    bl      mdns_build_probe_frame
.Ltcb_built:
    cbz     w0, .Ltcb_advance       /* empty hostname: skip send, still advance */
    mov     w21, w0

    /* Invoke send_fn(dwc2_base, ecm_state, tx_buf, frame_len). */
    ldr     x5, [x19, #MDNSC_SEND_FN]
    cbz     x5, .Ltcb_advance
    ldr     x0, [x19, #MDNSC_DWC2_BASE]
    ldr     x1, [x19, #MDNSC_ECM_STATE]
    ldr     x2, [x19, #MDNSC_TX_BUF]
    mov     w3, w21
    blr     x5

.Ltcb_advance:
    /* Advance state. PROBE_1..ANNOUNCE_2 → +1; ANNOUNCE_2 → LIVE. */
    add     w20, w20, #1
    str     w20, [x19, #MDNSC_STATE]

    /* If now LIVE, the cycle for the current ANNOUNCED_IP has
     * completed (peer caches reflect it via the cache-flush bit on
     * ANNOUNCE_2). Clear PRIOR_ANNOUNCED_IP so any future conflict
     * claim is evaluated as a true conflict, not a stale self-echo.
     * No re-arm needed in LIVE. */
    cmp     w20, #MDNS_STATE_LIVE
    b.ne    .Ltcb_post_live
    str     wzr, [x19, #MDNSC_PRIOR_ANNOUNCED_IP]
    b       .Ltcb_done
.Ltcb_post_live:

    /* Re-arm: PROBE_* and the transition into ANNOUNCE_1 use 250 ms;
     * ANNOUNCE_1 → ANNOUNCE_2 uses 1 s. New state w20 is what's
     * NEXT to send, so the delay until that send is:
     *   w20 in {PROBE_2, PROBE_3, ANNOUNCE_1} → 250 ms
     *   w20 == ANNOUNCE_2                     → 1000 ms
     */
    bl      timer_now
    mov     x1, x0                  /* x1 = now */
    ldr     x2, [x19, #MDNSC_TIMER_FREQ]
    cmp     w20, #MDNS_STATE_ANNOUNCE_2
    b.eq    .Ltcb_delay_1s
    /* 250 ms = freq / 4. */
    lsr     x2, x2, #2
    b       .Ltcb_arm
.Ltcb_delay_1s:
    /* 1 s = freq. (x2 already holds freq.) */
.Ltcb_arm:
    add     x1, x1, x2              /* expiry = now + delay */
    ldr     x0, [x19, #MDNSC_TIMER_POOL]
    cbz     x0, .Ltcb_done
    ldr     x2, =mdns_timer_cb
    mov     x3, x19
    bl      timer_set
    /* Track the new slot so an IP-change kick during this cycle
     * can cancel cleanly. */
    str     w0, [x19, #MDNSC_TIMER_SLOT]

.Ltcb_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


.section .bss
.balign 8
.global mdns_send_ctx
mdns_send_ctx:
    .space MDNSC_SIZE

/* Function pointer invoked from mdns_dispatch when a conflict is
 * detected during the probe window. Initialized in .data to
 * panic_n so production boot needs no explicit wiring; tests
 * overwrite it with a capture stub. Signature: void fn(void). */
.section .data
.balign 8
.global mdns_panic_fn
mdns_panic_fn:
    .quad panic_n
