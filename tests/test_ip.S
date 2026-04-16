/*
 * test_ip.S — Tests for IP checksum and IPv4 handler
 *
 * Checksum tests:
 *   1. test_ip_checksum         — Round-trip: compute, fill, verify returns 0
 *   2. test_ip_checksum_carry   — 3-byte input forces carry folding + odd byte
 *
 * ip_handle tests:
 *   3. test_ip_handle_icmp      — Valid ICMP echo request → returns 42
 *   4. test_ip_handle_short     — 33-byte frame → returns 0
 *   5. test_ip_handle_bad_cksum — Corrupted IP checksum → returns 0
 *   6. test_ip_handle_not_ours  — Dest IP = 10.0.2.99 → returns 0
 *   7. test_ip_handle_unknown_proto — Protocol = 255 → returns 0
 */

.include "net.inc"

.global test_ip_checksum
.global test_ip_checksum_carry
.global test_ip_handle_icmp
.global test_ip_handle_short
.global test_ip_handle_bad_cksum
.global test_ip_handle_not_ours
.global test_ip_handle_unknown_proto
.global test_ip_handle_bad_ver
.global test_ip_handle_totlen_short
.global test_ip_handle_totlen_overrun
.global test_ip_handle_ttl_zero
.global test_ip_handle_martian_src_zero
.global test_ip_handle_martian_src_loopback
.global test_ip_handle_martian_src_loopback_high
.global test_ip_handle_martian_src_self
.global test_ip_handle_frag_dispatch
.global test_ip_handle_udp
.global test_ip_handle_martian_src_bcast
.global test_ip_handle_martian_src_mcast
.global test_ip_reasm_two_frags
.global test_ip_reasm_timeout
.global test_ip_reasm_timeout_icmp
.global test_ip_reasm_big_complete
.global test_ip_reasm_overlap
.global test_ip_reasm_nonaligned
.global test_ip_reasm_min_ttl

.section .text

/* ========================================================================
 * test_ip_checksum — Compute checksum on zeroed header, store, verify
 * ======================================================================== */
test_ip_checksum:
    stp     x29, x30, [sp, #-16]!

    /* Copy 20-byte IP header template to mutable buffer */
    ldr     x0, =ip_cksum_template
    ldr     x1, =ip_cksum_buf
    ldp     x2, x3, [x0]           /* 16 bytes */
    stp     x2, x3, [x1]
    ldr     w2, [x0, #16]          /* 4 bytes */
    str     w2, [x1, #16]

    /* Compute checksum (checksum field is zero in template) */
    ldr     x0, =ip_cksum_buf
    mov     w1, #20
    bl      ip_checksum

    /* Should be non-zero */
    cbz     w0, .Lfail_ip_cksum

    /* Store computed checksum into header */
    ldr     x1, =ip_cksum_buf
    strh    w0, [x1, #IP_CHECKSUM]

    /* Verify: checksum of complete header should be 0 */
    ldr     x0, =ip_cksum_buf
    mov     w1, #20
    bl      ip_checksum

    cbnz    w0, .Lfail_ip_cksum

    ldr     x0, =name_ip_cksum
    bl      test_pass
    b       .Ldone_ip_cksum

.Lfail_ip_cksum:
    ldr     x0, =name_ip_cksum
    bl      test_fail

.Ldone_ip_cksum:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_checksum_carry — {0xFF, 0xFF, 0x03} forces carry + odd byte
 * ======================================================================== */
test_ip_checksum_carry:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =carry_test_data
    mov     w1, #3
    bl      ip_checksum

    /* Expected: 0xFFFC */
    mov     w1, #0xFFFC
    cmp     w0, w1
    b.ne    .Lfail_ip_carry

    ldr     x0, =name_ip_carry
    bl      test_pass
    b       .Ldone_ip_carry

.Lfail_ip_carry:
    ldr     x0, =name_ip_carry
    bl      test_fail

.Ldone_ip_carry:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_icmp — Valid ICMP echo request → returns 42
 * ======================================================================== */
test_ip_handle_icmp:
    stp     x29, x30, [sp, #-16]!

    /* Copy 42-byte template to mutable buffer */
    ldr     x0, =ip_icmp_template
    ldr     x1, =ip_handle_buf
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    ldr     x0, =ip_handle_buf
    mov     w1, #42
    bl      ip_handle

    cmp     w0, #42
    b.ne    .Lfail_ip_icmp

    ldr     x0, =name_ip_icmp
    bl      test_pass
    b       .Ldone_ip_icmp

.Lfail_ip_icmp:
    ldr     x0, =name_ip_icmp
    bl      test_fail

.Ldone_ip_icmp:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_short — 33-byte frame → returns 0
 * ======================================================================== */
test_ip_handle_short:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_icmp_template
    mov     w1, #33
    bl      ip_handle

    cbnz    w0, .Lfail_ip_short

    ldr     x0, =name_ip_short
    bl      test_pass
    b       .Ldone_ip_short

.Lfail_ip_short:
    ldr     x0, =name_ip_short
    bl      test_fail

.Ldone_ip_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_bad_cksum — Corrupted IP checksum → returns 0
 * ======================================================================== */
test_ip_handle_bad_cksum:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_bad_cksum_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_bad_cksum

    ldr     x0, =name_ip_bad_cksum
    bl      test_pass
    b       .Ldone_ip_bad_cksum

.Lfail_ip_bad_cksum:
    ldr     x0, =name_ip_bad_cksum
    bl      test_fail

.Ldone_ip_bad_cksum:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_not_ours — Dest IP = 10.0.2.99 → returns 0
 * ======================================================================== */
test_ip_handle_not_ours:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_not_ours_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_not_ours

    ldr     x0, =name_ip_not_ours
    bl      test_pass
    b       .Ldone_ip_not_ours

.Lfail_ip_not_ours:
    ldr     x0, =name_ip_not_ours
    bl      test_fail

.Ldone_ip_not_ours:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_unknown_proto — Protocol = UDP (17) → returns 0
 * ======================================================================== */
test_ip_handle_unknown_proto:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_unknown_proto_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_unknown

    ldr     x0, =name_ip_unknown
    bl      test_pass
    b       .Ldone_ip_unknown

.Lfail_ip_unknown:
    ldr     x0, =name_ip_unknown
    bl      test_fail

.Ldone_ip_unknown:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_bad_ver — VER_IHL=0x46 (options present) → returns 0
 * ======================================================================== */
test_ip_handle_bad_ver:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_bad_ver_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_bad_ver

    ldr     x0, =name_ip_bad_ver
    bl      test_pass
    b       .Ldone_ip_bad_ver

.Lfail_ip_bad_ver:
    ldr     x0, =name_ip_bad_ver
    bl      test_fail

.Ldone_ip_bad_ver:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_totlen_short — TotalLength=19 (< 20 minimum) → returns 0
 * ======================================================================== */
test_ip_handle_totlen_short:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_totlen_short_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_totlen_short

    ldr     x0, =name_ip_totlen_short
    bl      test_pass
    b       .Ldone_ip_totlen_short

.Lfail_ip_totlen_short:
    ldr     x0, =name_ip_totlen_short
    bl      test_fail

.Ldone_ip_totlen_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_totlen_overrun — TotalLength=29, frame=42 → 14+29=43>42 → 0
 * ======================================================================== */
test_ip_handle_totlen_overrun:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_totlen_overrun_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_totlen_overrun

    ldr     x0, =name_ip_totlen_overrun
    bl      test_pass
    b       .Ldone_ip_totlen_overrun

.Lfail_ip_totlen_overrun:
    ldr     x0, =name_ip_totlen_overrun
    bl      test_fail

.Ldone_ip_totlen_overrun:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_reasm_two_frags — Two-fragment ICMP reassembly
 *
 * Fragment 1: offset=0, MF=1, 16 bytes payload
 * Fragment 2: offset=2, MF=0, 8 bytes payload
 * Expected: reassembled frame with 24-byte ICMP payload
 * ======================================================================== */
.global test_ip_reasm_two_frags
test_ip_reasm_two_frags:
    stp     x29, x30, [sp, #-16]!

    /* Reset reassembly state */
    bl      ip_reasm_init

    /* ---- Fragment 1: should return 0 (incomplete) ---- */
    /* Copy fragment 1 to mutable buffer */
    ldr     x0, =ip_frag1_template
    ldr     x1, =ip_reasm_buf
    mov     w2, #50
.Lrf_copy1:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lrf_copy1

    ldr     x0, =ip_reasm_buf
    mov     w1, #50
    bl      ip_reasm_input

    cbnz    x0, .Lfail_ip_reasm

    /* ---- Fragment 2: should return non-zero (complete) ---- */
    ldr     x0, =ip_frag2_template
    ldr     x1, =ip_reasm_buf
    mov     w2, #42
.Lrf_copy2:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lrf_copy2

    ldr     x0, =ip_reasm_buf
    mov     w1, #42
    bl      ip_reasm_input

    cbz     x0, .Lfail_ip_reasm

    /* ---- Verify reassembled IP header ---- */
    mov     x4, x0                      /* x4 = frame ptr */

    /* IP total length should be 44 (20 + 24) = 0x002C */
    ldrh    w0, [x4, #(ETH_PAYLOAD + IP_TOTLEN)]
    rev16   w0, w0
    uxth    w0, w0
    cmp     w0, #44
    b.ne    .Lfail_ip_reasm

    /* Proto should be ICMP (1) */
    ldrb    w0, [x4, #(ETH_PAYLOAD + IP_PROTO)]
    cmp     w0, #IP_PROTO_ICMP
    b.ne    .Lfail_ip_reasm

    /* Flags/frag should be 0 (not fragmented) */
    ldrh    w0, [x4, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]
    cbnz    w0, .Lfail_ip_reasm

    /* Verify IP checksum == 0 */
    add     x0, x4, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_ip_reasm

    /* ---- Verify reassembled payload (24 bytes) ---- */
    add     x0, x4, #(ETH_PAYLOAD + IP_HDR_MIN)
    ldr     x1, =ip_reasm_expected_payload
    mov     w2, #24
.Lrf_verify:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    ldrb    w5, [x1, x2]
    cmp     w3, w5
    b.ne    .Lfail_ip_reasm
    cbnz    w2, .Lrf_verify

    /* ---- Verify slot is freed ---- */
    ldr     x0, =reasm_slots
    ldrb    w0, [x0, #REASM_FLAGS]
    cbnz    w0, .Lfail_ip_reasm

    ldr     x0, =name_ip_reasm
    bl      test_pass
    b       .Ldone_ip_reasm

.Lfail_ip_reasm:
    ldr     x0, =name_ip_reasm
    bl      test_fail

.Ldone_ip_reasm:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_reasm_timeout — Stale slot freed by timeout callback
 * ======================================================================== */
.global test_ip_reasm_timeout
test_ip_reasm_timeout:
    stp     x29, x30, [sp, #-16]!

    bl      ip_reasm_init

    /* Send fragment 1 to allocate a slot */
    ldr     x0, =ip_frag1_template
    ldr     x1, =ip_reasm_buf
    mov     w2, #50
.Lrt_copy:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lrt_copy

    ldr     x0, =ip_reasm_buf
    mov     w1, #50
    bl      ip_reasm_input

    /* Slot should be active */
    ldr     x0, =reasm_slots
    ldrb    w1, [x0, #REASM_FLAGS]
    tbz     w1, #7, .Lfail_ip_timeout

    /* Fire timeout callback on the slot */
    bl      ip_reasm_timeout_cb

    /* Slot should now be inactive */
    ldr     x0, =reasm_slots
    ldrb    w1, [x0, #REASM_FLAGS]
    tbnz    w1, #7, .Lfail_ip_timeout

    ldr     x0, =name_ip_timeout
    bl      test_pass
    b       .Ldone_ip_timeout

.Lfail_ip_timeout:
    ldr     x0, =name_ip_timeout
    bl      test_fail

.Ldone_ip_timeout:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_reasm_timeout_icmp — RFC 1122 §3.2.2.4: reassembly timeout
 * MUST generate ICMP Time Exceeded (type 11, code 1).
 *
 * Feed a fragment to allocate a slot, set up icmp_send_ctx with a
 * fake send function, fire the timeout callback, then verify the
 * fake send was called with the correct ICMP type and code.
 * ======================================================================== */
test_ip_reasm_timeout_icmp:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ip_reasm_init
    bl      icmp_init

    /* Set up icmp_send_ctx with fake send */
    ldr     x19, =icmp_send_ctx
    str     xzr, [x19, #ICMPC_DWC2_BASE]
    str     xzr, [x19, #ICMPC_ECM_STATE]
    ldr     x0, =reasm_icmp_tx_buf
    str     x0, [x19, #ICMPC_TX_BUF]
    ldr     x0, =fake_reasm_send
    str     x0, [x19, #ICMPC_SEND_FN]

    ldr     x0, =reasm_send_count
    str     wzr, [x0]

    /* Feed fragment 1 to allocate a slot */
    ldr     x0, =ip_frag1_template
    ldr     x1, =ip_reasm_buf
    mov     w2, #50
.Lrti_copy:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lrti_copy

    ldr     x0, =ip_reasm_buf
    mov     w1, #50
    bl      ip_reasm_input

    /* Fire timeout callback on the slot */
    ldr     x0, =reasm_slots
    bl      ip_reasm_timeout_cb

    /* Fake send should have been called */
    ldr     x0, =reasm_send_count
    ldr     w0, [x0]
    cbz     w0, .Lfail_ip_rti

    /* Verify ICMP type=11 (Time Exceeded), code=1 (reassembly) */
    ldr     x0, =reasm_icmp_tx_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cmp     w1, #ICMP_TIME_EXCEEDED
    b.ne    .Lfail_ip_rti
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]
    cmp     w1, #1                     /* code 1: reassembly */
    b.ne    .Lfail_ip_rti

    ldr     x0, =name_ip_rti
    bl      test_pass
    b       .Ldone_ip_rti

.Lfail_ip_rti:
    ldr     x0, =name_ip_rti
    bl      test_fail

.Ldone_ip_rti:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_ip_handle_ttl_zero — TTL=0 with valid checksum → returns 0
 * ======================================================================== */
test_ip_handle_ttl_zero:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_ttl_zero_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_ttl_zero

    ldr     x0, =name_ip_ttl_zero
    bl      test_pass
    b       .Ldone_ip_ttl_zero

.Lfail_ip_ttl_zero:
    ldr     x0, =name_ip_ttl_zero
    bl      test_fail

.Ldone_ip_ttl_zero:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_martian_src_zero — src=0.0.0.0 → returns 0 (drop)
 * ======================================================================== */
test_ip_handle_martian_src_zero:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_src_zero_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_src_zero

    ldr     x0, =name_ip_src_zero
    bl      test_pass
    b       .Ldone_ip_src_zero

.Lfail_ip_src_zero:
    ldr     x0, =name_ip_src_zero
    bl      test_fail

.Ldone_ip_src_zero:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_martian_src_loopback — src=127.0.0.1 → returns 0 (drop)
 * ======================================================================== */
test_ip_handle_martian_src_loopback:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_src_loopback_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_src_loopback

    ldr     x0, =name_ip_src_loopback
    bl      test_pass
    b       .Ldone_ip_src_loopback

.Lfail_ip_src_loopback:
    ldr     x0, =name_ip_src_loopback
    bl      test_fail

.Ldone_ip_src_loopback:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_martian_src_loopback_high — src=127.255.255.254 →
 * returns 0 (drop). Ensures the 127/8 check matches the whole range,
 * not just 127.0.0.1 exactly — mutation testing protection.
 * ======================================================================== */
test_ip_handle_martian_src_loopback_high:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_src_loopback_high_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_src_loopback_high

    ldr     x0, =name_ip_src_loopback_high
    bl      test_pass
    b       .Ldone_ip_src_loopback_high

.Lfail_ip_src_loopback_high:
    ldr     x0, =name_ip_src_loopback_high
    bl      test_fail

.Ldone_ip_src_loopback_high:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_martian_src_self — src==net_our_ip (10.0.2.15) →
 * returns 0 (drop). Prevents the self-spoof attack where a forged
 * frame claims to come from us.
 * ======================================================================== */
test_ip_handle_martian_src_self:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_src_self_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_src_self

    ldr     x0, =name_ip_src_self
    bl      test_pass
    b       .Ldone_ip_src_self

.Lfail_ip_src_self:
    ldr     x0, =name_ip_src_self
    bl      test_fail

.Ldone_ip_src_self:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_martian_src_bcast — src=255.255.255.255 → drop
 * RFC 1122 §3.2.1.3: broadcast source is invalid. Amplification vector.
 * ======================================================================== */
test_ip_handle_martian_src_bcast:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_src_bcast_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_src_bcast

    ldr     x0, =name_ip_src_bcast
    bl      test_pass
    b       .Ldone_ip_src_bcast

.Lfail_ip_src_bcast:
    ldr     x0, =name_ip_src_bcast
    bl      test_fail

.Ldone_ip_src_bcast:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_martian_src_mcast — src=224.0.0.1 → drop
 * RFC 1122 §3.2.1.3 / RFC 1112: multicast source is invalid.
 * ======================================================================== */
test_ip_handle_martian_src_mcast:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =ip_src_mcast_frame
    mov     w1, #42
    bl      ip_handle

    cbnz    w0, .Lfail_ip_src_mcast

    ldr     x0, =name_ip_src_mcast
    bl      test_pass
    b       .Ldone_ip_src_mcast

.Lfail_ip_src_mcast:
    ldr     x0, =name_ip_src_mcast
    bl      test_fail

.Ldone_ip_src_mcast:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_reasm_overlap — overlapping fragment dropped
 *
 * Frag1: offset=0, MF=1, 16 bytes (sets bitmap bits 0-1)
 * Frag2: offset=1 (8 bytes), MF=0, 8 bytes (bit 1 already set → overlap)
 * ======================================================================== */
/* ========================================================================
 * test_ip_handle_frag_dispatch — Send 2 fragments through ip_handle
 * (not ip_reasm_input directly). Exercises:
 *   - ip.S line 176: cbz w2 fallthrough (has fragments)
 *   - ip.S line 182: cbz x0 fallthrough (reassembly complete)
 * The reassembled payload is garbage ICMP (type=0x41) so icmp_handle
 * drops it. ip_handle returns 0, but the fragmentation branches
 * ARE taken.
 * ======================================================================== */
/* ========================================================================
 * test_ip_reasm_big_complete — 80-byte payload across 2 fragments.
 * Exercises the FULL-BYTE bitmap loop (ip_reasm.S line 397 fallthrough)
 * which requires total_bits >= 8 (payload >= 64 bytes).
 * Frag1: offset=0, MF=1, 72 bytes. Frag2: offset=9, MF=0, 8 bytes.
 * Total = 80 bytes = 10 bitmap units = 1 full byte + 2 bits.
 * ======================================================================== */
test_ip_reasm_big_complete:
    stp     x29, x30, [sp, #-16]!

    bl      ip_reasm_init

    /* Frag1 → ip_reasm_input */
    ldr     x0, =ip_big_frag1
    ldr     x1, =ip_reasm_buf
    mov     w2, #106                /* ETH(14) + IP(20) + payload(72) */
.Lbc_copy1:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lbc_copy1

    ldr     x0, =ip_reasm_buf
    mov     w1, #106
    bl      ip_reasm_input
    cbnz    x0, .Lfail_ip_bc       /* should be incomplete */

    /* Frag2 → ip_reasm_input */
    ldr     x0, =ip_big_frag2
    ldr     x1, =ip_reasm_buf
    mov     w2, #42
.Lbc_copy2:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lbc_copy2

    ldr     x0, =ip_reasm_buf
    mov     w1, #42
    bl      ip_reasm_input
    cbz     x0, .Lfail_ip_bc       /* should be complete */

    /* Verify reassembled IP totlen = 20 + 80 = 100 */
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_TOTLEN)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #100
    b.ne    .Lfail_ip_bc

    ldr     x0, =name_ip_bc
    bl      test_pass
    b       .Ldone_ip_bc

.Lfail_ip_bc:
    ldr     x0, =name_ip_bc
    bl      test_fail

.Ldone_ip_bc:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_reasm_oversize_drop — Reassembled payload > 1480 bytes.
 * Exercises ip_reasm.S line 430: b.hi .Lri_free_drop (taken).
 * Frag1: offset=0, 8 bytes. Frag2: offset=185, 8 bytes.
 * Total = 185*8+8 = 1488 > 1480.
 * ======================================================================== */
test_ip_reasm_oversize_drop:
    stp     x29, x30, [sp, #-16]!

    bl      ip_reasm_init

    /* Frag1 → ip_reasm_input */
    ldr     x0, =ip_over_frag1
    ldr     x1, =ip_reasm_buf
    mov     w2, #42
.Lod_copy1:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lod_copy1

    ldr     x0, =ip_reasm_buf
    mov     w1, #42
    bl      ip_reasm_input
    cbnz    x0, .Lfail_ip_od       /* incomplete */

    /* Frag2 (triggers completion + oversize drop) */
    ldr     x0, =ip_over_frag2
    ldr     x1, =ip_reasm_buf
    mov     w2, #42
.Lod_copy2:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lod_copy2

    ldr     x0, =ip_reasm_buf
    mov     w1, #42
    bl      ip_reasm_input
    cbnz    x0, .Lfail_ip_od       /* should return 0 (oversize drop) */

    /* Slot should be freed */
    ldr     x0, =reasm_slots
    ldrb    w1, [x0, #REASM_FLAGS]
    cbnz    w1, .Lfail_ip_od

    ldr     x0, =name_ip_od
    bl      test_pass
    b       .Ldone_ip_od

.Lfail_ip_od:
    ldr     x0, =name_ip_od
    bl      test_fail

.Ldone_ip_od:
    ldp     x29, x30, [sp], #16
    ret

test_ip_handle_frag_dispatch:
    stp     x29, x30, [sp, #-16]!

    bl      ip_reasm_init

    /* Fragment 1 → ip_handle (returns 0: incomplete) */
    ldr     x0, =ip_frag1_template
    ldr     x1, =ip_reasm_buf
    mov     w2, #50
.Lfd_copy1:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lfd_copy1

    ldr     x0, =ip_reasm_buf
    mov     w1, #50
    bl      ip_handle
    /* Fragment 1 returns 0 (no reply yet) — fine */

    /* Fragment 2 → ip_handle (completes reassembly, dispatches) */
    ldr     x0, =ip_frag2_template
    ldr     x1, =ip_reasm_buf
    mov     w2, #42
.Lfd_copy2:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lfd_copy2

    ldr     x0, =ip_reasm_buf
    mov     w1, #42
    bl      ip_handle
    /* Reassembled ICMP has garbage type (0x41), so icmp_handle
     * drops it and ip_handle returns 0. The test asserts this. */
    cbnz    w0, .Lfail_ip_fd

    ldr     x0, =name_ip_fd
    bl      test_pass
    b       .Ldone_ip_fd

.Lfail_ip_fd:
    ldr     x0, =name_ip_fd
    bl      test_fail

.Ldone_ip_fd:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_handle_udp — Route a UDP echo frame through ip_handle.
 * Exercises ip.S line 196: b.eq .Lip_udp (UDP dispatch taken).
 * Uses a valid UDP echo to port 7, expects a reply (w0 > 0).
 * ======================================================================== */
test_ip_handle_udp:
    stp     x29, x30, [sp, #-16]!

    /* Copy UDP frame to mutable buffer */
    ldr     x0, =ip_udp_template
    ldr     x1, =ip_handle_buf
    mov     w2, #46
.Lhudp_copy:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lhudp_copy

    ldr     x0, =ip_handle_buf
    mov     w1, #46
    bl      ip_handle
    /* UDP echo to port 7 should produce a reply */
    cbz     w0, .Lfail_ip_hudp

    ldr     x0, =name_ip_hudp
    bl      test_pass
    b       .Ldone_ip_hudp

.Lfail_ip_hudp:
    ldr     x0, =name_ip_hudp
    bl      test_fail

.Ldone_ip_hudp:
    ldp     x29, x30, [sp], #16
    ret

test_ip_reasm_overlap:
    stp     x29, x30, [sp, #-16]!

    bl      ip_reasm_init

    /* Send frag1 (offset=0, 16 bytes, MF=1) — returns 0 (incomplete) */
    ldr     x0, =ip_frag1_template
    ldr     x1, =ip_reasm_buf
    mov     w2, #50
.Lro_copy1:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lro_copy1

    ldr     x0, =ip_reasm_buf
    mov     w1, #50
    bl      ip_reasm_input
    cbnz    x0, .Lfail_ip_overlap

    /* Send overlapping frag (offset=1, 8 bytes) — should return 0 (dropped) */
    ldr     x0, =ip_frag_overlap
    ldr     x1, =ip_reasm_buf
    mov     w2, #42
.Lro_copy2:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lro_copy2

    ldr     x0, =ip_reasm_buf
    mov     w1, #42
    bl      ip_reasm_input
    cbnz    x0, .Lfail_ip_overlap

    ldr     x0, =name_ip_overlap
    bl      test_pass
    b       .Ldone_ip_overlap

.Lfail_ip_overlap:
    ldr     x0, =name_ip_overlap
    bl      test_fail

.Ldone_ip_overlap:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_reasm_nonaligned — MF=1 with payload not multiple of 8 → dropped
 * ======================================================================== */
test_ip_reasm_nonaligned:
    stp     x29, x30, [sp, #-16]!

    bl      ip_reasm_init

    /* Send fragment with MF=1, payload=13 bytes (not aligned) */
    ldr     x0, =ip_frag_nonaligned
    ldr     x1, =ip_reasm_buf
    mov     w2, #47
.Lrna_copy:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lrna_copy

    ldr     x0, =ip_reasm_buf
    mov     w1, #47
    bl      ip_reasm_input

    /* Should return 0 (dropped) */
    cbnz    x0, .Lfail_ip_nonaligned

    ldr     x0, =name_ip_nonaligned
    bl      test_pass
    b       .Ldone_ip_nonaligned

.Lfail_ip_nonaligned:
    ldr     x0, =name_ip_nonaligned
    bl      test_fail

.Ldone_ip_nonaligned:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ip_reasm_min_ttl — reassembled datagram uses min(fragment TTLs)
 *
 * Frag1: TTL=32, offset=0, MF=1, 16 bytes
 * Frag2: TTL=10, offset=2 (16 bytes), MF=0, 8 bytes
 * Expected: reassembled TTL=10
 * ======================================================================== */
test_ip_reasm_min_ttl:
    stp     x29, x30, [sp, #-16]!

    bl      ip_reasm_init

    /* Frag1 (TTL=32) */
    ldr     x0, =ip_frag_ttl32
    ldr     x1, =ip_reasm_buf
    mov     w2, #50
.Lrmt_copy1:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lrmt_copy1

    ldr     x0, =ip_reasm_buf
    mov     w1, #50
    bl      ip_reasm_input
    cbnz    x0, .Lfail_ip_min_ttl

    /* Frag2 (TTL=10) — should complete reassembly */
    ldr     x0, =ip_frag_ttl10
    ldr     x1, =ip_reasm_buf
    mov     w2, #42
.Lrmt_copy2:
    sub     w2, w2, #1
    ldrb    w3, [x0, x2]
    strb    w3, [x1, x2]
    cbnz    w2, .Lrmt_copy2

    ldr     x0, =ip_reasm_buf
    mov     w1, #42
    bl      ip_reasm_input
    cbz     x0, .Lfail_ip_min_ttl

    /* Verify reassembled TTL == 10 (min of 32 and 10) */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_TTL)]
    cmp     w1, #10
    b.ne    .Lfail_ip_min_ttl

    ldr     x0, =name_ip_min_ttl
    bl      test_pass
    b       .Ldone_ip_min_ttl

.Lfail_ip_min_ttl:
    ldr     x0, =name_ip_min_ttl
    bl      test_fail

.Ldone_ip_min_ttl:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* 3-byte input that forces carry folding and odd-byte handling */
.balign 4
carry_test_data:
    .byte   0xFF, 0xFF, 0x03

/*
 * 20-byte IP header with checksum field zeroed.
 * src=10.0.2.2, dst=10.0.2.15, proto=ICMP, TTL=64, totlen=28
 */
.balign 4
ip_cksum_template:
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x00, 0x00     /* checksum=0 */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F

/*
 * 42-byte ICMP echo request template (valid, for 10.0.2.15)
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=001C id=1234 flags=0000
 *                ttl=40 proto=01 cksum=509D src=0A000202 dst=0A00020F
 * ICMP (8):      type=08 code=00 cksum=F7FD id=0001 seq=0001
 */
.balign 4
ip_icmp_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D                   /* ttl=64, proto=ICMP, cksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD                   /* ICMP echo request */
    .byte   0x00, 0x01, 0x00, 0x01

/* Same frame but with corrupted IP checksum (0x519D instead of 0x509D) */
.balign 4
ip_bad_cksum_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x51, 0x9D                   /* bad checksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* Valid frame but dest IP = 10.0.2.99 (cksum recomputed: 0x5049) */
.balign 4
ip_not_ours_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x49                   /* cksum for dst=10.0.2.99 */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x63                   /* dst: 10.0.2.99 */
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* Valid IP header but protocol = 255 (truly unknown), cksum recomputed */
.balign 4
ip_unknown_proto_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0xFF, 0x4F, 0x9F                   /* proto=255, cksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x00, 0x00, 0x00, 0x00                   /* dummy payload */
    .byte   0x00, 0x00, 0x00, 0x00

/* VER_IHL=0x46 — rejected at check #2 before checksum, no valid cksum needed */
.balign 4
ip_bad_ver_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x46, 0x00, 0x00, 0x1C                   /* ver/ihl=0x46 */
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* TotalLength=19 (0x0013) — rejected at check #3, no valid cksum needed */
.balign 4
ip_totlen_short_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x13                   /* totlen=19 */
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* TotalLength=29 (0x001D) in 42-byte frame: 14+29=43>42 — rejected at check #4 */
.balign 4
ip_totlen_overrun_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1D                   /* totlen=29 */
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/*
 * Fragment 1: offset=0, MF=1, 16-byte payload (50 bytes total)
 * IP: totlen=36, id=0xABCD, flags_frag=0x2000 (MF=1,off=0)
 */
.balign 4
ip_frag1_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x08, 0x00, 0x45, 0x00
    .byte   0x00, 0x24, 0xAB, 0xCD, 0x20, 0x00, 0x40, 0x01, 0x96, 0xFB, 0x0A, 0x00, 0x02, 0x02, 0x0A, 0x00
    .byte   0x02, 0x0F, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E
    .byte   0x4F, 0x50

/*
 * Fragment 2: offset=2 (16 bytes), MF=0, 8-byte payload (42 bytes total)
 * IP: totlen=28, id=0xABCD, flags_frag=0x0002 (MF=0,off=2)
 */
.balign 4
ip_frag2_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x08, 0x00, 0x45, 0x00
    .byte   0x00, 0x1C, 0xAB, 0xCD, 0x00, 0x02, 0x40, 0x01, 0xB7, 0x01, 0x0A, 0x00, 0x02, 0x02, 0x0A, 0x00
    .byte   0x02, 0x0F, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58

/* Expected reassembled payload (16 + 8 = 24 bytes) */
.balign 4
ip_reasm_expected_payload:
    .byte   0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48
    .byte   0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50
    .byte   0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58

/* TTL=0, valid checksum (0x9D90), rest same as ip_icmp_template */
.balign 4
ip_ttl_zero_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x00, 0x01, 0x90, 0x9D                   /* TTL=0, cksum=0x9D90 */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* ========================================================================
 * Martian source IP test frames — each identical to ip_icmp_template
 * except for the IP.src field and the recomputed IP checksum.
 * Checksums computed via hw_test/ip_frames.ip_checksum and pinned here.
 * ======================================================================== */

/* src=0.0.0.0, cksum=0x5C9F */
.balign 4
ip_src_zero_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x5C, 0x9F
    .byte   0x00, 0x00, 0x00, 0x00                   /* src: 0.0.0.0 */
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* src=127.0.0.1, cksum=0xDD9D */
.balign 4
ip_src_loopback_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0xDD, 0x9D
    .byte   0x7F, 0x00, 0x00, 0x01                   /* src: 127.0.0.1 */
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* src=127.255.255.254, cksum=0xDCA0 — exercises the whole 127/8 range */
.balign 4
ip_src_loopback_high_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0xDC, 0xA0
    .byte   0x7F, 0xFF, 0xFF, 0xFE                   /* src: 127.255.255.254 */
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* src=10.0.2.15 (self), cksum=0x5090 */
.balign 4
ip_src_self_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x90
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* src: 10.0.2.15 */
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* src=255.255.255.255 (broadcast), cksum=0x5C9F — RFC 1122 §3.2.1.3 */
.balign 4
ip_src_bcast_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x5C, 0x9F
    .byte   0xFF, 0xFF, 0xFF, 0xFF                   /* src: broadcast */
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* src=224.0.0.1 (multicast), cksum=0x7C9D — RFC 1112 */
.balign 4
ip_src_mcast_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x7C, 0x9D
    .byte   0xE0, 0x00, 0x00, 0x01                   /* src: 224.0.0.1 */
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0xF7, 0xFD
    .byte   0x00, 0x01, 0x00, 0x01

/* Big frag1: offset=0, MF=1, 72-byte payload. id=0xBEEF.
 * IP: totlen=92, flags=0x2000, cksum=0x83A1. 106 bytes total. */
.balign 4
ip_big_frag1:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x5C
    .byte   0xBE, 0xEF, 0x20, 0x00
    .byte   0x40, 0x01, 0x83, 0xA1
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    /* 72 bytes payload (0x01..0x48) */
    .byte   0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    .byte   0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
    .byte   0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18
    .byte   0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20
    .byte   0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28
    .byte   0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30
    .byte   0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38
    .byte   0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40
    .byte   0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48

/* Big frag2: offset=9 (72 bytes), MF=0, 8-byte payload. id=0xBEEF.
 * IP: totlen=28, flags_frag=0x0009, cksum=0xA3D8. 42 bytes total. */
.balign 4
ip_big_frag2:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0xBE, 0xEF, 0x00, 0x09
    .byte   0x40, 0x01, 0xA3, 0xD8
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50

/* Oversize frag1: offset=0, MF=1, 8 bytes. id=0xDEAD.
 * IP: totlen=28, flags=0x2000, cksum=0x6423. */
.balign 4
ip_over_frag1:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0xDE, 0xAD, 0x20, 0x00
    .byte   0x40, 0x01, 0x64, 0x23
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8

/* Oversize frag2: offset=185 (1480 bytes), MF=0, 8 bytes. id=0xDEAD.
 * total = 185*8+8 = 1488 > 1480. IP: flags_frag=0x00B9, cksum=0x836A. */
.balign 4
ip_over_frag2:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0xDE, 0xAD, 0x00, 0xB9
    .byte   0x40, 0x01, 0x83, 0x6A
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8

/* UDP echo to port 7: 46 bytes (ETH 14 + IP 20 + UDP 8 + data 4).
 * sport=9999 (0x270F), dport=7, UDP len=12, checksum=0 (skip).
 * IP: totlen=32 (0x0020), proto=17, cksum=0x5089. */
.balign 4
ip_udp_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00, 0x00, 0x20                   /* ver/ihl, totlen=32 */
    .byte   0x12, 0x34, 0x00, 0x00                   /* id, flags/frag */
    .byte   0x40, 0x11, 0x50, 0x89                   /* ttl=64, proto=UDP, cksum */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    .byte   0x27, 0x0F, 0x00, 0x07                   /* sport=9999, dport=7 */
    .byte   0x00, 0x0C, 0x00, 0x00                   /* UDP len=12, cksum=0 */
    .byte   0x41, 0x42, 0x43, 0x44                   /* payload: ABCD */

/* Overlapping fragment: id=0xABCD, offset=1 (8 bytes), MF=0, 8-byte payload */
.balign 4
ip_frag_overlap:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C, 0xAB, 0xCD, 0x00, 0x01, 0x40, 0x01, 0xB7, 0x02
    .byte   0x0A, 0x00, 0x02, 0x02, 0x0A, 0x00, 0x02, 0x0F
    .byte   0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68

/* Non-aligned fragment: MF=1, offset=0, totlen=33 (payload=13), id=0xABCD */
.balign 4
ip_frag_nonaligned:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x21, 0xAB, 0xCD, 0x20, 0x00, 0x40, 0x01, 0x96, 0xFE
    .byte   0x0A, 0x00, 0x02, 0x02, 0x0A, 0x00, 0x02, 0x0F
    .byte   0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D

/* Frag1 for min-TTL test: TTL=32, id=0xBEEF, offset=0, MF=1, 16-byte payload */
.balign 4
ip_frag_ttl32:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x24, 0xBE, 0xEF, 0x20, 0x00, 0x20, 0x01, 0xA3, 0xD9
    .byte   0x0A, 0x00, 0x02, 0x02, 0x0A, 0x00, 0x02, 0x0F
    .byte   0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50

/* Frag2 for min-TTL test: TTL=10, id=0xBEEF, offset=2 (16 bytes), MF=0, 8-byte payload */
.balign 4
ip_frag_ttl10:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C, 0xBE, 0xEF, 0x00, 0x02, 0x0A, 0x01, 0xD9, 0xDF
    .byte   0x0A, 0x00, 0x02, 0x02, 0x0A, 0x00, 0x02, 0x0F
    .byte   0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58

name_ip_cksum:      .asciz "ip_checksum"
name_ip_carry:      .asciz "ip_checksum_carry"
name_ip_icmp:       .asciz "ip_handle_icmp"
name_ip_short:      .asciz "ip_handle_short"
name_ip_bad_cksum:  .asciz "ip_handle_bad_cksum"
name_ip_not_ours:   .asciz "ip_handle_not_ours"
name_ip_unknown:    .asciz "ip_handle_unknown_proto"
name_ip_bad_ver:    .asciz "ip_handle_bad_ver"
name_ip_totlen_short:   .asciz "ip_handle_totlen_short"
name_ip_totlen_overrun: .asciz "ip_handle_totlen_overrun"
name_ip_ttl_zero:   .asciz "ip_handle_ttl_zero"
name_ip_src_zero:          .asciz "ip_handle_martian_src_zero"
name_ip_src_loopback:      .asciz "ip_handle_martian_src_loopback"
name_ip_src_loopback_high: .asciz "ip_handle_martian_src_loopback_high"
name_ip_src_self:          .asciz "ip_handle_martian_src_self"
name_ip_bc:                .asciz "ip_reasm_big_complete"
name_ip_od:                .asciz "ip_reasm_oversize_drop"
name_ip_fd:                .asciz "ip_handle_frag_dispatch"
name_ip_hudp:              .asciz "ip_handle_udp"
name_ip_src_bcast:         .asciz "ip_handle_martian_src_bcast"
name_ip_src_mcast:         .asciz "ip_handle_martian_src_mcast"
name_ip_reasm:      .asciz "ip_reasm_two_frags"
name_ip_timeout:    .asciz "ip_reasm_timeout"
name_ip_rti:        .asciz "ip_reasm_timeout_icmp"
name_ip_overlap:    .asciz "ip_reasm_overlap"
name_ip_nonaligned: .asciz "ip_reasm_nonaligned"
name_ip_min_ttl:    .asciz "ip_reasm_min_ttl"

.section .data
.balign 4
ip_cksum_buf:
    .space  20

.balign 4
ip_handle_buf:
    .space  46

.balign 8
ip_reasm_buf:
    .space  ETH_FRAME_MAX

/* ICMP Time Exceeded test: fake send function + tx buffer */
.balign 4
reasm_send_count:
    .word   0

.balign 8
reasm_icmp_tx_buf:
    .space  70                     /* ICMP_ERROR_FRAME_LEN */

.section .text
/* Fake send for reasm timeout ICMP test */
fake_reasm_send:
    ldr     x9, =reasm_send_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]
    mov     w0, #0
    ret
