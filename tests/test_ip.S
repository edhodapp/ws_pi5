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
.global test_ip_reasm_two_frags
.global test_ip_reasm_timeout
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
 * test_ip_reasm_overlap — overlapping fragment dropped
 *
 * Frag1: offset=0, MF=1, 16 bytes (sets bitmap bits 0-1)
 * Frag2: offset=1 (8 bytes), MF=0, 8 bytes (bit 1 already set → overlap)
 * ======================================================================== */
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
name_ip_reasm:      .asciz "ip_reasm_two_frags"
name_ip_timeout:    .asciz "ip_reasm_timeout"
name_ip_overlap:    .asciz "ip_reasm_overlap"
name_ip_nonaligned: .asciz "ip_reasm_nonaligned"
name_ip_min_ttl:    .asciz "ip_reasm_min_ttl"

.section .data
.balign 4
ip_cksum_buf:
    .space  20

.balign 4
ip_handle_buf:
    .space  42

.balign 8
ip_reasm_buf:
    .space  ETH_FRAME_MAX
