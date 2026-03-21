/*
 * test_icmp.S — Tests for ICMP echo reply handler
 *
 * Tests:
 *   1. test_icmp_echo_reply — Valid echo request → reply built in-place
 *   2. test_icmp_not_echo   — ICMP type=3 (dest unreachable) → returns 0
 *   3. test_icmp_short      — frame_len implies ICMP length < 8 → returns 0
 */

.include "net.inc"

.global test_icmp_echo_reply
.global test_icmp_not_echo
.global test_icmp_short
.global test_icmp_echo_payload
.global test_icmp_echo_payload_odd
.global test_icmp_unknown_type
.global test_icmp_bad_checksum
.global test_icmp_send_error
.global test_icmp_send_loop_suppress
.global test_icmp_send_no_ctx
.global test_icmp_rate_allow
.global test_icmp_rate_deny

.section .text

/* ========================================================================
 * test_icmp_echo_reply — Full validation of in-place reply
 * ======================================================================== */
test_icmp_echo_reply:
    stp     x29, x30, [sp, #-16]!

    /* Copy 42-byte template to mutable buffer */
    ldr     x0, =icmp_echo_template
    ldr     x1, =icmp_echo_buf
    ldp     x2, x3, [x0]           /* 16 bytes */
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]      /* 16 bytes */
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]          /* 8 bytes */
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]          /* 2 bytes */
    strh    w2, [x1, #40]

    /* Call icmp_handle(buf, 42) */
    ldr     x0, =icmp_echo_buf
    mov     w1, #42
    bl      icmp_handle

    /* Should return 42 */
    cmp     w0, #42
    b.ne    .Lfail_icmp_echo

    /* Check ETH dst == original src (sender MAC: AA:BB:CC:DD:EE:FF) */
    ldr     x0, =icmp_echo_buf
    add     x0, x0, #ETH_DST
    ldr     x1, =icmp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_icmp_echo

    /* Check ETH src == our MAC (02:00:00:00:00:01) */
    ldr     x0, =icmp_echo_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_icmp_echo

    /* Check IP src == our IP (0A 00 02 0F) */
    ldr     x0, =icmp_echo_buf
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_SRC)]
    ldr     x2, =net_our_ip
    ldr     w2, [x2]
    cmp     w1, w2
    b.ne    .Lfail_icmp_echo

    /* Check IP dst == sender IP (0A 00 02 02) */
    ldr     x0, =icmp_echo_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST)]
    cmp     w1, #0x0A
    b.ne    .Lfail_icmp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 1)]
    cbnz    w1, .Lfail_icmp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 2)]
    cmp     w1, #0x02
    b.ne    .Lfail_icmp_echo
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_DST + 3)]
    cmp     w1, #0x02
    b.ne    .Lfail_icmp_echo

    /* Check TTL == 64 */
    ldr     x0, =icmp_echo_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_TTL)]
    cmp     w1, #64
    b.ne    .Lfail_icmp_echo

    /* Check ICMP type == 0 (echo reply) */
    ldr     x0, =icmp_echo_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cbnz    w1, .Lfail_icmp_echo

    /* Verify ICMP checksum valid (ip_checksum returns 0) */
    ldr     x0, =icmp_echo_buf
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #8                  /* ICMP len = 42 - 14 - 20 */
    bl      ip_checksum
    cbnz    w0, .Lfail_icmp_echo

    /* Verify IP checksum valid (ip_checksum returns 0) */
    ldr     x0, =icmp_echo_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #20
    bl      ip_checksum
    cbnz    w0, .Lfail_icmp_echo

    ldr     x0, =name_icmp_echo
    bl      test_pass
    b       .Ldone_icmp_echo

.Lfail_icmp_echo:
    ldr     x0, =name_icmp_echo
    bl      test_fail

.Ldone_icmp_echo:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_not_echo — ICMP type=3 → returns 0 (rejected before writing)
 * ======================================================================== */
test_icmp_not_echo:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =icmp_not_echo_frame
    mov     w1, #42
    bl      icmp_handle

    cbnz    w0, .Lfail_icmp_not_echo

    ldr     x0, =name_icmp_not_echo
    bl      test_pass
    b       .Ldone_icmp_not_echo

.Lfail_icmp_not_echo:
    ldr     x0, =name_icmp_not_echo
    bl      test_fail

.Ldone_icmp_not_echo:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_short — frame_len=41 → ICMP length 7 < 8 → returns 0
 * ======================================================================== */
test_icmp_short:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =icmp_echo_template
    mov     w1, #41                 /* ICMP len = 41 - 14 - 20 = 7 < 8 */
    bl      icmp_handle

    cbnz    w0, .Lfail_icmp_short

    ldr     x0, =name_icmp_short
    bl      test_pass
    b       .Ldone_icmp_short

.Lfail_icmp_short:
    ldr     x0, =name_icmp_short
    bl      test_fail

.Ldone_icmp_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_echo_payload — Echo request with 32-byte payload
 *
 * Verifies payload bytes survive the in-place reply transformation,
 * and that ICMP/IP checksums are recomputed correctly over the full
 * 40-byte ICMP section (8-byte header + 32-byte payload).
 * ======================================================================== */
test_icmp_echo_payload:
    stp     x29, x30, [sp, #-16]!

    /* Copy 74-byte template to mutable buffer */
    ldr     x0, =icmp_payload_template
    ldr     x1, =icmp_payload_buf
    mov     w2, #74
.Lcopy_payload:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_payload

    /* Call icmp_handle(buf, 74) */
    ldr     x0, =icmp_payload_buf
    mov     w1, #74
    bl      icmp_handle

    /* Should return 74 */
    cmp     w0, #74
    b.ne    .Lfail_payload

    /* Check ICMP type == 0 (reply) */
    ldr     x0, =icmp_payload_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cbnz    w1, .Lfail_payload

    /* Check ICMP id preserved (id=1, big-endian 00 01 → LE 0x0100) */
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_ID)]
    cmp     w1, #0x0100
    b.ne    .Lfail_payload

    /* Check ICMP seq preserved (seq=2, big-endian 00 02 → LE 0x0200) */
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_SEQ)]
    cmp     w1, #0x0200
    b.ne    .Lfail_payload

    /* Payload byte 0 at frame offset 42 = 0xDE */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_HDR_LEN)]
    cmp     w1, #0xDE
    b.ne    .Lfail_payload

    /* Payload byte 31 at frame offset 73 = 0xAD */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_HDR_LEN + 31)]
    cmp     w1, #0xAD
    b.ne    .Lfail_payload

    /* Verify ICMP checksum valid (40-byte ICMP section) */
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #40
    bl      ip_checksum
    cbnz    w0, .Lfail_payload

    /* Verify IP checksum valid */
    ldr     x0, =icmp_payload_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #20
    bl      ip_checksum
    cbnz    w0, .Lfail_payload

    ldr     x0, =name_icmp_payload
    bl      test_pass
    b       .Ldone_payload

.Lfail_payload:
    ldr     x0, =name_icmp_payload
    bl      test_fail

.Ldone_payload:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_echo_payload_odd — Echo request with 33-byte payload
 *
 * The 41-byte ICMP section (8 header + 33 payload) is odd-length,
 * exercising the trailing-byte path in ip_checksum during ICMP
 * checksum recomputation.
 * ======================================================================== */
test_icmp_echo_payload_odd:
    stp     x29, x30, [sp, #-16]!

    /* Copy 75-byte template to mutable buffer */
    ldr     x0, =icmp_payload_odd_template
    ldr     x1, =icmp_payload_odd_buf
    mov     w2, #75
.Lcopy_payload_odd:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_payload_odd

    /* Call icmp_handle(buf, 75) */
    ldr     x0, =icmp_payload_odd_buf
    mov     w1, #75
    bl      icmp_handle

    /* Should return 75 */
    cmp     w0, #75
    b.ne    .Lfail_payload_odd

    /* Check ICMP type == 0 (reply) */
    ldr     x0, =icmp_payload_odd_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cbnz    w1, .Lfail_payload_odd

    /* Payload byte 0 = 0xDE */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_HDR_LEN)]
    cmp     w1, #0xDE
    b.ne    .Lfail_payload_odd

    /* Payload byte 32 (the odd trailing byte) at frame offset 74 = 0xDE */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_HDR_LEN + 32)]
    cmp     w1, #0xDE
    b.ne    .Lfail_payload_odd

    /* Verify ICMP checksum valid (41-byte odd-length ICMP section) */
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #41
    bl      ip_checksum
    cbnz    w0, .Lfail_payload_odd

    /* Verify IP checksum valid */
    ldr     x0, =icmp_payload_odd_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #20
    bl      ip_checksum
    cbnz    w0, .Lfail_payload_odd

    ldr     x0, =name_icmp_payload_odd
    bl      test_pass
    b       .Ldone_payload_odd

.Lfail_payload_odd:
    ldr     x0, =name_icmp_payload_odd
    bl      test_fail

.Ldone_payload_odd:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_unknown_type — ICMP type=11 (Time Exceeded), not 3 or 8 → returns 0
 *
 * Exercises the "unknown type" fall-through in icmp_handle after the
 * dest-unreachable (type 3) check was added. Type 11 is neither 3 nor 8,
 * so icmp_handle should ignore it and return 0.
 * ======================================================================== */
test_icmp_unknown_type:
    stp     x29, x30, [sp, #-16]!

    /* Copy echo template to mutable buffer (reuse icmp_echo_buf) */
    ldr     x0, =icmp_echo_template
    ldr     x1, =icmp_echo_buf
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    /* Overwrite ICMP type to 11 (Time Exceeded) and recompute ICMP checksum */
    ldr     x0, =icmp_echo_buf
    mov     w1, #11
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    strh    wzr, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #8
    bl      ip_checksum
    ldr     x1, =icmp_echo_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]

    /* Call icmp_handle(buf, 42) */
    ldr     x0, =icmp_echo_buf
    mov     w1, #42
    bl      icmp_handle

    /* Should return 0 (ignored) */
    cbnz    w0, .Lfail_icmp_unk

    ldr     x0, =name_icmp_unknown
    bl      test_pass
    b       .Ldone_icmp_unk

.Lfail_icmp_unk:
    ldr     x0, =name_icmp_unknown
    bl      test_fail

.Ldone_icmp_unk:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_bad_checksum — echo request with corrupted ICMP checksum → 0
 * ======================================================================== */
test_icmp_bad_checksum:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =icmp_echo_template
    ldr     x1, =icmp_echo_buf
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]

    /* Corrupt ICMP checksum */
    ldr     x0, =icmp_echo_buf
    mov     w1, #0xFF
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CHECKSUM)]

    mov     w1, #42
    bl      icmp_handle

    cbnz    w0, .Lfail_icmp_badck
    ldr     x0, =name_icmp_badck
    bl      test_pass
    b       .Ldone_icmp_badck
.Lfail_icmp_badck:
    ldr     x0, =name_icmp_badck
    bl      test_fail
.Ldone_icmp_badck:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_send_error — build and send Protocol Unreachable error
 * ======================================================================== */
test_icmp_send_error:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      icmp_init

    /* Set up send context with fake send function */
    ldr     x19, =icmp_send_ctx
    str     xzr, [x19, #ICMPC_DWC2_BASE]
    str     xzr, [x19, #ICMPC_ECM_STATE]
    ldr     x0, =icmp_test_tx_buf
    str     x0, [x19, #ICMPC_TX_BUF]
    ldr     x0, =fake_icmp_send
    str     x0, [x19, #ICMPC_SEND_FN]

    ldr     x0, =icmp_test_send_count
    str     wzr, [x0]

    /* Call icmp_send_error with a UDP frame (triggers Protocol Unreachable) */
    ldr     x0, =icmp_echo_template     /* any valid frame will do */
    mov     w1, #42
    mov     w2, #ICMP_DEST_UNREACHABLE
    mov     w3, #ICMP_CODE_PROTO_UNREACH
    bl      icmp_send_error

    /* Send should have been called once */
    ldr     x0, =icmp_test_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_icmp_se

    /* Verify tx_buf has correct ICMP type and code */
    ldr     x0, =icmp_test_tx_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    cmp     w1, #ICMP_DEST_UNREACHABLE
    b.ne    .Lfail_icmp_se
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]
    cmp     w1, #ICMP_CODE_PROTO_UNREACH
    b.ne    .Lfail_icmp_se

    /* Verify IP checksum is valid */
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_icmp_se

    /* Verify ICMP checksum is valid (36 bytes) */
    ldr     x0, =icmp_test_tx_buf
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN)
    mov     w1, #36
    bl      ip_checksum
    cbnz    w0, .Lfail_icmp_se

    ldr     x0, =name_icmp_se
    bl      test_pass
    b       .Ldone_icmp_se
.Lfail_icmp_se:
    ldr     x0, =name_icmp_se
    bl      test_fail
.Ldone_icmp_se:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_icmp_send_loop_suppress — no error on ICMP error frame
 * ======================================================================== */
test_icmp_send_loop_suppress:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      icmp_init

    ldr     x19, =icmp_send_ctx
    ldr     x0, =icmp_test_tx_buf
    str     x0, [x19, #ICMPC_TX_BUF]
    ldr     x0, =fake_icmp_send
    str     x0, [x19, #ICMPC_SEND_FN]

    ldr     x0, =icmp_test_send_count
    str     wzr, [x0]

    /* Feed an ICMP type=3 frame as the "original" — should be suppressed */
    ldr     x0, =icmp_not_echo_frame
    mov     w1, #42
    mov     w2, #ICMP_DEST_UNREACHABLE
    mov     w3, #ICMP_CODE_PROTO_UNREACH
    bl      icmp_send_error

    /* Send should NOT have been called */
    ldr     x0, =icmp_test_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_icmp_loop
    ldr     x0, =name_icmp_loop
    bl      test_pass
    b       .Ldone_icmp_loop
.Lfail_icmp_loop:
    ldr     x0, =name_icmp_loop
    bl      test_fail
.Ldone_icmp_loop:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_icmp_send_no_ctx — NULL send_fn → returns 0 without crash
 * ======================================================================== */
test_icmp_send_no_ctx:
    stp     x29, x30, [sp, #-16]!

    bl      icmp_init

    ldr     x0, =icmp_send_ctx
    str     xzr, [x0, #ICMPC_SEND_FN]
    ldr     x1, =icmp_test_tx_buf
    str     x1, [x0, #ICMPC_TX_BUF]

    ldr     x0, =icmp_echo_template
    mov     w1, #42
    mov     w2, #ICMP_DEST_UNREACHABLE
    mov     w3, #ICMP_CODE_PORT_UNREACH
    bl      icmp_send_error

    /* Should return 0 */
    cbnz    w0, .Lfail_icmp_noctx
    ldr     x0, =name_icmp_noctx
    bl      test_pass
    b       .Ldone_icmp_noctx
.Lfail_icmp_noctx:
    ldr     x0, =name_icmp_noctx
    bl      test_fail
.Ldone_icmp_noctx:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_rate_allow — token bucket allows first call after init
 * ======================================================================== */
test_icmp_rate_allow:
    stp     x29, x30, [sp, #-16]!

    bl      icmp_init

    bl      icmp_err_allow
    cmp     w0, #1
    b.ne    .Lfail_icmp_ra

    /* Tokens should be BURST-1 */
    ldr     x0, =icmp_err_tokens
    ldr     w0, [x0]
    cmp     w0, #(ICMP_ERR_BURST - 1)
    b.ne    .Lfail_icmp_ra

    ldr     x0, =name_icmp_ra
    bl      test_pass
    b       .Ldone_icmp_ra
.Lfail_icmp_ra:
    ldr     x0, =name_icmp_ra
    bl      test_fail
.Ldone_icmp_ra:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_icmp_rate_deny — exhausted tokens → deny
 * ======================================================================== */
test_icmp_rate_deny:
    stp     x29, x30, [sp, #-16]!

    bl      icmp_init

    /* Exhaust all tokens */
    mov     w19, #ICMP_ERR_BURST
.Lird_drain:
    cbz     w19, .Lird_drained
    bl      icmp_err_allow
    sub     w19, w19, #1
    b       .Lird_drain
.Lird_drained:

    /* Next call should be denied */
    bl      icmp_err_allow
    cbnz    w0, .Lfail_icmp_rd

    ldr     x0, =name_icmp_rd
    bl      test_pass
    b       .Ldone_icmp_rd
.Lfail_icmp_rd:
    ldr     x0, =name_icmp_rd
    bl      test_fail
.Ldone_icmp_rd:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Fake ICMP send function — increments counter
 * ======================================================================== */
fake_icmp_send:
    ldr     x9, =icmp_test_send_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]
    mov     w0, #0
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* Sender MAC for verification */
icmp_sender_mac:
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF

/*
 * 42-byte ICMP echo request: who has 10.0.2.15? From 10.0.2.2
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=001C id=1234 flags=0000
 *                ttl=40 proto=01 cksum=509D src=0A000202 dst=0A00020F
 * ICMP (8):      type=08 code=00 cksum=F7FD id=0001 seq=0001
 */
.balign 4
icmp_echo_template:
    /* Ethernet header (14 bytes) */
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    /* IP header (20 bytes) */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x1C                               /* totlen: 28 */
    .byte   0x12, 0x34                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x01                               /* ttl=64, proto=ICMP */
    .byte   0x50, 0x9D                               /* checksum */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    /* ICMP (8 bytes) */
    .byte   0x08, 0x00                               /* type=echo request, code=0 */
    .byte   0xF7, 0xFD                               /* checksum */
    .byte   0x00, 0x01                               /* id */
    .byte   0x00, 0x01                               /* seq */

/* ICMP frame with type=3 (dest unreachable) — rejected before writing */
.balign 4
icmp_not_echo_frame:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x1C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x9D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x03, 0x00, 0xFC, 0xFD                   /* type=3, code=0, cksum=0xFDFC */
    .byte   0x00, 0x01, 0x00, 0x01

name_icmp_echo:       .asciz "icmp_echo_reply"
name_icmp_not_echo:   .asciz "icmp_not_echo"
name_icmp_short:      .asciz "icmp_short"
name_icmp_payload:    .asciz "icmp_echo_payload"
name_icmp_payload_odd: .asciz "icmp_echo_payload_odd"
name_icmp_unknown:    .asciz "icmp_unknown_type"
name_icmp_badck:      .asciz "icmp_bad_checksum"
name_icmp_se:         .asciz "icmp_send_error"
name_icmp_loop:       .asciz "icmp_send_loop_suppress"
name_icmp_noctx:      .asciz "icmp_send_no_ctx"
name_icmp_ra:         .asciz "icmp_rate_allow"
name_icmp_rd:         .asciz "icmp_rate_deny"

/*
 * 74-byte ICMP echo request with 32-byte payload
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=003C id=1234 flags=0000
 *                ttl=40 proto=01 cksum=507D src=0A000202 dst=0A00020F
 * ICMP (8):      type=08 code=00 cksum=0D1F id=0001 seq=0002
 * Payload (32):  DE AD repeated
 */
.balign 4
icmp_payload_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x3C
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x7D
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0x0D, 0x1F
    .byte   0x00, 0x01, 0x00, 0x02
    .byte   0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD
    .byte   0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD
    .byte   0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD
    .byte   0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD

/*
 * 75-byte ICMP echo request with 33-byte payload (odd length)
 *
 * Same structure as above but totlen=003D, cksum=507C
 * ICMP cksum=2F1E, payload has one extra 0xDE byte.
 * The 41-byte ICMP section exercises ip_checksum's trailing-byte path.
 */
.balign 4
icmp_payload_odd_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x3D
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x01, 0x50, 0x7C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x08, 0x00, 0x2F, 0x1E
    .byte   0x00, 0x01, 0x00, 0x02
    .byte   0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD
    .byte   0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD
    .byte   0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD
    .byte   0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE, 0xAD
    .byte   0xDE

.section .data
/* Mutable buffer for in-place reply test */
.balign 4
icmp_echo_buf:
    .space  42

.balign 4
icmp_payload_buf:
    .space  74

.balign 4
icmp_payload_odd_buf:
    .space  76

.balign 16
icmp_test_tx_buf:
    .space  ICMP_ERROR_FRAME_LEN

.balign 4
icmp_test_send_count:
    .word   0
