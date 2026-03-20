/*
 * test_tcp.S — Tests for TCP handler
 *
 * Phase 1 (tests 1-12): validation + RST (no tcp_init, table all-CLOSED)
 * Phase 2 (tests 13-19): connection table + three-way handshake
 *
 * Tests:
 *   1. test_tcp_checksum      — Compute+store+verify TCP checksum on 54-byte SYN
 *   2. test_tcp_checksum_data — Same with 4-byte payload (58 bytes)
 *   3. test_tcp_short         — Frame 1 byte short → returns 0
 *   4. test_tcp_bad_checksum  — Valid frame with corrupted checksum → returns 0
 *   5. test_tcp_bad_data_off  — data_off=0x30 (12 < 20 min) → returns 0
 *   6. test_tcp_doff_overrun  — data_off=0x60 (24 > segment 20) → returns 0
 *   7. test_tcp_rst_syn       — SYN to port 80 → RST+ACK, SEQ=0, ACK=SEG.SEQ+1
 *   8. test_tcp_rst_ack       — ACK to port 80 → RST, SEQ=SEG.ACK
 *   9. test_tcp_rst_wrong_port — SYN to port 12345 → RST+ACK (no listener)
 *  10. test_tcp_checksum_odd  — Odd-length segment (21 bytes) exercises trailing byte
 *  11. test_tcp_rst_bare_data — flags=0x00 (no SYN/ACK/FIN) → cinc SYN=0 path
 *  12. test_tcp_rst_fin       — flags=FIN (no ACK) → cinc FIN=1 path
 *  13. test_tcp_init          — Verify slot 0 = LISTEN port 80, slots 1-15 = CLOSED
 *  14. test_tcp_syn_ack       — SYN to port 80 → SYN-ACK (after tcp_init)
 *  15. test_tcp_handshake     — Full SYN → SYN-ACK → ACK → ESTABLISHED
 *  16. test_tcp_syn_no_listen — SYN to port 12345 (no LISTEN) → RST+ACK
 *  17. test_tcp_syn_rcvd_rst  — SYN → SYN-ACK, then RST → conn CLOSED
 *  18. test_tcp_syn_rcvd_bad_ack — SYN → SYN-ACK, then ACK with wrong ACK# → RST
 *  19. test_tcp_table_full    — All slots occupied, SYN → RST (no free slot)
 *  20. test_tcp_scan_rport_miss — Exact-match scan: lport matches, rport doesn't
 *  21. test_tcp_scan_rip_miss — Exact-match scan: lport+rport match, rip doesn't
 *  22. test_tcp_listen_synack_reject — SYN+ACK to LISTEN port → RST (pure SYN required)
 *  23. test_tcp_unknown_state — Exact match in CLOSE_WAIT (unknown to Phase 2) → RST
 *  24. test_tcp_syn_rcvd_no_ack — SYN_RCVD + bare data (no ACK/RST) → RST
 *  25. test_tcp_established_rst — Full handshake → ESTABLISHED, then RST → CLOSED
 *  26. test_tcp_listen_ack_reject — ACK to LISTEN port (no SYN) → RST (line 198 taken)
 *  27. test_tcp_established_data_drop — ACK to ESTABLISHED conn (no RST) → drop (line 330 not-taken)
 *  ...  (tests 28-40 added for active close: see individual headers)
 *  41. test_tcp_lastack_ack_bad — LAST_ACK + ACK with wrong ACK# → stays LAST_ACK, RST
 *  42. test_tcp_finwait1_ack_bad — FIN_WAIT_1 + ACK with wrong ACK# → stays FIN_WAIT_1, RST
 *  43. test_tcp_closing_ack_bad — CLOSING + ACK with wrong ACK# → stays CLOSING, RST
 */

.include "net.inc"
.include "tcp.inc"
.include "timer.inc"

.global test_tcp

.section .text

/*
 * test_tcp — Run all TCP tests
 */
test_tcp:
    stp     x29, x30, [sp, #-16]!

    /* Zero connection table so Phase 1 tests see all-CLOSED
     * (main() may have called tcp_init earlier in test_boot_main) */
    ldr     x0, =tcp_conn_table
    mov     w1, #64
.Lttcp_zero_table:
    stp     xzr, xzr, [x0], #16
    subs    w1, w1, #1
    b.ne    .Lttcp_zero_table

    bl      test_tcp_checksum
    bl      test_tcp_checksum_data
    bl      test_tcp_short
    bl      test_tcp_bad_checksum
    bl      test_tcp_bad_data_off
    bl      test_tcp_doff_overrun
    bl      test_tcp_rst_syn
    bl      test_tcp_rst_ack
    bl      test_tcp_rst_wrong_port
    bl      test_tcp_checksum_odd
    bl      test_tcp_rst_bare_data
    bl      test_tcp_rst_fin
    bl      test_tcp_init_test
    bl      test_tcp_syn_ack
    bl      test_tcp_handshake
    bl      test_tcp_syn_no_listen
    bl      test_tcp_syn_rcvd_rst
    bl      test_tcp_syn_rcvd_bad_ack
    bl      test_tcp_table_full
    bl      test_tcp_scan_rport_miss
    bl      test_tcp_scan_rip_miss
    bl      test_tcp_listen_synack_reject
    bl      test_tcp_unknown_state
    bl      test_tcp_syn_rcvd_no_ack
    bl      test_tcp_established_rst
    bl      test_tcp_listen_ack_reject
    bl      test_tcp_established_data_drop
    bl      test_tcp_estab_data
    bl      test_tcp_estab_data_bad_seq
    bl      test_tcp_estab_fin
    bl      test_tcp_close_wait_rst
    bl      test_tcp_estab_data_multi
    bl      test_tcp_fsa_null_handler
    bl      test_tcp_scan_lport_miss
    bl      test_tcp_close_estab
    bl      test_tcp_close_closewait
    bl      test_tcp_close_invalid
    bl      test_tcp_finwait1_ack
    bl      test_tcp_finwait1_fin
    bl      test_tcp_finwait2_fin
    bl      test_tcp_closing_ack
    bl      test_tcp_lastack_ack
    bl      test_tcp_timewait_rst
    bl      test_tcp_timewait_timeout
    bl      test_tcp_lastack_ack_bad
    bl      test_tcp_finwait1_ack_bad
    bl      test_tcp_closing_ack_bad
    bl      test_tcp_rx_buffer
    bl      test_tcp_rx_buffer_multi
    bl      test_tcp_rx_flush
    bl      test_tcp_rx_overflow
    bl      test_tcp_send
    bl      test_tcp_send_invalid
    bl      test_tcp_send_zero_len
    bl      test_tcp_send_oversize
    bl      test_tcp_window_tracks_fill
    bl      test_tcp_window_after_flush
    bl      test_tcp_window_zero
    bl      test_tcp_buffer_contents
    bl      test_tcp_buffer_survives_flush
    bl      test_tcp_send_frame_fields
    bl      test_tcp_send_rx_independent
    bl      test_tcp_window_update
    bl      test_tcp_window_update_invalid
    bl      test_tcp_window_update_closewait
    bl      test_tcp_snd_wnd_capture
    bl      test_tcp_snd_wnd_update
    bl      test_tcp_send_exceeds_window
    bl      test_tcp_send_decrements_window
    bl      test_tcp_send_ready
    bl      test_tcp_send_ready_invalid
    bl      test_tcp_send_window_exhaustion
    bl      test_tcp_window_update_partial
    bl      test_tcp_send_boundary
    bl      test_tcp_send_ready_zero
    bl      test_tcp_snd_wnd_pure_ack
    bl      test_tcp_snd_wnd_data_ack
    bl      test_tcp_snd_una_handshake
    bl      test_tcp_snd_una_data_ack
    bl      test_tcp_snd_una_pure_ack
    ldp     x29, x30, [sp], #16
    ret

/*
 * ttcp_fill_checksum — Copy template to buf and fill valid TCP checksum
 *
 * x0: template pointer (rodata)
 * x1: buf pointer (mutable)
 * w2: frame_len
 * Clobbers: x0-x3, x19-x20, x30
 */
ttcp_fill_checksum:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    mov     x19, x1                 /* save buf */
    mov     w20, w2                 /* save frame_len */

    /* Byte-copy template to buf */
.Lttcp_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lttcp_copy

    /* Zero TCP checksum field */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* tcp_checksum(buf, frame_len - 34) */
    mov     x0, x19
    sub     w1, w20, #(ETH_HDR_LEN + IP_HDR_MIN)
    bl      tcp_checksum

    /* Store computed checksum */
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_checksum — Compute checksum on SYN (cksum=0), store, re-verify
 * ======================================================================== */
test_tcp_checksum:
    stp     x29, x30, [sp, #-16]!

    /* Copy 54-byte template to mutable buffer */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
.Lcopy_tcp_ck1:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_tcp_ck1

    /* Compute checksum (cksum field = 0 in template) */
    ldr     x0, =tcp_test_buf
    mov     w1, #20
    bl      tcp_checksum

    /* Store computed checksum */
    ldr     x1, =tcp_test_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Re-verify: should return 0 */
    ldr     x0, =tcp_test_buf
    mov     w1, #20
    bl      tcp_checksum

    cbnz    w0, .Lfail_tcp_cksum

    ldr     x0, =name_tcp_cksum
    bl      test_pass
    b       .Ldone_tcp_cksum

.Lfail_tcp_cksum:
    ldr     x0, =name_tcp_cksum
    bl      test_fail

.Ldone_tcp_cksum:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_checksum_data — Checksum with 4-byte payload (58-byte frame)
 * ======================================================================== */
test_tcp_checksum_data:
    stp     x29, x30, [sp, #-16]!

    /* Copy 58-byte template to mutable buffer */
    ldr     x0, =tcp_syn_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #58
.Lcopy_tcp_ck2:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_tcp_ck2

    /* Compute checksum (tcp_section_len = 58 - 34 = 24) */
    ldr     x0, =tcp_test_buf
    mov     w1, #24
    bl      tcp_checksum

    /* Store */
    ldr     x1, =tcp_test_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Re-verify */
    ldr     x0, =tcp_test_buf
    mov     w1, #24
    bl      tcp_checksum

    cbnz    w0, .Lfail_tcp_ckdata

    ldr     x0, =name_tcp_ckdata
    bl      test_pass
    b       .Ldone_tcp_ckdata

.Lfail_tcp_ckdata:
    ldr     x0, =name_tcp_ckdata
    bl      test_fail

.Ldone_tcp_ckdata:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_short — frame_len=53 (tcp_section=19 < 20 min) → returns 0
 * ======================================================================== */
test_tcp_short:
    stp     x29, x30, [sp, #-16]!

    /* Copy to mutable buf (tcp_handle may not write, but be safe) */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
.Lcopy_tcp_short:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_tcp_short

    ldr     x0, =tcp_test_buf
    mov     w1, #53                 /* 1 byte short */
    bl      tcp_handle

    cbnz    w0, .Lfail_tcp_short

    ldr     x0, =name_tcp_short
    bl      test_pass
    b       .Ldone_tcp_short

.Lfail_tcp_short:
    ldr     x0, =name_tcp_short
    bl      test_fail

.Ldone_tcp_short:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_bad_checksum — Valid frame with corrupted checksum → returns 0
 * ======================================================================== */
test_tcp_bad_checksum:
    stp     x29, x30, [sp, #-16]!

    /* Build valid frame */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Corrupt TCP checksum (flip low byte) */
    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    eor     w1, w1, #0xFF
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* tcp_handle should drop */
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cbnz    w0, .Lfail_tcp_badck

    ldr     x0, =name_tcp_badck
    bl      test_pass
    b       .Ldone_tcp_badck

.Lfail_tcp_badck:
    ldr     x0, =name_tcp_badck
    bl      test_fail

.Ldone_tcp_badck:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_bad_data_off — data_off=0x30 (3*4=12 < 20 min) → returns 0
 * ======================================================================== */
test_tcp_bad_data_off:
    stp     x29, x30, [sp, #-16]!

    /* Copy bad-doff template to mutable buf */
    ldr     x0, =tcp_bad_doff_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
.Lcopy_tcp_baddoff:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_tcp_baddoff

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cbnz    w0, .Lfail_tcp_baddoff

    ldr     x0, =name_tcp_baddoff
    bl      test_pass
    b       .Ldone_tcp_baddoff

.Lfail_tcp_baddoff:
    ldr     x0, =name_tcp_baddoff
    bl      test_fail

.Ldone_tcp_baddoff:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_doff_overrun — data_off=0x60 (6*4=24 > segment 20) → returns 0
 * ======================================================================== */
test_tcp_doff_overrun:
    stp     x29, x30, [sp, #-16]!

    /* Copy overrun template to mutable buf */
    ldr     x0, =tcp_doff_overrun_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
.Lcopy_tcp_doffovr:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_tcp_doffovr

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cbnz    w0, .Lfail_tcp_doffovr

    ldr     x0, =name_tcp_doffovr
    bl      test_pass
    b       .Ldone_tcp_doffovr

.Lfail_tcp_doffovr:
    ldr     x0, =name_tcp_doffovr
    bl      test_fail

.Ldone_tcp_doffovr:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_rst_syn — SYN to port 80 → RST+ACK
 *
 * Verify: return=54, flags=RST+ACK, SEQ=0, ACK=SEG.SEQ+1=2,
 *         ports swapped, both checksums valid
 * ======================================================================== */
test_tcp_rst_syn:
    stp     x29, x30, [sp, #-16]!

    /* Build valid SYN frame */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Call tcp_handle */
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return value = 54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_rstsyn

    ldr     x0, =tcp_test_buf

    /* TCP flags = RST+ACK (0x14) */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_rstsyn

    /* TCP SEQ = 0 */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    cbnz    w1, .Lfail_tcp_rstsyn

    /* TCP ACK = 2 (SEG.SEQ(1) + SYN(1) = 2, in NBO) */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w1, w1
    cmp     w1, #2
    b.ne    .Lfail_tcp_rstsyn

    /* TCP sport = 80 (swapped from dport) */
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #80
    b.ne    .Lfail_tcp_rstsyn

    /* TCP dport = 12345 (swapped from sport) */
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #12345
    cmp     w1, w2
    b.ne    .Lfail_tcp_rstsyn

    /* Verify IP checksum */
    ldr     x0, =tcp_test_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_tcp_rstsyn

    /* Verify TCP checksum */
    ldr     x0, =tcp_test_buf
    mov     w1, #20
    bl      tcp_checksum
    cbnz    w0, .Lfail_tcp_rstsyn

    ldr     x0, =name_tcp_rstsyn
    bl      test_pass
    b       .Ldone_tcp_rstsyn

.Lfail_tcp_rstsyn:
    ldr     x0, =name_tcp_rstsyn
    bl      test_fail

.Ldone_tcp_rstsyn:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_rst_ack — ACK to port 80 → RST (no ACK flag)
 *
 * Verify: return=54, flags=RST, SEQ=SEG.ACK(200), ACK=0, checksums valid
 * ======================================================================== */
test_tcp_rst_ack:
    stp     x29, x30, [sp, #-16]!

    /* Build valid ACK frame */
    ldr     x0, =tcp_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Call tcp_handle */
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return value = 54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_rstack

    ldr     x0, =tcp_test_buf

    /* TCP flags = RST only (0x04) */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST
    b.ne    .Lfail_tcp_rstack

    /* TCP SEQ = 200 (SEG.ACK from incoming, in NBO) */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w1, w1
    cmp     w1, #200
    b.ne    .Lfail_tcp_rstack

    /* TCP ACK = 0 */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    cbnz    w1, .Lfail_tcp_rstack

    /* Verify IP checksum */
    ldr     x0, =tcp_test_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_tcp_rstack

    /* Verify TCP checksum */
    ldr     x0, =tcp_test_buf
    mov     w1, #20
    bl      tcp_checksum
    cbnz    w0, .Lfail_tcp_rstack

    ldr     x0, =name_tcp_rstack
    bl      test_pass
    b       .Ldone_tcp_rstack

.Lfail_tcp_rstack:
    ldr     x0, =name_tcp_rstack
    bl      test_fail

.Ldone_tcp_rstack:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_rst_wrong_port — SYN to port 12345 → RST+ACK (no listener)
 * ======================================================================== */
test_tcp_rst_wrong_port:
    stp     x29, x30, [sp, #-16]!

    /* Build valid SYN-to-wrong-port frame */
    ldr     x0, =tcp_syn_wrongport_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Call tcp_handle */
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return value = 54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_rstwp

    ldr     x0, =tcp_test_buf

    /* TCP flags = RST+ACK (same behavior, no listener anywhere) */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_rstwp

    /* TCP SEQ = 0 */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    cbnz    w1, .Lfail_tcp_rstwp

    /* TCP ACK = 2 (SEG.SEQ(1) + SYN(1)) */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w1, w1
    cmp     w1, #2
    b.ne    .Lfail_tcp_rstwp

    /* Verify TCP checksum */
    ldr     x0, =tcp_test_buf
    mov     w1, #20
    bl      tcp_checksum
    cbnz    w0, .Lfail_tcp_rstwp

    ldr     x0, =name_tcp_rstwp
    bl      test_pass
    b       .Ldone_tcp_rstwp

.Lfail_tcp_rstwp:
    ldr     x0, =name_tcp_rstwp
    bl      test_fail

.Ldone_tcp_rstwp:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_checksum_odd — Odd-length segment (21 bytes) exercises trailing byte
 *
 * SYN + 1-byte payload "X". tcp_section_len=21 (odd).
 * ======================================================================== */
test_tcp_checksum_odd:
    stp     x29, x30, [sp, #-16]!

    /* Copy 55-byte template to mutable buffer */
    ldr     x0, =tcp_syn_odd_template
    ldr     x1, =tcp_test_buf
    mov     w2, #55
.Lcopy_tcp_ckodd:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_tcp_ckodd

    /* Compute checksum (tcp_section_len = 55 - 34 = 21, odd) */
    ldr     x0, =tcp_test_buf
    mov     w1, #21
    bl      tcp_checksum

    /* Store */
    ldr     x1, =tcp_test_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Re-verify: should return 0 */
    ldr     x0, =tcp_test_buf
    mov     w1, #21
    bl      tcp_checksum

    cbnz    w0, .Lfail_tcp_ckodd

    ldr     x0, =name_tcp_ckodd
    bl      test_pass
    b       .Ldone_tcp_ckodd

.Lfail_tcp_ckodd:
    ldr     x0, =name_tcp_ckodd
    bl      test_fail

.Ldone_tcp_ckodd:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_rst_bare_data — flags=0x00 (no SYN/ACK/FIN)
 *
 * Exercises cinc SYN=0 (no increment). SEG.LEN = 0 data + 0 + 0 = 0.
 * RST+ACK reply: SEQ=0, ACK=SEG.SEQ+0=100.
 * ======================================================================== */
test_tcp_rst_bare_data:
    stp     x29, x30, [sp, #-16]!

    /* Build valid bare-data frame */
    ldr     x0, =tcp_bare_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Call tcp_handle */
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return value = 54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_rstbare

    ldr     x0, =tcp_test_buf

    /* Flags = RST+ACK (no ACK in incoming → RST+ACK path) */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_rstbare

    /* SEQ = 0 */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    cbnz    w1, .Lfail_tcp_rstbare

    /* ACK = 100 (SEG.SEQ + 0, no SYN/FIN/data) */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w1, w1
    cmp     w1, #100
    b.ne    .Lfail_tcp_rstbare

    /* Verify TCP checksum */
    ldr     x0, =tcp_test_buf
    mov     w1, #20
    bl      tcp_checksum
    cbnz    w0, .Lfail_tcp_rstbare

    ldr     x0, =name_tcp_rstbare
    bl      test_pass
    b       .Ldone_tcp_rstbare

.Lfail_tcp_rstbare:
    ldr     x0, =name_tcp_rstbare
    bl      test_fail

.Ldone_tcp_rstbare:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_rst_fin — flags=FIN(0x01), no ACK
 *
 * Exercises cinc FIN=1 (increment). SEG.LEN = 0 data + 0 SYN + 1 FIN = 1.
 * RST+ACK reply: SEQ=0, ACK=SEG.SEQ+1=101.
 * ======================================================================== */
test_tcp_rst_fin:
    stp     x29, x30, [sp, #-16]!

    /* Build valid FIN frame */
    ldr     x0, =tcp_fin_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Call tcp_handle */
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return value = 54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_rstfin

    ldr     x0, =tcp_test_buf

    /* Flags = RST+ACK */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_rstfin

    /* SEQ = 0 */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    cbnz    w1, .Lfail_tcp_rstfin

    /* ACK = 101 (SEG.SEQ(100) + FIN(1)) */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w1, w1
    cmp     w1, #101
    b.ne    .Lfail_tcp_rstfin

    /* Verify TCP checksum */
    ldr     x0, =tcp_test_buf
    mov     w1, #20
    bl      tcp_checksum
    cbnz    w0, .Lfail_tcp_rstfin

    ldr     x0, =name_tcp_rstfin
    bl      test_pass
    b       .Ldone_tcp_rstfin

.Lfail_tcp_rstfin:
    ldr     x0, =name_tcp_rstfin
    bl      test_fail

.Ldone_tcp_rstfin:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Phase 2 Tests (13-19)
 * ======================================================================== */

/* ========================================================================
 * test_tcp_init — Verify slot 0 = LISTEN port 80, slots 1-15 = CLOSED
 * ======================================================================== */
test_tcp_init_test:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    ldr     x0, =tcp_conn_table

    /* Slot 0: state = LISTEN (1) */
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_LISTEN
    b.ne    .Lfail_tcp_init

    /* Slot 0: lport = 0x5000 (port 80 NBO) */
    ldrh    w1, [x0, #TCONN_LPORT]
    mov     w2, #0x5000
    cmp     w1, w2
    b.ne    .Lfail_tcp_init

    /* Slots 1-15: all state = CLOSED (0) */
    add     x0, x0, #TCONN_SIZE    /* point to slot 1 */
    mov     w3, #15
.Ltcp_init_check:
    ldrb    w1, [x0, #TCONN_STATE]
    cbnz    w1, .Lfail_tcp_init
    add     x0, x0, #TCONN_SIZE
    subs    w3, w3, #1
    b.ne    .Ltcp_init_check

    ldr     x0, =name_tcp_init
    bl      test_pass
    b       .Ldone_tcp_init

.Lfail_tcp_init:
    ldr     x0, =name_tcp_init
    bl      test_fail

.Ldone_tcp_init:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_syn_ack — SYN to port 80 → SYN-ACK reply (after tcp_init)
 *
 * Verify: return=54, flags=SYN+ACK(0x12), ACK=SEG.SEQ+1=2 (NBO),
 *         ports swapped, checksums valid, conn state=SYN_RCVD,
 *         reply SEQ == SND_UNA (the ISN)
 * ======================================================================== */
test_tcp_syn_ack:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Build valid SYN frame */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Call tcp_handle */
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return value = 54 (SYN-ACK reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_synack

    ldr     x19, =tcp_test_buf

    /* TCP flags = SYN+ACK (0x12) */
    ldrb    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_SYN_ACK
    b.ne    .Lfail_tcp_synack

    /* TCP ACK = 2 (SEG.SEQ(1) + 1 for SYN, in NBO) */
    ldr     w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w1, w1
    cmp     w1, #2
    b.ne    .Lfail_tcp_synack

    /* TCP sport = 80 (swapped from dport) */
    ldrh    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #80
    b.ne    .Lfail_tcp_synack

    /* TCP dport = 12345 (swapped from sport) */
    ldrh    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #12345
    cmp     w1, w2
    b.ne    .Lfail_tcp_synack

    /* TCP window = TCP_RXBUF_SIZE (2048) NBO */
    ldrh    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #TCP_RXBUF_SIZE
    cmp     w1, w2
    b.ne    .Lfail_tcp_synack

    /* Verify reply SEQ == SND_UNA from connection table */
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20                /* reply SEQ in host order */

    /* Find the SYN_RCVD connection */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lsynack_find:
    cbz     w3, .Lfail_tcp_synack  /* no SYN_RCVD found */
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.eq    .Lsynack_found
    add     x0, x0, #TCONN_SIZE
    b       .Lsynack_find

.Lsynack_found:
    /* Verify state = SYN_RCVD */
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.ne    .Lfail_tcp_synack

    /* Verify SND_UNA == reply SEQ */
    ldr     w1, [x0, #TCONN_SND_UNA]
    cmp     w1, w20
    b.ne    .Lfail_tcp_synack

    /* Verify IP checksum */
    mov     x0, x19
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_tcp_synack

    /* Verify TCP checksum */
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    cbnz    w0, .Lfail_tcp_synack

    ldr     x0, =name_tcp_synack
    bl      test_pass
    b       .Ldone_tcp_synack

.Lfail_tcp_synack:
    ldr     x0, =name_tcp_synack
    bl      test_fail

.Ldone_tcp_synack:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_handshake — Full three-way handshake: SYN → SYN-ACK → ACK
 *
 * 1. tcp_init
 * 2. SYN → tcp_handle → return 54 (SYN-ACK)
 * 3. Extract ISN from SYN-ACK SEQ field
 * 4. Build ACK with SEQ=2, ACK=ISN+1 → tcp_handle → return 0
 * 5. Verify connection state = ESTABLISHED
 * ======================================================================== */
test_tcp_handshake:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Step 1: Send SYN */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Must return 54 (SYN-ACK) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_hs

    /* Step 2: Extract ISN from SYN-ACK reply SEQ */
    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20                /* w20 = ISN (host order) */

    /* Step 3: Build ACK packet in tcp_test_buf2 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
.Lcopy_hs_ack:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_hs_ack

    /* Write ACK = rev(ISN + 1) into buf2 TCP_ACK field */
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* Compute and store TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Step 4: Send ACK */
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Must return 0 (accepted, no reply) */
    cbnz    w0, .Lfail_tcp_hs

    /* Step 5: Verify connection state = ESTABLISHED */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lhs_find:
    cbz     w3, .Lfail_tcp_hs      /* no ESTABLISHED found */
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lhs_found
    add     x0, x0, #TCONN_SIZE
    b       .Lhs_find

.Lhs_found:
    ldr     x0, =name_tcp_hs
    bl      test_pass
    b       .Ldone_tcp_hs

.Lfail_tcp_hs:
    ldr     x0, =name_tcp_hs
    bl      test_fail

.Ldone_tcp_hs:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_syn_no_listen — SYN to port 12345 (no LISTEN) → RST+ACK
 *
 * After tcp_init, port 80 is LISTEN. SYN to port 12345 has no match.
 * ======================================================================== */
test_tcp_syn_no_listen:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Build SYN to wrong port */
    ldr     x0, =tcp_syn_wrongport_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return value = 54 (RST) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_synnolist

    ldr     x0, =tcp_test_buf

    /* Flags = RST+ACK */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_synnolist

    ldr     x0, =name_tcp_synnolist
    bl      test_pass
    b       .Ldone_tcp_synnolist

.Lfail_tcp_synnolist:
    ldr     x0, =name_tcp_synnolist
    bl      test_fail

.Ldone_tcp_synnolist:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_syn_rcvd_rst — SYN → SYN-ACK, then RST → conn CLOSED
 * ======================================================================== */
test_tcp_syn_rcvd_rst:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cmp     w0, #54
    b.ne    .Lfail_tcp_srst

    /* Build RST from peer (use tcp_rst_from_peer_template) */
    ldr     x0, =tcp_rst_from_peer_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* RST to existing connection → return 0 (close, no reply) */
    cbnz    w0, .Lfail_tcp_srst

    /* Verify no SYN_RCVD slots remain (all should be CLOSED or LISTEN) */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lsrst_check:
    cbz     w3, .Lsrst_ok
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.eq    .Lfail_tcp_srst         /* still SYN_RCVD → fail */
    add     x0, x0, #TCONN_SIZE
    b       .Lsrst_check

.Lsrst_ok:
    ldr     x0, =name_tcp_srst
    bl      test_pass
    b       .Ldone_tcp_srst

.Lfail_tcp_srst:
    ldr     x0, =name_tcp_srst
    bl      test_fail

.Ldone_tcp_srst:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_syn_rcvd_bad_ack — SYN → SYN-ACK, then ACK with wrong ACK# → RST
 * ======================================================================== */
test_tcp_syn_rcvd_bad_ack:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cmp     w0, #54
    b.ne    .Lfail_tcp_badack2

    /* Build ACK with wrong ACK number (use bad_ack template: ACK=0xDEADBEEF) */
    ldr     x0, =tcp_bad_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Bad ACK → RST reply (return 54) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_badack2

    ldr     x0, =tcp_test_buf

    /* Flags should include RST */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    tst     w1, #TCP_RST
    b.eq    .Lfail_tcp_badack2

    ldr     x0, =name_tcp_badack2
    bl      test_pass
    b       .Ldone_tcp_badack2

.Lfail_tcp_badack2:
    ldr     x0, =name_tcp_badack2
    bl      test_fail

.Ldone_tcp_badack2:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_table_full — Fill slots 1-15 as SYN_RCVD, then SYN → RST
 * ======================================================================== */
test_tcp_table_full:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Fill slots 1-15 with state=SYN_RCVD (non-CLOSED) */
    ldr     x0, =tcp_conn_table
    add     x0, x0, #TCONN_SIZE    /* skip slot 0 (LISTEN) */
    mov     w2, #TCPS_SYN_RCVD
    mov     w3, #15
.Ltfull_fill:
    strb    w2, [x0, #TCONN_STATE]
    add     x0, x0, #TCONN_SIZE
    subs    w3, w3, #1
    b.ne    .Ltfull_fill

    /* SYN to port 80 — should fail to allocate, fall back to RST */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return 54 (RST reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_tfull

    ldr     x0, =tcp_test_buf

    /* Flags = RST+ACK */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_tfull

    ldr     x0, =name_tcp_tfull
    bl      test_pass
    b       .Ldone_tcp_tfull

.Lfail_tcp_tfull:
    ldr     x0, =name_tcp_tfull
    bl      test_fail

.Ldone_tcp_tfull:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Branch coverage tests (20-25)
 * ======================================================================== */

/* ========================================================================
 * test_tcp_scan_rport_miss — Exact-match scan: lport matches, rport doesn't
 *
 * Exercises line 174 taken (b.ne .Ltcp_scan_next on rport mismatch).
 * Setup: tcp_init + SYN from :12345→:80 creates SYN_RCVD with rport=12345.
 * Then send bare data from :54321→:80 — same lport, different rport.
 * ======================================================================== */
test_tcp_scan_rport_miss:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Create SYN_RCVD connection from 10.0.2.2:12345→:80 */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_rpmiss

    /* Send bare data from :54321→:80 (rport mismatch in exact-match scan) */
    ldr     x0, =tcp_from54321_to80_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* LISTEN fallback, non-SYN → RST+ACK */
    cmp     w0, #54
    b.ne    .Lfail_tcp_rpmiss

    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_rpmiss

    ldr     x0, =name_tcp_rpmiss
    bl      test_pass
    b       .Ldone_tcp_rpmiss

.Lfail_tcp_rpmiss:
    ldr     x0, =name_tcp_rpmiss
    bl      test_fail

.Ldone_tcp_rpmiss:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_scan_rip_miss — Exact-match scan: lport+rport match, rip doesn't
 *
 * Exercises line 177 taken (b.ne .Ltcp_scan_next on rip mismatch).
 * Setup: tcp_init + SYN from 10.0.2.2:12345→:80 creates SYN_RCVD.
 * Then send bare data from 10.0.2.3:12345→:80 — same ports, different IP.
 * ======================================================================== */
test_tcp_scan_rip_miss:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Create SYN_RCVD connection from 10.0.2.2:12345→:80 */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_ripmiss

    /* Send bare data from 10.0.2.3:12345→:80 (rip mismatch) */
    ldr     x0, =tcp_diffip_to80_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* LISTEN fallback, non-SYN → RST+ACK */
    cmp     w0, #54
    b.ne    .Lfail_tcp_ripmiss

    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_ripmiss

    ldr     x0, =name_tcp_ripmiss
    bl      test_pass
    b       .Ldone_tcp_ripmiss

.Lfail_tcp_ripmiss:
    ldr     x0, =name_tcp_ripmiss
    bl      test_fail

.Ldone_tcp_ripmiss:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_listen_synack_reject — SYN+ACK to LISTEN port → RST
 *
 * Exercises line 200 taken (b.ne .Ltcp_no_conn when ACK set with SYN).
 * LISTEN fallback matches, SYN=1 passes line 198, but ACK=1 fails line 200.
 * Since incoming has ACK → RST with SEQ=SEG.ACK (flags=RST only).
 * ======================================================================== */
test_tcp_listen_synack_reject:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Send SYN+ACK to port 80 */
    ldr     x0, =tcp_synack_to80_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Should get RST (return 54) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_lsar

    /* Incoming had ACK → RST path (flags=RST only, SEQ=SEG.ACK) */
    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST
    b.ne    .Lfail_tcp_lsar

    ldr     x0, =name_tcp_lsar
    bl      test_pass
    b       .Ldone_tcp_lsar

.Lfail_tcp_lsar:
    ldr     x0, =name_tcp_lsar
    bl      test_fail

.Ldone_tcp_lsar:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_unknown_state — Exact match in unknown state → RST
 *
 * Exercises line 243 (b .Ltcp_no_conn fallthrough from conn_dispatch).
 * Setup: tcp_init + SYN→SYN-ACK, then overwrite slot state to CLOSE_WAIT.
 * Send matching bare data → exact match → dispatch → not SYN_RCVD,
 * not ESTABLISHED → falls to .Ltcp_no_conn → RST.
 * ======================================================================== */
test_tcp_unknown_state:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Create SYN_RCVD connection */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_unkst

    /* Find SYN_RCVD slot and change state to CLOSE_WAIT */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lunkst_find:
    cbz     w3, .Lfail_tcp_unkst
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.eq    .Lunkst_found
    add     x0, x0, #TCONN_SIZE
    b       .Lunkst_find

.Lunkst_found:
    mov     w1, #TCPS_CLOSE_WAIT
    strb    w1, [x0, #TCONN_STATE]

    /* Send matching bare data → exact match → unknown state → RST */
    ldr     x0, =tcp_bare_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Unknown state → no_conn → RST+ACK (incoming flags=0 → no ACK path) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_unkst

    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_unkst

    ldr     x0, =name_tcp_unkst
    bl      test_pass
    b       .Ldone_tcp_unkst

.Lfail_tcp_unkst:
    ldr     x0, =name_tcp_unkst
    bl      test_fail

.Ldone_tcp_unkst:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_syn_rcvd_no_ack — SYN_RCVD + bare data (no ACK, no RST) → RST
 *
 * Exercises line 312 taken (b.eq .Ltcp_no_conn when ACK not set).
 * Setup: tcp_init + SYN→SYN-ACK, then send bare data (flags=0) from
 * same source → exact match → SYN_RCVD → no RST → no ACK → RST.
 * ======================================================================== */
test_tcp_syn_rcvd_no_ack:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Create SYN_RCVD connection */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_srnoack

    /* Send bare data from same source (flags=0) → SYN_RCVD + no ACK */
    ldr     x0, =tcp_bare_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* No ACK in SYN_RCVD → no_conn → RST+ACK */
    cmp     w0, #54
    b.ne    .Lfail_tcp_srnoack

    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST_ACK
    b.ne    .Lfail_tcp_srnoack

    ldr     x0, =name_tcp_srnoack
    bl      test_pass
    b       .Ldone_tcp_srnoack

.Lfail_tcp_srnoack:
    ldr     x0, =name_tcp_srnoack
    bl      test_fail

.Ldone_tcp_srnoack:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_established_rst — ESTABLISHED + RST → close connection
 *
 * Exercises line 330 taken (b.ne .Ltcp_conn_close in ESTABLISHED).
 * Full handshake → ESTABLISHED, then send RST → return 0, state = CLOSED.
 * ======================================================================== */
test_tcp_established_rst:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Step 1: SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_erst

    /* Extract ISN from SYN-ACK SEQ field */
    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20                /* w20 = ISN (host order) */

    /* Step 2: ACK with correct ACK=ISN+1 → ESTABLISHED */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
.Lcopy_erst_ack:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_erst_ack

    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_erst

    /* Step 3: Send RST → ESTABLISHED + RST → close */
    ldr     x0, =tcp_rst_from_peer_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_erst

    /* Verify no ESTABLISHED slots remain */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lerst_check:
    cbz     w3, .Lerst_ok
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lfail_tcp_erst
    add     x0, x0, #TCONN_SIZE
    b       .Lerst_check

.Lerst_ok:
    ldr     x0, =name_tcp_erst
    bl      test_pass
    b       .Ldone_tcp_erst

.Lfail_tcp_erst:
    ldr     x0, =name_tcp_erst
    bl      test_fail

.Ldone_tcp_erst:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_listen_ack_reject — ACK to LISTEN port (no existing conn) → RST
 *
 * Exercises line 198 taken (b.eq .Ltcp_no_conn — SYN not set).
 * After tcp_init, send ACK-only to port 80.  No SYN_RCVD connection
 * exists, so scan finds LISTEN (x24 set) but no exact match.  At
 * scan_done, flags=ACK has no SYN bit → line 198 branches to RST.
 * ======================================================================== */
test_tcp_listen_ack_reject:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Build valid ACK to port 80 */
    ldr     x0, =tcp_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Should return 54 (RST reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_lar

    /* Verify flags = RST (has ACK in original → RST with SEQ=SEG.ACK) */
    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST
    b.ne    .Lfail_tcp_lar

    ldr     x0, =name_tcp_lar
    bl      test_pass
    b       .Ldone_tcp_lar

.Lfail_tcp_lar:
    ldr     x0, =name_tcp_lar
    bl      test_fail

.Ldone_tcp_lar:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_established_data_drop — ACK to ESTABLISHED conn → drop (return 0)
 *
 * Exercises line 330 not-taken (non-RST in ESTABLISHED → drop).
 * Full handshake → ESTABLISHED, then send another ACK — handler sees
 * no RST bit and falls through to drop path.
 * ======================================================================== */
test_tcp_established_data_drop:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Step 1: SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_edd

    /* Extract ISN from SYN-ACK SEQ field */
    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20                /* w20 = ISN (host order) */

    /* Step 2: ACK with correct ACK=ISN+1 → ESTABLISHED */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
.Lcopy_edd_ack:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_edd_ack

    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_edd

    /* Step 3: Send another ACK (non-RST) to ESTABLISHED → drop */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
.Lcopy_edd_data:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_edd_data

    ldr     x19, =tcp_test_buf
    /* ACK=ISN+1 (same as step 2) */
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Should return 0 (dropped, no reply) */
    cbnz    w0, .Lfail_tcp_edd

    /* Verify connection still ESTABLISHED (not closed) */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ledd_check:
    cbz     w3, .Lfail_tcp_edd     /* no ESTABLISHED found → fail */
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Ledd_ok
    add     x0, x0, #TCONN_SIZE
    b       .Ledd_check

.Ledd_ok:
    ldr     x0, =name_tcp_edd
    bl      test_pass
    b       .Ldone_tcp_edd

.Lfail_tcp_edd:
    ldr     x0, =name_tcp_edd
    bl      test_fail

.Ldone_tcp_edd:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_estab_data — ACK+PSH with 5-byte payload to ESTABLISHED conn
 *
 * Handshake → ESTABLISHED, then send 59-byte frame (54 + 5 data).
 * Verify: return=54 (ACK reply), RCV_NXT updated by 5.
 * ======================================================================== */
test_tcp_estab_data:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Step 1: SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_ed

    /* Extract ISN from SYN-ACK SEQ */
    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20                /* w20 = ISN (host order) */

    /* Step 2: ACK → ESTABLISHED */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum      /* copies + fills cksum with ACK=0 */

    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_ed

    /* Save RCV_NXT before data */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Led_find_estab:
    cbz     w3, .Lfail_tcp_ed
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Led_found_estab
    add     x0, x0, #TCONN_SIZE
    b       .Led_find_estab
.Led_found_estab:
    mov     x21, x0                 /* x21 = conn ptr */
    ldr     w22, [x21, #TCONN_RCV_NXT]  /* w22 = old RCV_NXT */

    /* Step 3: Send ACK+PSH with 5-byte payload */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum

    ldr     x19, =tcp_test_buf
    /* Fill ACK = ISN+1 */
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25                 /* tcp_section_len = 59 - 34 */
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle

    /* Verify return = 54 (ACK reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_ed

    /* Verify RCV_NXT incremented by 5 */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    add     w1, w22, #5
    cmp     w0, w1
    b.ne    .Lfail_tcp_ed

    ldr     x0, =name_tcp_ed
    bl      test_pass
    b       .Ldone_tcp_ed
.Lfail_tcp_ed:
    ldr     x0, =name_tcp_ed
    bl      test_fail
.Ldone_tcp_ed:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_estab_data_bad_seq — Data with wrong SEQ → drop, RCV_NXT unchanged
 * ======================================================================== */
test_tcp_estab_data_bad_seq:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake (same as above) */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_edb

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_edb

    /* Find ESTABLISHED conn, save RCV_NXT */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ledb_find:
    cbz     w3, .Lfail_tcp_edb
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Ledb_found
    add     x0, x0, #TCONN_SIZE
    b       .Ledb_find
.Ledb_found:
    mov     x21, x0
    ldr     w22, [x21, #TCONN_RCV_NXT]

    /* Send data with bad SEQ (100 instead of 2) */
    ldr     x0, =tcp_data_badseq_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle

    /* Verify return = 0 (drop) */
    cbnz    w0, .Lfail_tcp_edb

    /* Verify RCV_NXT unchanged */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, w22
    b.ne    .Lfail_tcp_edb

    ldr     x0, =name_tcp_edb
    bl      test_pass
    b       .Ldone_tcp_edb
.Lfail_tcp_edb:
    ldr     x0, =name_tcp_edb
    bl      test_fail
.Ldone_tcp_edb:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_estab_fin — FIN+ACK to ESTABLISHED → ACK reply, CLOSE_WAIT
 * ======================================================================== */
test_tcp_estab_fin:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_ef

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_ef

    /* Find ESTABLISHED conn */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lef_find:
    cbz     w3, .Lfail_tcp_ef
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lef_found
    add     x0, x0, #TCONN_SIZE
    b       .Lef_find
.Lef_found:
    mov     x21, x0

    /* Send FIN+ACK: SEQ=2 (matches RCV_NXT), ACK=ISN+1 */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify return = 54 (ACK reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_ef

    /* Verify state = CLOSE_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSE_WAIT
    b.ne    .Lfail_tcp_ef

    ldr     x0, =name_tcp_ef
    bl      test_pass
    b       .Ldone_tcp_ef
.Lfail_tcp_ef:
    ldr     x0, =name_tcp_ef
    bl      test_fail
.Ldone_tcp_ef:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_close_wait_rst — RST to CLOSE_WAIT → CLOSED
 * ======================================================================== */
test_tcp_close_wait_rst:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_cwr

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_cwr

    /* Find ESTABLISHED, save conn ptr */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lcwr_find_e:
    cbz     w3, .Lfail_tcp_cwr
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lcwr_found_e
    add     x0, x0, #TCONN_SIZE
    b       .Lcwr_find_e
.Lcwr_found_e:
    mov     x21, x0

    /* Send FIN+ACK → CLOSE_WAIT */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Send RST to CLOSE_WAIT conn */
    ldr     x0, =tcp_rst_from_peer_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Verify state = CLOSED */
    ldrb    w0, [x21, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_cwr     /* CLOSED = 0 */

    ldr     x0, =name_tcp_cwr
    bl      test_pass
    b       .Ldone_tcp_cwr
.Lfail_tcp_cwr:
    ldr     x0, =name_tcp_cwr
    bl      test_fail
.Ldone_tcp_cwr:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_estab_data_multi — Two data segments, verify RCV_NXT
 * ======================================================================== */
test_tcp_estab_data_multi:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_edm

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_edm

    /* Find ESTABLISHED conn */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ledm_find:
    cbz     w3, .Lfail_tcp_edm
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Ledm_found
    add     x0, x0, #TCONN_SIZE
    b       .Ledm_find
.Ledm_found:
    mov     x21, x0

    /* Data segment 1: SEQ=2, 5 bytes */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_edm

    /* Verify RCV_NXT = 2 + 5 = 7 */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, #7
    b.ne    .Lfail_tcp_edm

    /* Data segment 2: SEQ=7, 5 bytes */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    /* Fix SEQ to 7 (NBO) */
    mov     w0, #7
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    /* Fix ACK = ISN+1 */
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_edm

    /* Verify RCV_NXT = 7 + 5 = 12 */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, #12
    b.ne    .Lfail_tcp_edm

    ldr     x0, =name_tcp_edm
    bl      test_pass
    b       .Ldone_tcp_edm
.Lfail_tcp_edm:
    ldr     x0, =name_tcp_edm
    bl      test_fail
.Ldone_tcp_edm:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_fsa_null_handler — FSA dispatch with NULL handler entry → RST
 *
 * Handshake → ESTABLISHED, overwrite state to LAST_ACK (state 5).
 * Send matching SYNACK → exact match → FSA lookup → handler=0 →
 * cbz x16 taken → .Ltcp_no_conn → RST.
 * ======================================================================== */
test_tcp_fsa_null_handler:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_fnh

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_fnh

    /* Find ESTABLISHED slot, overwrite state to LAST_ACK */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lfnh_find:
    cbz     w3, .Lfail_tcp_fnh
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lfnh_found
    add     x0, x0, #TCONN_SIZE
    b       .Lfnh_find
.Lfnh_found:
    mov     w1, #TCPS_LAST_ACK
    strb    w1, [x0, #TCONN_STATE]

    /* Send matching SYNACK → exact match → LAST_ACK+SYNACK → NULL handler → RST */
    ldr     x0, =tcp_synack_to80_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Should get RST (return 54). Incoming had ACK → RST only (SEQ=SEG.ACK) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_fnh

    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_RST
    b.ne    .Lfail_tcp_fnh

    ldr     x0, =name_tcp_fnh
    bl      test_pass
    b       .Ldone_tcp_fnh
.Lfail_tcp_fnh:
    ldr     x0, =name_tcp_fnh
    bl      test_fail
.Ldone_tcp_fnh:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_scan_lport_miss — Exact-match scan lport mismatch → skip entry
 *
 * Handshake → SYN_RCVD, change SYN_RCVD slot's lport to 8080.
 * Send SYN to port 80 → scan hits SYN_RCVD (not LISTEN, not CLOSED) →
 * lport=8080 ≠ dport=80 → scan_next. LISTEN fallback → SYN-ACK (new conn).
 * ======================================================================== */
test_tcp_scan_lport_miss:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* SYN → SYN-ACK (creates SYN_RCVD in slot 1) */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_slm

    /* Find SYN_RCVD slot and change lport to 8080 (NBO = 0x901F) */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lslm_find:
    cbz     w3, .Lfail_tcp_slm
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.eq    .Lslm_found
    add     x0, x0, #TCONN_SIZE
    b       .Lslm_find
.Lslm_found:
    mov     x19, x0                 /* save SYN_RCVD slot ptr */
    mov     w1, #0x901F             /* 8080 NBO as LE halfword */
    strh    w1, [x0, #TCONN_LPORT]

    /* Send another SYN to port 80 — should skip the SYN_RCVD entry
     * (lport mismatch), use LISTEN fallback, allocate a new SYN_RCVD */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Should get SYN-ACK (return 54) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_slm

    /* Verify the original SYN_RCVD slot is untouched (still SYN_RCVD, lport=8080) */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_SYN_RCVD
    b.ne    .Lfail_tcp_slm
    ldrh    w0, [x19, #TCONN_LPORT]
    mov     w1, #0x901F
    cmp     w0, w1
    b.ne    .Lfail_tcp_slm

    ldr     x0, =name_tcp_slm
    bl      test_pass
    b       .Ldone_tcp_slm
.Lfail_tcp_slm:
    ldr     x0, =name_tcp_slm
    bl      test_fail
.Ldone_tcp_slm:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_close_estab — tcp_close from ESTABLISHED → FIN_WAIT_1
 * ======================================================================== */
test_tcp_close_estab:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_ce

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20                /* w20 = ISN (host order) */

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_ce

    /* Find ESTABLISHED conn */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lce_find:
    cbz     w3, .Lfail_tcp_ce
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lce_found
    add     x0, x0, #TCONN_SIZE
    b       .Lce_find
.Lce_found:
    mov     x21, x0
    ldr     w22, [x21, #TCONN_SND_NXT]  /* save SND_NXT before close */

    /* Call tcp_close */
    mov     x0, x21
    ldr     x1, =tcp_test_buf2
    bl      tcp_close

    /* Verify return = 54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_ce

    /* Verify flags = FIN+ACK (0x11) */
    ldr     x0, =tcp_test_buf2
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_FIN_ACK
    b.ne    .Lfail_tcp_ce

    /* Verify state = FIN_WAIT_1 */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_FIN_WAIT_1
    b.ne    .Lfail_tcp_ce

    /* Verify SND_NXT = old + 1 */
    ldr     w0, [x21, #TCONN_SND_NXT]
    add     w1, w22, #1
    cmp     w0, w1
    b.ne    .Lfail_tcp_ce

    ldr     x0, =name_tcp_ce
    bl      test_pass
    b       .Ldone_tcp_ce
.Lfail_tcp_ce:
    ldr     x0, =name_tcp_ce
    bl      test_fail
.Ldone_tcp_ce:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_close_closewait — tcp_close from CLOSE_WAIT → LAST_ACK
 * ======================================================================== */
test_tcp_close_closewait:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_ccw

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_ccw

    /* Find ESTABLISHED conn */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lccw_find:
    cbz     w3, .Lfail_tcp_ccw
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lccw_found
    add     x0, x0, #TCONN_SIZE
    b       .Lccw_find
.Lccw_found:
    mov     x21, x0

    /* Send FIN+ACK → CLOSE_WAIT */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_ccw

    /* Verify CLOSE_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSE_WAIT
    b.ne    .Lfail_tcp_ccw

    /* Save SND_NXT before close */
    ldr     w22, [x21, #TCONN_SND_NXT]

    /* Call tcp_close from CLOSE_WAIT */
    mov     x0, x21
    ldr     x1, =tcp_test_buf2
    bl      tcp_close

    /* Verify return = 54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_ccw

    /* Verify flags = FIN+ACK */
    ldr     x0, =tcp_test_buf2
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_FIN_ACK
    b.ne    .Lfail_tcp_ccw

    /* Verify state = LAST_ACK */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_LAST_ACK
    b.ne    .Lfail_tcp_ccw

    /* Verify SND_NXT = old + 1 */
    ldr     w0, [x21, #TCONN_SND_NXT]
    add     w1, w22, #1
    cmp     w0, w1
    b.ne    .Lfail_tcp_ccw

    ldr     x0, =name_tcp_ccw
    bl      test_pass
    b       .Ldone_tcp_ccw
.Lfail_tcp_ccw:
    ldr     x0, =name_tcp_ccw
    bl      test_fail
.Ldone_tcp_ccw:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_close_invalid — tcp_close from LISTEN → returns 0, no change
 * ======================================================================== */
test_tcp_close_invalid:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Attempt close on LISTEN slot */
    ldr     x0, =tcp_conn_table
    ldr     x1, =tcp_test_buf
    bl      tcp_close

    /* Verify return = 0 */
    cbnz    w0, .Lfail_tcp_ci

    /* Verify state unchanged (LISTEN) */
    ldr     x0, =tcp_conn_table
    ldrb    w0, [x0, #TCONN_STATE]
    cmp     w0, #TCPS_LISTEN
    b.ne    .Lfail_tcp_ci

    ldr     x0, =name_tcp_ci
    bl      test_pass
    b       .Ldone_tcp_ci
.Lfail_tcp_ci:
    ldr     x0, =name_tcp_ci
    bl      test_fail
.Ldone_tcp_ci:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_finwait1_ack — FIN_WAIT_1 + ACK → FIN_WAIT_2
 * ======================================================================== */
test_tcp_finwait1_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_fw1a

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_fw1a

    /* Find ESTABLISHED, set FIN_WAIT_1, SND_NXT += 1 (simulates our FIN) */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lfw1a_find:
    cbz     w3, .Lfail_tcp_fw1a
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lfw1a_found
    add     x0, x0, #TCONN_SIZE
    b       .Lfw1a_find
.Lfw1a_found:
    mov     x21, x0
    mov     w1, #TCPS_FIN_WAIT_1
    strb    w1, [x21, #TCONN_STATE]
    ldr     w22, [x21, #TCONN_SND_NXT]
    add     w22, w22, #1
    str     w22, [x21, #TCONN_SND_NXT]  /* SND_NXT = ISN + 2 */

    /* Send ACK with ACK# = SND_NXT */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    rev     w0, w22
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ret = 0 (no reply) */
    cbnz    w0, .Lfail_tcp_fw1a

    /* Verify state = FIN_WAIT_2 */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_FIN_WAIT_2
    b.ne    .Lfail_tcp_fw1a

    ldr     x0, =name_tcp_fw1a
    bl      test_pass
    b       .Ldone_tcp_fw1a
.Lfail_tcp_fw1a:
    ldr     x0, =name_tcp_fw1a
    bl      test_fail
.Ldone_tcp_fw1a:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_finwait1_fin — FIN_WAIT_1 + FIN → CLOSING (simultaneous close)
 * ======================================================================== */
test_tcp_finwait1_fin:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_fw1f

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_fw1f

    /* Find ESTABLISHED, set FIN_WAIT_1 */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lfw1f_find:
    cbz     w3, .Lfail_tcp_fw1f
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lfw1f_found
    add     x0, x0, #TCONN_SIZE
    b       .Lfw1f_find
.Lfw1f_found:
    mov     x21, x0
    mov     w1, #TCPS_FIN_WAIT_1
    strb    w1, [x21, #TCONN_STATE]
    ldr     w22, [x21, #TCONN_RCV_NXT]  /* save RCV_NXT */

    /* Send FIN+ACK */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ret = 54 (ACK reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_fw1f

    /* Verify state = CLOSING */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSING
    b.ne    .Lfail_tcp_fw1f

    /* Verify RCV_NXT += 1 */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    add     w1, w22, #1
    cmp     w0, w1
    b.ne    .Lfail_tcp_fw1f

    ldr     x0, =name_tcp_fw1f
    bl      test_pass
    b       .Ldone_tcp_fw1f
.Lfail_tcp_fw1f:
    ldr     x0, =name_tcp_fw1f
    bl      test_fail
.Ldone_tcp_fw1f:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_finwait2_fin — FIN_WAIT_2 + FIN → TIME_WAIT, timer armed
 * ======================================================================== */
test_tcp_finwait2_fin:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Init test timer pool */
    ldr     x0, =test_tcp_timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init
    ldr     x0, =test_tcp_timer_pool
    bl      tcp_set_timer_pool

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_fw2f

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_fw2f

    /* Find ESTABLISHED, set FIN_WAIT_2 */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lfw2f_find:
    cbz     w3, .Lfail_tcp_fw2f
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lfw2f_found
    add     x0, x0, #TCONN_SIZE
    b       .Lfw2f_find
.Lfw2f_found:
    mov     x21, x0
    mov     w1, #TCPS_FIN_WAIT_2
    strb    w1, [x21, #TCONN_STATE]

    /* Send FIN+ACK */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ret = 54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_fw2f

    /* Verify state = TIME_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_TIME_WAIT
    b.ne    .Lfail_tcp_fw2f

    /* Verify timer armed (TIMER_SLOT != -1) */
    ldr     w0, [x21, #TCONN_TIMER_SLOT]
    cmn     w0, #1
    b.eq    .Lfail_tcp_fw2f

    ldr     x0, =name_tcp_fw2f
    bl      test_pass
    b       .Ldone_tcp_fw2f
.Lfail_tcp_fw2f:
    ldr     x0, =name_tcp_fw2f
    bl      test_fail
.Ldone_tcp_fw2f:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_closing_ack — CLOSING + ACK → TIME_WAIT, timer armed
 * ======================================================================== */
test_tcp_closing_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Init test timer pool */
    ldr     x0, =test_tcp_timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init
    ldr     x0, =test_tcp_timer_pool
    bl      tcp_set_timer_pool

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_cla

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_cla

    /* Find ESTABLISHED, set CLOSING, SND_NXT += 1 */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lcla_find:
    cbz     w3, .Lfail_tcp_cla
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lcla_found
    add     x0, x0, #TCONN_SIZE
    b       .Lcla_find
.Lcla_found:
    mov     x21, x0
    mov     w1, #TCPS_CLOSING
    strb    w1, [x21, #TCONN_STATE]
    ldr     w22, [x21, #TCONN_SND_NXT]
    add     w22, w22, #1
    str     w22, [x21, #TCONN_SND_NXT]

    /* Send ACK with ACK# = SND_NXT */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    rev     w0, w22
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ret = 0 */
    cbnz    w0, .Lfail_tcp_cla

    /* Verify state = TIME_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_TIME_WAIT
    b.ne    .Lfail_tcp_cla

    /* Verify timer armed */
    ldr     w0, [x21, #TCONN_TIMER_SLOT]
    cmn     w0, #1
    b.eq    .Lfail_tcp_cla

    ldr     x0, =name_tcp_cla
    bl      test_pass
    b       .Ldone_tcp_cla
.Lfail_tcp_cla:
    ldr     x0, =name_tcp_cla
    bl      test_fail
.Ldone_tcp_cla:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_lastack_ack — LAST_ACK + ACK → CLOSED
 * ======================================================================== */
test_tcp_lastack_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_laa

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_laa

    /* Find ESTABLISHED, set LAST_ACK, SND_NXT += 1 */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Llaa_find:
    cbz     w3, .Lfail_tcp_laa
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Llaa_found
    add     x0, x0, #TCONN_SIZE
    b       .Llaa_find
.Llaa_found:
    mov     x21, x0
    mov     w1, #TCPS_LAST_ACK
    strb    w1, [x21, #TCONN_STATE]
    ldr     w22, [x21, #TCONN_SND_NXT]
    add     w22, w22, #1
    str     w22, [x21, #TCONN_SND_NXT]

    /* Send ACK with ACK# = SND_NXT */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    rev     w0, w22
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ret = 0 */
    cbnz    w0, .Lfail_tcp_laa

    /* Verify state = CLOSED */
    ldrb    w0, [x21, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_laa

    ldr     x0, =name_tcp_laa
    bl      test_pass
    b       .Ldone_tcp_laa
.Lfail_tcp_laa:
    ldr     x0, =name_tcp_laa
    bl      test_fail
.Ldone_tcp_laa:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_timewait_rst — RST to TIME_WAIT → CLOSED
 * ======================================================================== */
test_tcp_timewait_rst:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_twr

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_twr

    /* Find ESTABLISHED, set TIME_WAIT */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ltwr_find:
    cbz     w3, .Lfail_tcp_twr
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Ltwr_found
    add     x0, x0, #TCONN_SIZE
    b       .Ltwr_find
.Ltwr_found:
    mov     x19, x0
    mov     w1, #TCPS_TIME_WAIT
    strb    w1, [x19, #TCONN_STATE]

    /* Send RST */
    ldr     x0, =tcp_rst_from_peer_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Verify state = CLOSED */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_twr

    ldr     x0, =name_tcp_twr
    bl      test_pass
    b       .Ldone_tcp_twr
.Lfail_tcp_twr:
    ldr     x0, =name_tcp_twr
    bl      test_fail
.Ldone_tcp_twr:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_timewait_timeout — TIME_WAIT timer expiry → CLOSED
 * ======================================================================== */
test_tcp_timewait_timeout:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Init test timer pool */
    ldr     x0, =test_tcp_timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init
    ldr     x0, =test_tcp_timer_pool
    bl      tcp_set_timer_pool

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_twto

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_twto

    /* Find ESTABLISHED, set TIME_WAIT */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ltwto_find:
    cbz     w3, .Lfail_tcp_twto
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Ltwto_found
    add     x0, x0, #TCONN_SIZE
    b       .Ltwto_find
.Ltwto_found:
    mov     x19, x0
    mov     w1, #TCPS_TIME_WAIT
    strb    w1, [x19, #TCONN_STATE]

    /* Arm timer with expiry=0 (already expired) */
    ldr     x0, =test_tcp_timer_pool
    mov     x1, #0                      /* expiry = 0 */
    ldr     x2, =tcp_timewait_cb        /* callback */
    mov     x3, x19                     /* context = conn ptr */
    bl      timer_set
    str     w0, [x19, #TCONN_TIMER_SLOT]

    /* Fire timer: timer_check(pool, tick=1) */
    ldr     x0, =test_tcp_timer_pool
    mov     x1, #1                      /* current tick */
    bl      timer_check

    /* Verify state = CLOSED */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_twto

    /* Verify TIMER_SLOT = -1 */
    ldr     w0, [x19, #TCONN_TIMER_SLOT]
    cmn     w0, #1
    b.ne    .Lfail_tcp_twto

    ldr     x0, =name_tcp_twto
    bl      test_pass
    b       .Ldone_tcp_twto
.Lfail_tcp_twto:
    ldr     x0, =name_tcp_twto
    bl      test_fail
.Ldone_tcp_twto:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_lastack_ack_bad — LAST_ACK + ACK with wrong ACK# → stays LAST_ACK, RST
 * ======================================================================== */
test_tcp_lastack_ack_bad:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_laab

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_laab

    /* Find ESTABLISHED, set LAST_ACK, SND_NXT += 1 */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Llaab_find:
    cbz     w3, .Lfail_tcp_laab
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Llaab_found
    add     x0, x0, #TCONN_SIZE
    b       .Llaab_find
.Llaab_found:
    mov     x21, x0
    mov     w1, #TCPS_LAST_ACK
    strb    w1, [x21, #TCONN_STATE]
    ldr     w22, [x21, #TCONN_SND_NXT]
    add     w22, w22, #1
    str     w22, [x21, #TCONN_SND_NXT]

    /* Send ACK with wrong ACK# = SND_NXT + 1 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w22, #1          /* wrong: SND_NXT + 1 */
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ret = 54 (RST reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_laab

    /* Verify state restored to LAST_ACK */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_LAST_ACK
    b.ne    .Lfail_tcp_laab

    /* Verify reply flags = RST (0x04) */
    ldr     x19, =tcp_test_buf
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_RST
    b.ne    .Lfail_tcp_laab

    ldr     x0, =name_tcp_laab
    bl      test_pass
    b       .Ldone_tcp_laab
.Lfail_tcp_laab:
    ldr     x0, =name_tcp_laab
    bl      test_fail
.Ldone_tcp_laab:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_finwait1_ack_bad — FIN_WAIT_1 + ACK with wrong ACK# → stays FIN_WAIT_1, RST
 * ======================================================================== */
test_tcp_finwait1_ack_bad:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_fw1ab

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_fw1ab

    /* Find ESTABLISHED, set FIN_WAIT_1, SND_NXT += 1 */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lfw1ab_find:
    cbz     w3, .Lfail_tcp_fw1ab
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lfw1ab_found
    add     x0, x0, #TCONN_SIZE
    b       .Lfw1ab_find
.Lfw1ab_found:
    mov     x21, x0
    mov     w1, #TCPS_FIN_WAIT_1
    strb    w1, [x21, #TCONN_STATE]
    ldr     w22, [x21, #TCONN_SND_NXT]
    add     w22, w22, #1
    str     w22, [x21, #TCONN_SND_NXT]

    /* Send ACK with wrong ACK# = SND_NXT + 1 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w22, #1          /* wrong: SND_NXT + 1 */
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ret = 54 (RST reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_fw1ab

    /* Verify state restored to FIN_WAIT_1 */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_FIN_WAIT_1
    b.ne    .Lfail_tcp_fw1ab

    /* Verify reply flags = RST (0x04) */
    ldr     x19, =tcp_test_buf
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_RST
    b.ne    .Lfail_tcp_fw1ab

    ldr     x0, =name_tcp_fw1ab
    bl      test_pass
    b       .Ldone_tcp_fw1ab
.Lfail_tcp_fw1ab:
    ldr     x0, =name_tcp_fw1ab
    bl      test_fail
.Ldone_tcp_fw1ab:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_closing_ack_bad — CLOSING + ACK with wrong ACK# → stays CLOSING, RST
 * ======================================================================== */
test_tcp_closing_ack_bad:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_clab

    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_clab

    /* Find ESTABLISHED, set CLOSING, SND_NXT += 1 */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lclab_find:
    cbz     w3, .Lfail_tcp_clab
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lclab_found
    add     x0, x0, #TCONN_SIZE
    b       .Lclab_find
.Lclab_found:
    mov     x21, x0
    mov     w1, #TCPS_CLOSING
    strb    w1, [x21, #TCONN_STATE]
    ldr     w22, [x21, #TCONN_SND_NXT]
    add     w22, w22, #1
    str     w22, [x21, #TCONN_SND_NXT]

    /* Send ACK with wrong ACK# = SND_NXT + 1 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w22, #1          /* wrong: SND_NXT + 1 */
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ret = 54 (RST reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_clab

    /* Verify state restored to CLOSING */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSING
    b.ne    .Lfail_tcp_clab

    /* Verify reply flags = RST (0x04) */
    ldr     x19, =tcp_test_buf
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_RST
    b.ne    .Lfail_tcp_clab

    ldr     x0, =name_tcp_clab
    bl      test_pass
    b       .Ldone_tcp_clab
.Lfail_tcp_clab:
    ldr     x0, =name_tcp_clab
    bl      test_fail
.Ldone_tcp_clab:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * Helper: ttcp_do_handshake — tcp_init + full three-way handshake
 *
 * Returns: x0 = ESTABLISHED connection pointer, w1 = ISN (host order)
 *          or x0 = 0 on failure
 * Uses: tcp_test_buf, tcp_test_buf2
 * Clobbers: x0-x6, x19-x22, x30
 * ======================================================================== */
ttcp_do_handshake:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Step 1: SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lths_fail

    /* Extract ISN from SYN-ACK SEQ field */
    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20                /* w20 = ISN (host order) */

    /* Step 2: ACK → ESTABLISHED */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf2
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf2
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lths_fail

    /* Find ESTABLISHED connection */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lths_find:
    cbz     w3, .Lths_fail
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_ESTABLISHED
    b.eq    .Lths_found
    add     x0, x0, #TCONN_SIZE
    b       .Lths_find

.Lths_found:
    mov     w1, w20
    b       .Lths_done
.Lths_fail:
    mov     x0, #0
    mov     w1, #0
.Lths_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * Helper: ttcp_build_data_frame — Build a data frame with arbitrary payload
 *
 * x0: dest buffer
 * w1: payload length (1..1460)
 * w2: payload fill byte (e.g. 'A')
 * w3: SEQ number (host order)
 * w4: ACK number (host order)
 * Returns: w0 = frame length (54 + payload_len)
 * Clobbers: x0-x6, x19-x24, x30
 * ======================================================================== */
ttcp_build_data_frame:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* dest buf */
    mov     w20, w1                 /* payload len */
    mov     w21, w2                 /* fill byte */
    mov     w22, w3                 /* SEQ host */
    mov     w23, w4                 /* ACK host */

    /* Copy 54-byte template */
    ldr     x0, =tcp_handshake_ack_template
    mov     x1, x19
    mov     w2, #54
.Ltbdf_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Ltbdf_copy

    /* Set flags = PSH+ACK */
    mov     w0, #TCP_PSH_ACK
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]

    /* Set SEQ = rev(seq_host) */
    rev     w0, w22
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]

    /* Set ACK = rev(ack_host) */
    rev     w0, w23
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* IP TotalLength = 40 + payload_len (NBO) */
    add     w0, w20, #40
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Fill payload at offset 54 */
    add     x0, x19, #54
    mov     w1, w20
.Ltbdf_fill:
    cbz     w1, .Ltbdf_fill_done
    strb    w21, [x0], #1
    sub     w1, w1, #1
    b       .Ltbdf_fill
.Ltbdf_fill_done:

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    add     w1, w20, #TCP_HDR_MIN
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Return 54 + payload_len */
    add     w0, w20, #54

    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rx_buffer — Receive 5 bytes, peek returns "Hello"
 * ======================================================================== */
test_tcp_rx_buffer:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rxb
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Send data: 5 bytes "Hello" */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_rxb

    /* tcp_rx_peek */
    mov     x0, x21
    bl      tcp_rx_peek
    /* x0 = buf ptr, w1 = byte count */
    cmp     w1, #5
    b.ne    .Lfail_tcp_rxb

    /* Verify bytes = "Hello" */
    ldrb    w2, [x0]
    cmp     w2, #0x48               /* 'H' */
    b.ne    .Lfail_tcp_rxb
    ldrb    w2, [x0, #1]
    cmp     w2, #0x65               /* 'e' */
    b.ne    .Lfail_tcp_rxb
    ldrb    w2, [x0, #2]
    cmp     w2, #0x6C               /* 'l' */
    b.ne    .Lfail_tcp_rxb
    ldrb    w2, [x0, #3]
    cmp     w2, #0x6C               /* 'l' */
    b.ne    .Lfail_tcp_rxb
    ldrb    w2, [x0, #4]
    cmp     w2, #0x6F               /* 'o' */
    b.ne    .Lfail_tcp_rxb

    ldr     x0, =name_tcp_rxb
    bl      test_pass
    b       .Ldone_tcp_rxb
.Lfail_tcp_rxb:
    ldr     x0, =name_tcp_rxb
    bl      test_fail
.Ldone_tcp_rxb:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_rx_buffer_multi — Two 5-byte segments, peek returns 10 bytes
 * ======================================================================== */
test_tcp_rx_buffer_multi:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rxm
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Send first data: 5 bytes "Hello", SEQ=2 */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_rxm

    /* Send second data: 5 bytes "Hello", SEQ=7 (2+5) */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    /* SEQ = 7 (host order) */
    mov     w0, #7
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    /* ACK = ISN+1 */
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_rxm

    /* tcp_rx_peek */
    mov     x0, x21
    bl      tcp_rx_peek
    cmp     w1, #10
    b.ne    .Lfail_tcp_rxm

    /* First 5 bytes = "Hello" */
    ldrb    w2, [x0]
    cmp     w2, #0x48
    b.ne    .Lfail_tcp_rxm
    ldrb    w2, [x0, #4]
    cmp     w2, #0x6F
    b.ne    .Lfail_tcp_rxm
    /* Second 5 bytes also = "Hello" */
    ldrb    w2, [x0, #5]
    cmp     w2, #0x48
    b.ne    .Lfail_tcp_rxm
    ldrb    w2, [x0, #9]
    cmp     w2, #0x6F
    b.ne    .Lfail_tcp_rxm

    ldr     x0, =name_tcp_rxm
    bl      test_pass
    b       .Ldone_tcp_rxm
.Lfail_tcp_rxm:
    ldr     x0, =name_tcp_rxm
    bl      test_fail
.Ldone_tcp_rxm:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_rx_flush — Send data, flush, peek returns 0
 * ======================================================================== */
test_tcp_rx_flush:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rxfl
    mov     x21, x0
    mov     w22, w1

    /* Send data: 5 bytes */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_rxfl

    /* Flush */
    mov     x0, x21
    bl      tcp_rx_flush

    /* Peek — should return 0 bytes */
    mov     x0, x21
    bl      tcp_rx_peek
    cbnz    w1, .Lfail_tcp_rxfl

    ldr     x0, =name_tcp_rxfl
    bl      test_pass
    b       .Ldone_tcp_rxfl
.Lfail_tcp_rxfl:
    ldr     x0, =name_tcp_rxfl
    bl      test_fail
.Ldone_tcp_rxfl:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_rx_overflow — Pre-set RXLEN=2045, send 5 bytes → drop
 * ======================================================================== */
test_tcp_rx_overflow:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rxov
    mov     x21, x0
    mov     w22, w1

    /* Pre-set RXLEN = 2045 (overflow: 2045 + 5 = 2050 > 2048) */
    mov     w0, #2045
    strh    w0, [x21, #TCONN_RXLEN]

    /* Save RCV_NXT */
    ldr     w19, [x21, #TCONN_RCV_NXT]

    /* Send data: 5 bytes */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x20, =tcp_test_buf
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x20
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x20
    mov     w1, #59
    bl      tcp_handle

    /* Verify return = 0 (dropped) */
    cbnz    w0, .Lfail_tcp_rxov

    /* Verify RXLEN unchanged = 2045 */
    ldrh    w0, [x21, #TCONN_RXLEN]
    cmp     w0, #2045
    b.ne    .Lfail_tcp_rxov

    /* Verify RCV_NXT unchanged */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, w19
    b.ne    .Lfail_tcp_rxov

    ldr     x0, =name_tcp_rxov
    bl      test_pass
    b       .Ldone_tcp_rxov
.Lfail_tcp_rxov:
    ldr     x0, =name_tcp_rxov
    bl      test_fail
.Ldone_tcp_rxov:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_send — tcp_send 5 bytes, verify frame and SND_NXT
 * ======================================================================== */
test_tcp_send:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_ts
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Save SND_NXT before send */
    ldr     w19, [x21, #TCONN_SND_NXT]

    /* tcp_send(conn, buf, "World", 5) */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send

    /* Verify return = 59 (54 + 5) */
    cmp     w0, #59
    b.ne    .Lfail_tcp_ts

    /* Verify flags = PSH+ACK */
    ldr     x20, =tcp_send_test_buf
    ldrb    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_PSH_ACK
    b.ne    .Lfail_tcp_ts

    /* Verify SND_NXT += 5 */
    ldr     w0, [x21, #TCONN_SND_NXT]
    add     w1, w19, #5
    cmp     w0, w1
    b.ne    .Lfail_tcp_ts

    /* Verify payload at offset 54 = "World" */
    ldrb    w0, [x20, #54]
    cmp     w0, #0x57               /* 'W' */
    b.ne    .Lfail_tcp_ts
    ldrb    w0, [x20, #55]
    cmp     w0, #0x6F               /* 'o' */
    b.ne    .Lfail_tcp_ts
    ldrb    w0, [x20, #56]
    cmp     w0, #0x72               /* 'r' */
    b.ne    .Lfail_tcp_ts
    ldrb    w0, [x20, #57]
    cmp     w0, #0x6C               /* 'l' */
    b.ne    .Lfail_tcp_ts
    ldrb    w0, [x20, #58]
    cmp     w0, #0x64               /* 'd' */
    b.ne    .Lfail_tcp_ts

    ldr     x0, =name_tcp_ts
    bl      test_pass
    b       .Ldone_tcp_ts
.Lfail_tcp_ts:
    ldr     x0, =name_tcp_ts
    bl      test_fail
.Ldone_tcp_ts:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_invalid — tcp_send from CLOSE_WAIT returns 0
 * ======================================================================== */
test_tcp_send_invalid:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tsi
    mov     x21, x0

    /* Force state to CLOSE_WAIT */
    mov     w0, #TCPS_CLOSE_WAIT
    strb    w0, [x21, #TCONN_STATE]

    /* tcp_send should fail */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbnz    w0, .Lfail_tcp_tsi

    ldr     x0, =name_tcp_tsi
    bl      test_pass
    b       .Ldone_tcp_tsi
.Lfail_tcp_tsi:
    ldr     x0, =name_tcp_tsi
    bl      test_fail
.Ldone_tcp_tsi:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_zero_len — tcp_send with payload_len=0 returns 0
 * Covers: cbz w21, .Lts_err (payload_len == 0, ESTABLISHED state)
 * ======================================================================== */
test_tcp_send_zero_len:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tszl
    mov     x21, x0

    /* Save SND_NXT before call */
    ldr     w22, [x21, #TCONN_SND_NXT]

    /* tcp_send with payload_len=0 should fail */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #0
    bl      tcp_send
    cbnz    w0, .Lfail_tcp_tszl

    /* SND_NXT must be unchanged */
    ldr     w0, [x21, #TCONN_SND_NXT]
    cmp     w0, w22
    b.ne    .Lfail_tcp_tszl

    ldr     x0, =name_tcp_tszl
    bl      test_pass
    b       .Ldone_tcp_tszl
.Lfail_tcp_tszl:
    ldr     x0, =name_tcp_tszl
    bl      test_fail
.Ldone_tcp_tszl:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_oversize — tcp_send with payload_len=1461 returns 0
 * Covers: b.hi .Lts_err (payload_len > 1460, ESTABLISHED state)
 * ======================================================================== */
test_tcp_send_oversize:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tsos
    mov     x21, x0

    /* Save SND_NXT before call */
    ldr     w22, [x21, #TCONN_SND_NXT]

    /* tcp_send with payload_len=1461 should fail */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #1461
    bl      tcp_send
    cbnz    w0, .Lfail_tcp_tsos

    /* SND_NXT must be unchanged */
    ldr     w0, [x21, #TCONN_SND_NXT]
    cmp     w0, w22
    b.ne    .Lfail_tcp_tsos

    ldr     x0, =name_tcp_tsos
    bl      test_pass
    b       .Ldone_tcp_tsos
.Lfail_tcp_tsos:
    ldr     x0, =name_tcp_tsos
    bl      test_fail
.Ldone_tcp_tsos:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_window_tracks_fill (S1) — Window shrinks as buffer fills
 * Handshake → send 100 bytes → verify ACK window = (2048-100) NBO
 * → send 200 bytes → verify ACK window = (2048-300) NBO
 * ======================================================================== */
test_tcp_window_tracks_fill:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_wtf
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Send 100-byte data, SEQ=2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #100
    mov     w2, #0x41               /* 'A' */
    mov     w3, #2                  /* SEQ */
    add     w4, w22, #1             /* ACK = ISN+1 */
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #154                /* 54 + 100 */
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_wtf

    /* Check window in reply: should be (2048-100)=1948 NBO */
    ldr     x0, =tcp_test_buf3
    ldrh    w0, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    mov     w1, #1948
    rev16   w1, w1
    uxth    w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_wtf

    /* Send 200-byte data, SEQ=102 (2+100) */
    ldr     x0, =tcp_test_buf3
    mov     w1, #200
    mov     w2, #0x42               /* 'B' */
    mov     w3, #102                /* SEQ = 2+100 */
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #254                /* 54 + 200 */
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_wtf

    /* Check window: should be (2048-300)=1748 NBO */
    ldr     x0, =tcp_test_buf3
    ldrh    w0, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    mov     w1, #1748
    rev16   w1, w1
    uxth    w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_wtf

    ldr     x0, =name_tcp_wtf
    bl      test_pass
    b       .Ldone_tcp_wtf
.Lfail_tcp_wtf:
    ldr     x0, =name_tcp_wtf
    bl      test_fail
.Ldone_tcp_wtf:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_window_after_flush (S2) — Flush restores window space
 * Handshake → send 100 bytes → flush → send 50 bytes
 * → verify ACK window = (2048-50) NBO
 * ======================================================================== */
test_tcp_window_after_flush:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_waf
    mov     x21, x0
    mov     w22, w1

    /* Send 100-byte data, SEQ=2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #100
    mov     w2, #0x41
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #154
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_waf

    /* Flush */
    mov     x0, x21
    bl      tcp_rx_flush

    /* Send 50-byte data, SEQ=102 (RCV_NXT after 100 bytes) */
    ldr     x0, =tcp_test_buf3
    mov     w1, #50
    mov     w2, #0x43               /* 'C' */
    mov     w3, #102
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #104                /* 54 + 50 */
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_waf

    /* Check window: should be (2048-50)=1998 NBO */
    ldr     x0, =tcp_test_buf3
    ldrh    w0, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    mov     w1, #1998
    rev16   w1, w1
    uxth    w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_waf

    ldr     x0, =name_tcp_waf
    bl      test_pass
    b       .Ldone_tcp_waf
.Lfail_tcp_waf:
    ldr     x0, =name_tcp_waf
    bl      test_fail
.Ldone_tcp_waf:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_window_zero (S3) — Buffer full → window = 0
 * Handshake → pre-set RXLEN=2043 → send 5 bytes → window = 0 NBO
 * ======================================================================== */
test_tcp_window_zero:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_wz
    mov     x21, x0
    mov     w22, w1

    /* Pre-set RXLEN=2043 (2043+5=2048 exactly) */
    mov     w0, #2043
    strh    w0, [x21, #TCONN_RXLEN]

    /* Send 5-byte data, SEQ=2 */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_wz

    /* Check window = 0 in reply */
    ldr     x0, =tcp_test_buf
    ldrh    w0, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    cbnz    w0, .Lfail_tcp_wz

    ldr     x0, =name_tcp_wz
    bl      test_pass
    b       .Ldone_tcp_wz
.Lfail_tcp_wz:
    ldr     x0, =name_tcp_wz
    bl      test_fail
.Ldone_tcp_wz:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_buffer_contents (S4) — "AAAA" + "BBBB" → peek = "AAAABBBB"
 * ======================================================================== */
test_tcp_buffer_contents:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_bc
    mov     x21, x0
    mov     w22, w1

    /* Send "AAAA" (4 bytes), SEQ=2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #4
    mov     w2, #0x41               /* 'A' */
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #58                 /* 54 + 4 */
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_bc

    /* Send "BBBB" (4 bytes), SEQ=6 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #4
    mov     w2, #0x42               /* 'B' */
    mov     w3, #6                  /* 2+4 */
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #58
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_bc

    /* Peek and verify 8 bytes = "AAAABBBB" */
    mov     x0, x21
    bl      tcp_rx_peek
    cmp     w1, #8
    b.ne    .Lfail_tcp_bc
    mov     x19, x0

    ldrb    w0, [x19]
    cmp     w0, #0x41
    b.ne    .Lfail_tcp_bc
    ldrb    w0, [x19, #1]
    cmp     w0, #0x41
    b.ne    .Lfail_tcp_bc
    ldrb    w0, [x19, #2]
    cmp     w0, #0x41
    b.ne    .Lfail_tcp_bc
    ldrb    w0, [x19, #3]
    cmp     w0, #0x41
    b.ne    .Lfail_tcp_bc
    ldrb    w0, [x19, #4]
    cmp     w0, #0x42
    b.ne    .Lfail_tcp_bc
    ldrb    w0, [x19, #5]
    cmp     w0, #0x42
    b.ne    .Lfail_tcp_bc
    ldrb    w0, [x19, #6]
    cmp     w0, #0x42
    b.ne    .Lfail_tcp_bc
    ldrb    w0, [x19, #7]
    cmp     w0, #0x42
    b.ne    .Lfail_tcp_bc

    ldr     x0, =name_tcp_bc
    bl      test_pass
    b       .Ldone_tcp_bc
.Lfail_tcp_bc:
    ldr     x0, =name_tcp_bc
    bl      test_fail
.Ldone_tcp_bc:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_buffer_survives_flush (S5) — "AAAA" → flush → "CCCC" → peek = "CCCC"
 * ======================================================================== */
test_tcp_buffer_survives_flush:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_bsf
    mov     x21, x0
    mov     w22, w1

    /* Send "AAAA" (4 bytes), SEQ=2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #4
    mov     w2, #0x41
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #58
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_bsf

    /* Flush */
    mov     x0, x21
    bl      tcp_rx_flush

    /* Send "CCCC" (4 bytes), SEQ=6 (RCV_NXT after "AAAA") */
    ldr     x0, =tcp_test_buf3
    mov     w1, #4
    mov     w2, #0x43               /* 'C' */
    mov     w3, #6
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #58
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_bsf

    /* Peek: should have 4 bytes = "CCCC" */
    mov     x0, x21
    bl      tcp_rx_peek
    cmp     w1, #4
    b.ne    .Lfail_tcp_bsf

    ldrb    w2, [x0]
    cmp     w2, #0x43
    b.ne    .Lfail_tcp_bsf
    ldrb    w2, [x0, #3]
    cmp     w2, #0x43
    b.ne    .Lfail_tcp_bsf

    ldr     x0, =name_tcp_bsf
    bl      test_pass
    b       .Ldone_tcp_bsf
.Lfail_tcp_bsf:
    ldr     x0, =name_tcp_bsf
    bl      test_fail
.Ldone_tcp_bsf:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_send_frame_fields (S6) — Verify tcp_send frame contents in detail
 * Handshake → receive 100 bytes → tcp_send "World" → verify all fields
 * ======================================================================== */
test_tcp_send_frame_fields:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_sff
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Receive 100 bytes to fill buffer (affects window) */
    ldr     x0, =tcp_test_buf3
    mov     w1, #100
    mov     w2, #0x41
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #154
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_sff

    /* Save SND_NXT and RCV_NXT before send */
    ldr     w23, [x21, #TCONN_SND_NXT]
    ldr     w24, [x21, #TCONN_RCV_NXT]

    /* tcp_send "World" */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_sff

    ldr     x19, =tcp_send_test_buf

    /* Verify ETH dst = RMAC (AA:BB:CC:DD:EE:FF) */
    ldrb    w0, [x19, #ETH_DST]
    cmp     w0, #0xAA
    b.ne    .Lfail_tcp_sff
    ldrb    w0, [x19, #(ETH_DST + 5)]
    cmp     w0, #0xFF
    b.ne    .Lfail_tcp_sff

    /* Verify IP totlen = 45 (0x002D NBO) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]
    mov     w1, #45
    rev16   w1, w1
    uxth    w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_sff

    /* Verify TCP sport = 80 (0x0050 NBO) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SPORT)]
    mov     w1, #0x5000             /* port 80 as NBO LE halfword */
    cmp     w0, w1
    b.ne    .Lfail_tcp_sff

    /* Verify TCP dport = 12345 (0x3039 NBO) */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DPORT)]
    /* 12345 = 0x3039, NBO halfword stored as LE = 0x3930 */
    mov     w1, #0x3930
    cmp     w0, w1
    b.ne    .Lfail_tcp_sff

    /* Verify TCP SEQ = rev(SND_NXT before send) */
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w1, w23
    cmp     w0, w1
    b.ne    .Lfail_tcp_sff

    /* Verify TCP ACK = rev(RCV_NXT) */
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w1, w24
    cmp     w0, w1
    b.ne    .Lfail_tcp_sff

    /* Verify flags = PSH+ACK */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_PSH_ACK
    b.ne    .Lfail_tcp_sff

    /* Verify window = (2048-100) = 1948 NBO */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    mov     w1, #1948
    rev16   w1, w1
    uxth    w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_sff

    /* Verify TCP checksum is valid */
    mov     x0, x19
    mov     w1, #25                 /* 20 + 5 */
    bl      tcp_checksum
    cbnz    w0, .Lfail_tcp_sff

    /* Verify payload = "World" */
    ldrb    w0, [x19, #54]
    cmp     w0, #0x57
    b.ne    .Lfail_tcp_sff
    ldrb    w0, [x19, #58]
    cmp     w0, #0x64
    b.ne    .Lfail_tcp_sff

    ldr     x0, =name_tcp_sff
    bl      test_pass
    b       .Ldone_tcp_sff
.Lfail_tcp_sff:
    ldr     x0, =name_tcp_sff
    bl      test_fail
.Ldone_tcp_sff:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* ========================================================================
 * test_tcp_send_rx_independent (S7) — tcp_send doesn't disturb rx buffer
 * Handshake → receive 50 bytes → tcp_send 5 bytes → rx buffer still has 50
 * ======================================================================== */
test_tcp_send_rx_independent:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_sri
    mov     x21, x0
    mov     w22, w1

    /* Receive 50 bytes, SEQ=2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #50
    mov     w2, #0x58               /* 'X' */
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #104                /* 54 + 50 */
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_sri

    /* Save SND_NXT */
    ldr     w19, [x21, #TCONN_SND_NXT]

    /* tcp_send "World" */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_sri

    /* Verify rx buffer still has 50 bytes */
    mov     x0, x21
    bl      tcp_rx_peek
    cmp     w1, #50
    b.ne    .Lfail_tcp_sri

    /* Verify first byte of rx buffer is 'X' */
    ldrb    w2, [x0]
    cmp     w2, #0x58
    b.ne    .Lfail_tcp_sri

    /* Verify SND_NXT advanced by 5 */
    ldr     w0, [x21, #TCONN_SND_NXT]
    add     w1, w19, #5
    cmp     w0, w1
    b.ne    .Lfail_tcp_sri

    ldr     x0, =name_tcp_sri
    bl      test_pass
    b       .Ldone_tcp_sri
.Lfail_tcp_sri:
    ldr     x0, =name_tcp_sri
    bl      test_fail
.Ldone_tcp_sri:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_window_update — Flush rx → window update sends ACK with window=2048
 * ======================================================================== */
test_tcp_window_update:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_twu
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Receive 100 bytes, SEQ=2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #100
    mov     w2, #0x41               /* 'A' */
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #154                /* 54 + 100 */
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_twu

    /* Flush rx buffer */
    mov     x0, x21
    bl      tcp_rx_flush

    /* Call tcp_window_update */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    bl      tcp_window_update

    /* Verify ret=54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_twu

    /* Verify window = 2048 NBO */
    ldr     x19, =tcp_send_test_buf
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    mov     w1, #2048
    rev16   w1, w1
    uxth    w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_twu

    /* Verify flags = ACK */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_ACK_FLAG
    b.ne    .Lfail_tcp_twu

    /* Verify SEQ = rev(SND_NXT) */
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    ldr     w1, [x21, #TCONN_SND_NXT]
    rev     w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_twu

    /* Verify ACK = rev(RCV_NXT) */
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    ldr     w1, [x21, #TCONN_RCV_NXT]
    rev     w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_twu

    /* Verify TCP checksum */
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    cbnz    w0, .Lfail_tcp_twu

    ldr     x0, =name_tcp_twu
    bl      test_pass
    b       .Ldone_tcp_twu
.Lfail_tcp_twu:
    ldr     x0, =name_tcp_twu
    bl      test_fail
.Ldone_tcp_twu:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_window_update_invalid — FIN_WAIT_1 → returns 0
 * ======================================================================== */
test_tcp_window_update_invalid:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_twui
    mov     x21, x0

    /* Force state = FIN_WAIT_1 */
    mov     w0, #TCPS_FIN_WAIT_1
    strb    w0, [x21, #TCONN_STATE]

    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    bl      tcp_window_update
    cbnz    w0, .Lfail_tcp_twui

    ldr     x0, =name_tcp_twui
    bl      test_pass
    b       .Ldone_tcp_twui
.Lfail_tcp_twui:
    ldr     x0, =name_tcp_twui
    bl      test_fail
.Ldone_tcp_twui:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_window_update_closewait — CLOSE_WAIT → returns 54, window=2048
 * ======================================================================== */
test_tcp_window_update_closewait:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_twuc
    mov     x21, x0
    mov     w22, w1                 /* ISN */

    /* Send FIN+ACK to get CLOSE_WAIT */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #54                 /* ACK reply */
    b.ne    .Lfail_tcp_twuc

    /* Verify state = CLOSE_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSE_WAIT
    b.ne    .Lfail_tcp_twuc

    /* Flush rx buffer */
    mov     x0, x21
    bl      tcp_rx_flush

    /* Call tcp_window_update */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    bl      tcp_window_update

    /* Verify ret=54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_twuc

    /* Verify window = 2048 NBO */
    ldr     x19, =tcp_send_test_buf
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    mov     w1, #2048
    rev16   w1, w1
    uxth    w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_twuc

    ldr     x0, =name_tcp_twuc
    bl      test_pass
    b       .Ldone_tcp_twuc
.Lfail_tcp_twuc:
    ldr     x0, =name_tcp_twuc
    bl      test_fail
.Ldone_tcp_twuc:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_snd_wnd_capture — SYN template window=65535 → SND_WND=65535
 * ======================================================================== */
test_tcp_snd_wnd_capture:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_swc
    mov     x21, x0

    ldrh    w0, [x21, #TCONN_SND_WND]
    mov     w1, #0xFFFF
    cmp     w0, w1
    b.ne    .Lfail_tcp_swc

    ldr     x0, =name_tcp_swc
    bl      test_pass
    b       .Ldone_tcp_swc
.Lfail_tcp_swc:
    ldr     x0, =name_tcp_swc
    bl      test_fail
.Ldone_tcp_swc:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_snd_wnd_update — ACK with window=8192 → SND_WND updated
 * ======================================================================== */
test_tcp_snd_wnd_update:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_swu
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Build 5-byte data frame, SEQ=2, ACK=ISN+1 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #5
    mov     w2, #0x41               /* 'A' */
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame

    /* Patch window to 8192 NBO */
    ldr     x19, =tcp_test_buf3
    mov     w0, #8192
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]

    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25                 /* TCP header 20 + 5 bytes data */
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Send the frame */
    mov     x0, x19
    mov     w1, #59                 /* 54 + 5 */
    bl      tcp_handle

    /* Verify SND_WND = 8192 */
    ldrh    w0, [x21, #TCONN_SND_WND]
    mov     w1, #8192
    cmp     w0, w1
    b.ne    .Lfail_tcp_swu

    ldr     x0, =name_tcp_swu
    bl      test_pass
    b       .Ldone_tcp_swu
.Lfail_tcp_swu:
    ldr     x0, =name_tcp_swu
    bl      test_fail
.Ldone_tcp_swu:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_exceeds_window — payload > SND_WND → rejected
 * ======================================================================== */
test_tcp_send_exceeds_window:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_sew
    mov     x21, x0

    /* Set SND_WND=100 */
    mov     w0, #100
    strh    w0, [x21, #TCONN_SND_WND]

    /* Save SND_NXT */
    ldr     w19, [x21, #TCONN_SND_NXT]

    /* tcp_send 200 bytes (exceeds window of 100) */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #200
    bl      tcp_send

    /* Should return 0 */
    cbnz    w0, .Lfail_tcp_sew

    /* SND_NXT unchanged */
    ldr     w0, [x21, #TCONN_SND_NXT]
    cmp     w0, w19
    b.ne    .Lfail_tcp_sew

    /* SND_WND unchanged */
    ldrh    w0, [x21, #TCONN_SND_WND]
    cmp     w0, #100
    b.ne    .Lfail_tcp_sew

    ldr     x0, =name_tcp_sew
    bl      test_pass
    b       .Ldone_tcp_sew
.Lfail_tcp_sew:
    ldr     x0, =name_tcp_sew
    bl      test_fail
.Ldone_tcp_sew:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_decrements_window — SND_WND=1000 → send 5 → SND_WND=995
 * ======================================================================== */
test_tcp_send_decrements_window:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_sdw
    mov     x21, x0

    /* Set SND_WND=1000 */
    mov     w0, #1000
    strh    w0, [x21, #TCONN_SND_WND]

    /* tcp_send 5 bytes */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send

    /* Should return 59 */
    cmp     w0, #59
    b.ne    .Lfail_tcp_sdw

    /* SND_WND = 995 */
    ldrh    w0, [x21, #TCONN_SND_WND]
    mov     w1, #995
    cmp     w0, w1
    b.ne    .Lfail_tcp_sdw

    ldr     x0, =name_tcp_sdw
    bl      test_pass
    b       .Ldone_tcp_sdw
.Lfail_tcp_sdw:
    ldr     x0, =name_tcp_sdw
    bl      test_fail
.Ldone_tcp_sdw:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_ready — min(SND_WND, 1460) when ESTABLISHED
 * ======================================================================== */
test_tcp_send_ready:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tsr
    mov     x21, x0

    /* Set SND_WND=500 → tcp_send_ready returns 500 */
    mov     w0, #500
    strh    w0, [x21, #TCONN_SND_WND]
    mov     x0, x21
    bl      tcp_send_ready
    cmp     w0, #500
    b.ne    .Lfail_tcp_tsr

    /* Set SND_WND=2000 → tcp_send_ready returns 1460 (clamped) */
    mov     w0, #2000
    strh    w0, [x21, #TCONN_SND_WND]
    mov     x0, x21
    bl      tcp_send_ready
    cmp     w0, #1460
    b.ne    .Lfail_tcp_tsr

    ldr     x0, =name_tcp_tsr
    bl      test_pass
    b       .Ldone_tcp_tsr
.Lfail_tcp_tsr:
    ldr     x0, =name_tcp_tsr
    bl      test_fail
.Ldone_tcp_tsr:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_ready_invalid — CLOSE_WAIT → returns 0
 * ======================================================================== */
test_tcp_send_ready_invalid:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tsri
    mov     x21, x0

    /* Force state = CLOSE_WAIT */
    mov     w0, #TCPS_CLOSE_WAIT
    strb    w0, [x21, #TCONN_STATE]

    mov     x0, x21
    bl      tcp_send_ready
    cbnz    w0, .Lfail_tcp_tsri

    ldr     x0, =name_tcp_tsri
    bl      test_pass
    b       .Ldone_tcp_tsri
.Lfail_tcp_tsri:
    ldr     x0, =name_tcp_tsri
    bl      test_fail
.Ldone_tcp_tsri:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_send_window_exhaustion (S8) — Full lifecycle: drain → block →
 * reopen → resume.  Handshake → SND_WND=15 → send 5+5+5 (drain) →
 * send 5 (rejected) → send_ready=0 → pure ACK window=1000 →
 * send_ready=1000 → send 5 (succeeds, SND_WND=995)
 * ======================================================================== */
test_tcp_send_window_exhaustion:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_swe
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Set SND_WND=15 */
    mov     w0, #15
    strh    w0, [x21, #TCONN_SND_WND]

    /* Step 1: tcp_send 5 bytes → ret=59, SND_WND=10 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_swe
    ldrh    w0, [x21, #TCONN_SND_WND]
    cmp     w0, #10
    b.ne    .Lfail_tcp_swe

    /* Step 2: tcp_send 5 bytes → ret=59, SND_WND=5 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_swe
    ldrh    w0, [x21, #TCONN_SND_WND]
    cmp     w0, #5
    b.ne    .Lfail_tcp_swe

    /* Step 3: tcp_send 5 bytes → ret=59, SND_WND=0 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_swe
    ldrh    w0, [x21, #TCONN_SND_WND]
    cbnz    w0, .Lfail_tcp_swe

    /* Step 4: tcp_send 5 bytes → rejected (ret=0), SND_WND still 0 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbnz    w0, .Lfail_tcp_swe
    ldrh    w0, [x21, #TCONN_SND_WND]
    cbnz    w0, .Lfail_tcp_swe

    /* Step 5: tcp_send_ready → returns 0 */
    mov     x0, x21
    bl      tcp_send_ready
    cbnz    w0, .Lfail_tcp_swe

    /* Step 6: Inject pure ACK with window=1000 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    /* Patch ACK = rev(ISN+1) */
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    /* Patch window = 1000 NBO */
    mov     w0, #1000
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20                 /* TCP header only, no data */
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    /* tcp_handle → pure ACK dropped (ret=0) */
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_swe
    /* SND_WND should be 1000 */
    ldrh    w0, [x21, #TCONN_SND_WND]
    mov     w1, #1000
    cmp     w0, w1
    b.ne    .Lfail_tcp_swe

    /* Step 7: tcp_send_ready → returns 1000 */
    mov     x0, x21
    bl      tcp_send_ready
    cmp     w0, #1000
    b.ne    .Lfail_tcp_swe

    /* Step 8: tcp_send 5 bytes → ret=59, SND_WND=995 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_swe
    ldrh    w0, [x21, #TCONN_SND_WND]
    mov     w1, #995
    cmp     w0, w1
    b.ne    .Lfail_tcp_swe

    ldr     x0, =name_tcp_swe
    bl      test_pass
    b       .Ldone_tcp_swe
.Lfail_tcp_swe:
    ldr     x0, =name_tcp_swe
    bl      test_fail
.Ldone_tcp_swe:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_window_update_partial (S9) — Window update with non-empty buffer
 * Handshake → receive 500 bytes → tcp_window_update → window=(2048-500)
 * ======================================================================== */
test_tcp_window_update_partial:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_wup
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Receive 500 bytes, SEQ=2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #500
    mov     w2, #0x41               /* 'A' */
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    ldr     x0, =tcp_test_buf3
    mov     w1, #554                /* 54 + 500 */
    bl      tcp_handle
    cmp     w0, #54
    b.ne    .Lfail_tcp_wup

    /* Call tcp_window_update */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    bl      tcp_window_update

    /* Verify ret=54 */
    cmp     w0, #54
    b.ne    .Lfail_tcp_wup

    /* Verify window = (2048-500) = 1548 NBO */
    ldr     x19, =tcp_send_test_buf
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    mov     w1, #1548
    rev16   w1, w1
    uxth    w1, w1
    cmp     w0, w1
    b.ne    .Lfail_tcp_wup

    ldr     x0, =name_tcp_wup
    bl      test_pass
    b       .Ldone_tcp_wup
.Lfail_tcp_wup:
    ldr     x0, =name_tcp_wup
    bl      test_fail
.Ldone_tcp_wup:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_boundary (S10) — payload_len exactly equals SND_WND
 * Handshake → SND_WND=5 → send 5 → ret=59, SND_WND=0
 * ======================================================================== */
test_tcp_send_boundary:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_sb
    mov     x21, x0

    /* Set SND_WND=5 */
    mov     w0, #5
    strh    w0, [x21, #TCONN_SND_WND]

    /* tcp_send 5 bytes (exactly equals SND_WND) */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_sb

    /* SND_WND should be 0 */
    ldrh    w0, [x21, #TCONN_SND_WND]
    cbnz    w0, .Lfail_tcp_sb

    ldr     x0, =name_tcp_sb
    bl      test_pass
    b       .Ldone_tcp_sb
.Lfail_tcp_sb:
    ldr     x0, =name_tcp_sb
    bl      test_fail
.Ldone_tcp_sb:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_send_ready_zero (S11) — SND_WND=0 returns 0
 * ======================================================================== */
test_tcp_send_ready_zero:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_srz
    mov     x21, x0

    /* Set SND_WND=0 */
    strh    wzr, [x21, #TCONN_SND_WND]

    mov     x0, x21
    bl      tcp_send_ready
    cbnz    w0, .Lfail_tcp_srz

    ldr     x0, =name_tcp_srz
    bl      test_pass
    b       .Ldone_tcp_srz
.Lfail_tcp_srz:
    ldr     x0, =name_tcp_srz
    bl      test_fail
.Ldone_tcp_srz:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_snd_wnd_pure_ack (S12) — Pure ACK (no data) updates SND_WND
 * Handshake → SND_WND=0 → pure ACK window=4096 → SND_WND=4096
 * ======================================================================== */
test_tcp_snd_wnd_pure_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_swpa
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Set SND_WND=0 */
    strh    wzr, [x21, #TCONN_SND_WND]

    /* Build pure ACK from tcp_handshake_ack_template */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    /* Patch ACK = rev(ISN+1) */
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    /* Patch window = 4096 NBO */
    mov     w0, #4096
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    /* tcp_handle → pure ACK dropped (ret=0) */
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle
    cbnz    w0, .Lfail_tcp_swpa
    /* SND_WND should be 4096 */
    ldrh    w0, [x21, #TCONN_SND_WND]
    mov     w1, #4096
    cmp     w0, w1
    b.ne    .Lfail_tcp_swpa

    ldr     x0, =name_tcp_swpa
    bl      test_pass
    b       .Ldone_tcp_swpa
.Lfail_tcp_swpa:
    ldr     x0, =name_tcp_swpa
    bl      test_fail
.Ldone_tcp_swpa:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_snd_wnd_data_ack (S13) — Data ACK updates both rx buffer and
 * SND_WND.  Handshake → SND_WND=100 → 5-byte data with window=8192 →
 * ret=54, RXLEN=5, SND_WND=8192
 * ======================================================================== */
test_tcp_snd_wnd_data_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_swda
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Set SND_WND=100 */
    mov     w0, #100
    strh    w0, [x21, #TCONN_SND_WND]

    /* Build 5-byte data frame, SEQ=2, ACK=ISN+1 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #5
    mov     w2, #0x41               /* 'A' */
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame

    /* Patch window to 8192 NBO */
    ldr     x19, =tcp_test_buf3
    mov     w0, #8192
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25                 /* TCP header 20 + 5 bytes data */
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* tcp_handle */
    mov     x0, x19
    mov     w1, #59                 /* 54 + 5 */
    bl      tcp_handle

    /* Verify ret=54 (ACK reply) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_swda

    /* Verify RXLEN=5 */
    ldrh    w0, [x21, #TCONN_RXLEN]
    cmp     w0, #5
    b.ne    .Lfail_tcp_swda

    /* Verify SND_WND=8192 */
    ldrh    w0, [x21, #TCONN_SND_WND]
    mov     w1, #8192
    cmp     w0, w1
    b.ne    .Lfail_tcp_swda

    ldr     x0, =name_tcp_swda
    bl      test_pass
    b       .Ldone_tcp_swda
.Lfail_tcp_swda:
    ldr     x0, =name_tcp_swda
    bl      test_fail
.Ldone_tcp_swda:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_snd_una_handshake — After handshake ACK, SND_UNA == SND_NXT
 *
 * Handshake completes → SND_UNA should be ISN+1 (SYN consumed 1 seq)
 * ======================================================================== */
test_tcp_snd_una_handshake:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_suah
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* After handshake: SND_UNA should == SND_NXT == ISN+1 */
    ldr     w0, [x21, #TCONN_SND_UNA]
    ldr     w1, [x21, #TCONN_SND_NXT]
    cmp     w0, w1
    b.ne    .Lfail_tcp_suah

    /* Both should == ISN+1 */
    add     w2, w22, #1
    cmp     w0, w2
    b.ne    .Lfail_tcp_suah

    ldr     x0, =name_tcp_suah
    bl      test_pass
    b       .Ldone_tcp_suah
.Lfail_tcp_suah:
    ldr     x0, =name_tcp_suah
    bl      test_fail
.Ldone_tcp_suah:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_snd_una_data_ack — After send + ACK, SND_UNA advances
 *
 * Handshake → tcp_send 5 bytes → peer ACKs → SND_UNA == SND_NXT
 * ======================================================================== */
test_tcp_snd_una_data_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_suada
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Send 5 bytes → SND_NXT += 5 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_suada

    /* SND_UNA should still be ISN+1, SND_NXT should be ISN+6 */
    ldr     w0, [x21, #TCONN_SND_UNA]
    add     w1, w22, #1
    cmp     w0, w1
    b.ne    .Lfail_tcp_suada

    ldr     w0, [x21, #TCONN_SND_NXT]
    add     w1, w22, #6
    cmp     w0, w1
    b.ne    .Lfail_tcp_suada

    /* Peer ACKs all data: send ACK with SEG.ACK = ISN+6, SEQ = 2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #0                  /* no payload */
    mov     w2, #0
    mov     w3, #2                  /* SEQ (peer's seq, = RCV_NXT after handshake) */
    add     w4, w22, #6             /* ACK = ISN+6 */
    bl      ttcp_build_data_frame

    /* tcp_handle */
    ldr     x0, =tcp_test_buf3
    mov     w1, #54
    bl      tcp_handle

    /* SND_UNA should now == SND_NXT == ISN+6 */
    ldr     w0, [x21, #TCONN_SND_UNA]
    ldr     w1, [x21, #TCONN_SND_NXT]
    cmp     w0, w1
    b.ne    .Lfail_tcp_suada

    add     w2, w22, #6
    cmp     w0, w2
    b.ne    .Lfail_tcp_suada

    ldr     x0, =name_tcp_suada
    bl      test_pass
    b       .Ldone_tcp_suada
.Lfail_tcp_suada:
    ldr     x0, =name_tcp_suada
    bl      test_fail
.Ldone_tcp_suada:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_snd_una_pure_ack — Pure ACK (no data) advances SND_UNA
 *
 * Handshake → tcp_send 5 bytes → pure ACK with partial advance →
 * verify SND_UNA advanced but != SND_NXT
 * ======================================================================== */
test_tcp_snd_una_pure_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_suapa
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Send 5 bytes */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_suapa

    /* Peer partially ACKs: ACK = ISN+3 (only 2 of 5 bytes) */
    ldr     x0, =tcp_test_buf3
    mov     w1, #0
    mov     w2, #0
    mov     w3, #2
    add     w4, w22, #3             /* ACK = ISN+3 */
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf3
    mov     w1, #54
    bl      tcp_handle

    /* SND_UNA should be ISN+3 (partial advance) */
    ldr     w0, [x21, #TCONN_SND_UNA]
    add     w1, w22, #3
    cmp     w0, w1
    b.ne    .Lfail_tcp_suapa

    /* SND_NXT should still be ISN+6 */
    ldr     w0, [x21, #TCONN_SND_NXT]
    add     w1, w22, #6
    cmp     w0, w1
    b.ne    .Lfail_tcp_suapa

    ldr     x0, =name_tcp_suapa
    bl      test_pass
    b       .Ldone_tcp_suapa
.Lfail_tcp_suapa:
    ldr     x0, =name_tcp_suapa
    bl      test_fail
.Ldone_tcp_suapa:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/*
 * 54-byte TCP SYN to port 80 from 10.0.2.2:12345, SEQ=1, checksum=0
 *
 * Ethernet (14): dst=02:00:00:00:00:01 src=AA:BB:CC:DD:EE:FF type=0800
 * IP (20):       ver/ihl=45 dscp=00 totlen=0028 id=1234 flags=0000
 *                ttl=40 proto=06 cksum=508C src=0A000202 dst=0A00020F
 * TCP (20):      sport=3039 dport=0050 seq=00000001 ack=00000000
 *                doff=50 flags=02(SYN) win=FFFF cksum=0000 urg=0000
 */
.balign 4
tcp_syn_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x28                               /* totlen: 40 */
    .byte   0x12, 0x34                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x06                               /* ttl=64, proto=TCP */
    .byte   0x50, 0x8C                               /* IP checksum */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x01                   /* seq: 1 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 (20 bytes) */
    .byte   0x02                                     /* flags: SYN */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 54-byte TCP ACK to port 80, SEQ=100, ACK=200, checksum=0
 */
.balign 4
tcp_ack_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x64                   /* seq: 100 */
    .byte   0x00, 0x00, 0x00, 0xC8                   /* ack: 200 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x10                                     /* flags: ACK */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 58-byte TCP SYN + "ABCD" payload to port 80
 * IP totlen=002C (44), IP cksum=5088
 */
.balign 4
tcp_syn_data_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x2C                   /* totlen: 44 */
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x88                   /* IP checksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x01                   /* seq: 1 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x02                                     /* flags: SYN */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */
    .byte   0x41, 0x42, 0x43, 0x44                   /* "ABCD" */

/*
 * 54-byte TCP with bad data offset: 0x30 (3*4=12 < 20 minimum)
 */
.balign 4
tcp_bad_doff_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39
    .byte   0x00, 0x50
    .byte   0x00, 0x00, 0x00, 0x01
    .byte   0x00, 0x00, 0x00, 0x00
    .byte   0x30                                     /* data offset: 3 (12 bytes!) */
    .byte   0x02
    .byte   0xFF, 0xFF
    .byte   0x00, 0x00
    .byte   0x00, 0x00

/*
 * 54-byte TCP with data offset overrun: 0x60 (6*4=24 > segment 20)
 */
.balign 4
tcp_doff_overrun_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39
    .byte   0x00, 0x50
    .byte   0x00, 0x00, 0x00, 0x01
    .byte   0x00, 0x00, 0x00, 0x00
    .byte   0x60                                     /* data offset: 6 (24 bytes!) */
    .byte   0x02
    .byte   0xFF, 0xFF
    .byte   0x00, 0x00
    .byte   0x00, 0x00

/*
 * 54-byte TCP SYN to port 12345 (not 80), SEQ=1, checksum=0
 * sport=54321(0xD431), dport=12345(0x3039)
 */
.balign 4
tcp_syn_wrongport_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0xD4, 0x31                               /* sport: 54321 */
    .byte   0x30, 0x39                               /* dport: 12345 */
    .byte   0x00, 0x00, 0x00, 0x01                   /* seq: 1 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x02                                     /* flags: SYN */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 55-byte TCP SYN + 1-byte payload "X" (odd-length TCP segment: 21 bytes)
 * IP totlen=0029 (41), IP cksum=508B
 */
.balign 4
tcp_syn_odd_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x29                   /* totlen: 41 */
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8B                   /* IP checksum */
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x01                   /* seq: 1 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x02                                     /* flags: SYN */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */
    .byte   0x58                                     /* "X" */

/*
 * 54-byte TCP bare data: flags=0x00 (no SYN/ACK/FIN), SEQ=100, checksum=0
 */
.balign 4
tcp_bare_data_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x64                   /* seq: 100 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x00                                     /* flags: none */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 54-byte TCP FIN: flags=0x01 (FIN only, no ACK), SEQ=100, checksum=0
 */
.balign 4
tcp_fin_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x64                   /* seq: 100 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x01                                     /* flags: FIN */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 54-byte ACK for handshake completion: sport=12345, dport=80, SEQ=2, ACK=0 (placeholder)
 * Same ETH/IP headers as tcp_syn_template.
 */
.balign 4
tcp_handshake_ack_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x02                   /* seq: 2 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 (filled at runtime) */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x10                                     /* flags: ACK */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 54-byte RST from peer: sport=12345, dport=80, SEQ=2, flags=RST+ACK
 * Used to test SYN_RCVD + RST → CLOSED
 */
.balign 4
tcp_rst_from_peer_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x02                   /* seq: 2 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x04                                     /* flags: RST */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 54-byte ACK with wrong ACK number: sport=12345, dport=80, SEQ=2, ACK=0xDEADBEEF
 * Used to test SYN_RCVD + bad ACK → RST
 */
.balign 4
tcp_bad_ack_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x02                   /* seq: 2 */
    .byte   0xDE, 0xAD, 0xBE, 0xEF                   /* ack: 0xDEADBEEF (wrong) */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x10                                     /* flags: ACK */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 54-byte bare data from 10.0.2.2:54321→:80, flags=0x00
 * Used to exercise rport mismatch in exact-match scan.
 */
.balign 4
tcp_from54321_to80_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0xD4, 0x31                               /* sport: 54321 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x64                   /* seq: 100 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x00                                     /* flags: none */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 54-byte bare data from 10.0.2.3:12345→:80, flags=0x00
 * Used to exercise rip mismatch in exact-match scan.
 */
.balign 4
tcp_diffip_to80_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8B                   /* IP cksum for src=10.0.2.3 */
    .byte   0x0A, 0x00, 0x02, 0x03                   /* src: 10.0.2.3 */
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x64                   /* seq: 100 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x00                                     /* flags: none */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 54-byte SYN+ACK from 10.0.2.2:12345→:80, flags=0x12
 * Used to exercise LISTEN rejecting SYN+ACK (pure SYN required).
 */
.balign 4
tcp_synack_to80_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x01                   /* seq: 1 */
    .byte   0x00, 0x00, 0x00, 0xC8                   /* ack: 200 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x12                                     /* flags: SYN+ACK */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

/*
 * 59-byte TCP ACK+PSH with 5-byte payload to port 80
 * SEQ=2 (matches RCV_NXT after handshake), ACK=0 (filled at runtime)
 * IP totlen=45 (0x002D), TCP segment=25 (header 20 + data 5)
 */
.balign 4
tcp_data_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x2D                               /* totlen: 45 */
    .byte   0x12, 0x34                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x06                               /* ttl=64, proto=TCP */
    .byte   0x50, 0x87                               /* IP checksum (placeholder) */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x02                   /* seq: 2 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 (filled at runtime) */
    .byte   0x50                                     /* data offset: 5 (20 bytes) */
    .byte   0x18                                     /* flags: ACK+PSH */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */
    .byte   0x48, 0x65, 0x6C, 0x6C, 0x6F            /* data: "Hello" */

/*
 * 59-byte TCP ACK+PSH with 5-byte payload, bad SEQ=100 (not matching RCV_NXT)
 */
.balign 4
tcp_data_badseq_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x2D
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x87
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x64                   /* seq: 100 (wrong!) */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x18                                     /* flags: ACK+PSH */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */
    .byte   0x48, 0x65, 0x6C, 0x6C, 0x6F            /* data: "Hello" */

/*
 * 54-byte TCP FIN+ACK to port 80, SEQ=2, ACK=0 (filled at runtime)
 * Used for passive close testing.
 */
.balign 4
tcp_finack_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x00
    .byte   0x45, 0x00, 0x00, 0x28
    .byte   0x12, 0x34, 0x00, 0x00
    .byte   0x40, 0x06, 0x50, 0x8C
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x0A, 0x00, 0x02, 0x0F
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x02                   /* seq: 2 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 (filled at runtime) */
    .byte   0x50                                     /* data offset: 5 */
    .byte   0x11                                     /* flags: FIN+ACK */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */

name_tcp_cksum:     .asciz "tcp_checksum"
name_tcp_ckdata:    .asciz "tcp_checksum_data"
name_tcp_short:     .asciz "tcp_short"
name_tcp_badck:     .asciz "tcp_bad_checksum"
name_tcp_baddoff:   .asciz "tcp_bad_data_off"
name_tcp_doffovr:   .asciz "tcp_doff_overrun"
name_tcp_rstsyn:    .asciz "tcp_rst_syn"
name_tcp_rstack:    .asciz "tcp_rst_ack"
name_tcp_rstwp:     .asciz "tcp_rst_wrong_port"
name_tcp_ckodd:     .asciz "tcp_checksum_odd"
name_tcp_rstbare:   .asciz "tcp_rst_bare_data"
name_tcp_rstfin:    .asciz "tcp_rst_fin"
name_tcp_init:      .asciz "tcp_init"
name_tcp_synack:    .asciz "tcp_syn_ack"
name_tcp_hs:        .asciz "tcp_handshake"
name_tcp_synnolist: .asciz "tcp_syn_no_listen"
name_tcp_srst:      .asciz "tcp_syn_rcvd_rst"
name_tcp_badack2:   .asciz "tcp_syn_rcvd_bad_ack"
name_tcp_tfull:     .asciz "tcp_table_full"
name_tcp_rpmiss:    .asciz "tcp_scan_rport_miss"
name_tcp_ripmiss:   .asciz "tcp_scan_rip_miss"
name_tcp_lsar:      .asciz "tcp_listen_synack_reject"
name_tcp_unkst:     .asciz "tcp_unknown_state"
name_tcp_srnoack:   .asciz "tcp_syn_rcvd_no_ack"
name_tcp_erst:      .asciz "tcp_established_rst"
name_tcp_lar:       .asciz "tcp_listen_ack_reject"
name_tcp_edd:       .asciz "tcp_established_data_drop"
name_tcp_ed:        .asciz "tcp_estab_data"
name_tcp_edb:       .asciz "tcp_estab_data_bad_seq"
name_tcp_ef:        .asciz "tcp_estab_fin"
name_tcp_cwr:       .asciz "tcp_close_wait_rst"
name_tcp_edm:       .asciz "tcp_estab_data_multi"
name_tcp_fnh:       .asciz "tcp_fsa_null_handler"
name_tcp_slm:       .asciz "tcp_scan_lport_miss"
name_tcp_ce:        .asciz "tcp_close_estab"
name_tcp_ccw:       .asciz "tcp_close_closewait"
name_tcp_ci:        .asciz "tcp_close_invalid"
name_tcp_fw1a:      .asciz "tcp_finwait1_ack"
name_tcp_fw1f:      .asciz "tcp_finwait1_fin"
name_tcp_fw2f:      .asciz "tcp_finwait2_fin"
name_tcp_cla:       .asciz "tcp_closing_ack"
name_tcp_laa:       .asciz "tcp_lastack_ack"
name_tcp_twr:       .asciz "tcp_timewait_rst"
name_tcp_twto:      .asciz "tcp_timewait_timeout"
name_tcp_laab:      .asciz "tcp_lastack_ack_bad"
name_tcp_fw1ab:     .asciz "tcp_finwait1_ack_bad"
name_tcp_clab:      .asciz "tcp_closing_ack_bad"
name_tcp_rxb:       .asciz "tcp_rx_buffer"
name_tcp_rxm:       .asciz "tcp_rx_buffer_multi"
name_tcp_rxfl:      .asciz "tcp_rx_flush"
name_tcp_rxov:      .asciz "tcp_rx_overflow"
name_tcp_ts:        .asciz "tcp_send"
name_tcp_tsi:       .asciz "tcp_send_invalid"
name_tcp_tszl:      .asciz "tcp_send_zero_len"
name_tcp_tsos:      .asciz "tcp_send_oversize"
name_tcp_wtf:       .asciz "tcp_window_tracks_fill"
name_tcp_waf:       .asciz "tcp_window_after_flush"
name_tcp_wz:        .asciz "tcp_window_zero"
name_tcp_bc:        .asciz "tcp_buffer_contents"
name_tcp_bsf:       .asciz "tcp_buffer_survives_flush"
name_tcp_sff:       .asciz "tcp_send_frame_fields"
name_tcp_sri:       .asciz "tcp_send_rx_independent"
name_tcp_twu:       .asciz "tcp_window_update"
name_tcp_twui:      .asciz "tcp_window_update_invalid"
name_tcp_twuc:      .asciz "tcp_window_update_closewait"
name_tcp_swc:       .asciz "tcp_snd_wnd_capture"
name_tcp_swu:       .asciz "tcp_snd_wnd_update"
name_tcp_sew:       .asciz "tcp_send_exceeds_window"
name_tcp_sdw:       .asciz "tcp_send_decrements_window"
name_tcp_tsr:       .asciz "tcp_send_ready"
name_tcp_tsri:      .asciz "tcp_send_ready_invalid"
name_tcp_swe:       .asciz "tcp_send_window_exhaustion"
name_tcp_wup:       .asciz "tcp_window_update_partial"
name_tcp_sb:        .asciz "tcp_send_boundary"
name_tcp_srz:       .asciz "tcp_send_ready_zero"
name_tcp_swpa:      .asciz "tcp_snd_wnd_pure_ack"
name_tcp_swda:      .asciz "tcp_snd_wnd_data_ack"
name_tcp_suah:      .asciz "tcp_snd_una_handshake"
name_tcp_suada:     .asciz "tcp_snd_una_data_ack"
name_tcp_suapa:     .asciz "tcp_snd_una_pure_ack"

tcp_send_payload:
    .ascii  "World"

.section .data
.balign 4
tcp_test_buf:
    .space  512

.balign 4
tcp_test_buf2:
    .space  512

.balign 4
tcp_test_buf3:
    .space  512

.balign 4
tcp_send_test_buf:
    .space  1536

.balign 8
test_tcp_timer_pool:
    .space  TPOOL_DEFAULT_SIZE
