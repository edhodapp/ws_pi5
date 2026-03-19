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

.section .data
.balign 4
tcp_test_buf:
    .space  128

.balign 4
tcp_test_buf2:
    .space  128
