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
 */

.include "net.inc"
.include "tcp.inc"

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

    /* TCP window = 1460 (NBO) */
    ldrh    w1, [x19, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_WINDOW)]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #1460
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
 * Handshake → ESTABLISHED, overwrite state to LAST_ACK (state 5, all-zero
 * FSA row). Send matching ACK → exact match → FSA lookup → handler=0 →
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

    /* Send matching ACK → exact match → LAST_ACK → FSA handler=NULL → RST */
    ldr     x0, =tcp_handshake_ack_template
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

.section .data
.balign 4
tcp_test_buf:
    .space  128

.balign 4
tcp_test_buf2:
    .space  128
