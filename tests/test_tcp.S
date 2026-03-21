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
    mov     w1, #128
.Lttcp_zero_table:
    stp     xzr, xzr, [x0], #16
    subs    w1, w1, #1
    b.ne    .Lttcp_zero_table

    /* Initialize RST rate limiter for Phase 1 tests */
    ldr     x0, =tcp_rst_tokens
    mov     w1, #TCP_RST_BURST
    str     w1, [x0]
    bl      timer_now
    ldr     x1, =tcp_rst_last_tick
    str     x0, [x1]

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
    bl      test_tcp_synack_mss
    bl      test_tcp_peer_mss
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
    bl      test_tcp_rtx_save_on_send
    bl      test_tcp_rtx_clear_on_ack
    bl      test_tcp_send_gate_rtx
    bl      test_tcp_send_ready_gate_rtx
    bl      test_tcp_rtx_cb_send
    bl      test_tcp_rtx_cb_max_retries
    bl      test_tcp_synack_rtx_save
    bl      test_tcp_synack_rtx_clear
    bl      test_tcp_fin_rtx_save
    bl      test_tcp_fin_rtx_clear_fw1
    bl      test_tcp_fin_rtx_clear_lastack
    bl      test_tcp_dup_data_ack
    bl      test_tcp_rst_clears_rtx
    bl      test_tcp_rtx_arm_rto_cap
    bl      test_tcp_rtx_clear_no_pool
    bl      test_tcp_rtx_cb_stale_closed
    bl      test_tcp_rtx_cb_stale_listen
    bl      test_tcp_rtx_cb_no_send_fn
    bl      test_tcp_snd_una_future_ack
    bl      test_tcp_listen_port
    bl      test_tcp_listen_multi
    bl      test_tcp_listen_full
    bl      test_tcp_isn_different_tuples
    bl      test_tcp_isn_same_tuple
    bl      test_tcp_isn_nonzero
    bl      test_tcp_icmp_err_match
    bl      test_tcp_icmp_err_no_match
    bl      test_tcp_icmp_err_rtx_clear
    bl      test_tcp_icmp_err_short
    bl      test_tcp_ts_syn_negotiate
    bl      test_tcp_ts_syn_no_opt
    bl      test_tcp_ts_reply_frame_size
    bl      test_tcp_ts_reply_no_ts
    bl      test_tcp_ts_build_frame_size
    bl      test_tcp_ts_paws_accept
    bl      test_tcp_ts_paws_reject
    bl      test_tcp_ts_recent_update
    bl      test_tcp_icmp_err_lport
    bl      test_tcp_icmp_err_rip
    bl      test_tcp_icmp_err_proto_unreach
    bl      test_tcp_icmp_err_port_unreach
    bl      test_tcp_tsopt_exhaust
    bl      test_tcp_tsopt_eol
    bl      test_tcp_tsopt_trunc
    bl      test_tcp_tsopt_badlen
    bl      test_tcp_tsopt_skip
    bl      test_tcp_tsopt_wrong_tslen
    bl      test_tcp_paws_no_tsopt
    bl      test_tcp_tsopt_trunc_ts
    bl      test_tcp_cwnd_grow
    bl      test_tcp_cwnd_rtx_reset
    bl      test_tcp_cwnd_gate
    bl      test_tcp_ooo_merge
    bl      test_tcp_rst_ratelimit
    bl      test_tcp_rst_refill
    bl      test_tcp_syn_evict
    bl      test_tcp_rst_seq_valid
    bl      test_tcp_rst_seq_invalid
    bl      test_tcp_idle_estab_timeout
    bl      test_tcp_idle_estab_active
    bl      test_tcp_idle_finwait2_timeout
    bl      test_tcp_idle_closewait_timeout
    bl      test_tcp_fast_retransmit
    bl      test_tcp_dupack_below_thresh
    bl      test_tcp_persist_arm
    bl      test_tcp_persist_cancel
    bl      test_tcp_dupack_no_rtxdata
    bl      test_tcp_persist_already_armed
    bl      test_tcp_frtx_no_send_fn
    bl      test_tcp_frtx_cwnd_floor
    bl      test_tcp_reaper_skip_listen
    bl      test_tcp_reaper_skip_timewait
    bl      test_tcp_reaper_synrcvd
    bl      test_tcp_reaper_finwait1
    bl      test_tcp_start_reaper
    bl      test_tcp_start_reaper_no_pool
    bl      test_tcp_persist_cb_send
    bl      test_tcp_persist_cb_not_estab
    bl      test_tcp_persist_cb_wnd_open
    bl      test_tcp_persist_cb_no_send_fn
    bl      test_tcp_persist_cb_shift_cap
    bl      test_tcp_persist_arm_with_pool
    bl      test_tcp_df_bit
    bl      test_tcp_fin_with_data
    bl      test_tcp_fin_data_bad_seq
    bl      test_tcp_fin_data_overflow
    bl      test_tcp_timewait_fin_reack
    bl      test_tcp_tw_fin_no_timer
    bl      test_tcp_tw_fin_no_pool
    bl      test_tcp_tw_fin_arm_no_pool
    bl      test_tcp_ooo_outside_window
    bl      test_tcp_badack_state_rollback
    bl      test_tcp_rtx_resets_dupack
    bl      test_tcp_reaper_synrcvd_60s
    bl      test_tcp_rtt_init
    bl      test_tcp_rto_double
    bl      test_tcp_rtt_karn
    bl      test_tcp_wscale_negotiate
    bl      test_tcp_wscale_no_opt
    bl      test_tcp_wscale_window_apply
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
    mov     w0, #80
    bl      tcp_listen

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
    mov     w0, #80
    bl      tcp_listen

    /* Build valid SYN frame */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Call tcp_handle */
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Return value = 58 (SYN-ACK reply: 54 + 4 MSS option) */
    cmp     w0, #62
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
    cbz     w3, .Lfail_tcp_synack
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

    /* Verify TCP checksum (28 = 20 base + 4 MSS + 4 WSCALE) */
    mov     x0, x19
    mov     w1, #28
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
 * test_tcp_synack_mss — SYN-ACK contains MSS option (Kind=2, Len=4, 1460)
 * ======================================================================== */
test_tcp_synack_mss:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Send SYN */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
    b.ne    .Lfail_tcp_samss

    ldr     x0, =tcp_test_buf

    /* Data offset should be 7 (28 bytes = 20 base + 4 MSS + 4 WSCALE) */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    lsr     w1, w1, #4
    cmp     w1, #7
    b.ne    .Lfail_tcp_samss

    /* MSS option at TCP header offset 20: Kind=2 */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + 20)]
    cmp     w1, #TCP_OPT_MSS
    b.ne    .Lfail_tcp_samss

    /* MSS option byte 1: Len=4 */
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + 21)]
    cmp     w1, #TCP_OPT_MSS_LEN
    b.ne    .Lfail_tcp_samss

    /* MSS option bytes 2-3: 1460 NBO = 0x05B4 */
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + 22)]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #TCP_OUR_MSS
    cmp     w1, w2
    b.ne    .Lfail_tcp_samss

    ldr     x0, =name_tcp_samss
    bl      test_pass
    b       .Ldone_tcp_samss

.Lfail_tcp_samss:
    ldr     x0, =name_tcp_samss
    bl      test_fail

.Ldone_tcp_samss:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_peer_mss — SYN with MSS=1460 → TCONN_PEER_MSS=1460,
 *                      tcp_send_ready clamps to 1460 (not 536 default)
 * ======================================================================== */
test_tcp_peer_mss:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Send SYN with MSS=1460 option */
    ldr     x0, =tcp_syn_mss_template
    ldr     x1, =tcp_test_buf
    mov     w2, #58                     /* 54 + 4 MSS option */
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #58
    bl      tcp_handle
    cmp     w0, #62                     /* SYN-ACK */
    b.ne    .Lfail_tcp_pmss

    /* Extract ISN from SYN-ACK */
    ldr     x19, =tcp_test_buf
    ldr     w20, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w20, w20

    /* Find the SYN_RCVD connection */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lpmss_find:
    cbz     w3, .Lfail_tcp_pmss
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.eq    .Lpmss_found
    add     x0, x0, #TCONN_SIZE
    b       .Lpmss_find
.Lpmss_found:
    mov     x19, x0                     /* x19 = conn */

    /* Verify TCONN_PEER_MSS = 1460 */
    ldrh    w0, [x19, #TCONN_PEER_MSS]
    mov     w1, #TCP_OUR_MSS
    cmp     w0, w1
    b.ne    .Lfail_tcp_pmss

    /* Complete handshake: ACK with SEQ=2, ACK=ISN+1 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    add     w1, w20, #1
    rev     w1, w1
    str     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     w1, #20
    bl      tcp_checksum
    ldr     x1, =tcp_test_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Verify state = ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_pmss

    /* tcp_send_ready with SND_WND=2000 → should return 1460 (peer MSS) */
    mov     w0, #2000
    str     w0, [x19, #TCONN_SND_WND]
    mov     x0, x19
    bl      tcp_send_ready
    mov     w1, #TCP_OUR_MSS
    cmp     w0, w1
    b.ne    .Lfail_tcp_pmss

    ldr     x0, =name_tcp_pmss
    bl      test_pass
    b       .Ldone_tcp_pmss

.Lfail_tcp_pmss:
    ldr     x0, =name_tcp_pmss
    bl      test_fail

.Ldone_tcp_pmss:
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
    mov     w0, #80
    bl      tcp_listen

    /* Step 1: Send SYN */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Must return 58 (SYN-ACK: 54 + 4 MSS) */
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

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
    mov     w0, #80
    bl      tcp_listen

    /* SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cmp     w0, #62
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
 * test_tcp_table_full — Fill slots 1-15 as ESTABLISHED, then SYN → RST
 * (Uses ESTABLISHED so SYN_RCVD eviction cannot rescue the allocation)
 * ======================================================================== */
test_tcp_table_full:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Fill slots 1-15 with state=ESTABLISHED (non-evictable) */
    ldr     x0, =tcp_conn_table
    add     x0, x0, #TCONN_SIZE    /* skip slot 0 (LISTEN) */
    mov     w2, #TCPS_ESTABLISHED
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
    mov     w0, #80
    bl      tcp_listen

    /* Create SYN_RCVD connection from 10.0.2.2:12345→:80 */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Create SYN_RCVD connection from 10.0.2.2:12345→:80 */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

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
    mov     w0, #80
    bl      tcp_listen

    /* Create SYN_RCVD connection */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Create SYN_RCVD connection */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Step 1: SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

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
    mov     w0, #80
    bl      tcp_listen

    /* Step 1: SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Step 1: SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake (same as above) */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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

    /* Verify return = 54 (dup ACK sent, OOO segment buffered) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_edb

    /* Verify RCV_NXT unchanged (OOO doesn't advance RCV_NXT) */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, w22
    b.ne    .Lfail_tcp_edb

    /* Verify OOO_COUNT = 1 (segment was buffered) */
    ldrb    w0, [x21, #TCONN_OOO_COUNT]
    cmp     w0, #1
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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

    /* Send RST to CLOSE_WAIT conn — SEQ must match RCV_NXT (=3 after FIN) */
    ldr     x0, =tcp_rst_from_peer_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    /* Patch SEQ to current RCV_NXT */
    ldr     x19, =tcp_test_buf
    ldr     w0, [x21, #TCONN_RCV_NXT]
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* SYN → SYN-ACK (creates SYN_RCVD in slot 1) */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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

    /* Should get SYN-ACK (return 58) */
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

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
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

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
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

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
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Handshake → ESTABLISHED */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
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
    mov     w0, #80
    bl      tcp_listen

    /* Step 1: SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62                 /* 54 + 4 (MSS option) */
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

    ldr     w0, [x21, #TCONN_SND_WND]
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
    ldr     w0, [x21, #TCONN_SND_WND]
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
    str     w0, [x21, #TCONN_SND_WND]

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
    ldr     w0, [x21, #TCONN_SND_WND]
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
    str     w0, [x21, #TCONN_SND_WND]

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
    ldr     w0, [x21, #TCONN_SND_WND]
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
    str     w0, [x21, #TCONN_SND_WND]
    mov     x0, x21
    bl      tcp_send_ready
    cmp     w0, #500
    b.ne    .Lfail_tcp_tsr

    /* Set SND_WND=2000 → tcp_send_ready returns 536 (clamped to default peer MSS) */
    mov     w0, #2000
    str     w0, [x21, #TCONN_SND_WND]
    mov     x0, x21
    bl      tcp_send_ready
    cmp     w0, #TCP_DEFAULT_MSS
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
    str     w0, [x21, #TCONN_SND_WND]

    /* Step 1: tcp_send 5 bytes → ret=59, SND_WND=10 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_swe
    ldr     w0, [x21, #TCONN_SND_WND]
    cmp     w0, #10
    b.ne    .Lfail_tcp_swe
    /* Clear retransmit state to allow next send (simulates ACK) */
    strh    wzr, [x21, #TCONN_RTXLEN]

    /* Step 2: tcp_send 5 bytes → ret=59, SND_WND=5 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_swe
    ldr     w0, [x21, #TCONN_SND_WND]
    cmp     w0, #5
    b.ne    .Lfail_tcp_swe
    /* Clear retransmit state to allow next send */
    strh    wzr, [x21, #TCONN_RTXLEN]

    /* Step 3: tcp_send 5 bytes → ret=59, SND_WND=0 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_swe
    ldr     w0, [x21, #TCONN_SND_WND]
    cbnz    w0, .Lfail_tcp_swe

    /* Clear retransmit gate so step 4 tests window exhaustion specifically */
    strh    wzr, [x21, #TCONN_RTXLEN]

    /* Step 4: tcp_send 5 bytes → rejected (ret=0), SND_WND still 0 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbnz    w0, .Lfail_tcp_swe
    ldr     w0, [x21, #TCONN_SND_WND]
    cbnz    w0, .Lfail_tcp_swe

    /* Step 5: tcp_send_ready → returns 0 (SND_WND=0) */
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
    ldr     w0, [x21, #TCONN_SND_WND]
    mov     w1, #1000
    cmp     w0, w1
    b.ne    .Lfail_tcp_swe

    /* Step 7: tcp_send_ready → returns 536 (min of SND_WND=1000, peer_mss=536) */
    mov     x0, x21
    bl      tcp_send_ready
    cmp     w0, #TCP_DEFAULT_MSS
    b.ne    .Lfail_tcp_swe

    /* Step 8: tcp_send 5 bytes → ret=59, SND_WND=995 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_swe
    ldr     w0, [x21, #TCONN_SND_WND]
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
    str     w0, [x21, #TCONN_SND_WND]

    /* tcp_send 5 bytes (exactly equals SND_WND) */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_sb

    /* SND_WND should be 0 */
    ldr     w0, [x21, #TCONN_SND_WND]
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
    str     wzr, [x21, #TCONN_SND_WND]

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
    str     wzr, [x21, #TCONN_SND_WND]

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
    ldr     w0, [x21, #TCONN_SND_WND]
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
    str     w0, [x21, #TCONN_SND_WND]

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
    ldr     w0, [x21, #TCONN_SND_WND]
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
 * test_tcp_rtx_save_on_send — tcp_send saves frame to retransmit buffer
 *
 * Handshake → tcp_send 5 bytes → verify RTXLEN == frame_len (59),
 * first byte of rtxbuf matches first byte of sent frame
 * ======================================================================== */
test_tcp_rtx_save_on_send:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rtxs
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Verify RTXLEN starts at 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_rtxs

    /* Send 5 bytes */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_rtxs

    /* Verify RTXLEN == 59 (54 + 5) */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cmp     w0, #59
    b.ne    .Lfail_tcp_rtxs

    /* Verify RTXCOUNT == 0 */
    ldrb    w0, [x21, #TCONN_RTXCOUNT]
    cbnz    w0, .Lfail_tcp_rtxs

    /* Verify first byte of rtxbuf matches send_test_buf */
    ldr     x0, =tcp_conn_table
    sub     x0, x21, x0
    lsr     x0, x0, #TCONN_SHIFT   /* slot index */
    ldr     x1, =tcp_rtxbuf_pool
    add     x1, x1, x0, lsl #TCP_RXBUF_SHIFT
    ldrb    w2, [x1]
    ldr     x3, =tcp_send_test_buf
    ldrb    w4, [x3]
    cmp     w2, w4
    b.ne    .Lfail_tcp_rtxs

    ldr     x0, =name_tcp_rtxs
    bl      test_pass
    b       .Ldone_tcp_rtxs
.Lfail_tcp_rtxs:
    ldr     x0, =name_tcp_rtxs
    bl      test_fail
.Ldone_tcp_rtxs:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rtx_clear_on_ack — ACK that advances SND_UNA == SND_NXT clears
 * retransmit state
 *
 * Handshake → tcp_send 5 bytes → ACK all → verify RTXLEN == 0
 * ======================================================================== */
test_tcp_rtx_clear_on_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rtxc
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Send 5 bytes */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_rtxc

    /* Verify RTXLEN != 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbz     w0, .Lfail_tcp_rtxc

    /* Peer ACKs all: ACK = ISN+6 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #0
    mov     w2, #0
    mov     w3, #2                  /* SEQ = peer's seq */
    add     w4, w22, #6             /* ACK = ISN+6 = SND_NXT */
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf3
    mov     w1, #54
    bl      tcp_handle

    /* Verify RTXLEN == 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_rtxc

    /* Verify RTXCOUNT == 0 */
    ldrb    w0, [x21, #TCONN_RTXCOUNT]
    cbnz    w0, .Lfail_tcp_rtxc

    ldr     x0, =name_tcp_rtxc
    bl      test_pass
    b       .Ldone_tcp_rtxc
.Lfail_tcp_rtxc:
    ldr     x0, =name_tcp_rtxc
    bl      test_fail
.Ldone_tcp_rtxc:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_send_gate_rtx — tcp_send returns 0 when RTXLEN != 0
 *
 * Handshake → tcp_send 5 bytes (RTXLEN set) → second tcp_send → returns 0
 * ======================================================================== */
test_tcp_send_gate_rtx:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_sgate
    mov     x21, x0                 /* conn */

    /* First send succeeds */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_sgate

    /* RTXLEN should be non-zero */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbz     w0, .Lfail_tcp_sgate

    /* Second send should return 0 (gated) */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbnz    w0, .Lfail_tcp_sgate

    ldr     x0, =name_tcp_sgate
    bl      test_pass
    b       .Ldone_tcp_sgate
.Lfail_tcp_sgate:
    ldr     x0, =name_tcp_sgate
    bl      test_fail
.Ldone_tcp_sgate:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_send_ready_gate_rtx — tcp_send_ready returns 0 when RTXLEN != 0
 *
 * Handshake → tcp_send 5 bytes → tcp_send_ready → returns 0
 * ======================================================================== */
test_tcp_send_ready_gate_rtx:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_srgate
    mov     x21, x0                 /* conn */

    /* Send 5 bytes */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_srgate

    /* tcp_send_ready should return 0 */
    mov     x0, x21
    bl      tcp_send_ready
    cbnz    w0, .Lfail_tcp_srgate

    ldr     x0, =name_tcp_srgate
    bl      test_pass
    b       .Ldone_tcp_srgate
.Lfail_tcp_srgate:
    ldr     x0, =name_tcp_srgate
    bl      test_fail
.Ldone_tcp_srgate:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/*
 * ttcp_mock_send_fn — Mock send function that records calls
 *
 * x0: dwc2_base, x1: ecm_state, x2: tx_buf, w3: frame_len
 * Records: call count, last frame_len
 */
ttcp_mock_send_fn:
    ldr     x4, =ttcp_mock_send_count
    ldr     w5, [x4]
    add     w5, w5, #1
    str     w5, [x4]
    ldr     x4, =ttcp_mock_send_len
    str     w3, [x4]
    mov     w0, #0
    ret

/* ========================================================================
 * test_tcp_rtx_cb_send — Retransmit callback sends frame via mock
 *
 * Handshake → tcp_send → set up mock send_ctx → call tcp_retransmit_cb →
 * verify mock was called, RTXCOUNT incremented
 * ======================================================================== */
test_tcp_rtx_cb_send:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rcbs
    mov     x21, x0                 /* conn */

    /* Send 5 bytes to populate retransmit buffer */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_rcbs

    /* Set up mock send context */
    mov     x0, #0                  /* fake dwc2_base */
    mov     x1, #0                  /* fake ecm_state */
    ldr     x2, =tcp_test_buf3      /* tx_buf */
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    /* Reset mock counters */
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]
    ldr     x0, =ttcp_mock_send_len
    str     wzr, [x0]

    /* Verify RTXCOUNT == 0 before callback */
    ldrb    w0, [x21, #TCONN_RTXCOUNT]
    cbnz    w0, .Lfail_tcp_rcbs

    /* Call tcp_retransmit_cb(conn) */
    mov     x0, x21
    bl      tcp_retransmit_cb

    /* Verify mock was called once */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_tcp_rcbs

    /* Verify frame_len was 59 (54 + 5) */
    ldr     x0, =ttcp_mock_send_len
    ldr     w0, [x0]
    cmp     w0, #59
    b.ne    .Lfail_tcp_rcbs

    /* Verify RTXCOUNT == 1 */
    ldrb    w0, [x21, #TCONN_RTXCOUNT]
    cmp     w0, #1
    b.ne    .Lfail_tcp_rcbs

    ldr     x0, =name_tcp_rcbs
    bl      test_pass
    b       .Ldone_tcp_rcbs
.Lfail_tcp_rcbs:
    ldr     x0, =name_tcp_rcbs
    bl      test_fail
.Ldone_tcp_rcbs:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rtx_cb_max_retries — Max retries → CLOSED
 *
 * Handshake → tcp_send → set RTXCOUNT = TCP_MAX_RETRIES → callback →
 * verify state == CLOSED, RTXLEN == 0
 * ======================================================================== */
test_tcp_rtx_cb_max_retries:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rcbm
    mov     x21, x0                 /* conn */

    /* Send 5 bytes to populate retransmit buffer */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_rcbm

    /* Set RTXCOUNT = TCP_MAX_RETRIES */
    mov     w0, #TCP_MAX_RETRIES
    strb    w0, [x21, #TCONN_RTXCOUNT]

    /* Set up mock send context (shouldn't be called) */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_test_buf3
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    /* Reset mock counter */
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    /* Call tcp_retransmit_cb(conn) */
    mov     x0, x21
    bl      tcp_retransmit_cb

    /* Verify state == CLOSED */
    ldrb    w0, [x21, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_rcbm

    /* Verify RTXLEN == 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_rcbm

    /* Verify mock was NOT called */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_tcp_rcbm

    ldr     x0, =name_tcp_rcbm
    bl      test_pass
    b       .Ldone_tcp_rcbm
.Lfail_tcp_rcbm:
    ldr     x0, =name_tcp_rcbm
    bl      test_fail
.Ldone_tcp_rcbm:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_synack_rtx_save — SYN → SYN-ACK saves frame in retransmit buffer
 *
 * tcp_init → SYN → verify new connection has RTXLEN == 54
 * ======================================================================== */
test_tcp_synack_rtx_save:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Send SYN */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62                 /* 54 + 4 MSS option */
    b.ne    .Lfail_tcp_sars

    /* Find SYN_RCVD connection */
    ldr     x21, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lsars_find:
    cbz     w3, .Lfail_tcp_sars
    sub     w3, w3, #1
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_SYN_RCVD
    b.eq    .Lsars_found
    add     x21, x21, #TCONN_SIZE
    b       .Lsars_find
.Lsars_found:

    /* Verify RTXLEN == 58 (SYN-ACK frame: 54 + 4 MSS) */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cmp     w0, #62
    b.ne    .Lfail_tcp_sars

    /* Verify RTXCOUNT == 0 */
    ldrb    w0, [x21, #TCONN_RTXCOUNT]
    cbnz    w0, .Lfail_tcp_sars

    ldr     x0, =name_tcp_sars
    bl      test_pass
    b       .Ldone_tcp_sars
.Lfail_tcp_sars:
    ldr     x0, =name_tcp_sars
    bl      test_fail
.Ldone_tcp_sars:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_synack_rtx_clear — Handshake ACK clears SYN-ACK retransmit
 *
 * Full handshake → verify RTXLEN == 0
 * ======================================================================== */
test_tcp_synack_rtx_clear:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_sarc
    mov     x21, x0

    /* After handshake, RTXLEN should be 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_sarc

    ldr     x0, =name_tcp_sarc
    bl      test_pass
    b       .Ldone_tcp_sarc
.Lfail_tcp_sarc:
    ldr     x0, =name_tcp_sarc
    bl      test_fail
.Ldone_tcp_sarc:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_fin_rtx_save — tcp_close saves FIN in retransmit buffer
 *
 * Handshake → tcp_close → verify RTXLEN == 54
 * ======================================================================== */
test_tcp_fin_rtx_save:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_frs
    mov     x21, x0

    /* tcp_close */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    bl      tcp_close
    cmp     w0, #54
    b.ne    .Lfail_tcp_frs

    /* Verify RTXLEN == 54 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cmp     w0, #54
    b.ne    .Lfail_tcp_frs

    /* Verify state == FIN_WAIT_1 */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_FIN_WAIT_1
    b.ne    .Lfail_tcp_frs

    ldr     x0, =name_tcp_frs
    bl      test_pass
    b       .Ldone_tcp_frs
.Lfail_tcp_frs:
    ldr     x0, =name_tcp_frs
    bl      test_fail
.Ldone_tcp_frs:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_fin_rtx_clear_fw1 — FIN_WAIT_1 + ACK clears retransmit
 *
 * Handshake → tcp_close → FIN_WAIT_1 → ACK → FIN_WAIT_2, RTXLEN==0
 * ======================================================================== */
test_tcp_fin_rtx_clear_fw1:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_frcf
    mov     x21, x0
    mov     w22, w1                 /* ISN */

    /* tcp_close → FIN_WAIT_1 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    bl      tcp_close
    cmp     w0, #54
    b.ne    .Lfail_tcp_frcf

    /* Build ACK for the FIN: SEQ=2 (peer's seq), ACK=ISN+2 (FIN consumed 1) */
    ldr     x0, =tcp_test_buf3
    mov     w1, #0
    mov     w2, #0
    mov     w3, #2
    add     w4, w22, #2             /* ACK = ISN+2 (SND_NXT after FIN) */
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf3
    mov     w1, #54
    bl      tcp_handle

    /* Verify state == FIN_WAIT_2 */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_FIN_WAIT_2
    b.ne    .Lfail_tcp_frcf

    /* Verify RTXLEN == 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_frcf

    ldr     x0, =name_tcp_frcf
    bl      test_pass
    b       .Ldone_tcp_frcf
.Lfail_tcp_frcf:
    ldr     x0, =name_tcp_frcf
    bl      test_fail
.Ldone_tcp_frcf:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_fin_rtx_clear_lastack — LAST_ACK + ACK clears retransmit
 *
 * Handshake → recv FIN → CLOSE_WAIT → tcp_close → LAST_ACK → ACK → CLOSED
 * ======================================================================== */
test_tcp_fin_rtx_clear_lastack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_frcl
    mov     x21, x0
    mov     w22, w1                 /* ISN */

    /* Inject FIN from peer: FIN+ACK, SEQ=2, ACK=ISN+1 → CLOSE_WAIT */
    ldr     x0, =tcp_test_buf3
    mov     w1, #0
    mov     w2, #0
    mov     w3, #2                  /* peer SEQ */
    add     w4, w22, #1             /* ACK = ISN+1 */
    bl      ttcp_build_data_frame
    /* Patch flags to FIN+ACK */
    ldr     x19, =tcp_test_buf3
    mov     w0, #TCP_FIN_ACK
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify CLOSE_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSE_WAIT
    b.ne    .Lfail_tcp_frcl

    /* tcp_close → LAST_ACK */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    bl      tcp_close
    cmp     w0, #54
    b.ne    .Lfail_tcp_frcl

    /* Verify RTXLEN == 54 (FIN saved) */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cmp     w0, #54
    b.ne    .Lfail_tcp_frcl

    /* ACK for the FIN: SEQ=3 (peer consumed FIN), ACK=ISN+2 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #0
    mov     w2, #0
    mov     w3, #3                  /* peer SEQ (FIN consumed 1) */
    add     w4, w22, #2             /* ACK = ISN+2 */
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf3
    mov     w1, #54
    bl      tcp_handle

    /* Verify CLOSED */
    ldrb    w0, [x21, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_frcl

    /* Verify RTXLEN == 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_frcl

    ldr     x0, =name_tcp_frcl
    bl      test_pass
    b       .Ldone_tcp_frcl
.Lfail_tcp_frcl:
    ldr     x0, =name_tcp_frcl
    bl      test_fail
.Ldone_tcp_frcl:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_dup_data_ack — Duplicate data (SEQ < RCV_NXT) → re-ACK
 *
 * Handshake → receive 5 bytes (RCV_NXT advances) → inject same data
 * again (SEQ < RCV_NXT) → should get ACK reply with current RCV_NXT
 * ======================================================================== */
test_tcp_dup_data_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_dda
    mov     x21, x0
    mov     w22, w1                 /* ISN */

    /* Receive 5 bytes: SEQ=2, ACK=ISN+1 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #5
    mov     w2, #0x41               /* 'A' */
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf3
    mov     w1, #59
    bl      tcp_handle
    cmp     w0, #54                 /* ACK reply */
    b.ne    .Lfail_tcp_dda

    /* RCV_NXT should now be 7 (2 + 5) */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, #7
    b.ne    .Lfail_tcp_dda

    /* Inject duplicate: same SEQ=2, ACK=ISN+1 (SEQ < RCV_NXT) */
    ldr     x0, =tcp_test_buf3
    mov     w1, #5
    mov     w2, #0x41
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf3
    mov     w1, #59
    bl      tcp_handle

    /* Should get ACK reply (54) with current RCV_NXT */
    cmp     w0, #54
    b.ne    .Lfail_tcp_dda

    /* Verify ACK field = rev(RCV_NXT) = rev(7) */
    ldr     x19, =tcp_test_buf3
    ldr     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    rev     w0, w0
    cmp     w0, #7
    b.ne    .Lfail_tcp_dda

    /* RCV_NXT should still be 7 (not advanced by duplicate) */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, #7
    b.ne    .Lfail_tcp_dda

    ldr     x0, =name_tcp_dda
    bl      test_pass
    b       .Ldone_tcp_dda
.Lfail_tcp_dda:
    ldr     x0, =name_tcp_dda
    bl      test_fail
.Ldone_tcp_dda:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rst_clears_rtx — RST clears retransmit state
 *
 * Handshake → tcp_send (RTXLEN set) → RST → CLOSED, RTXLEN == 0
 * ======================================================================== */
test_tcp_rst_clears_rtx:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rcr
    mov     x21, x0
    mov     w22, w1                 /* ISN */

    /* Send 5 bytes to set RTXLEN */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_rcr

    /* Verify RTXLEN != 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbz     w0, .Lfail_tcp_rcr

    /* Inject RST: flags=RST+ACK, SEQ=2, ACK=ISN+1 */
    ldr     x0, =tcp_test_buf3
    mov     w1, #0
    mov     w2, #0
    mov     w3, #2
    add     w4, w22, #1
    bl      ttcp_build_data_frame
    /* Patch flags to RST+ACK */
    ldr     x19, =tcp_test_buf3
    mov     w0, #TCP_RST_ACK
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify CLOSED */
    ldrb    w0, [x21, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_rcr

    /* Verify RTXLEN == 0 */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_rcr

    ldr     x0, =name_tcp_rcr
    bl      test_pass
    b       .Ldone_tcp_rcr
.Lfail_tcp_rcr:
    ldr     x0, =name_tcp_rcr
    bl      test_fail
.Ldone_tcp_rcr:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rtx_arm_rto_cap — RTO capped at 60s when RTXCOUNT >= 6
 *
 * Handshake → tcp_send → set up timer pool + mock send_ctx →
 * set RTXCOUNT=5 → tcp_retransmit_cb → RTXCOUNT becomes 6 →
 * re-arm hits 1<<6=64 > 60 cap → verify RTXCOUNT==6, mock called
 * ======================================================================== */
test_tcp_rtx_arm_rto_cap:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rtocap
    mov     x21, x0                 /* conn */

    /* Send 5 bytes to populate retransmit buffer */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_rtocap

    /* Init timer pool (so tcp_rtx_arm actually arms) */
    ldr     x0, =test_tcp_timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init
    ldr     x0, =test_tcp_timer_pool
    bl      tcp_set_timer_pool

    /* Set up mock send context */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_test_buf3
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    /* Reset mock counters */
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    /* Set RTXCOUNT = 5 (callback increments to 6, 1<<6=64 > 60 cap) */
    mov     w0, #5
    strb    w0, [x21, #TCONN_RTXCOUNT]

    /* Call tcp_retransmit_cb(conn) */
    mov     x0, x21
    bl      tcp_retransmit_cb

    /* Verify RTXCOUNT == 6 */
    ldrb    w0, [x21, #TCONN_RTXCOUNT]
    cmp     w0, #6
    b.ne    .Lfail_tcp_rtocap

    /* Verify mock was called */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_tcp_rtocap

    /* Verify timer was armed (TIMER_SLOT != -1) */
    ldr     w0, [x21, #TCONN_TIMER_SLOT]
    cmn     w0, #1
    b.eq    .Lfail_tcp_rtocap

    /* Clean up: clear timer pool ptr to avoid affecting later tests */
    mov     x0, #0
    bl      tcp_set_timer_pool

    ldr     x0, =name_tcp_rtocap
    bl      test_pass
    b       .Ldone_tcp_rtocap
.Lfail_tcp_rtocap:
    mov     x0, #0
    bl      tcp_set_timer_pool
    ldr     x0, =name_tcp_rtocap
    bl      test_fail
.Ldone_tcp_rtocap:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rtx_clear_no_pool — tcp_rtx_clear with TIMER_SLOT != -1
 * but timer pool ptr == NULL
 *
 * Defensive guard: should not crash, should still zero RTXLEN/RTXCOUNT
 * ======================================================================== */
test_tcp_rtx_clear_no_pool:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rcnp
    mov     x19, x0                 /* conn */

    /* Ensure timer pool ptr is NULL */
    mov     x0, #0
    bl      tcp_set_timer_pool

    /* Set up state as if retransmit is active with a stale timer slot */
    mov     w0, #54
    strh    w0, [x19, #TCONN_RTXLEN]
    mov     w0, #3
    strb    w0, [x19, #TCONN_RTXCOUNT]
    mov     w0, #5                  /* fake timer slot */
    str     w0, [x19, #TCONN_TIMER_SLOT]

    /* Call tcp_rtx_clear — should not crash */
    mov     x0, x19
    bl      tcp_rtx_clear

    /* Verify RTXLEN == 0 */
    ldrh    w0, [x19, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_rcnp

    /* Verify RTXCOUNT == 0 */
    ldrb    w0, [x19, #TCONN_RTXCOUNT]
    cbnz    w0, .Lfail_tcp_rcnp

    /* Verify TIMER_SLOT == -1 */
    ldr     w0, [x19, #TCONN_TIMER_SLOT]
    cmn     w0, #1
    b.ne    .Lfail_tcp_rcnp

    ldr     x0, =name_tcp_rcnp
    bl      test_pass
    b       .Ldone_tcp_rcnp
.Lfail_tcp_rcnp:
    ldr     x0, =name_tcp_rcnp
    bl      test_fail
.Ldone_tcp_rcnp:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rtx_cb_stale_closed — Retransmit callback on CLOSED conn (stale timer)
 *
 * Set conn state=CLOSED, set up mock send, call tcp_retransmit_cb →
 * should return without sending
 * ======================================================================== */
test_tcp_rtx_cb_stale_closed:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rcsc
    mov     x19, x0                 /* conn */

    /* Set up mock send context */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_test_buf3
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    /* Reset mock counter */
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    /* Force state to CLOSED (simulates stale timer firing after close) */
    strb    wzr, [x19, #TCONN_STATE]

    /* Set RTXLEN to nonzero so we can detect if callback runs the send path */
    mov     w0, #54
    strh    w0, [x19, #TCONN_RTXLEN]

    /* Call tcp_retransmit_cb(conn) */
    mov     x0, x19
    bl      tcp_retransmit_cb

    /* Verify mock was NOT called */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_tcp_rcsc

    ldr     x0, =name_tcp_rcsc
    bl      test_pass
    b       .Ldone_tcp_rcsc
.Lfail_tcp_rcsc:
    ldr     x0, =name_tcp_rcsc
    bl      test_fail
.Ldone_tcp_rcsc:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rtx_cb_stale_listen — Retransmit callback on LISTEN conn (stale timer)
 *
 * Set conn state=LISTEN, call tcp_retransmit_cb → should return without sending
 * ======================================================================== */
test_tcp_rtx_cb_stale_listen:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rcsl
    mov     x19, x0                 /* conn */

    /* Set up mock send context */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_test_buf3
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    /* Reset mock counter */
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    /* Force state to LISTEN */
    mov     w0, #TCPS_LISTEN
    strb    w0, [x19, #TCONN_STATE]

    mov     w0, #54
    strh    w0, [x19, #TCONN_RTXLEN]

    /* Call tcp_retransmit_cb(conn) */
    mov     x0, x19
    bl      tcp_retransmit_cb

    /* Verify mock was NOT called */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_tcp_rcsl

    ldr     x0, =name_tcp_rcsl
    bl      test_pass
    b       .Ldone_tcp_rcsl
.Lfail_tcp_rcsl:
    ldr     x0, =name_tcp_rcsl
    bl      test_fail
.Ldone_tcp_rcsl:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
    .ltorg

/* ========================================================================
 * test_tcp_rtx_cb_no_send_fn — Retransmit callback with send_fn == NULL
 *
 * Active conn, RTXCOUNT < MAX, but send_fn not set up → should return safely
 * ======================================================================== */
test_tcp_rtx_cb_no_send_fn:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rcnsf
    mov     x19, x0                 /* conn */

    /* Send 5 bytes to populate retransmit buffer */
    mov     x0, x19
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_rcnsf

    /* Set send_fn to NULL (clear send context) */
    mov     x0, #0
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0                  /* send_fn = NULL */
    bl      tcp_set_send_ctx

    /* Reset mock counter to verify no send */
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    /* Call tcp_retransmit_cb(conn) — should bail out at send_fn NULL check */
    mov     x0, x19
    bl      tcp_retransmit_cb

    /* Verify mock was NOT called */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_tcp_rcnsf

    /* Verify state is still ESTABLISHED (not closed) */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_rcnsf

    ldr     x0, =name_tcp_rcnsf
    bl      test_pass
    b       .Ldone_tcp_rcnsf
.Lfail_tcp_rcnsf:
    ldr     x0, =name_tcp_rcnsf
    bl      test_fail
.Ldone_tcp_rcnsf:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
    .ltorg

/* ========================================================================
 * test_tcp_snd_una_future_ack — ACK beyond SND_NXT is ignored
 *
 * Handshake → tcp_send 5 bytes → ACK with seg_ack = ISN+100 (> SND_NXT) →
 * verify SND_UNA unchanged (still ISN+1)
 * ======================================================================== */
test_tcp_snd_una_future_ack:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_sufa
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Send 5 bytes → SND_NXT = ISN+6 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_sufa

    /* Record SND_UNA before (should be ISN+1) */
    ldr     w0, [x21, #TCONN_SND_UNA]
    add     w1, w22, #1
    cmp     w0, w1
    b.ne    .Lfail_tcp_sufa

    /* Send ACK with seg_ack = ISN+100 (way past SND_NXT) */
    ldr     x0, =tcp_test_buf3
    mov     w1, #0                  /* no payload */
    mov     w2, #0
    mov     w3, #2                  /* SEQ = peer's seq */
    add     w4, w22, #100           /* ACK = ISN+100 (bogus) */
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf3
    mov     w1, #54
    bl      tcp_handle

    /* Verify SND_UNA is still ISN+1 (not advanced) */
    ldr     w0, [x21, #TCONN_SND_UNA]
    add     w1, w22, #1
    cmp     w0, w1
    b.ne    .Lfail_tcp_sufa

    ldr     x0, =name_tcp_sufa
    bl      test_pass
    b       .Ldone_tcp_sufa
.Lfail_tcp_sufa:
    ldr     x0, =name_tcp_sufa
    bl      test_fail
.Ldone_tcp_sufa:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_listen_port — tcp_listen(80) sets slot to LISTEN with correct port
 * ======================================================================== */
test_tcp_listen_port:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Return value should be slot 0 */
    cmp     w0, #0
    b.ne    .Lfail_tcp_lp

    /* Verify slot 0 state = LISTEN */
    ldr     x0, =tcp_conn_table
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_LISTEN
    b.ne    .Lfail_tcp_lp

    /* Verify slot 0 lport = 0x5000 (port 80 NBO) */
    ldrh    w1, [x0, #TCONN_LPORT]
    mov     w2, #0x5000
    cmp     w1, w2
    b.ne    .Lfail_tcp_lp

    ldr     x0, =name_tcp_lp
    bl      test_pass
    b       .Ldone_tcp_lp
.Lfail_tcp_lp:
    ldr     x0, =name_tcp_lp
    bl      test_fail
.Ldone_tcp_lp:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_listen_multi — tcp_listen on two ports uses distinct slots
 * ======================================================================== */
test_tcp_listen_multi:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen
    mov     w19, w0                 /* w19 = slot for port 80 */

    mov     w0, #8080
    bl      tcp_listen
    mov     w20, w0                 /* w20 = slot for port 8080 */

    /* Both should succeed (>= 0) */
    cmn     w19, #1
    b.eq    .Lfail_tcp_lm
    cmn     w20, #1
    b.eq    .Lfail_tcp_lm

    /* Slots must be different */
    cmp     w19, w20
    b.eq    .Lfail_tcp_lm

    /* Verify port 8080 slot: state=LISTEN, lport=0x901F (8080 NBO) */
    ldr     x0, =tcp_conn_table
    add     x0, x0, x20, lsl #TCONN_SHIFT  /* slot * TCONN_SIZE */
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_LISTEN
    b.ne    .Lfail_tcp_lm
    ldrh    w1, [x0, #TCONN_LPORT]
    mov     w2, #0x901F             /* 8080 = 0x1F90, NBO as LE = 0x901F */
    cmp     w1, w2
    b.ne    .Lfail_tcp_lm

    ldr     x0, =name_tcp_lm
    bl      test_pass
    b       .Ldone_tcp_lm
.Lfail_tcp_lm:
    ldr     x0, =name_tcp_lm
    bl      test_fail
.Ldone_tcp_lm:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_listen_full — Fill all 16 slots, verify tcp_listen returns -1
 * ======================================================================== */
test_tcp_listen_full:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Fill all 16 slots with LISTEN on ports 1..16 */
    mov     w19, #1
.Ltlf_fill:
    mov     w0, w19
    bl      tcp_listen
    cmn     w0, #1
    b.eq    .Lfail_tcp_lf           /* shouldn't fail yet */
    add     w19, w19, #1
    cmp     w19, #17
    b.lt    .Ltlf_fill

    /* Now table is full — next listen should return -1 */
    mov     w0, #9999
    bl      tcp_listen
    cmn     w0, #1
    b.ne    .Lfail_tcp_lf

    ldr     x0, =name_tcp_lf
    bl      test_pass
    b       .Ldone_tcp_lf
.Lfail_tcp_lf:
    ldr     x0, =name_tcp_lf
    bl      test_fail
.Ldone_tcp_lf:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_isn_different_tuples — Different 4-tuples produce different ISNs
 * ======================================================================== */
test_tcp_isn_different_tuples:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    /* Call with tuple A: lport=80, rport=12345, lip=10.0.2.15, rip=10.0.2.2 */
    mov     w0, #0x5000             /* port 80 NBO */
    mov     w1, #0x3930             /* port 12345 NBO (0x3039 → rev16 = 0x3930) */
    ldr     w2, =0x0F02000A        /* 10.0.2.15 NBO */
    ldr     w3, =0x0202000A        /* 10.0.2.2 NBO */
    bl      tcp_isn
    mov     w19, w0

    /* Call with tuple B: lport=80, rport=54321, lip=10.0.2.15, rip=10.0.2.2 */
    mov     w0, #0x5000
    mov     w1, #0x31D4             /* port 54321 = 0xD431, NBO LE = 0x31D4 */
    ldr     w2, =0x0F02000A
    ldr     w3, =0x0202000A
    bl      tcp_isn
    mov     w20, w0

    /* Results should differ */
    cmp     w19, w20
    b.eq    .Lfail_tcp_idt

    ldr     x0, =name_tcp_idt
    bl      test_pass
    b       .Ldone_tcp_idt
.Lfail_tcp_idt:
    ldr     x0, =name_tcp_idt
    bl      test_fail
.Ldone_tcp_idt:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_isn_same_tuple — Same 4-tuple in rapid succession produces
 * close results (time component only difference)
 * ======================================================================== */
test_tcp_isn_same_tuple:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init

    mov     w0, #0x5000
    mov     w1, #0x3930
    ldr     w2, =0x0F02000A
    ldr     w3, =0x0202000A
    bl      tcp_isn
    mov     w19, w0

    /* Same tuple again immediately */
    mov     w0, #0x5000
    mov     w1, #0x3930
    ldr     w2, =0x0F02000A
    ldr     w3, =0x0202000A
    bl      tcp_isn
    mov     w20, w0

    /* Difference should be small (< 1024 ticks given rapid succession) */
    sub     w0, w20, w19
    cmp     w0, #0
    b.lt    .Lfail_tcp_ist          /* shouldn't go backwards */
    cmp     w0, #1024
    b.hi    .Lfail_tcp_ist

    ldr     x0, =name_tcp_ist
    bl      test_pass
    b       .Ldone_tcp_ist
.Lfail_tcp_ist:
    ldr     x0, =name_tcp_ist
    bl      test_fail
.Ldone_tcp_ist:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_isn_nonzero — ISN is nonzero for typical inputs
 * ======================================================================== */
test_tcp_isn_nonzero:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    mov     w0, #0x5000
    mov     w1, #0x3930
    ldr     w2, =0x0F02000A
    ldr     w3, =0x0202000A
    bl      tcp_isn

    cbz     w0, .Lfail_tcp_inz

    ldr     x0, =name_tcp_inz
    bl      test_pass
    b       .Ldone_tcp_inz
.Lfail_tcp_inz:
    ldr     x0, =name_tcp_inz
    bl      test_fail
.Ldone_tcp_inz:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * ttcp_build_icmp_err — Build ICMP Destination Unreachable (type 3) frame
 *
 * Encapsulates a fake TCP segment from (our_ip:our_port → peer_ip:peer_port).
 * Frame layout: ETH(14) + IP(20) + ICMP(8) + encap_IP(20) + encap_TCP(8) = 70 bytes
 *
 * x0: buffer (must have 70+ bytes)
 * w1: our_port (NBO)
 * w2: peer_port (NBO)
 * w3: peer_ip (NBO)
 * Clobbers: x0-x5
 * ======================================================================== */
ttcp_build_icmp_err:
    /* Zero first 70 bytes */
    mov     x4, x0
    mov     w5, #70
.Lbie_zero:
    strb    wzr, [x4], #1
    subs    w5, w5, #1
    b.ne    .Lbie_zero

    /* ETH type = IPv4 */
    mov     w4, #0x0008             /* 0x0800 big-endian as LE halfword */
    strh    w4, [x0, #ETH_TYPE]

    /* IP: ver/ihl=0x45, proto=ICMP(1), totlen=56 (0x0038 BE) */
    mov     w4, #0x45
    strb    w4, [x0, #ETH_PAYLOAD]
    mov     w4, #0x3800             /* 56 in NBO as LE halfword */
    strh    w4, [x0, #(ETH_PAYLOAD + IP_TOTLEN)]
    mov     w4, #IP_PROTO_ICMP
    strb    w4, [x0, #(ETH_PAYLOAD + IP_PROTO)]
    /* IP src = peer (the router sending the ICMP error) */
    str     w3, [x0, #(ETH_PAYLOAD + IP_SRC)]
    /* IP dst = us */
    ldr     w4, =NET_IP_NBO
    str     w4, [x0, #(ETH_PAYLOAD + IP_DST)]

    /* ICMP: type=3 (dest unreachable), code=1 (host unreachable) */
    mov     w4, #ICMP_DEST_UNREACHABLE
    strb    w4, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_TYPE)]
    mov     w4, #1
    strb    w4, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]
    /* ICMP checksum = 0 (not verified by tcp_icmp_err) */
    /* 4 bytes unused/zero at offset 38..41 */

    /* Encapsulated IP header at offset 42 */
    mov     w4, #0x45
    strb    w4, [x0, #42]
    mov     w4, #6                  /* proto = TCP */
    strb    w4, [x0, #(42 + IP_PROTO)]
    /* Encap IP src = our IP (we sent the original) */
    ldr     w4, =NET_IP_NBO
    str     w4, [x0, #(42 + IP_SRC)]
    /* Encap IP dst = peer IP */
    str     w3, [x0, #(42 + IP_DST)]

    /* Encapsulated TCP header at offset 62: sport=our_port, dport=peer_port */
    strh    w1, [x0, #(62 + TCP_SPORT)]
    strh    w2, [x0, #(62 + TCP_DPORT)]
    ret

/* ========================================================================
 * test_tcp_icmp_err_match — ICMP type 3 on ESTABLISHED → soft error (stays ESTABLISHED)
 * ======================================================================== */
test_tcp_icmp_err_match:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    /* Perform handshake to get an ESTABLISHED connection */
    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_iem
    mov     x19, x0                 /* conn ptr */

    /* Build ICMP dest unreachable matching this connection */
    ldr     x0, =tcp_test_buf2
    ldrh    w1, [x19, #TCONN_LPORT]    /* our port NBO */
    ldrh    w2, [x19, #TCONN_RPORT]    /* peer port NBO */
    ldr     w3, [x19, #TCONN_RIP]      /* peer IP NBO */
    bl      ttcp_build_icmp_err

    /* Call tcp_icmp_err directly */
    ldr     x0, =tcp_test_buf2
    mov     w1, #70
    bl      tcp_icmp_err

    /* Verify return value = 0 */
    cbnz    w0, .Lfail_tcp_iem

    /* ESTABLISHED → soft error: connection stays ESTABLISHED (RFC 5461) */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_iem

    ldr     x0, =name_tcp_iem
    bl      test_pass
    b       .Ldone_tcp_iem
.Lfail_tcp_iem:
    ldr     x0, =name_tcp_iem
    bl      test_fail
.Ldone_tcp_iem:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_icmp_err_no_match — ICMP type 3 with non-matching tuple → no change
 * ======================================================================== */
test_tcp_icmp_err_no_match:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_ienm
    mov     x19, x0

    /* Build ICMP with wrong peer port (0x9999) */
    ldr     x0, =tcp_test_buf2
    ldrh    w1, [x19, #TCONN_LPORT]
    mov     w2, #0x9999             /* wrong rport */
    ldr     w3, [x19, #TCONN_RIP]
    bl      ttcp_build_icmp_err

    ldr     x0, =tcp_test_buf2
    mov     w1, #70
    bl      tcp_icmp_err

    /* Connection should still be ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_ienm

    ldr     x0, =name_tcp_ienm
    bl      test_pass
    b       .Ldone_tcp_ienm
.Lfail_tcp_ienm:
    ldr     x0, =name_tcp_ienm
    bl      test_fail
.Ldone_tcp_ienm:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_icmp_err_rtx_clear — ICMP error on SYN_RCVD clears retransmit state
 * ======================================================================== */
test_tcp_icmp_err_rtx_clear:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    /* SYN → SYN_RCVD (stop before completing handshake) */
    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
    b.ne    .Lfail_tcp_ierc

    /* Find SYN_RCVD connection */
    ldr     x19, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lierc_find:
    cbz     w3, .Lfail_tcp_ierc
    sub     w3, w3, #1
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_SYN_RCVD
    b.eq    .Lierc_found
    add     x19, x19, #TCONN_SIZE
    b       .Lierc_find
.Lierc_found:

    /* Verify retransmit state is present (SYN-ACK saved) */
    ldrh    w0, [x19, #TCONN_RTXLEN]
    cbz     w0, .Lfail_tcp_ierc

    /* Build matching ICMP error */
    ldr     x0, =tcp_test_buf2
    ldrh    w1, [x19, #TCONN_LPORT]
    ldrh    w2, [x19, #TCONN_RPORT]
    ldr     w3, [x19, #TCONN_RIP]
    bl      ttcp_build_icmp_err

    ldr     x0, =tcp_test_buf2
    mov     w1, #70
    bl      tcp_icmp_err

    /* Verify retransmit state cleared */
    ldrh    w0, [x19, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_ierc
    ldrb    w0, [x19, #TCONN_RTXCOUNT]
    cbnz    w0, .Lfail_tcp_ierc

    /* Verify state is CLOSED */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_ierc

    ldr     x0, =name_tcp_ierc
    bl      test_pass
    b       .Ldone_tcp_ierc
.Lfail_tcp_ierc:
    ldr     x0, =name_tcp_ierc
    bl      test_fail
.Ldone_tcp_ierc:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_icmp_err_short — ICMP frame too short → silently ignored
 * ======================================================================== */
test_tcp_icmp_err_short:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_ies
    mov     x19, x0

    /* Build matching ICMP error but pass short length */
    ldr     x0, =tcp_test_buf2
    ldrh    w1, [x19, #TCONN_LPORT]
    ldrh    w2, [x19, #TCONN_RPORT]
    ldr     w3, [x19, #TCONN_RIP]
    bl      ttcp_build_icmp_err

    /* Call with frame_len = 60 (less than minimum 70) */
    ldr     x0, =tcp_test_buf2
    mov     w1, #60
    bl      tcp_icmp_err

    /* Connection should still be ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_ies

    ldr     x0, =name_tcp_ies
    bl      test_pass
    b       .Ldone_tcp_ies
.Lfail_tcp_ies:
    ldr     x0, =name_tcp_ies
    bl      test_fail
.Ldone_tcp_ies:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_ts_syn_negotiate — SYN with TSopt → TS_ENABLED=1, TS_RECENT set
 *
 * Build a 66-byte SYN (14+20+32) with TCP timestamps option containing
 * TSval=0x12345678. After tcp_handle → SYN-ACK, verify the new connection
 * has TCONN_TS_ENABLED=1 and TCONN_TS_RECENT=0x12345678.
 * ======================================================================== */
test_tcp_ts_syn_negotiate:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Build SYN with TSopt in tcp_test_buf.
       Start from the 54-byte SYN template, then extend to 66 bytes. */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum      /* copy + fill checksum (we'll overwrite) */

    ldr     x19, =tcp_test_buf

    /* Set data offset to 0x80 (8 words = 32 bytes) */
    mov     w0, #0x80
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* Update IP total length: 52 (20+32) = 0x0034 BE */
    mov     w0, #0x3400
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Write options at offset 54 (ETH+IP+TCP_HDR_MIN):
       NOP(01) NOP(01) Kind(08) Len(0A) TSval(12345678) TSecr(00000000) */
    mov     w0, #0x01
    strb    w0, [x19, #54]         /* NOP */
    strb    w0, [x19, #55]         /* NOP */
    mov     w0, #0x08
    strb    w0, [x19, #56]         /* Kind = Timestamps */
    mov     w0, #0x0A
    strb    w0, [x19, #57]         /* Length = 10 */
    /* TSval = 0x12345678 (NBO) */
    mov     w0, #0x12
    strb    w0, [x19, #58]
    mov     w0, #0x34
    strb    w0, [x19, #59]
    mov     w0, #0x56
    strb    w0, [x19, #60]
    mov     w0, #0x78
    strb    w0, [x19, #61]
    /* TSecr = 0 (4 bytes already zero from fill) */

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum over 32 bytes */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #32                 /* TCP segment = 32 bytes */
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Call tcp_handle */
    mov     x0, x19
    mov     w1, #66
    bl      tcp_handle
    /* Should return > 0 (SYN-ACK) */
    cbz     w0, .Lfail_tcp_tssn

    /* Find the SYN_RCVD connection */
    ldr     x19, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ltssn_scan:
    cbz     w3, .Lfail_tcp_tssn
    sub     w3, w3, #1
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_SYN_RCVD
    b.eq    .Ltssn_found
    add     x19, x19, #TCONN_SIZE
    b       .Ltssn_scan
.Ltssn_found:
    /* Verify TS_ENABLED = 1 */
    ldrb    w0, [x19, #TCONN_TS_ENABLED]
    cmp     w0, #1
    b.ne    .Lfail_tcp_tssn

    /* Verify TS_RECENT = 0x12345678 (host order) */
    ldr     w0, [x19, #TCONN_TS_RECENT]
    ldr     w1, =0x12345678
    cmp     w0, w1
    b.ne    .Lfail_tcp_tssn

    ldr     x0, =name_tcp_tssn
    bl      test_pass
    b       .Ldone_tcp_tssn
.Lfail_tcp_tssn:
    ldr     x0, =name_tcp_tssn
    bl      test_fail
.Ldone_tcp_tssn:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_ts_syn_no_opt — SYN without TSopt → TS_ENABLED=0
 * ======================================================================== */
test_tcp_ts_syn_no_opt:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Build plain 54-byte SYN (no options) */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cbz     w0, .Lfail_tcp_tsno

    /* Find the SYN_RCVD connection */
    ldr     x19, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Ltsno_scan:
    cbz     w3, .Lfail_tcp_tsno
    sub     w3, w3, #1
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_SYN_RCVD
    b.eq    .Ltsno_found
    add     x19, x19, #TCONN_SIZE
    b       .Ltsno_scan
.Ltsno_found:
    /* Verify TS_ENABLED = 0 */
    ldrb    w0, [x19, #TCONN_TS_ENABLED]
    cbnz    w0, .Lfail_tcp_tsno

    ldr     x0, =name_tcp_tsno
    bl      test_pass
    b       .Ldone_tcp_tsno
.Lfail_tcp_tsno:
    ldr     x0, =name_tcp_tsno
    bl      test_fail
.Ldone_tcp_tsno:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_ts_reply_frame_size — TS-enabled conn → tcp_build_reply returns 66
 * ======================================================================== */
test_tcp_ts_reply_frame_size:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_trfs
    mov     x19, x0                 /* conn */

    /* Enable timestamps on this connection */
    mov     w0, #1
    strb    w0, [x19, #TCONN_TS_ENABLED]
    ldr     w0, =0x12345678
    str     w0, [x19, #TCONN_TS_RECENT]

    /* Build a reply frame (need a valid frame to swap addresses in) */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf      /* frame */
    mov     w1, #0                  /* SEQ */
    mov     w2, #0                  /* ACK */
    mov     w3, #TCP_ACK_FLAG      /* flags */
    mov     w4, #0                  /* window */
    mov     x5, x19                 /* conn → timestamps */
    bl      tcp_build_reply

    cmp     w0, #66
    b.ne    .Lfail_tcp_trfs

    ldr     x0, =name_tcp_trfs
    bl      test_pass
    b       .Ldone_tcp_trfs
.Lfail_tcp_trfs:
    ldr     x0, =name_tcp_trfs
    bl      test_fail
.Ldone_tcp_trfs:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_ts_reply_no_ts — TS-disabled conn → tcp_build_reply returns 54
 * ======================================================================== */
test_tcp_ts_reply_no_ts:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_trnt
    mov     x19, x0

    /* Ensure timestamps disabled */
    strb    wzr, [x19, #TCONN_TS_ENABLED]

    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #0
    mov     w2, #0
    mov     w3, #TCP_ACK_FLAG
    mov     w4, #0
    mov     x5, x19                 /* conn → no timestamps */
    bl      tcp_build_reply

    cmp     w0, #54
    b.ne    .Lfail_tcp_trnt

    ldr     x0, =name_tcp_trnt
    bl      test_pass
    b       .Ldone_tcp_trnt
.Lfail_tcp_trnt:
    ldr     x0, =name_tcp_trnt
    bl      test_fail
.Ldone_tcp_trnt:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_ts_build_frame_size — TS-enabled conn → tcp_build_frame returns 66+payload
 * ======================================================================== */
test_tcp_ts_build_frame_size:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tbfs
    mov     x19, x0

    /* Enable timestamps */
    mov     w0, #1
    strb    w0, [x19, #TCONN_TS_ENABLED]
    ldr     w0, =0x12345678
    str     w0, [x19, #TCONN_TS_RECENT]

    /* Build frame with 5-byte payload */
    mov     x0, x19                 /* conn */
    ldr     x1, =tcp_send_test_buf  /* frame buf */
    mov     w2, #TCP_PSH_ACK        /* flags */
    ldr     x3, =tcp_send_payload   /* payload "World" */
    mov     w4, #5                  /* payload_len */
    bl      tcp_build_frame

    /* Expected: 66 + 5 = 71 */
    cmp     w0, #71
    b.ne    .Lfail_tcp_tbfs

    ldr     x0, =name_tcp_tbfs
    bl      test_pass
    b       .Ldone_tcp_tbfs
.Lfail_tcp_tbfs:
    ldr     x0, =name_tcp_tbfs
    bl      test_fail
.Ldone_tcp_tbfs:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * Helper: ttcp_build_ts_data_frame — Build data frame with TCP Timestamps option
 *
 * x0: dest buffer (must hold 71 bytes)
 * w1: ISN (host order, for ACK = ISN+1)
 * w2: TSval (host order)
 * Returns: w0 = 71 (frame length: 66 header + 5 payload)
 * Clobbers: x0-x6, x19-x24, x30
 * ======================================================================== */
ttcp_build_ts_data_frame:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* dest buf */
    mov     w20, w1                 /* ISN host */
    mov     w21, w2                 /* TSval host */

    /* Copy first 54 bytes from data template (ETH+IP+TCP base) */
    ldr     x0, =tcp_data_template
    mov     x1, x19
    mov     w2, #54
.Lbtdf_copy_hdr:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lbtdf_copy_hdr

    /* Insert TSopt at TCP+20 (frame offset 54): NOP NOP Kind8 Len10 TSval TSecr */
    mov     w0, #0x01
    strb    w0, [x19, #54]          /* NOP */
    strb    w0, [x19, #55]          /* NOP */
    mov     w0, #0x08
    strb    w0, [x19, #56]          /* Kind = Timestamps */
    mov     w0, #0x0A
    strb    w0, [x19, #57]          /* Length = 10 */
    rev     w0, w21                 /* TSval → NBO */
    str     w0, [x19, #58]          /* TSval */
    str     wzr, [x19, #62]         /* TSecr = 0 */

    /* Copy 5-byte payload ("Hello") from data template offset 54 */
    ldr     x0, =tcp_data_template
    add     x0, x0, #54
    add     x1, x19, #66            /* payload at offset 66 */
    mov     w2, #5
.Lbtdf_copy_payload:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lbtdf_copy_payload

    /* Set doff = 0x80 (8 words = 32 bytes) */
    mov     w0, #0x80
    strb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* IP totlen = 57 (0x0039): 20 + 32 + 5 */
    mov     w0, #0x0039
    rev16   w0, w0
    uxth    w0, w0
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Set ACK = rev(ISN+1) */
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum (section_len = 32 + 5 = 37) */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #37
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     w0, #71

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_ts_paws_accept — TSval >= TS_RECENT → segment accepted
 * ======================================================================== */
test_tcp_ts_paws_accept:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tpa
    mov     x19, x0                 /* conn */
    mov     w20, w1                 /* ISN */

    /* Enable timestamps, set TS_RECENT = 1000 */
    mov     w0, #1
    strb    w0, [x19, #TCONN_TS_ENABLED]
    mov     w0, #1000
    str     w0, [x19, #TCONN_TS_RECENT]

    /* Save RCV_NXT before */
    ldr     w21, [x19, #TCONN_RCV_NXT]

    /* Build data frame with TSval = 2000 (> 1000 → should pass PAWS) */
    ldr     x0, =tcp_test_buf
    mov     w1, w20                 /* ISN */
    mov     w2, #2000               /* TSval */
    bl      ttcp_build_ts_data_frame

    /* Send it */
    ldr     x0, =tcp_test_buf
    mov     w1, #71
    bl      tcp_handle

    /* Segment should be accepted: RCV_NXT should advance by 5 */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    add     w1, w21, #5
    cmp     w0, w1
    b.ne    .Lfail_tcp_tpa

    ldr     x0, =name_tcp_tpa
    bl      test_pass
    b       .Ldone_tcp_tpa
.Lfail_tcp_tpa:
    ldr     x0, =name_tcp_tpa
    bl      test_fail
.Ldone_tcp_tpa:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_ts_paws_reject — TSval < TS_RECENT → segment dropped
 * ======================================================================== */
test_tcp_ts_paws_reject:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tpr
    mov     x19, x0                 /* conn */
    mov     w20, w1                 /* ISN */

    /* Enable timestamps, set TS_RECENT = 5000 */
    mov     w0, #1
    strb    w0, [x19, #TCONN_TS_ENABLED]
    ldr     w0, =5000
    str     w0, [x19, #TCONN_TS_RECENT]

    /* Save RCV_NXT before */
    ldr     w21, [x19, #TCONN_RCV_NXT]

    /* Build data frame with TSval = 1000 (< 5000 → should fail PAWS) */
    ldr     x0, =tcp_test_buf
    mov     w1, w20                 /* ISN */
    mov     w2, #1000               /* TSval */
    bl      ttcp_build_ts_data_frame

    /* Send it */
    ldr     x0, =tcp_test_buf
    mov     w1, #71
    bl      tcp_handle

    /* Segment should be dropped: RCV_NXT unchanged */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    cmp     w0, w21
    b.ne    .Lfail_tcp_tpr

    ldr     x0, =name_tcp_tpr
    bl      test_pass
    b       .Ldone_tcp_tpr
.Lfail_tcp_tpr:
    ldr     x0, =name_tcp_tpr
    bl      test_fail
.Ldone_tcp_tpr:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_ts_recent_update — After accepting data, TS_RECENT updated
 * ======================================================================== */
test_tcp_ts_recent_update:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_tru
    mov     x19, x0                 /* conn */
    mov     w20, w1                 /* ISN */

    /* Enable timestamps, set TS_RECENT = 1000 */
    mov     w0, #1
    strb    w0, [x19, #TCONN_TS_ENABLED]
    mov     w0, #1000
    str     w0, [x19, #TCONN_TS_RECENT]

    /* Build data frame with TSval = 3000 */
    ldr     x0, =tcp_test_buf
    mov     w1, w20                 /* ISN */
    ldr     w2, =3000               /* TSval */
    bl      ttcp_build_ts_data_frame

    /* Send it */
    ldr     x0, =tcp_test_buf
    mov     w1, #71
    bl      tcp_handle

    /* TS_RECENT should now be 3000 */
    ldr     w0, [x19, #TCONN_TS_RECENT]
    ldr     w1, =3000
    cmp     w0, w1
    b.ne    .Lfail_tcp_tru

    ldr     x0, =name_tcp_tru
    bl      test_pass
    b       .Ldone_tcp_tru
.Lfail_tcp_tru:
    ldr     x0, =name_tcp_tru
    bl      test_fail
.Ldone_tcp_tru:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_icmp_err_lport — ICMP type 3 with wrong lport → no state change
 * ======================================================================== */
test_tcp_icmp_err_lport:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_ielp
    mov     x19, x0

    /* Build ICMP with wrong lport (0x8888) but correct rport and rip */
    ldr     x0, =tcp_test_buf2
    mov     w1, #0x8888             /* wrong lport */
    ldrh    w2, [x19, #TCONN_RPORT]
    ldr     w3, [x19, #TCONN_RIP]
    bl      ttcp_build_icmp_err

    ldr     x0, =tcp_test_buf2
    mov     w1, #70
    bl      tcp_icmp_err

    /* Connection should still be ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_ielp

    ldr     x0, =name_tcp_ielp
    bl      test_pass
    b       .Ldone_tcp_ielp
.Lfail_tcp_ielp:
    ldr     x0, =name_tcp_ielp
    bl      test_fail
.Ldone_tcp_ielp:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_icmp_err_rip — ICMP type 3 with wrong peer IP → no state change
 * ======================================================================== */
test_tcp_icmp_err_rip:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_ierip
    mov     x19, x0

    /* Build ICMP with correct lport/rport but wrong peer IP */
    ldr     x0, =tcp_test_buf2
    ldrh    w1, [x19, #TCONN_LPORT]
    ldrh    w2, [x19, #TCONN_RPORT]
    ldr     w3, =0xC0A80101         /* 192.168.1.1 NBO — wrong */
    bl      ttcp_build_icmp_err

    ldr     x0, =tcp_test_buf2
    mov     w1, #70
    bl      tcp_icmp_err

    /* Connection should still be ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_ierip

    ldr     x0, =name_tcp_ierip
    bl      test_pass
    b       .Ldone_tcp_ierip
.Lfail_tcp_ierip:
    ldr     x0, =name_tcp_ierip
    bl      test_fail
.Ldone_tcp_ierip:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_icmp_err_proto_unreach — code=2 on ESTABLISHED → hard close
 * ======================================================================== */
.global test_tcp_icmp_err_proto_unreach
test_tcp_icmp_err_proto_unreach:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_iepu
    mov     x19, x0

    ldr     x0, =tcp_test_buf2
    ldrh    w1, [x19, #TCONN_LPORT]
    ldrh    w2, [x19, #TCONN_RPORT]
    ldr     w3, [x19, #TCONN_RIP]
    bl      ttcp_build_icmp_err

    /* Overwrite ICMP code to 2 (Protocol Unreachable) */
    ldr     x0, =tcp_test_buf2
    mov     w1, #ICMP_CODE_PROTO_UNREACH
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]

    mov     w1, #70
    bl      tcp_icmp_err

    /* ESTABLISHED + code=2 → hard close (CLOSED) */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_iepu

    ldr     x0, =name_tcp_iepu
    bl      test_pass
    b       .Ldone_tcp_iepu
.Lfail_tcp_iepu:
    ldr     x0, =name_tcp_iepu
    bl      test_fail
.Ldone_tcp_iepu:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_icmp_err_port_unreach — code=3 on ESTABLISHED → hard close
 * ======================================================================== */
.global test_tcp_icmp_err_port_unreach
test_tcp_icmp_err_port_unreach:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_ieptu
    mov     x19, x0

    ldr     x0, =tcp_test_buf2
    ldrh    w1, [x19, #TCONN_LPORT]
    ldrh    w2, [x19, #TCONN_RPORT]
    ldr     w3, [x19, #TCONN_RIP]
    bl      ttcp_build_icmp_err

    /* Overwrite ICMP code to 3 (Port Unreachable) */
    ldr     x0, =tcp_test_buf2
    mov     w1, #ICMP_CODE_PORT_UNREACH
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + ICMP_CODE)]

    mov     w1, #70
    bl      tcp_icmp_err

    /* ESTABLISHED + code=3 → hard close (CLOSED) */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_ieptu

    ldr     x0, =name_tcp_ieptu
    bl      test_pass
    b       .Ldone_tcp_ieptu
.Lfail_tcp_ieptu:
    ldr     x0, =name_tcp_ieptu
    bl      test_fail
.Ldone_tcp_ieptu:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_tsopt_exhaust — Options without Kind=8 → not found (loop exhaustion)
 *
 * Build a 66-byte SYN with doff=0x80 (32 bytes TCP header).
 * Options: MSS(Kind=2, Len=4, val=0x05B4) + 8 bytes NOP padding.
 * tcp_parse_tsopt should return w1=0.
 * ======================================================================== */
test_tcp_tsopt_exhaust:
    stp     x29, x30, [sp, #-16]!

    /* Build frame in tcp_test_buf: copy 54-byte SYN, then add options */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf

    /* Set doff=0x80 (32 bytes) */
    mov     w1, #0x80
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* Options at frame offset 54: MSS(02 04 05 B4) + NOP(01) x8 */
    mov     w1, #0x02
    strb    w1, [x0, #54]          /* Kind = MSS */
    mov     w1, #0x04
    strb    w1, [x0, #55]          /* Length = 4 */
    mov     w1, #0x05
    strb    w1, [x0, #56]          /* MSS high byte */
    mov     w1, #0xB4
    strb    w1, [x0, #57]          /* MSS low byte */
    /* Fill remaining 8 bytes with NOP */
    mov     w1, #0x01
    strb    w1, [x0, #58]
    strb    w1, [x0, #59]
    strb    w1, [x0, #60]
    strb    w1, [x0, #61]
    strb    w1, [x0, #62]
    strb    w1, [x0, #63]
    strb    w1, [x0, #64]
    strb    w1, [x0, #65]

    /* Call tcp_parse_tsopt(frame, 32) */
    mov     w1, #32
    bl      tcp_parse_tsopt

    /* Should return w1=0 (not found) */
    cbnz    w1, .Lfail_tcp_tse

    ldr     x0, =name_tcp_tse
    bl      test_pass
    b       .Ldone_tcp_tse
.Lfail_tcp_tse:
    ldr     x0, =name_tcp_tse
    bl      test_fail
.Ldone_tcp_tse:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_tsopt_eol — Options with EOL (Kind=0) before TSopt → not found
 *
 * Options: NOP(01) EOL(00) — parser hits EOL, stops, returns not-found.
 * ======================================================================== */
test_tcp_tsopt_eol:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf

    /* Set doff=0x60 (24 bytes = 4 bytes of options) */
    mov     w1, #0x60
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* Options: NOP(01) EOL(00) NOP(01) NOP(01) */
    mov     w1, #0x01
    strb    w1, [x0, #54]          /* NOP */
    strb    wzr, [x0, #55]         /* EOL */
    strb    w1, [x0, #56]          /* NOP (after EOL, should not be reached) */
    strb    w1, [x0, #57]          /* NOP */

    /* Call tcp_parse_tsopt(frame, 24) */
    mov     w1, #24
    bl      tcp_parse_tsopt

    /* Should return w1=0 (not found due to EOL) */
    cbnz    w1, .Lfail_tcp_tseol

    ldr     x0, =name_tcp_tseol
    bl      test_pass
    b       .Ldone_tcp_tseol
.Lfail_tcp_tseol:
    ldr     x0, =name_tcp_tseol
    bl      test_fail
.Ldone_tcp_tseol:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_tsopt_trunc — Kind byte at last option position, no room for length
 *
 * doff=0x60 (24 bytes = 4 option bytes). Options: NOP NOP NOP Kind=8
 * Kind=8 is at position 3 of 4, no room for length byte → not found.
 * ======================================================================== */
test_tcp_tsopt_trunc:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf

    /* Set doff=0x60 (24 bytes) */
    mov     w1, #0x60
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* Options: NOP NOP NOP Kind=8 */
    mov     w1, #0x01
    strb    w1, [x0, #54]
    strb    w1, [x0, #55]
    strb    w1, [x0, #56]
    mov     w1, #0x08
    strb    w1, [x0, #57]          /* Kind=8 at last position */

    /* Call tcp_parse_tsopt(frame, 24) */
    mov     w1, #24
    bl      tcp_parse_tsopt

    /* Should return w1=0 (truncated) */
    cbnz    w1, .Lfail_tcp_tstr

    ldr     x0, =name_tcp_tstr
    bl      test_pass
    b       .Ldone_tcp_tstr
.Lfail_tcp_tstr:
    ldr     x0, =name_tcp_tstr
    bl      test_fail
.Ldone_tcp_tstr:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_tsopt_badlen — Option with length < 2 → not found (malformed)
 *
 * Options: Kind=8 Len=1 — length < 2 triggers malformed check.
 * ======================================================================== */
test_tcp_tsopt_badlen:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf

    /* Set doff=0x60 (24 bytes = 4 option bytes) */
    mov     w1, #0x60
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* Options: Kind=8 Len=1 (malformed) + padding */
    mov     w1, #0x08
    strb    w1, [x0, #54]          /* Kind = Timestamps */
    mov     w1, #0x01
    strb    w1, [x0, #55]          /* Length = 1 (< 2, malformed) */
    strb    wzr, [x0, #56]
    strb    wzr, [x0, #57]

    /* Call tcp_parse_tsopt(frame, 24) */
    mov     w1, #24
    bl      tcp_parse_tsopt

    /* Should return w1=0 (malformed) */
    cbnz    w1, .Lfail_tcp_tsbl

    ldr     x0, =name_tcp_tsbl
    bl      test_pass
    b       .Ldone_tcp_tsbl
.Lfail_tcp_tsbl:
    ldr     x0, =name_tcp_tsbl
    bl      test_fail
.Ldone_tcp_tsbl:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_tsopt_skip — Non-TS variable-length option before TSopt → found
 *
 * Options: MSS(Kind=2 Len=4 05B4) NOP NOP Kind=8 Len=10 TSval TSecr
 * Parser should skip MSS, skip NOPs, find TSopt.
 * doff=0xA0 (40 bytes = 20 option bytes)
 * ======================================================================== */
test_tcp_tsopt_skip:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf

    /* Set doff=0x90 (36 bytes = 16 option bytes) */
    mov     w1, #0x90
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* Option bytes at offset 54:
       MSS: 02 04 05 B4
       NOP: 01
       NOP: 01
       TSopt: 08 0A AA BB CC DD 00 00 00 00 */
    mov     w1, #0x02
    strb    w1, [x0, #54]          /* MSS Kind */
    mov     w1, #0x04
    strb    w1, [x0, #55]          /* MSS Length */
    mov     w1, #0x05
    strb    w1, [x0, #56]          /* MSS value high */
    mov     w1, #0xB4
    strb    w1, [x0, #57]          /* MSS value low */
    mov     w1, #0x01
    strb    w1, [x0, #58]          /* NOP */
    strb    w1, [x0, #59]          /* NOP */
    mov     w1, #0x08
    strb    w1, [x0, #60]          /* TS Kind */
    mov     w1, #0x0A
    strb    w1, [x0, #61]          /* TS Length */
    /* TSval = 0xAABBCCDD (NBO) */
    mov     w1, #0xAA
    strb    w1, [x0, #62]
    mov     w1, #0xBB
    strb    w1, [x0, #63]
    mov     w1, #0xCC
    strb    w1, [x0, #64]
    mov     w1, #0xDD
    strb    w1, [x0, #65]
    /* TSecr = 0 */
    strb    wzr, [x0, #66]
    strb    wzr, [x0, #67]
    strb    wzr, [x0, #68]
    strb    wzr, [x0, #69]

    /* Call tcp_parse_tsopt(frame, 36) */
    mov     w1, #36
    bl      tcp_parse_tsopt

    /* Should return w1=1 (found), w0=TSval as loaded by ldr (LE word) */
    cmp     w1, #1
    b.ne    .Lfail_tcp_tssk
    ldr     w2, =0xDDCCBBAA         /* AA BB CC DD in memory → 0xDDCCBBAA via ldr */
    cmp     w0, w2
    b.ne    .Lfail_tcp_tssk

    ldr     x0, =name_tcp_tssk
    bl      test_pass
    b       .Ldone_tcp_tssk
.Lfail_tcp_tssk:
    ldr     x0, =name_tcp_tssk
    bl      test_fail
.Ldone_tcp_tssk:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_tsopt_wrong_tslen — Kind=8 with wrong Length (6 != 10) → skip
 *
 * Options: Kind=8 Len=6 (wrong) + padding → parser skips, returns not found.
 * doff=0x70 (28 bytes = 8 option bytes)
 * ======================================================================== */
test_tcp_tsopt_wrong_tslen:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf

    /* Set doff=0x70 (28 bytes = 8 option bytes) */
    mov     w1, #0x70
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* Options: Kind=8 Len=6 (wrong) val(4 bytes) + 2 NOP */
    mov     w1, #0x08
    strb    w1, [x0, #54]          /* Kind = Timestamps */
    mov     w1, #0x06
    strb    w1, [x0, #55]          /* Length = 6 (wrong, should be 10) */
    strb    wzr, [x0, #56]
    strb    wzr, [x0, #57]
    strb    wzr, [x0, #58]
    strb    wzr, [x0, #59]
    mov     w1, #0x01
    strb    w1, [x0, #60]          /* NOP */
    strb    w1, [x0, #61]          /* NOP */

    /* Call tcp_parse_tsopt(frame, 28) */
    mov     w1, #28
    bl      tcp_parse_tsopt

    /* Should return w1=0 (not found — Kind=8 skipped due to wrong length) */
    cbnz    w1, .Lfail_tcp_tswt

    ldr     x0, =name_tcp_tswt
    bl      test_pass
    b       .Ldone_tcp_tswt
.Lfail_tcp_tswt:
    ldr     x0, =name_tcp_tswt
    bl      test_fail
.Ldone_tcp_tswt:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_paws_no_tsopt — TS_ENABLED but segment has no TSopt → accepted
 *
 * Verifies that when TCONN_TS_ENABLED=1 but the incoming data segment
 * has a plain 20-byte TCP header (no options), PAWS is skipped and the
 * segment is still processed normally.
 * ======================================================================== */
test_tcp_paws_no_tsopt:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pnt
    mov     x19, x0                 /* conn */
    mov     w20, w1                 /* ISN */

    /* Enable timestamps on the connection */
    mov     w0, #1
    strb    w0, [x19, #TCONN_TS_ENABLED]
    mov     w0, #1000
    str     w0, [x19, #TCONN_TS_RECENT]

    /* Save RCV_NXT before */
    ldr     w21, [x19, #TCONN_RCV_NXT]

    /* Build a plain data frame (no TSopt, doff=0x50) using ttcp_build_data_frame */
    ldr     x0, =tcp_test_buf
    mov     w1, #5                  /* 5-byte payload */
    mov     w2, #0x41               /* fill with 'A' */
    ldr     w3, [x19, #TCONN_RCV_NXT] /* SEQ = RCV_NXT */
    add     w4, w20, #1             /* ACK = ISN+1 */
    bl      ttcp_build_data_frame

    mov     w22, w0                 /* frame_len */

    /* Send it */
    ldr     x0, =tcp_test_buf
    mov     w1, w22
    bl      tcp_handle

    /* Segment should be accepted: RCV_NXT should advance by 5 */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    add     w1, w21, #5
    cmp     w0, w1
    b.ne    .Lfail_tcp_pnt

    ldr     x0, =name_tcp_pnt
    bl      test_pass
    b       .Ldone_tcp_pnt
.Lfail_tcp_pnt:
    ldr     x0, =name_tcp_pnt
    bl      test_fail
.Ldone_tcp_pnt:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_tsopt_trunc_ts — Kind=8 Len=10 but not enough bytes remaining
 *
 * doff=0x70 (28 bytes = 8 option bytes). Options start with Kind=8 Len=10,
 * but only 8 bytes of option space exist. ptr+10 > end triggers line 1914.
 * This is distinct from tsopt_trunc which tests ptr+1 >= end (line 1898).
 * ======================================================================== */
test_tcp_tsopt_trunc_ts:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf

    /* Set doff=0x70 (28 bytes = 8 option bytes) */
    mov     w1, #0x70
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]

    /* Options: Kind=8 Len=10 + 6 zero-fill bytes */
    mov     w1, #0x08
    strb    w1, [x0, #54]          /* Kind = Timestamps */
    mov     w1, #0x0A
    strb    w1, [x0, #55]          /* Length = 10 */
    strb    wzr, [x0, #56]
    strb    wzr, [x0, #57]
    strb    wzr, [x0, #58]
    strb    wzr, [x0, #59]
    strb    wzr, [x0, #60]
    strb    wzr, [x0, #61]

    /* Call tcp_parse_tsopt(frame, 28) — 8 option bytes, TSopt needs 10 */
    mov     w1, #28
    bl      tcp_parse_tsopt

    /* Should return w1=0 (truncated TSopt) */
    cbnz    w1, .Lfail_tcp_tstt

    ldr     x0, =name_tcp_tstt
    bl      test_pass
    b       .Ldone_tcp_tstt
.Lfail_tcp_tstt:
    ldr     x0, =name_tcp_tstt
    bl      test_fail
.Ldone_tcp_tstt:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_cwnd_grow — cwnd grows on new ACK (slow start: cwnd += MSS)
 *
 * 1. Handshake → ESTABLISHED (cwnd = 536, ssthresh = 256 KB)
 * 2. tcp_send 5 bytes → frame built
 * 3. Inject ACK acknowledging those bytes → cwnd grows to 536+536 = 1072
 * ======================================================================== */
test_tcp_cwnd_grow:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_cwg
    mov     x19, x0                 /* conn */
    mov     w20, w1                 /* ISN */

    /* Verify initial cwnd = 536 (default MSS) */
    ldr     w0, [x19, #TCONN_CWND]
    cmp     w0, #TCP_DEFAULT_MSS
    b.ne    .Lfail_tcp_cwg

    /* Send 5 bytes */
    mov     x0, x19
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_cwg

    /* Inject ACK for the 5 bytes: ACK = ISN + 1 + 5 = ISN + 6 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x21, =tcp_test_buf
    add     w0, w20, #6
    rev     w0, w0
    str     w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    /* Set SEQ = 2 (peer's next byte after handshake) */
    mov     w0, #2
    rev     w0, w0
    str     w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x21
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x21
    mov     w1, #54
    bl      tcp_handle

    /* cwnd should have grown: 536 + 536 = 1072 */
    ldr     w0, [x19, #TCONN_CWND]
    mov     w1, #1072
    cmp     w0, w1
    b.ne    .Lfail_tcp_cwg

    ldr     x0, =name_tcp_cwg
    bl      test_pass
    b       .Ldone_tcp_cwg

.Lfail_tcp_cwg:
    ldr     x0, =name_tcp_cwg
    bl      test_fail

.Ldone_tcp_cwg:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_cwnd_rtx_reset — retransmit timeout resets cwnd to MSS
 *
 * 1. Handshake → ESTABLISHED
 * 2. Manually set cwnd=2000, ssthresh=65535
 * 3. tcp_send → saves retransmit frame
 * 4. Call tcp_retransmit_cb → cwnd should reset to MSS (536)
 *    ssthresh = max(2000/2, 2*536) = max(1000, 1072) = 1072
 * ======================================================================== */
test_tcp_cwnd_rtx_reset:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_crr
    mov     x19, x0                 /* conn */

    /* Set cwnd = 2000 */
    mov     w0, #2000
    str     w0, [x19, #TCONN_CWND]
    mov     w0, #0xFFFF
    str     w0, [x19, #TCONN_SSTHRESH]

    /* Send 5 bytes to create retransmit state */
    mov     x0, x19
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_crr

    /* Call tcp_retransmit_cb(conn) */
    mov     x0, x19
    bl      tcp_retransmit_cb

    /* cwnd should be MSS (536) */
    ldr     w0, [x19, #TCONN_CWND]
    cmp     w0, #TCP_DEFAULT_MSS
    b.ne    .Lfail_tcp_crr

    /* ssthresh = max(2000/2, 2*536) = max(1000, 1072) = 1072 */
    ldr     w0, [x19, #TCONN_SSTHRESH]
    mov     w1, #1072
    cmp     w0, w1
    b.ne    .Lfail_tcp_crr

    ldr     x0, =name_tcp_crr
    bl      test_pass
    b       .Ldone_tcp_crr

.Lfail_tcp_crr:
    ldr     x0, =name_tcp_crr
    bl      test_fail

.Ldone_tcp_crr:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_cwnd_gate — send gated by cwnd (lower cwnd blocks large sends)
 *
 * 1. Handshake → ESTABLISHED
 * 2. Set cwnd=10, SND_WND=2000
 * 3. tcp_send 11 bytes → rejected (exceeds cwnd)
 * 4. tcp_send 5 bytes → accepted (within cwnd)
 * ======================================================================== */
test_tcp_cwnd_gate:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_cwga
    mov     x19, x0                 /* conn */

    /* Set cwnd=10, SND_WND=2000 */
    mov     w0, #10
    str     w0, [x19, #TCONN_CWND]
    mov     w0, #2000
    str     w0, [x19, #TCONN_SND_WND]

    /* tcp_send 11 bytes → should fail (exceeds cwnd=10) */
    mov     x0, x19
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #11
    bl      tcp_send
    cbnz    w0, .Lfail_tcp_cwga

    /* tcp_send 5 bytes → should succeed (within cwnd=10) */
    mov     x0, x19
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cmp     w0, #59
    b.ne    .Lfail_tcp_cwga

    /* tcp_send_ready should return 10 (min of SND_WND=2000-5=1995, cwnd=10, peer_mss=536)) */
    /* Actually cwnd=10 is smallest, but SND_WND was decremented to 1995 by send,
       and rtx pending gates send_ready to 0. Clear rtx first. */
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     x0, x19
    bl      tcp_send_ready
    cmp     w0, #10
    b.ne    .Lfail_tcp_cwga

    ldr     x0, =name_tcp_cwga
    bl      test_pass
    b       .Ldone_tcp_cwga

.Lfail_tcp_cwga:
    ldr     x0, =name_tcp_cwga
    bl      test_fail

.Ldone_tcp_cwga:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_ooo_merge — OOO segment buffered, gap fill merges
 *
 * 1. Handshake → ESTABLISHED (RCV_NXT=2)
 * 2. Send data SEQ=7 (5-byte gap) → OOO buffered, dup ACK, OOO_COUNT=1
 * 3. Send data SEQ=2 (fills gap) → accepted + OOO merged, RCV_NXT=12
 * ======================================================================== */
test_tcp_ooo_merge:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_oom
    mov     x19, x0                 /* conn */
    mov     w20, w1                 /* ISN */

    /* Step 1: Send OOO data with SEQ=7 (gap of 5 from RCV_NXT=2) */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum

    ldr     x21, =tcp_test_buf
    /* Patch SEQ = 7 */
    mov     w0, #7
    rev     w0, w0
    str     w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    /* Patch ACK = ISN + 1 */
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    /* Recompute TCP checksum */
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x21
    mov     w1, #25                 /* TCP segment: 20 hdr + 5 data */
    bl      tcp_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x21
    mov     w1, #59
    bl      tcp_handle

    /* Should return 54 (dup ACK) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_oom

    /* OOO_COUNT = 1 */
    ldrb    w0, [x19, #TCONN_OOO_COUNT]
    cmp     w0, #1
    b.ne    .Lfail_tcp_oom

    /* RCV_NXT unchanged = 2 */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    cmp     w0, #2
    b.ne    .Lfail_tcp_oom

    /* Step 2: Send in-order data with SEQ=2 (fills gap) */
    ldr     x0, =tcp_data_template
    ldr     x1, =tcp_test_buf
    mov     w2, #59
    bl      ttcp_fill_checksum

    ldr     x21, =tcp_test_buf
    /* SEQ=2 is already the template default */
    /* Patch ACK = ISN + 1 */
    add     w0, w20, #1
    rev     w0, w0
    str     w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    /* Recompute TCP checksum */
    strh    wzr, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x21
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x21, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x21
    mov     w1, #59
    bl      tcp_handle

    /* Should return 54 (data ACK) */
    cmp     w0, #54
    b.ne    .Lfail_tcp_oom

    /* RCV_NXT should be 12 (2 + 5 in-order + 5 OOO merged) */
    ldr     w0, [x19, #TCONN_RCV_NXT]
    cmp     w0, #12
    b.ne    .Lfail_tcp_oom

    /* RXLEN should be 10 */
    ldrh    w0, [x19, #TCONN_RXLEN]
    cmp     w0, #10
    b.ne    .Lfail_tcp_oom

    /* OOO_COUNT should be 0 (merged) */
    ldrb    w0, [x19, #TCONN_OOO_COUNT]
    cbnz    w0, .Lfail_tcp_oom

    ldr     x0, =name_tcp_oom
    bl      test_pass
    b       .Ldone_tcp_oom

.Lfail_tcp_oom:
    ldr     x0, =name_tcp_oom
    bl      test_fail

.Ldone_tcp_oom:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_rst_ratelimit — Send 11 SYNs to unmatched port; first 10 get
 * RST, 11th is dropped (rate-limited)
 * ======================================================================== */
test_tcp_rst_ratelimit:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Seed last_tick with current time so no refill occurs during test */
    bl      timer_now
    ldr     x1, =tcp_rst_last_tick
    str     x0, [x1]

    /* Send 10 SYNs to port 12345 (no listener) — all should get RST (54) */
    mov     w19, #10
.Lrl_send_loop:
    cbz     w19, .Lrl_send_11th
    sub     w19, w19, #1

    ldr     x0, =tcp_syn_wrongport_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cmp     w0, #54
    b.ne    .Lfail_tcp_rl
    b       .Lrl_send_loop

.Lrl_send_11th:
    /* 11th SYN — tokens exhausted, should be dropped (return 0) */
    ldr     x0, =tcp_syn_wrongport_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cbnz    w0, .Lfail_tcp_rl

    ldr     x0, =name_tcp_rl
    bl      test_pass
    b       .Ldone_tcp_rl

.Lfail_tcp_rl:
    ldr     x0, =name_tcp_rl
    bl      test_fail

.Ldone_tcp_rl:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_rst_refill — Zero tokens, forge stale last_tick so elapsed >
 * freq, send SYN → refill triggers → RST (not dropped)
 *
 * Covers: tcp_rst_allow b.lo .Lrst_no_refill NOT-taken (refill path)
 * Sets last_tick = timer_now() - 2*timer_freq() so elapsed is guaranteed
 * > freq regardless of QEMU counter speed.
 * ======================================================================== */
test_tcp_rst_refill:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Zero tokens and forge a stale last_tick */
    ldr     x0, =tcp_rst_tokens
    str     wzr, [x0]

    bl      timer_freq
    mov     x19, x0                 /* x19 = freq */
    bl      timer_now
    /* last_tick = now - 2*freq → elapsed will be >= freq */
    sub     x0, x0, x19, lsl #1
    ldr     x1, =tcp_rst_last_tick
    str     x0, [x1]

    /* Send SYN — tokens=0 but refill should fire → RST (54) */
    ldr     x0, =tcp_syn_wrongport_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    cmp     w0, #54
    b.ne    .Lfail_tcp_rf

    ldr     x0, =name_tcp_rf
    bl      test_pass
    b       .Ldone_tcp_rf

.Lfail_tcp_rf:
    ldr     x0, =name_tcp_rf
    bl      test_fail

.Ldone_tcp_rf:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_syn_evict — Fill slots 1-15 with SYN_RCVD, send SYN → SYN-ACK
 * (evicts a SYN_RCVD slot instead of returning RST)
 * ======================================================================== */
test_tcp_syn_evict:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Fill slots 1-15 with state=SYN_RCVD (evictable) */
    ldr     x0, =tcp_conn_table
    add     x0, x0, #TCONN_SIZE    /* skip slot 0 (LISTEN) */
    mov     w2, #TCPS_SYN_RCVD
    mov     w3, #15
.Lsevict_fill:
    strb    w2, [x0, #TCONN_STATE]
    add     x0, x0, #TCONN_SIZE
    subs    w3, w3, #1
    b.ne    .Lsevict_fill

    /* Send SYN to port 80 — should evict a SYN_RCVD slot, return SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* Expect 58 (SYN-ACK reply: 54 + 4 MSS option) */
    cmp     w0, #62
    b.ne    .Lfail_tcp_sevict

    /* Verify flags = SYN+ACK */
    ldr     x0, =tcp_test_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w1, #TCP_SYN_ACK
    b.ne    .Lfail_tcp_sevict

    /* Verify a SYN_RCVD slot exists with our peer's rport (12345 = 0x3039 NBO) */
    ldr     x0, =tcp_conn_table
    mov     w3, #TCP_MAX_CONNS
.Lsevict_verify:
    cbz     w3, .Lfail_tcp_sevict
    sub     w3, w3, #1
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.ne    .Lsevict_next
    ldrh    w1, [x0, #TCONN_RPORT]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #12345
    cmp     w1, w2
    b.eq    .Lsevict_found
.Lsevict_next:
    add     x0, x0, #TCONN_SIZE
    b       .Lsevict_verify

.Lsevict_found:
    ldr     x0, =name_tcp_sevict
    bl      test_pass
    b       .Ldone_tcp_sevict

.Lfail_tcp_sevict:
    ldr     x0, =name_tcp_sevict
    bl      test_fail

.Ldone_tcp_sevict:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_rst_seq_valid — RST with in-window SEQ closes ESTABLISHED
 *
 * Pre-seed ESTABLISHED with RCV_NXT=1000, RXLEN=0 (so RCV_WND=2048).
 * Send RST with SEQ=1000 (== RCV_NXT, in window). Expect state=CLOSED.
 * ======================================================================== */
test_tcp_rst_seq_valid:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Pre-seed slot 1 as ESTABLISHED */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE           /* slot 1 */
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000                      /* port 80 NBO */
    strh    w0, [x19, #TCONN_LPORT]
    mov     w0, #0x3930                      /* port 12345 NBO (0x3039 rev16) */
    strh    w0, [x19, #TCONN_RPORT]
    movz    w0, #0x000A                      /* 10.0.2.2 NBO as LE word */
    movk    w0, #0x0202, lsl #16
    str     w0, [x19, #TCONN_RIP]
    mov     w0, #1000
    str     w0, [x19, #TCONN_RCV_NXT]
    strh    wzr, [x19, #TCONN_RXLEN]
    /* Peer MAC */
    mov     w0, #0xBBAA
    movk    w0, #0xDDCC, lsl #16
    str     w0, [x19, #TCONN_RMAC]
    mov     w0, #0xFFEE
    strh    w0, [x19, #(TCONN_RMAC + 4)]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    /* Build RST with SEQ=1000 (in window) */
    ldr     x0, =tcp_rst_from_peer_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x20, =tcp_test_buf
    mov     w0, #1000
    rev     w0, w0
    str     w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x20
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x20
    mov     w1, #54
    bl      tcp_handle

    /* Verify state = CLOSED */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_rsv

    ldr     x0, =name_tcp_rsv
    bl      test_pass
    b       .Ldone_tcp_rsv
.Lfail_tcp_rsv:
    ldr     x0, =name_tcp_rsv
    bl      test_fail
.Ldone_tcp_rsv:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_rst_seq_invalid — RST with out-of-window SEQ is dropped
 *
 * Pre-seed ESTABLISHED with RCV_NXT=1000, RXLEN=0 (RCV_WND=2048).
 * Send RST with SEQ=5000 (outside window). Expect state=ESTABLISHED.
 * ======================================================================== */
test_tcp_rst_seq_invalid:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Pre-seed slot 1 as ESTABLISHED */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]
    mov     w0, #0x3930
    strh    w0, [x19, #TCONN_RPORT]
    movz    w0, #0x0A00
    movk    w0, #0x0202, lsl #16
    str     w0, [x19, #TCONN_RIP]
    mov     w0, #1000
    str     w0, [x19, #TCONN_RCV_NXT]
    strh    wzr, [x19, #TCONN_RXLEN]
    mov     w0, #0xBBAA
    movk    w0, #0xDDCC, lsl #16
    str     w0, [x19, #TCONN_RMAC]
    mov     w0, #0xFFEE
    strh    w0, [x19, #(TCONN_RMAC + 4)]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    /* Build RST with SEQ=5000 (outside window: 5000-1000=4000 >= 2048) */
    ldr     x0, =tcp_rst_from_peer_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x20, =tcp_test_buf
    mov     w0, #5000
    rev     w0, w0
    str     w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    strh    wzr, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x20
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x20, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x20
    mov     w1, #54
    bl      tcp_handle

    /* tcp_handle should return 0 (dropped) */
    cbnz    w0, .Lfail_tcp_rsi

    /* Verify state still ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_rsi

    ldr     x0, =name_tcp_rsi
    bl      test_pass
    b       .Ldone_tcp_rsi
.Lfail_tcp_rsi:
    ldr     x0, =name_tcp_rsi
    bl      test_fail
.Ldone_tcp_rsi:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_idle_estab_timeout — Reaper closes idle ESTABLISHED connection
 *
 * Pre-seed ESTABLISHED with LAST_ACTIVE = now - 121*freq.
 * Call tcp_idle_reaper_cb. Verify state=CLOSED.
 * ======================================================================== */
test_tcp_idle_estab_timeout:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    /* Don't set up LISTEN — we only need to pre-seed a slot */

    /* Compute LAST_ACTIVE = now - 121*freq */
    bl      timer_freq
    mov     x22, x0                         /* freq */
    bl      timer_now
    mov     x20, x0                         /* now */
    mov     x1, #121
    mul     x1, x22, x1
    sub     x21, x20, x1                    /* past = now - 121*freq */

    /* Pre-seed slot 0 as ESTABLISHED */
    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    str     x21, [x19, #TCONN_LAST_ACTIVE]
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    /* Call reaper */
    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    /* Verify state = CLOSED */
    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_iet

    ldr     x0, =name_tcp_iet
    bl      test_pass
    b       .Ldone_tcp_iet
.Lfail_tcp_iet:
    ldr     x0, =name_tcp_iet
    bl      test_fail
.Ldone_tcp_iet:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_idle_estab_active — Reaper preserves active ESTABLISHED connection
 *
 * Pre-seed ESTABLISHED with LAST_ACTIVE = now - 60*freq (under threshold).
 * Call reaper. Verify state=ESTABLISHED.
 * ======================================================================== */
test_tcp_idle_estab_active:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    bl      timer_freq
    mov     x22, x0
    bl      timer_now
    mov     x20, x0
    mov     x1, #60
    mul     x1, x22, x1
    sub     x21, x20, x1                    /* past = now - 60*freq */

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    str     x21, [x19, #TCONN_LAST_ACTIVE]
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    /* Verify state still ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lfail_tcp_iea

    ldr     x0, =name_tcp_iea
    bl      test_pass
    b       .Ldone_tcp_iea
.Lfail_tcp_iea:
    ldr     x0, =name_tcp_iea
    bl      test_fail
.Ldone_tcp_iea:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_idle_finwait2_timeout — Reaper closes idle FIN_WAIT_2
 *
 * Pre-seed FIN_WAIT_2 with LAST_ACTIVE = now - 61*freq.
 * Call reaper. Verify state=CLOSED.
 * ======================================================================== */
test_tcp_idle_finwait2_timeout:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    bl      timer_freq
    mov     x22, x0
    bl      timer_now
    mov     x20, x0
    mov     x1, #61
    mul     x1, x22, x1
    sub     x21, x20, x1

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_FIN_WAIT_2
    strb    w0, [x19, #TCONN_STATE]
    str     x21, [x19, #TCONN_LAST_ACTIVE]
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_ift

    ldr     x0, =name_tcp_ift
    bl      test_pass
    b       .Ldone_tcp_ift
.Lfail_tcp_ift:
    ldr     x0, =name_tcp_ift
    bl      test_fail
.Ldone_tcp_ift:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_idle_closewait_timeout — Reaper closes idle CLOSE_WAIT
 *
 * Pre-seed CLOSE_WAIT with LAST_ACTIVE = now - 61*freq.
 * Call reaper. Verify state=CLOSED.
 * ======================================================================== */
test_tcp_idle_closewait_timeout:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    bl      timer_freq
    mov     x22, x0
    bl      timer_now
    mov     x20, x0
    mov     x1, #61
    mul     x1, x22, x1
    sub     x21, x20, x1

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_CLOSE_WAIT
    strb    w0, [x19, #TCONN_STATE]
    str     x21, [x19, #TCONN_LAST_ACTIVE]
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_ict

    ldr     x0, =name_tcp_ict
    bl      test_pass
    b       .Ldone_tcp_ict
.Lfail_tcp_ict:
    ldr     x0, =name_tcp_ict
    bl      test_fail
.Ldone_tcp_ict:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_fast_retransmit — 3 duplicate ACKs trigger fast retransmit
 *
 * Handshake → tcp_send → set up mock send_ctx → send 3 dup ACKs →
 * verify send_fn called, DUP_ACK_CNT reset, ssthresh updated.
 * ======================================================================== */
test_tcp_fast_retransmit:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_frtx
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Send 5 bytes to populate retransmit buffer */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_frtx

    /* Set up mock send context */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_test_buf3
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    /* Reset mock counters */
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    /* Record SND_UNA for dup ACK check */
    ldr     w20, [x21, #TCONN_SND_UNA]

    /* Send 3 duplicate ACKs (seg_ack == SND_UNA) */
    mov     w19, #3
.Lfrtx_dup_loop:
    cbz     w19, .Lfrtx_check

    /* Build ACK frame with seg_ack = SND_UNA */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    /* Set SEQ = RCV_NXT of peer (use 2, from SYN template SEQ=1 +1) */
    ldr     w1, [x21, #TCONN_RCV_NXT]
    rev     w1, w1
    str     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    /* Set ACK = SND_UNA (NBO) — this is the dup ACK */
    rev     w1, w20
    str     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     w1, #20
    bl      tcp_checksum
    ldr     x1, =tcp_test_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    sub     w19, w19, #1
    b       .Lfrtx_dup_loop

.Lfrtx_check:
    /* Verify mock send was called (retransmit happened) */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_tcp_frtx

    /* Verify DUP_ACK_CNT reset to 0 */
    ldrb    w0, [x21, #TCONN_DUP_ACK_CNT]
    cbnz    w0, .Lfail_tcp_frtx

    /* Verify ssthresh was set (should be max(cwnd/2, 2*MSS)) */
    ldr     w0, [x21, #TCONN_SSTHRESH]
    cbz     w0, .Lfail_tcp_frtx

    ldr     x0, =name_tcp_frtx
    bl      test_pass
    b       .Ldone_tcp_frtx
.Lfail_tcp_frtx:
    ldr     x0, =name_tcp_frtx
    bl      test_fail
.Ldone_tcp_frtx:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_dupack_below_thresh — 2 dup ACKs don't trigger retransmit
 *
 * Same setup, send only 2 dup ACKs. Verify DUP_ACK_CNT=2, no retransmit.
 * ======================================================================== */
test_tcp_dupack_below_thresh:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_dabt
    mov     x21, x0
    mov     w22, w1

    /* Send 5 bytes to populate retransmit buffer */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_dabt

    /* Set up mock send context */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_test_buf3
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    ldr     w20, [x21, #TCONN_SND_UNA]

    /* Send 2 duplicate ACKs */
    mov     w19, #2
.Ldabt_dup_loop:
    cbz     w19, .Ldabt_check
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    ldr     w1, [x21, #TCONN_RCV_NXT]
    rev     w1, w1
    str     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w1, w20
    str     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     w1, #20
    bl      tcp_checksum
    ldr     x1, =tcp_test_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    sub     w19, w19, #1
    b       .Ldabt_dup_loop

.Ldabt_check:
    /* Verify DUP_ACK_CNT == 2 */
    ldrb    w0, [x21, #TCONN_DUP_ACK_CNT]
    cmp     w0, #2
    b.ne    .Lfail_tcp_dabt

    /* Verify mock send was NOT called */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_tcp_dabt

    ldr     x0, =name_tcp_dabt
    bl      test_pass
    b       .Ldone_tcp_dabt
.Lfail_tcp_dabt:
    ldr     x0, =name_tcp_dabt
    bl      test_fail
.Ldone_tcp_dabt:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_persist_arm — Zero-window ACK sets PERSIST_SHIFT=1
 *
 * Handshake → send ACK with window=0. Verify PERSIST_SHIFT=1.
 * ======================================================================== */
test_tcp_persist_arm:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pa
    mov     x21, x0
    mov     w22, w1

    /* Verify PERSIST_SHIFT starts at 0 */
    ldrb    w0, [x21, #TCONN_PERSIST_SHIFT]
    cbnz    w0, .Lfail_tcp_pa

    /* Build ACK with window=0 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    /* Set SEQ from peer perspective */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    /* Set ACK = SND_NXT (valid) */
    ldr     w0, [x21, #TCONN_SND_NXT]
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    /* Set window = 0 */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    /* Recompute checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify PERSIST_SHIFT == 1 */
    ldrb    w0, [x21, #TCONN_PERSIST_SHIFT]
    cmp     w0, #1
    b.ne    .Lfail_tcp_pa

    /* Verify SND_WND == 0 */
    ldr     w0, [x21, #TCONN_SND_WND]
    cbnz    w0, .Lfail_tcp_pa

    ldr     x0, =name_tcp_pa
    bl      test_pass
    b       .Ldone_tcp_pa
.Lfail_tcp_pa:
    ldr     x0, =name_tcp_pa
    bl      test_fail
.Ldone_tcp_pa:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_persist_cancel — Non-zero window clears PERSIST_SHIFT
 *
 * Pre-seed ESTABLISHED with PERSIST_SHIFT=2. Send ACK with window>0.
 * Verify PERSIST_SHIFT=0.
 * ======================================================================== */
test_tcp_persist_cancel:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pc
    mov     x21, x0
    mov     w22, w1

    /* Set PERSIST_SHIFT = 2 (as if persist was armed) */
    mov     w0, #2
    strb    w0, [x21, #TCONN_PERSIST_SHIFT]

    /* Build ACK with window > 0 (template has 0xFFFF) */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    ldr     w0, [x21, #TCONN_RCV_NXT]
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    ldr     w0, [x21, #TCONN_SND_NXT]
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

    /* Verify PERSIST_SHIFT == 0 */
    ldrb    w0, [x21, #TCONN_PERSIST_SHIFT]
    cbnz    w0, .Lfail_tcp_pc

    ldr     x0, =name_tcp_pc
    bl      test_pass
    b       .Ldone_tcp_pc
.Lfail_tcp_pc:
    ldr     x0, =name_tcp_pc
    bl      test_fail
.Ldone_tcp_pc:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_dupack_no_rtxdata — Dup ACK with RTXLEN=0 is ignored
 *
 * Exercises .Leak_pure_ack cbz w6 (RTXLEN==0) taken path.
 * Handshake → do NOT send data (RTXLEN stays 0) → send dup ACK →
 * verify DUP_ACK_CNT stays 0.
 * ======================================================================== */
test_tcp_dupack_no_rtxdata:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_dnr
    mov     x21, x0

    /* Verify RTXLEN == 0 (no outstanding data) */
    ldrh    w0, [x21, #TCONN_RTXLEN]
    cbnz    w0, .Lfail_tcp_dnr

    /* Save SND_UNA for dup ACK */
    ldr     w20, [x21, #TCONN_SND_UNA]

    /* Send ACK with seg_ack == SND_UNA (would be dup ACK if RTXLEN > 0) */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    ldr     w0, [x21, #TCONN_RCV_NXT]
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    rev     w0, w20
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* DUP_ACK_CNT should still be 0 (RTXLEN==0 guard skipped increment) */
    ldrb    w0, [x21, #TCONN_DUP_ACK_CNT]
    cbnz    w0, .Lfail_tcp_dnr

    ldr     x0, =name_tcp_dnr
    bl      test_pass
    b       .Ldone_tcp_dnr
.Lfail_tcp_dnr:
    ldr     x0, =name_tcp_dnr
    bl      test_fail
.Ldone_tcp_dnr:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_persist_already_armed — Second zero-window ACK doesn't re-arm
 *
 * Exercises .Leak_zero_window cbnz w5 (already armed) taken path.
 * ======================================================================== */
test_tcp_persist_already_armed:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_paa
    mov     x21, x0

    /* Pre-set PERSIST_SHIFT = 2 (as if already armed) */
    mov     w0, #2
    strb    w0, [x21, #TCONN_PERSIST_SHIFT]

    /* Send ACK with window=0 */
    ldr     x0, =tcp_handshake_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf
    ldr     w0, [x21, #TCONN_RCV_NXT]
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    ldr     w0, [x21, #TCONN_SND_NXT]
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* PERSIST_SHIFT should still be 2 (not reset to 1) */
    ldrb    w0, [x21, #TCONN_PERSIST_SHIFT]
    cmp     w0, #2
    b.ne    .Lfail_tcp_paa

    ldr     x0, =name_tcp_paa
    bl      test_pass
    b       .Ldone_tcp_paa
.Lfail_tcp_paa:
    ldr     x0, =name_tcp_paa
    bl      test_fail
.Ldone_tcp_paa:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_frtx_no_send_fn — Fast retransmit with NULL send_fn bails
 *
 * Exercises tcp_fast_retransmit cbz x1 (send_fn NULL) taken path.
 * Direct call: set up conn with data, clear send_ctx, call tcp_fast_retransmit.
 * ======================================================================== */
test_tcp_frtx_no_send_fn:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_fns
    mov     x21, x0

    /* Send 5 bytes to get RTXLEN > 0 */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_fns

    /* Clear send_fn to NULL */
    mov     x0, #0
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    bl      tcp_set_send_ctx

    /* Record cwnd before */
    ldr     w19, [x21, #TCONN_CWND]

    /* Call tcp_fast_retransmit directly */
    mov     x0, x21
    bl      tcp_fast_retransmit

    /* ssthresh should still be updated (happens before send_fn check) */
    ldr     w0, [x21, #TCONN_SSTHRESH]
    cbz     w0, .Lfail_tcp_fns

    /* But no crash occurred — test passes if we reach here */
    ldr     x0, =name_tcp_fns
    bl      test_pass
    b       .Ldone_tcp_fns
.Lfail_tcp_fns:
    ldr     x0, =name_tcp_fns
    bl      test_fail
.Ldone_tcp_fns:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_frtx_cwnd_floor — Fast retransmit with low cwnd uses 2*MSS floor
 *
 * Exercises tcp_fast_retransmit csel: cwnd/2 < 2*MSS case.
 * Set cwnd to MSS (536), so cwnd/2=268 < 2*MSS=1072 → ssthresh=1072.
 * Also tests 256 KB cap path by setting cwnd high enough that
 * ssthresh + 3*MSS > 256 KB.
 * ======================================================================== */
test_tcp_frtx_cwnd_floor:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_fcf
    mov     x21, x0

    /* Send 5 bytes */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_fcf

    /* Set up mock send context */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_test_buf3
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    /* Set cwnd to MSS (536) — cwnd/2=268 < 2*MSS=1072 */
    ldrh    w0, [x21, #TCONN_PEER_MSS]    /* w0 = MSS (536) */
    str     w0, [x21, #TCONN_CWND]

    mov     x0, x21
    bl      tcp_fast_retransmit

    /* ssthresh should be 2*MSS = 1072 (floor) */
    ldr     w0, [x21, #TCONN_SSTHRESH]
    ldrh    w1, [x21, #TCONN_PEER_MSS]
    lsl     w1, w1, #1                     /* 2*MSS */
    cmp     w0, w1
    b.ne    .Lfail_tcp_fcf

    /* cwnd should be ssthresh + 3*MSS = 1072 + 1608 = 2680 */
    ldr     w0, [x21, #TCONN_CWND]
    ldrh    w1, [x21, #TCONN_PEER_MSS]
    lsl     w2, w1, #1                     /* 2*MSS = ssthresh */
    mov     w3, #3
    mul     w3, w1, w3                     /* 3*MSS */
    add     w2, w2, w3                     /* expected cwnd */
    cmp     w0, w2
    b.ne    .Lfail_tcp_fcf

    /* --- Now test 256KB cap: set cwnd and MSS so ssthresh+3*MSS > 256KB --- */
    mov     w0, #0x40000                    /* cwnd = 256 KB */
    str     w0, [x21, #TCONN_CWND]
    mov     w0, #60000                      /* MSS = 60000 (fits u16) */
    strh    w0, [x21, #TCONN_PEER_MSS]
    strh    wzr, [x21, #TCONN_RTXLEN]

    /* Re-send 5 bytes */
    mov     x0, x21
    ldr     x1, =tcp_send_test_buf
    ldr     x2, =tcp_send_payload
    mov     w3, #5
    bl      tcp_send
    cbz     w0, .Lfail_tcp_fcf

    mov     x0, x21
    bl      tcp_fast_retransmit

    /* ssthresh = max(256K/2=131072, 2*60000=120000) = 131072
     * cwnd = 131072 + 3*60000 = 311072 → capped at 256KB (262144) */
    ldr     w0, [x21, #TCONN_CWND]
    mov     w1, #0x40000
    cmp     w0, w1
    b.ne    .Lfail_tcp_fcf

    ldr     x0, =name_tcp_fcf
    bl      test_pass
    b       .Ldone_tcp_fcf
.Lfail_tcp_fcf:
    ldr     x0, =name_tcp_fcf
    bl      test_fail
.Ldone_tcp_fcf:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_reaper_skip_listen — Reaper skips LISTEN slots
 *
 * Exercises tcp_idle_reaper_cb b.eq .Lreap_next for LISTEN state.
 * ======================================================================== */
test_tcp_reaper_skip_listen:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Slot 0: set to LISTEN with old LAST_ACTIVE (reaper should skip it) */
    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_LISTEN
    strb    w0, [x19, #TCONN_STATE]
    str     xzr, [x19, #TCONN_LAST_ACTIVE]  /* ancient timestamp */
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    /* LISTEN should be preserved */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_LISTEN
    b.ne    .Lfail_tcp_rsl

    ldr     x0, =name_tcp_rsl
    bl      test_pass
    b       .Ldone_tcp_rsl
.Lfail_tcp_rsl:
    ldr     x0, =name_tcp_rsl
    bl      test_fail
.Ldone_tcp_rsl:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_reaper_skip_timewait — Reaper skips TIME_WAIT slots
 *
 * Exercises tcp_idle_reaper_cb b.eq .Lreap_next for TIME_WAIT state.
 * ======================================================================== */
test_tcp_reaper_skip_timewait:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_TIME_WAIT
    strb    w0, [x19, #TCONN_STATE]
    str     xzr, [x19, #TCONN_LAST_ACTIVE]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_TIME_WAIT
    b.ne    .Lfail_tcp_rst2

    ldr     x0, =name_tcp_rst2
    bl      test_pass
    b       .Ldone_tcp_rst2
.Lfail_tcp_rst2:
    ldr     x0, =name_tcp_rst2
    bl      test_fail
.Ldone_tcp_rst2:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_reaper_synrcvd — Reaper closes idle SYN_RCVD
 *
 * Exercises tcp_idle_reaper_cb b.eq .Lreap_estab for SYN_RCVD state.
 * SYN_RCVD uses ESTAB timeout (120s).
 * ======================================================================== */
test_tcp_reaper_synrcvd:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    bl      timer_freq
    mov     x22, x0
    bl      timer_now
    mov     x20, x0
    mov     x1, #121
    mul     x1, x22, x1
    sub     x21, x20, x1                    /* past = now - 121*freq */

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_SYN_RCVD
    strb    w0, [x19, #TCONN_STATE]
    str     x21, [x19, #TCONN_LAST_ACTIVE]
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_rsyr

    ldr     x0, =name_tcp_rsyr
    bl      test_pass
    b       .Ldone_tcp_rsyr
.Lfail_tcp_rsyr:
    ldr     x0, =name_tcp_rsyr
    bl      test_fail
.Ldone_tcp_rsyr:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_reaper_finwait1 — Reaper closes idle FIN_WAIT_1
 *
 * Exercises tcp_idle_reaper_cb b.eq .Lreap_finwait for FIN_WAIT_1 state.
 * FIN_WAIT_1 uses FINWAIT2 timeout (60s).
 * ======================================================================== */
test_tcp_reaper_finwait1:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    bl      timer_freq
    mov     x22, x0
    bl      timer_now
    mov     x20, x0
    mov     x1, #61
    mul     x1, x22, x1
    sub     x21, x20, x1

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_FIN_WAIT_1
    strb    w0, [x19, #TCONN_STATE]
    str     x21, [x19, #TCONN_LAST_ACTIVE]
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_rfw1

    ldr     x0, =name_tcp_rfw1
    bl      test_pass
    b       .Ldone_tcp_rfw1
.Lfail_tcp_rfw1:
    ldr     x0, =name_tcp_rfw1
    bl      test_fail
.Ldone_tcp_rfw1:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_start_reaper — tcp_start_reaper with timer pool arms timer
 *
 * Exercises tcp_start_reaper not-taken (pool set) path.
 * Also exercises tcp_idle_reaper_cb re-arm path (not-taken at cbz).
 * ======================================================================== */
test_tcp_start_reaper:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    /* Init and set timer pool */
    ldr     x0, =test_tcp_timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init
    ldr     x0, =test_tcp_timer_pool
    bl      tcp_set_timer_pool

    /* Call tcp_start_reaper */
    bl      tcp_start_reaper

    /* Verify a timer was armed: check that slot 0 has a callback set */
    ldr     x0, =test_tcp_timer_pool
    ldr     x1, [x0, #(TPOOL_SLOTS + SLOT_CALLBACK)]
    cbz     x1, .Lfail_tcp_sr

    /* Verify callback is tcp_idle_reaper_cb */
    ldr     x2, =tcp_idle_reaper_cb
    cmp     x1, x2
    b.ne    .Lfail_tcp_sr

    /* Now test the reaper re-arm path: call reaper with pool set.
     * First, cancel the timer in slot 0 so we can see it re-armed. */
    ldr     x0, =test_tcp_timer_pool
    mov     w1, #0
    bl      timer_cancel

    /* Verify callback cleared */
    ldr     x0, =test_tcp_timer_pool
    ldr     x1, [x0, #(TPOOL_SLOTS + SLOT_CALLBACK)]
    cbnz    x1, .Lfail_tcp_sr

    /* Call reaper — should re-arm itself */
    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    /* Verify callback re-armed */
    ldr     x0, =test_tcp_timer_pool
    ldr     x1, [x0, #(TPOOL_SLOTS + SLOT_CALLBACK)]
    cbz     x1, .Lfail_tcp_sr

    ldr     x0, =name_tcp_sr
    bl      test_pass
    b       .Ldone_tcp_sr
.Lfail_tcp_sr:
    ldr     x0, =name_tcp_sr
    bl      test_fail
.Ldone_tcp_sr:
    /* Clear timer pool so other tests aren't affected */
    mov     x0, xzr
    bl      tcp_set_timer_pool
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_start_reaper_no_pool — tcp_start_reaper with no pool bails
 *
 * Exercises tcp_start_reaper cbz (taken) path.
 * ======================================================================== */
test_tcp_start_reaper_no_pool:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init

    /* Ensure no timer pool is set */
    mov     x0, xzr
    bl      tcp_set_timer_pool

    /* Call tcp_start_reaper — should not crash */
    bl      tcp_start_reaper

    /* If we reached here, the NULL guard worked */
    ldr     x0, =name_tcp_srnp
    bl      test_pass

    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_tcp_persist_cb_send — Persist callback sends probe and increments shift
 *
 * Exercises tcp_persist_cb happy path: state=ESTABLISHED, SND_WND=0,
 * send_fn set → sends probe, increments PERSIST_SHIFT, re-arms.
 * ======================================================================== */
test_tcp_persist_cb_send:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pcs
    mov     x21, x0

    /* Set SND_WND = 0, PERSIST_SHIFT = 1 */
    str     wzr, [x21, #TCONN_SND_WND]
    mov     w0, #1
    strb    w0, [x21, #TCONN_PERSIST_SHIFT]

    /* Set up mock send context */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_send_test_buf
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    /* Reset mock counters */
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    /* Call tcp_persist_cb(conn) */
    mov     x0, x21
    bl      tcp_persist_cb

    /* Verify mock was called (probe sent) */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_tcp_pcs

    /* Verify PERSIST_SHIFT incremented to 2 */
    ldrb    w0, [x21, #TCONN_PERSIST_SHIFT]
    cmp     w0, #2
    b.ne    .Lfail_tcp_pcs

    ldr     x0, =name_tcp_pcs
    bl      test_pass
    b       .Ldone_tcp_pcs
.Lfail_tcp_pcs:
    ldr     x0, =name_tcp_pcs
    bl      test_fail
.Ldone_tcp_pcs:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_persist_cb_not_estab — Persist callback bails if not ESTABLISHED
 *
 * Exercises tcp_persist_cb b.ne .Lpersist_done (state != ESTABLISHED).
 * ======================================================================== */
test_tcp_persist_cb_not_estab:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pcne
    mov     x21, x0

    /* Change state to CLOSE_WAIT (not ESTABLISHED) */
    mov     w0, #TCPS_CLOSE_WAIT
    strb    w0, [x21, #TCONN_STATE]
    str     wzr, [x21, #TCONN_SND_WND]
    mov     w0, #1
    strb    w0, [x21, #TCONN_PERSIST_SHIFT]

    /* Set up mock */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_send_test_buf
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    mov     x0, x21
    bl      tcp_persist_cb

    /* Mock should NOT have been called */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_tcp_pcne

    ldr     x0, =name_tcp_pcne
    bl      test_pass
    b       .Ldone_tcp_pcne
.Lfail_tcp_pcne:
    ldr     x0, =name_tcp_pcne
    bl      test_fail
.Ldone_tcp_pcne:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_persist_cb_wnd_open — Persist callback bails if window opened
 *
 * Exercises tcp_persist_cb cbnz w1 (SND_WND != 0) taken path.
 * ======================================================================== */
test_tcp_persist_cb_wnd_open:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pcwo
    mov     x21, x0

    /* State=ESTABLISHED but SND_WND > 0 (window opened since timer was set) */
    mov     w0, #1000
    str     w0, [x21, #TCONN_SND_WND]
    mov     w0, #1
    strb    w0, [x21, #TCONN_PERSIST_SHIFT]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_send_test_buf
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx
    ldr     x0, =ttcp_mock_send_count
    str     wzr, [x0]

    mov     x0, x21
    bl      tcp_persist_cb

    /* Mock should NOT have been called */
    ldr     x0, =ttcp_mock_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_tcp_pcwo

    ldr     x0, =name_tcp_pcwo
    bl      test_pass
    b       .Ldone_tcp_pcwo
.Lfail_tcp_pcwo:
    ldr     x0, =name_tcp_pcwo
    bl      test_fail
.Ldone_tcp_pcwo:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_persist_cb_no_send_fn — Persist callback bails if no send_fn
 *
 * Exercises tcp_persist_cb cbz x1 (send_fn NULL) taken path.
 * ======================================================================== */
test_tcp_persist_cb_no_send_fn:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pcns
    mov     x21, x0

    str     wzr, [x21, #TCONN_SND_WND]
    mov     w0, #1
    strb    w0, [x21, #TCONN_PERSIST_SHIFT]

    /* Clear send context */
    mov     x0, #0
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    bl      tcp_set_send_ctx

    /* Should not crash */
    mov     x0, x21
    bl      tcp_persist_cb

    ldr     x0, =name_tcp_pcns
    bl      test_pass
    b       .Ldone_tcp_pcns
.Lfail_tcp_pcns:
    ldr     x0, =name_tcp_pcns
    bl      test_fail
.Ldone_tcp_pcns:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_persist_cb_shift_cap — Persist callback caps shift at 5
 *
 * Exercises tcp_persist_cb csel: shift >= 5 → cap at 5.
 * ======================================================================== */
test_tcp_persist_cb_shift_cap:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pcsc
    mov     x21, x0

    str     wzr, [x21, #TCONN_SND_WND]
    /* Set PERSIST_SHIFT = 4 (after increment → 5, should be capped) */
    mov     w0, #4
    strb    w0, [x21, #TCONN_PERSIST_SHIFT]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =tcp_send_test_buf
    ldr     x3, =ttcp_mock_send_fn
    bl      tcp_set_send_ctx

    mov     x0, x21
    bl      tcp_persist_cb

    /* PERSIST_SHIFT should be 5 (capped) */
    ldrb    w0, [x21, #TCONN_PERSIST_SHIFT]
    cmp     w0, #5
    b.ne    .Lfail_tcp_pcsc

    /* Call again — shift should still be 5 (capped, not 6) */
    mov     x0, x21
    bl      tcp_persist_cb

    ldrb    w0, [x21, #TCONN_PERSIST_SHIFT]
    cmp     w0, #5
    b.ne    .Lfail_tcp_pcsc

    ldr     x0, =name_tcp_pcsc
    bl      test_pass
    b       .Ldone_tcp_pcsc
.Lfail_tcp_pcsc:
    ldr     x0, =name_tcp_pcsc
    bl      test_fail
.Ldone_tcp_pcsc:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_persist_arm_with_pool — Persist arm actually sets timer
 *
 * Exercises tcp_persist_arm not-taken (pool set) path and timeout
 * computation.
 * ======================================================================== */
test_tcp_persist_arm_with_pool:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_pawp
    mov     x21, x0

    /* Init and set timer pool */
    ldr     x0, =test_tcp_timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init
    ldr     x0, =test_tcp_timer_pool
    bl      tcp_set_timer_pool

    /* Set PERSIST_SHIFT = 1 */
    mov     w0, #1
    strb    w0, [x21, #TCONN_PERSIST_SHIFT]

    /* Call tcp_persist_arm */
    mov     x0, x21
    bl      tcp_persist_arm

    /* Verify a timer was armed with tcp_persist_cb callback */
    ldr     x0, =test_tcp_timer_pool
    add     x0, x0, #TPOOL_SLOTS           /* scan from first slot */
    mov     w1, #TPOOL_DEFAULT_CAP
    ldr     x2, =tcp_persist_cb
.Lpawp_scan:
    cbz     w1, .Lfail_tcp_pawp             /* no slot found */
    ldr     x3, [x0, #SLOT_CALLBACK]
    cmp     x3, x2
    b.eq    .Lpawp_found
    add     x0, x0, #SLOT_SIZE
    sub     w1, w1, #1
    b       .Lpawp_scan

.Lpawp_found:
    /* Verify context == conn */
    ldr     x3, [x0, #SLOT_CONTEXT]
    cmp     x3, x21
    b.ne    .Lfail_tcp_pawp

    ldr     x0, =name_tcp_pawp
    bl      test_pass
    b       .Ldone_tcp_pawp
.Lfail_tcp_pawp:
    ldr     x0, =name_tcp_pawp
    bl      test_fail
.Ldone_tcp_pawp:
    /* Clean up timer pool */
    mov     x0, xzr
    bl      tcp_set_timer_pool
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
    .ltorg

/* ========================================================================
 * test_tcp_df_bit — Verify DF bit set on outgoing TCP frames
 * ======================================================================== */
test_tcp_df_bit:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_df
    mov     x19, x0                 /* conn */

    /* tcp_build_frame: build a bare ACK */
    mov     x0, x19
    ldr     x1, =tcp_test_buf3
    mov     w2, #TCP_ACK_FLAG
    mov     x3, #0
    mov     w4, #0
    bl      tcp_build_frame

    /* Check IP_FLAGS_FRAG field: expect 0x0040 (DF bit in LE halfword) */
    ldr     x0, =tcp_test_buf3
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]
    mov     w2, #0x0040
    cmp     w1, w2
    b.ne    .Lfail_tcp_df

    /* Also verify tcp_build_reply path: SYN→SYN-ACK frame has DF */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf3
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf3
    mov     w1, #54
    bl      tcp_handle
    cbz     w0, .Lfail_tcp_df

    ldr     x0, =tcp_test_buf3
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]
    mov     w2, #0x0040
    cmp     w1, w2
    b.ne    .Lfail_tcp_df

    ldr     x0, =name_tcp_df
    bl      test_pass
    b       .Ldone_tcp_df
.Lfail_tcp_df:
    ldr     x0, =name_tcp_df
    bl      test_fail
.Ldone_tcp_df:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_fin_with_data — FIN+ACK carrying data → data accepted + CLOSE_WAIT
 * ======================================================================== */
test_tcp_fin_with_data:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_fwd
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Build FIN+ACK with 5 bytes of data: SEQ=2, ACK=ISN+1 */
    /* Use the finack template (54 bytes) but extend to 59 bytes */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x19, =tcp_test_buf

    /* Fix ACK to ISN+1 */
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* Append 5 bytes of payload: "Hello" */
    mov     w0, #'H'
    strb    w0, [x19, #54]
    mov     w0, #'e'
    strb    w0, [x19, #55]
    mov     w0, #'l'
    strb    w0, [x19, #56]
    mov     w0, #'l'
    strb    w0, [x19, #57]
    mov     w0, #'o'
    strb    w0, [x19, #58]

    /* Update IP TotalLength: 40 + 5 = 45 → 0x002D NBO → 0x2D00 LE */
    mov     w0, #0x2D00
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum over 25 bytes (20 hdr + 5 data) */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Call tcp_handle with frame_len=59 (14+45) */
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle

    /* Verify reply generated (ACK) */
    cmp     w0, #54
    b.lt    .Lfail_tcp_fwd

    /* Verify state = CLOSE_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSE_WAIT
    b.ne    .Lfail_tcp_fwd

    /* Verify RXLEN = 5 (data was accepted) */
    ldrh    w0, [x21, #TCONN_RXLEN]
    cmp     w0, #5
    b.ne    .Lfail_tcp_fwd

    /* Verify RCV_NXT = 2 + 5 + 1(FIN) = 8 */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, #8
    b.ne    .Lfail_tcp_fwd

    /* Verify data in rxbuf */
    mov     x0, x21
    bl      tcp_rx_peek
    /* x0 = buf ptr, w1 = len */
    cmp     w1, #5
    b.ne    .Lfail_tcp_fwd
    ldrb    w2, [x0]
    cmp     w2, #'H'
    b.ne    .Lfail_tcp_fwd
    ldrb    w2, [x0, #4]
    cmp     w2, #'o'
    b.ne    .Lfail_tcp_fwd

    ldr     x0, =name_tcp_fwd
    bl      test_pass
    b       .Ldone_tcp_fwd
.Lfail_tcp_fwd:
    ldr     x0, =name_tcp_fwd
    bl      test_fail
.Ldone_tcp_fwd:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* ========================================================================
 * test_tcp_timewait_fin_reack — TIME_WAIT + FIN → re-ACK with frame output
 * ======================================================================== */
test_tcp_timewait_fin_reack:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_twfr
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Force connection into TIME_WAIT */
    mov     w0, #TCPS_TIME_WAIT
    strb    w0, [x21, #TCONN_STATE]
    /* Set RCV_NXT = 3 (as if we already processed FIN: initial 2 + 1 FIN) */
    mov     w0, #3
    str     w0, [x21, #TCONN_RCV_NXT]

    /* Send retransmitted FIN+ACK: SEQ=2, ACK=ISN+1 */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x19, =tcp_test_buf

    /* Fix ACK to ISN+1 */
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #20
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Call tcp_handle */
    mov     x0, x19
    mov     w1, #54
    bl      tcp_handle

    /* Verify ACK reply was generated (>0) */
    cmp     w0, #54
    b.lt    .Lfail_tcp_twfr

    /* Verify state is still TIME_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_TIME_WAIT
    b.ne    .Lfail_tcp_twfr

    /* Verify reply has ACK flag */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_ACK_FLAG
    b.ne    .Lfail_tcp_twfr

    ldr     x0, =name_tcp_twfr
    bl      test_pass
    b       .Ldone_tcp_twfr
.Lfail_tcp_twfr:
    ldr     x0, =name_tcp_twfr
    bl      test_fail
.Ldone_tcp_twfr:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* ========================================================================
 * test_tcp_fin_data_bad_seq — FIN+data with wrong SEQ → data skipped, FIN ok
 *
 * Branch: tcp_estab_fin_handler line 1538 (b.ne .Lefin_no_data)
 * Exercises: SEQ != RCV_NXT taken path
 * ======================================================================== */
test_tcp_fin_data_bad_seq:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_fdbs
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Build FIN+ACK with 5 bytes of data but BAD SEQ (99 instead of 2) */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x19, =tcp_test_buf

    /* Fix ACK to ISN+1 */
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* Set SEQ to 99 (wrong — RCV_NXT is 2) */
    mov     w0, #99
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]

    /* Append 5 bytes of payload */
    mov     w0, #'H'
    strb    w0, [x19, #54]
    mov     w0, #'e'
    strb    w0, [x19, #55]
    mov     w0, #'l'
    strb    w0, [x19, #56]
    mov     w0, #'l'
    strb    w0, [x19, #57]
    mov     w0, #'o'
    strb    w0, [x19, #58]

    /* Update IP TotalLength: 40 + 5 = 45 → 0x002D NBO → 0x2D00 LE */
    mov     w0, #0x2D00
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum over 25 bytes (20 hdr + 5 data) */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Call tcp_handle with frame_len=59 */
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle

    /* Verify reply generated (ACK for FIN) */
    cmp     w0, #54
    b.lt    .Lfail_tcp_fdbs

    /* Verify state = CLOSE_WAIT (FIN was still processed) */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSE_WAIT
    b.ne    .Lfail_tcp_fdbs

    /* Verify RXLEN = 0 (data was NOT accepted — bad SEQ) */
    ldrh    w0, [x21, #TCONN_RXLEN]
    cbnz    w0, .Lfail_tcp_fdbs

    /* Verify RCV_NXT = 2 + 1(FIN only) = 3 (no data advance) */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, #3
    b.ne    .Lfail_tcp_fdbs

    ldr     x0, =name_tcp_fdbs
    bl      test_pass
    b       .Ldone_tcp_fdbs
.Lfail_tcp_fdbs:
    ldr     x0, =name_tcp_fdbs
    bl      test_fail
.Ldone_tcp_fdbs:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* ========================================================================
 * test_tcp_fin_data_overflow — FIN+data when rxbuf nearly full → skip data
 *
 * Branch: tcp_estab_fin_handler line 1544 (b.hi .Lefin_no_data)
 * Exercises: rxlen + data_len > TCP_RXBUF_SIZE taken path
 * ======================================================================== */
test_tcp_fin_data_overflow:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_fdov
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Pre-fill RXLEN to TCP_RXBUF_SIZE - 2 (only 2 bytes of room, 5 won't fit) */
    mov     w0, #(TCP_RXBUF_SIZE - 2)
    strh    w0, [x21, #TCONN_RXLEN]

    /* Build FIN+ACK with 5 bytes data, correct SEQ=2 */
    ldr     x0, =tcp_finack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x19, =tcp_test_buf

    /* Fix ACK to ISN+1 */
    add     w0, w22, #1
    rev     w0, w0
    str     w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]

    /* Append 5 bytes of payload */
    mov     w0, #'H'
    strb    w0, [x19, #54]
    mov     w0, #'e'
    strb    w0, [x19, #55]
    mov     w0, #'l'
    strb    w0, [x19, #56]
    mov     w0, #'l'
    strb    w0, [x19, #57]
    mov     w0, #'o'
    strb    w0, [x19, #58]

    /* Update IP TotalLength: 45 */
    mov     w0, #0x2D00
    strh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]

    /* Recompute IP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]
    add     x0, x19, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Recompute TCP checksum */
    strh    wzr, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     x0, x19
    mov     w1, #25
    bl      tcp_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    /* Call tcp_handle */
    mov     x0, x19
    mov     w1, #59
    bl      tcp_handle

    /* Verify reply generated */
    cmp     w0, #54
    b.lt    .Lfail_tcp_fdov

    /* Verify CLOSE_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_CLOSE_WAIT
    b.ne    .Lfail_tcp_fdov

    /* Verify RXLEN unchanged (still TCP_RXBUF_SIZE - 2, data NOT accepted) */
    ldrh    w0, [x21, #TCONN_RXLEN]
    cmp     w0, #(TCP_RXBUF_SIZE - 2)
    b.ne    .Lfail_tcp_fdov

    /* Verify RCV_NXT = 2 + 1(FIN only) = 3 */
    ldr     w0, [x21, #TCONN_RCV_NXT]
    cmp     w0, #3
    b.ne    .Lfail_tcp_fdov

    ldr     x0, =name_tcp_fdov
    bl      test_pass
    b       .Ldone_tcp_fdov
.Lfail_tcp_fdov:
    ldr     x0, =name_tcp_fdov
    bl      test_fail
.Ldone_tcp_fdov:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* ========================================================================
 * test_tcp_tw_fin_no_timer — TIME_WAIT+FIN with TIMER_SLOT=-1 → skip cancel
 *
 * Branch: tcp_timewait_fin_handler line 2772 (b.eq .Ltwfin_arm)
 * Exercises: TIMER_SLOT == -1 taken path (skips timer_cancel)
 * ======================================================================== */
test_tcp_tw_fin_no_timer:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_twnt
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Force TIME_WAIT with TIMER_SLOT = -1 (no active timer) */
    mov     w0, #TCPS_TIME_WAIT
    strb    w0, [x21, #TCONN_STATE]
    mov     w0, #3
    str     w0, [x21, #TCONN_RCV_NXT]
    mov     w0, #-1
    str     w0, [x21, #TCONN_TIMER_SLOT]

    /* Send FIN+ACK */
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

    /* Verify ACK reply generated */
    cmp     w0, #54
    b.lt    .Lfail_tcp_twnt

    /* Verify still TIME_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_TIME_WAIT
    b.ne    .Lfail_tcp_twnt

    /* Verify ACK flag in reply */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_ACK_FLAG
    b.ne    .Lfail_tcp_twnt

    ldr     x0, =name_tcp_twnt
    bl      test_pass
    b       .Ldone_tcp_twnt
.Lfail_tcp_twnt:
    ldr     x0, =name_tcp_twnt
    bl      test_fail
.Ldone_tcp_twnt:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* ========================================================================
 * test_tcp_tw_fin_no_pool — TIME_WAIT+FIN with pool=NULL → ACK but no timers
 *
 * Branches: tcp_timewait_fin_handler lines 2776, 2782 (cbz x0, .Ltwfin_done)
 * Exercises: pool==NULL taken path on both cancel and arm
 * ======================================================================== */
test_tcp_tw_fin_no_pool:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_twnp
    mov     x21, x0                 /* conn */
    mov     w22, w1                 /* ISN */

    /* Force TIME_WAIT */
    mov     w0, #TCPS_TIME_WAIT
    strb    w0, [x21, #TCONN_STATE]
    mov     w0, #3
    str     w0, [x21, #TCONN_RCV_NXT]
    /* TIMER_SLOT = 0 (not -1) so cancel path is entered */
    str     wzr, [x21, #TCONN_TIMER_SLOT]

    /* Save current timer pool ptr and set to NULL */
    ldr     x23, =tcp_timer_pool_ptr
    ldr     x24, [x23]              /* save old pool ptr */
    str     xzr, [x23]              /* pool = NULL */

    /* Send FIN+ACK */
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
    mov     w20, w0                 /* save return value */

    /* Restore timer pool ptr before any assertions */
    str     x24, [x23]

    /* Verify ACK reply generated */
    cmp     w20, #54
    b.lt    .Lfail_tcp_twnp

    /* Verify still TIME_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_TIME_WAIT
    b.ne    .Lfail_tcp_twnp

    /* Verify ACK flag in reply */
    ldrb    w0, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    cmp     w0, #TCP_ACK_FLAG
    b.ne    .Lfail_tcp_twnp

    ldr     x0, =name_tcp_twnp
    bl      test_pass
    b       .Ldone_tcp_twnp
.Lfail_tcp_twnp:
    /* Restore pool ptr on failure path too */
    str     x24, [x23]
    ldr     x0, =name_tcp_twnp
    bl      test_fail
.Ldone_tcp_twnp:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* ========================================================================
 * test_tcp_tw_fin_arm_no_pool — TIME_WAIT+FIN, TIMER_SLOT=-1 + pool=NULL
 *
 * Branch: tcp_timewait_fin_handler line 2782 (cbz x0, .Ltwfin_done)
 * Exercises: arm-path pool==NULL taken (skips timer_set)
 * Also exercises: TIMER_SLOT==-1 taken (line 2772)
 * ======================================================================== */
test_tcp_tw_fin_arm_no_pool:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_twap
    mov     x21, x0
    mov     w22, w1

    /* Force TIME_WAIT, TIMER_SLOT=-1, pool=NULL */
    mov     w0, #TCPS_TIME_WAIT
    strb    w0, [x21, #TCONN_STATE]
    mov     w0, #3
    str     w0, [x21, #TCONN_RCV_NXT]
    mov     w0, #-1
    str     w0, [x21, #TCONN_TIMER_SLOT]

    ldr     x23, =tcp_timer_pool_ptr
    ldr     x24, [x23]
    str     xzr, [x23]

    /* Send FIN+ACK */
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
    mov     w20, w0

    /* Restore pool */
    str     x24, [x23]

    /* Verify ACK reply */
    cmp     w20, #54
    b.lt    .Lfail_tcp_twap

    /* Verify still TIME_WAIT */
    ldrb    w0, [x21, #TCONN_STATE]
    cmp     w0, #TCPS_TIME_WAIT
    b.ne    .Lfail_tcp_twap

    ldr     x0, =name_tcp_twap
    bl      test_pass
    b       .Ldone_tcp_twap
.Lfail_tcp_twap:
    str     x24, [x23]
    ldr     x0, =name_tcp_twap
    bl      test_fail
.Ldone_tcp_twap:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret
    .ltorg

/* ========================================================================
 * test_tcp_ooo_outside_window — OOO segment with SEQ beyond RCV_WND → dup ACK
 * ======================================================================== */
.global test_tcp_ooo_outside_window
test_tcp_ooo_outside_window:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_oow
    mov     x19, x0

    /* Set RXLEN = 2000, so RCV_WND = 2048 - 2000 = 48 */
    mov     w0, #2000
    strh    w0, [x19, #TCONN_RXLEN]

    /* Build data frame with SEQ = RCV_NXT + 100 (gap=100 > window=48) */
    ldr     w3, [x19, #TCONN_RCV_NXT]
    add     w3, w3, #100            /* SEQ = RCV_NXT + 100 */
    ldr     w4, [x19, #TCONN_SND_NXT]
    ldr     x0, =tcp_test_buf
    mov     w1, #5                  /* 5 bytes payload */
    mov     w2, #0x41               /* fill = 'A' */
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf
    mov     w1, #59
    bl      tcp_handle

    /* Should return > 0 (dup ACK reply) */
    cmp     w0, #0
    b.le    .Lfail_tcp_oow

    /* OOO_COUNT should be 0 (not buffered due to window check) */
    ldrb    w0, [x19, #TCONN_OOO_COUNT]
    cbnz    w0, .Lfail_tcp_oow

    ldr     x0, =name_tcp_oow
    bl      test_pass
    b       .Ldone_tcp_oow
.Lfail_tcp_oow:
    ldr     x0, =name_tcp_oow
    bl      test_fail
.Ldone_tcp_oow:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_badack_state_rollback — handler fail restores original state
 * ======================================================================== */
.global test_tcp_badack_state_rollback
test_tcp_badack_state_rollback:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* SYN → SYN-ACK */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #62
    b.lt    .Lfail_tcp_bsr

    /* Find the SYN_RCVD connection */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE  /* slot 1 */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_SYN_RCVD
    b.ne    .Lfail_tcp_bsr

    /* Send bad ACK (ACK=0xDEADBEEF) → handler returns -1 */
    ldr     x0, =tcp_bad_ack_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle

    /* State should be rolled back to SYN_RCVD (not ESTABLISHED or CLOSED) */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_SYN_RCVD
    b.ne    .Lfail_tcp_bsr

    ldr     x0, =name_tcp_bsr
    bl      test_pass
    b       .Ldone_tcp_bsr
.Lfail_tcp_bsr:
    ldr     x0, =name_tcp_bsr
    bl      test_fail
.Ldone_tcp_bsr:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_rtx_resets_dupack — RTO callback resets DUP_ACK_CNT
 * ======================================================================== */
.global test_tcp_rtx_resets_dupack
test_tcp_rtx_resets_dupack:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rrd
    mov     x19, x0

    /* Set DUP_ACK_CNT to 2 */
    mov     w0, #2
    strb    w0, [x19, #TCONN_DUP_ACK_CNT]

    /* Set up for retransmit: need RTXLEN > 0, RTXCOUNT < max */
    mov     w0, #54
    strh    w0, [x19, #TCONN_RTXLEN]
    strb    wzr, [x19, #TCONN_RTXCOUNT]

    /* Install NULL send fn (skip actual send) */
    ldr     x0, =tcp_send_ctx
    str     xzr, [x0, #TSCTX_SEND_FN]

    /* Call retransmit callback */
    mov     x0, x19
    bl      tcp_retransmit_cb

    /* DUP_ACK_CNT should be 0 */
    ldrb    w0, [x19, #TCONN_DUP_ACK_CNT]
    cbnz    w0, .Lfail_tcp_rrd

    ldr     x0, =name_tcp_rrd
    bl      test_pass
    b       .Ldone_tcp_rrd
.Lfail_tcp_rrd:
    ldr     x0, =name_tcp_rrd
    bl      test_fail
.Ldone_tcp_rrd:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_reaper_synrcvd_60s — SYN_RCVD reaped at 60s, not 120s
 * ======================================================================== */
.global test_tcp_reaper_synrcvd_60s
test_tcp_reaper_synrcvd_60s:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init

    bl      timer_freq
    mov     x22, x0                 /* x22 = freq */

    /* Pre-seed slot 0 as SYN_RCVD with last_active = now - 61s */
    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_SYN_RCVD
    strb    w0, [x19, #TCONN_STATE]
    strh    wzr, [x19, #TCONN_RTXLEN]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    bl      timer_now
    mov     x1, #61
    mul     x1, x22, x1
    sub     x21, x0, x1            /* last_active = now - 61*freq */
    str     x21, [x19, #TCONN_LAST_ACTIVE]

    /* Fire reaper — should close (61 > 60s SYN_RCVD timeout) */
    mov     x0, xzr
    bl      tcp_idle_reaper_cb

    ldrb    w0, [x19, #TCONN_STATE]
    cbnz    w0, .Lfail_tcp_rs60

    ldr     x0, =name_tcp_rs60
    bl      test_pass
    b       .Ldone_tcp_rs60
.Lfail_tcp_rs60:
    ldr     x0, =name_tcp_rs60
    bl      test_fail
.Ldone_tcp_rs60:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_tcp_rtt_init — first RTT sample initializes SRTT/RTTVAR/RTO
 * ======================================================================== */
.global test_tcp_rtt_init
test_tcp_rtt_init:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_ri
    mov     x19, x0

    /* Simulate RTT: set SEND_TICK, clear RTXCOUNT, then call tcp_rtt_update */
    bl      timer_freq
    mov     x20, x0                 /* freq */

    /* R = 50ms = freq / 20 */
    udiv    w0, w20, w0
    mov     w2, #20
    udiv    w0, w20, w2             /* R = freq/20 (50ms in ticks) */
    mov     x1, x19
    bl      tcp_rtt_update

    /* SRTT should be R (first sample) */
    ldr     w0, [x19, #TCONN_SRTT]
    cbz     w0, .Lfail_tcp_ri      /* should be non-zero */

    /* RTTVAR should be R/2 */
    ldr     w1, [x19, #TCONN_RTTVAR]
    cbz     w1, .Lfail_tcp_ri

    /* RTO should be SRTT + 4*RTTVAR >= freq (1 sec minimum) */
    ldr     w2, [x19, #TCONN_RTO]
    cmp     w2, w20                 /* RTO >= freq? */
    b.lo    .Lfail_tcp_ri

    ldr     x0, =name_tcp_ri
    bl      test_pass
    b       .Ldone_tcp_ri
.Lfail_tcp_ri:
    ldr     x0, =name_tcp_ri
    bl      test_fail
.Ldone_tcp_ri:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_rto_double — retransmit callback doubles RTO
 * ======================================================================== */
.global test_tcp_rto_double
test_tcp_rto_double:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rd2
    mov     x19, x0

    /* Set RTO to a known value */
    bl      timer_freq
    str     w0, [x19, #TCONN_RTO]  /* RTO = 1 sec */
    mov     w20, w0                 /* save freq */

    /* Set up retransmit state */
    mov     w0, #54
    strh    w0, [x19, #TCONN_RTXLEN]
    strb    wzr, [x19, #TCONN_RTXCOUNT]
    ldr     x0, =tcp_send_ctx
    str     xzr, [x0, #TSCTX_SEND_FN]  /* NULL send → skip actual send */

    /* Call retransmit callback */
    mov     x0, x19
    bl      tcp_retransmit_cb

    /* RTO should be doubled (2 * freq) */
    ldr     w0, [x19, #TCONN_RTO]
    lsl     w1, w20, #1            /* 2 * freq */
    cmp     w0, w1
    b.ne    .Lfail_tcp_rd2

    ldr     x0, =name_tcp_rd2
    bl      test_pass
    b       .Ldone_tcp_rd2
.Lfail_tcp_rd2:
    ldr     x0, =name_tcp_rd2
    bl      test_fail
.Ldone_tcp_rd2:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_rtt_karn — no RTT sample on retransmitted segment
 * ======================================================================== */
.global test_tcp_rtt_karn
test_tcp_rtt_karn:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_rk
    mov     x19, x0

    /* Set up: SRTT=1000, RTXCOUNT=1 (retransmitted), SEND_TICK=nonzero */
    mov     w0, #1000
    str     w0, [x19, #TCONN_SRTT]
    mov     w0, #500
    str     w0, [x19, #TCONN_RTTVAR]
    mov     w0, #1
    strb    w0, [x19, #TCONN_RTXCOUNT]  /* marks as retransmitted */
    mov     x0, #12345
    str     x0, [x19, #TCONN_SEND_TICK]

    /* Send data segment — ACK handler should skip RTT sample (Karn) */
    ldr     w3, [x19, #TCONN_RCV_NXT]  /* SEQ = RCV_NXT */
    ldr     w4, [x19, #TCONN_SND_NXT]  /* ACK = SND_NXT */
    ldr     x0, =tcp_test_buf
    mov     w1, #5                      /* 5 bytes payload */
    mov     w2, #0x41                   /* fill = 'A' */
    bl      ttcp_build_data_frame

    ldr     x0, =tcp_test_buf
    mov     w1, #59
    bl      tcp_handle

    /* SRTT should still be 1000 (not updated due to Karn) */
    ldr     w0, [x19, #TCONN_SRTT]
    cmp     w0, #1000
    b.ne    .Lfail_tcp_rk

    ldr     x0, =name_tcp_rk
    bl      test_pass
    b       .Ldone_tcp_rk
.Lfail_tcp_rk:
    ldr     x0, =name_tcp_rk
    bl      test_fail
.Ldone_tcp_rk:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_wscale_negotiate — SYN with WSCALE=4 → SND_WSCALE=4
 * ======================================================================== */
.global test_tcp_wscale_negotiate
test_tcp_wscale_negotiate:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Build SYN with WSCALE option: 58 bytes = 54 + NOP + Kind=3 + Len=3 + Shift=4 */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum

    /* Append WSCALE option at TCP offset 20 */
    ldr     x0, =tcp_test_buf
    /* Fix doff to 6 words (24 bytes = 20 + 4 WSCALE) */
    mov     w1, #0x60
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_DATA_OFF)]
    /* NOP + WSCALE option */
    mov     w1, #1
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + 20)]     /* NOP */
    mov     w1, #TCP_OPT_WSCALE
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + 21)]
    mov     w1, #TCP_OPT_WSCALE_LEN
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + 22)]
    mov     w1, #4                                          /* shift=4 */
    strb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + 23)]
    /* Update IP totlen = 44 (IP(20) + TCP(24)) → 0x2C00 LE */
    mov     w1, #0x2C00
    strh    w1, [x0, #(ETH_PAYLOAD + IP_TOTLEN)]
    /* Recompute checksums for 58-byte frame (TCP section = 24 bytes) */
    strh    wzr, [x0, #(ETH_PAYLOAD + IP_CHECKSUM)]
    strh    wzr, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    ldr     x1, =tcp_test_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_CHECKSUM)]
    mov     x0, x1
    mov     w1, #24
    bl      tcp_checksum
    ldr     x1, =tcp_test_buf
    strh    w0, [x1, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    ldr     x0, =tcp_test_buf
    mov     w1, #58
    bl      tcp_handle
    cmp     w0, #0
    b.le    .Lfail_tcp_wsn

    /* Find SYN_RCVD conn and check SND_WSCALE == 4 */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE
    ldrb    w0, [x19, #TCONN_SND_WSCALE]
    cmp     w0, #4
    b.ne    .Lfail_tcp_wsn

    ldr     x0, =name_tcp_wsn
    bl      test_pass
    b       .Ldone_tcp_wsn
.Lfail_tcp_wsn:
    ldr     x0, =name_tcp_wsn
    bl      test_fail
.Ldone_tcp_wsn:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_wscale_no_opt — SYN without WSCALE → SND_WSCALE=0
 * ======================================================================== */
.global test_tcp_wscale_no_opt
test_tcp_wscale_no_opt:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen

    /* Send bare SYN (no WSCALE) */
    ldr     x0, =tcp_syn_template
    ldr     x1, =tcp_test_buf
    mov     w2, #54
    bl      ttcp_fill_checksum
    ldr     x0, =tcp_test_buf
    mov     w1, #54
    bl      tcp_handle
    cmp     w0, #0
    b.le    .Lfail_tcp_wno

    /* SND_WSCALE should be 0 */
    ldr     x19, =tcp_conn_table
    add     x19, x19, #TCONN_SIZE
    ldrb    w0, [x19, #TCONN_SND_WSCALE]
    cbnz    w0, .Lfail_tcp_wno

    ldr     x0, =name_tcp_wno
    bl      test_pass
    b       .Ldone_tcp_wno
.Lfail_tcp_wno:
    ldr     x0, =name_tcp_wno
    bl      test_fail
.Ldone_tcp_wno:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_tcp_wscale_window_apply — WSCALE=2 → SND_WND = raw_window << 2
 * ======================================================================== */
.global test_tcp_wscale_window_apply
test_tcp_wscale_window_apply:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      ttcp_do_handshake
    cbz     x0, .Lfail_tcp_wwa
    mov     x19, x0

    /* Set SND_WSCALE = 2 */
    mov     w0, #2
    strb    w0, [x19, #TCONN_SND_WSCALE]

    /* Build data ACK with window=100 (NBO) */
    ldr     w3, [x19, #TCONN_RCV_NXT]
    ldr     w4, [x19, #TCONN_SND_NXT]
    ldr     x0, =tcp_test_buf
    mov     w1, #5
    mov     w2, #0x41
    bl      ttcp_build_data_frame

    /* Patch window to 100 (NBO) = 0x6400 LE */
    ldr     x0, =tcp_test_buf
    mov     w1, #0x6400
    strh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]

    /* Recompute TCP checksum */
    strh    wzr, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]
    mov     w1, #25
    bl      tcp_checksum
    mov     w2, w0                  /* save checksum */
    ldr     x0, =tcp_test_buf
    strh    w2, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_CHECKSUM)]

    mov     w1, #59
    bl      tcp_handle

    /* SND_WND should be 100 << 2 = 400 */
    ldr     w0, [x19, #TCONN_SND_WND]
    cmp     w0, #400
    b.ne    .Lfail_tcp_wwa

    ldr     x0, =name_tcp_wwa
    bl      test_pass
    b       .Ldone_tcp_wwa
.Lfail_tcp_wwa:
    ldr     x0, =name_tcp_wwa
    bl      test_fail
.Ldone_tcp_wwa:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

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
 * 58-byte TCP SYN to port 80 from 10.0.2.2:12345, SEQ=1, with MSS=1460
 *
 * Same as tcp_syn_template but with MSS option (Kind=2, Len=4, MSS=1460)
 * IP totlen = 44 (0x002C), data offset = 6 (24 bytes)
 */
.balign 4
tcp_syn_mss_template:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x00                               /* EtherType: IPv4 */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x2C                               /* totlen: 44 */
    .byte   0x12, 0x34                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x06                               /* ttl=64, proto=TCP */
    .byte   0x50, 0x88                               /* IP checksum */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* src: 10.0.2.2 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    .byte   0x30, 0x39                               /* sport: 12345 */
    .byte   0x00, 0x50                               /* dport: 80 */
    .byte   0x00, 0x00, 0x00, 0x01                   /* seq: 1 */
    .byte   0x00, 0x00, 0x00, 0x00                   /* ack: 0 */
    .byte   0x60                                     /* data offset: 6 (24 bytes) */
    .byte   0x02                                     /* flags: SYN */
    .byte   0xFF, 0xFF                               /* window: 65535 */
    .byte   0x00, 0x00                               /* checksum: 0 */
    .byte   0x00, 0x00                               /* urgent: 0 */
    .byte   0x02, 0x04, 0x05, 0xB4                   /* MSS option: 1460 */

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
name_tcp_samss:     .asciz "tcp_synack_mss"
name_tcp_pmss:      .asciz "tcp_peer_mss"
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
name_tcp_rtxs:      .asciz "tcp_rtx_save_on_send"
name_tcp_rtxc:      .asciz "tcp_rtx_clear_on_ack"
name_tcp_sgate:     .asciz "tcp_send_gate_rtx"
name_tcp_srgate:    .asciz "tcp_send_ready_gate_rtx"
name_tcp_rcbs:      .asciz "tcp_rtx_cb_send"
name_tcp_rcbm:      .asciz "tcp_rtx_cb_max_retries"
name_tcp_sars:      .asciz "tcp_synack_rtx_save"
name_tcp_sarc:      .asciz "tcp_synack_rtx_clear"
name_tcp_frs:       .asciz "tcp_fin_rtx_save"
name_tcp_frcf:      .asciz "tcp_fin_rtx_clear_fw1"
name_tcp_frcl:      .asciz "tcp_fin_rtx_clear_lastack"
name_tcp_dda:       .asciz "tcp_dup_data_ack"
name_tcp_rcr:       .asciz "tcp_rst_clears_rtx"
name_tcp_rtocap:    .asciz "tcp_rtx_arm_rto_cap"
name_tcp_rcnp:      .asciz "tcp_rtx_clear_no_pool"
name_tcp_rcsc:      .asciz "tcp_rtx_cb_stale_closed"
name_tcp_rcsl:      .asciz "tcp_rtx_cb_stale_listen"
name_tcp_rcnsf:     .asciz "tcp_rtx_cb_no_send_fn"
name_tcp_sufa:      .asciz "tcp_snd_una_future_ack"
name_tcp_lp:        .asciz "tcp_listen_port"
name_tcp_lm:        .asciz "tcp_listen_multi"
name_tcp_lf:        .asciz "tcp_listen_full"
name_tcp_idt:       .asciz "tcp_isn_different_tuples"
name_tcp_ist:       .asciz "tcp_isn_same_tuple"
name_tcp_inz:       .asciz "tcp_isn_nonzero"
name_tcp_iem:       .asciz "tcp_icmp_err_match"
name_tcp_ienm:      .asciz "tcp_icmp_err_no_match"
name_tcp_ierc:      .asciz "tcp_icmp_err_rtx_clear"
name_tcp_ies:       .asciz "tcp_icmp_err_short"
name_tcp_tssn:      .asciz "tcp_ts_syn_negotiate"
name_tcp_tsno:      .asciz "tcp_ts_syn_no_opt"
name_tcp_trfs:      .asciz "tcp_ts_reply_frame_size"
name_tcp_trnt:      .asciz "tcp_ts_reply_no_ts"
name_tcp_tbfs:      .asciz "tcp_ts_build_frame_size"
name_tcp_tpa:       .asciz "tcp_ts_paws_accept"
name_tcp_tpr:       .asciz "tcp_ts_paws_reject"
name_tcp_tru:       .asciz "tcp_ts_recent_update"
name_tcp_ielp:      .asciz "tcp_icmp_err_lport"
name_tcp_ierip:     .asciz "tcp_icmp_err_rip"
name_tcp_iepu:      .asciz "tcp_icmp_err_proto_unreach"
name_tcp_ieptu:     .asciz "tcp_icmp_err_port_unreach"
name_tcp_tse:       .asciz "tcp_tsopt_exhaust"
name_tcp_tseol:     .asciz "tcp_tsopt_eol"
name_tcp_tstr:      .asciz "tcp_tsopt_trunc"
name_tcp_tsbl:      .asciz "tcp_tsopt_badlen"
name_tcp_tssk:      .asciz "tcp_tsopt_skip"
name_tcp_tswt:      .asciz "tcp_tsopt_wrong_tslen"
name_tcp_pnt:       .asciz "tcp_paws_no_tsopt"
name_tcp_tstt:      .asciz "tcp_tsopt_trunc_ts"
name_tcp_cwg:       .asciz "tcp_cwnd_grow"
name_tcp_crr:       .asciz "tcp_cwnd_rtx_reset"
name_tcp_cwga:      .asciz "tcp_cwnd_gate"
name_tcp_oom:       .asciz "tcp_ooo_merge"
name_tcp_rl:        .asciz "tcp_rst_ratelimit"
name_tcp_rf:        .asciz "tcp_rst_refill"
name_tcp_sevict:    .asciz "tcp_syn_evict"
name_tcp_rsv:       .asciz "tcp_rst_seq_valid"
name_tcp_rsi:       .asciz "tcp_rst_seq_invalid"
name_tcp_iet:       .asciz "tcp_idle_estab_timeout"
name_tcp_iea:       .asciz "tcp_idle_estab_active"
name_tcp_ift:       .asciz "tcp_idle_finwait2_timeout"
name_tcp_ict:       .asciz "tcp_idle_closewait_timeout"
name_tcp_frtx:      .asciz "tcp_fast_retransmit"
name_tcp_dabt:      .asciz "tcp_dupack_below_thresh"
name_tcp_pa:        .asciz "tcp_persist_arm"
name_tcp_pc:        .asciz "tcp_persist_cancel"
name_tcp_dnr:       .asciz "tcp_dupack_no_rtxdata"
name_tcp_paa:       .asciz "tcp_persist_already_armed"
name_tcp_fns:       .asciz "tcp_frtx_no_send_fn"
name_tcp_fcf:       .asciz "tcp_frtx_cwnd_floor"
name_tcp_rsl:       .asciz "tcp_reaper_skip_listen"
name_tcp_rst2:      .asciz "tcp_reaper_skip_timewait"
name_tcp_rsyr:      .asciz "tcp_reaper_synrcvd"
name_tcp_rfw1:      .asciz "tcp_reaper_finwait1"
name_tcp_sr:        .asciz "tcp_start_reaper"
name_tcp_srnp:      .asciz "tcp_start_reaper_no_pool"
name_tcp_pcs:       .asciz "tcp_persist_cb_send"
name_tcp_pcne:      .asciz "tcp_persist_cb_not_estab"
name_tcp_pcwo:      .asciz "tcp_persist_cb_wnd_open"
name_tcp_pcns:      .asciz "tcp_persist_cb_no_send_fn"
name_tcp_pcsc:      .asciz "tcp_persist_cb_shift_cap"
name_tcp_pawp:      .asciz "tcp_persist_arm_with_pool"
name_tcp_df:        .asciz "tcp_df_bit"
name_tcp_fwd:       .asciz "tcp_fin_with_data"
name_tcp_fdbs:      .asciz "tcp_fin_data_bad_seq"
name_tcp_fdov:      .asciz "tcp_fin_data_overflow"
name_tcp_twfr:      .asciz "tcp_timewait_fin_reack"
name_tcp_twnt:      .asciz "tcp_tw_fin_no_timer"
name_tcp_twnp:      .asciz "tcp_tw_fin_no_pool"
name_tcp_twap:      .asciz "tcp_tw_fin_arm_no_pool"
name_tcp_oow:       .asciz "tcp_ooo_outside_window"
name_tcp_bsr:       .asciz "tcp_badack_state_rollback"
name_tcp_rrd:       .asciz "tcp_rtx_resets_dupack"
name_tcp_rs60:      .asciz "tcp_reaper_synrcvd_60s"
name_tcp_ri:        .asciz "tcp_rtt_init"
name_tcp_rd2:       .asciz "tcp_rto_double"
name_tcp_rk:        .asciz "tcp_rtt_karn"
name_tcp_wsn:       .asciz "tcp_wscale_negotiate"
name_tcp_wno:       .asciz "tcp_wscale_no_opt"
name_tcp_wwa:       .asciz "tcp_wscale_window_apply"

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

.balign 4
ttcp_mock_send_count:
    .word   0

.balign 4
ttcp_mock_send_len:
    .word   0
