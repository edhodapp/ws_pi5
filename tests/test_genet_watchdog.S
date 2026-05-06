/*
 * test_genet_watchdog.S — Unit tests for the GENET watchdog helpers.
 *
 * The TX-wedge watchdog has two sides: a counter-arithmetic helper
 * (genet_wd_record_timeout) called from the .Ltx_timeout path inside
 * genet_send, and a counter-arithmetic helper (genet_wd_record_reset)
 * called from genet_watchdog_trip before it fires the actual GENET
 * reinit. Both helpers were extracted into pure-software functions
 * specifically so the bookkeeping can be pinned in unit tests
 * without faking the GENET MMIO surface or the uart_puts /
 * genet_init dependencies that genet_watchdog_trip itself depends
 * on.
 *
 * The MMIO-bearing trip path (genet_watchdog_trip) is not unit-
 * testable with the same techniques and is exercised at the
 * integration tier (the dynamics suite + manual bringup runs).
 *
 * Tests:
 *   1. test_wd_timeout_first_increment
 *   2. test_wd_timeout_below_threshold
 *   3. test_wd_timeout_at_threshold
 *   4. test_wd_timeout_above_threshold
 *   5. test_wd_timeout_preserves_other_state
 *   6. test_wd_reset_increments_count
 *   7. test_wd_reset_zeros_consec_timeouts
 *   8. test_wd_reset_preserves_other_state
 *   9. test_wd_reset_count_accumulates_across_calls
 */

.include "genet.inc"

.global test_wd_timeout_first_increment
.global test_wd_timeout_below_threshold
.global test_wd_timeout_at_threshold
.global test_wd_timeout_above_threshold
.global test_wd_timeout_preserves_other_state
.global test_wd_reset_increments_count
.global test_wd_reset_zeros_consec_timeouts
.global test_wd_reset_preserves_other_state
.global test_wd_reset_count_accumulates_across_calls

.section .text

/* Helper: zero the fake_state block (40 bytes / GENET_STATE_SIZE).
 * Clobbers x0, x1. */
.Lzero_state:
    ldr     x0, =fake_state
    str     xzr, [x0, #0]
    str     xzr, [x0, #8]
    str     xzr, [x0, #16]
    str     xzr, [x0, #24]
    str     xzr, [x0, #32]
    ret

/* Helper: load fake_state into x19 for assertions. */
.Lload_state:
    ldr     x19, =fake_state
    ret

/* ============================================================
 * Counter helper test scaffolding.
 * Each test does:
 *   1. zero fake_state
 *   2. (optionally) seed fields
 *   3. call helper(s)
 *   4. assert observable post-conditions
 * ============================================================ */

/* test_wd_timeout_first_increment
 *   Pre:  TX_CONSEC_TIMEOUTS = 0
 *   Call: genet_wd_record_timeout(&state)
 *   Post: TX_CONSEC_TIMEOUTS = 1, w0 = 0 (below threshold)
 */
.balign 4
test_wd_timeout_first_increment:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    bl      genet_wd_record_timeout
    cbnz    w0, .Lt1_fail
    bl      .Lload_state
    ldr     w0, [x19, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    cmp     w0, #1
    b.ne    .Lt1_fail
    ldr     x0, =.Lname_t1
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt1_fail:
    ldr     x0, =.Lname_t1
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t1: .asciz "wd_timeout_first_increment"

/* test_wd_timeout_below_threshold
 *   Pre:  TX_CONSEC_TIMEOUTS = THRESHOLD - 2
 *   Call: genet_wd_record_timeout(&state)
 *   Post: TX_CONSEC_TIMEOUTS = THRESHOLD - 1, w0 = 0 (still below)
 *
 * Pins the boundary just below the trip point — proves the
 * comparison is "≥ threshold", not "> threshold".
 */
.balign 4
test_wd_timeout_below_threshold:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    mov     w1, #(GENET_WD_TX_TIMEOUT_THRESHOLD - 2)
    str     w1, [x0, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    bl      genet_wd_record_timeout
    cbnz    w0, .Lt2_fail
    bl      .Lload_state
    ldr     w0, [x19, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    cmp     w0, #(GENET_WD_TX_TIMEOUT_THRESHOLD - 1)
    b.ne    .Lt2_fail
    ldr     x0, =.Lname_t2
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt2_fail:
    ldr     x0, =.Lname_t2
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t2: .asciz "wd_timeout_below_threshold"

/* test_wd_timeout_at_threshold
 *   Pre:  TX_CONSEC_TIMEOUTS = THRESHOLD - 1
 *   Call: genet_wd_record_timeout(&state)
 *   Post: TX_CONSEC_TIMEOUTS = THRESHOLD, w0 = 1 (trip)
 */
.balign 4
test_wd_timeout_at_threshold:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    mov     w1, #(GENET_WD_TX_TIMEOUT_THRESHOLD - 1)
    str     w1, [x0, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    bl      genet_wd_record_timeout
    cmp     w0, #1
    b.ne    .Lt3_fail
    bl      .Lload_state
    ldr     w0, [x19, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    cmp     w0, #GENET_WD_TX_TIMEOUT_THRESHOLD
    b.ne    .Lt3_fail
    ldr     x0, =.Lname_t3
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt3_fail:
    ldr     x0, =.Lname_t3
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t3: .asciz "wd_timeout_at_threshold"

/* test_wd_timeout_above_threshold
 *   Pre:  TX_CONSEC_TIMEOUTS = THRESHOLD (we missed the reset)
 *   Call: genet_wd_record_timeout(&state)
 *   Post: TX_CONSEC_TIMEOUTS = THRESHOLD + 1, w0 = 1 (still trip)
 *
 * The helper must keep returning 1 above threshold so the caller
 * always retries the trip path until somebody zeros the counter.
 * Without this property a missed reset would silently un-trip on
 * the next timeout.
 */
.balign 4
test_wd_timeout_above_threshold:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    mov     w1, #GENET_WD_TX_TIMEOUT_THRESHOLD
    str     w1, [x0, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    bl      genet_wd_record_timeout
    cmp     w0, #1
    b.ne    .Lt4_fail
    bl      .Lload_state
    ldr     w0, [x19, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    cmp     w0, #(GENET_WD_TX_TIMEOUT_THRESHOLD + 1)
    b.ne    .Lt4_fail
    ldr     x0, =.Lname_t4
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt4_fail:
    ldr     x0, =.Lname_t4
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t4: .asciz "wd_timeout_above_threshold"

/* test_wd_timeout_preserves_other_state
 *   Pre:  All non-watchdog fields populated with sentinels
 *   Call: genet_wd_record_timeout(&state)
 *   Post: Only TX_CONSEC_TIMEOUTS changed; everything else intact.
 *
 * Pins the helper's locality — it must not stomp on RX/TX ring
 * indices or the RX pool pointer or PHY speed, all of which live
 * in the same struct.
 */
.balign 4
test_wd_timeout_preserves_other_state:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    /* Sentinel values for every non-WD field. */
    mov     w1, #0xAA
    str     w1, [x0, #GENET_STATE_RX_CIDX]
    mov     w1, #0xBB
    str     w1, [x0, #GENET_STATE_RX_RIDX]
    mov     w1, #0xCC
    str     w1, [x0, #GENET_STATE_TX_PIDX]
    mov     w1, #0xDD
    str     w1, [x0, #GENET_STATE_TX_RIDX]
    ldr     x1, =0x1122334455667788
    str     x1, [x0, #GENET_STATE_RX_POOL]
    mov     w1, #0xEE
    str     w1, [x0, #GENET_STATE_PHY_SPEED]
    mov     w1, #0xF1
    str     w1, [x0, #GENET_STATE_WD_RESET_COUNT]
    bl      genet_wd_record_timeout
    bl      .Lload_state
    /* Verify the helper actually moved TX_CONSEC_TIMEOUTS — without
     * this the test would also pass against a hypothetical buggy
     * helper that incremented WD_RESET_COUNT instead. */
    ldr     w0, [x19, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    cmp     w0, #1
    b.ne    .Lt5_fail
    ldr     w0, [x19, #GENET_STATE_RX_CIDX]
    cmp     w0, #0xAA
    b.ne    .Lt5_fail
    ldr     w0, [x19, #GENET_STATE_RX_RIDX]
    cmp     w0, #0xBB
    b.ne    .Lt5_fail
    ldr     w0, [x19, #GENET_STATE_TX_PIDX]
    cmp     w0, #0xCC
    b.ne    .Lt5_fail
    ldr     w0, [x19, #GENET_STATE_TX_RIDX]
    cmp     w0, #0xDD
    b.ne    .Lt5_fail
    ldr     x0, [x19, #GENET_STATE_RX_POOL]
    ldr     x1, =0x1122334455667788
    cmp     x0, x1
    b.ne    .Lt5_fail
    ldr     w0, [x19, #GENET_STATE_PHY_SPEED]
    cmp     w0, #0xEE
    b.ne    .Lt5_fail
    ldr     w0, [x19, #GENET_STATE_WD_RESET_COUNT]
    cmp     w0, #0xF1
    b.ne    .Lt5_fail
    ldr     x0, =.Lname_t5
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt5_fail:
    ldr     x0, =.Lname_t5
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t5: .asciz "wd_timeout_preserves_other_state"

/* test_wd_reset_increments_count
 *   Pre:  WD_RESET_COUNT = 5
 *   Call: genet_wd_record_reset(&state)
 *   Post: WD_RESET_COUNT = 6
 */
.balign 4
test_wd_reset_increments_count:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    mov     w1, #5
    str     w1, [x0, #GENET_STATE_WD_RESET_COUNT]
    bl      genet_wd_record_reset
    bl      .Lload_state
    ldr     w0, [x19, #GENET_STATE_WD_RESET_COUNT]
    cmp     w0, #6
    b.ne    .Lt6_fail
    ldr     x0, =.Lname_t6
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt6_fail:
    ldr     x0, =.Lname_t6
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t6: .asciz "wd_reset_increments_count"

/* test_wd_reset_zeros_consec_timeouts
 *   Pre:  TX_CONSEC_TIMEOUTS = THRESHOLD (just tripped)
 *   Call: genet_wd_record_reset(&state)
 *   Post: TX_CONSEC_TIMEOUTS = 0
 *
 * This is the property that prevents the tight reset-loop failure
 * mode: once we reset, the next timeout starts a brand-new window
 * rather than re-tripping immediately.
 */
.balign 4
test_wd_reset_zeros_consec_timeouts:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    mov     w1, #GENET_WD_TX_TIMEOUT_THRESHOLD
    str     w1, [x0, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    bl      genet_wd_record_reset
    bl      .Lload_state
    ldr     w0, [x19, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    cbnz    w0, .Lt7_fail
    ldr     x0, =.Lname_t7
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt7_fail:
    ldr     x0, =.Lname_t7
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t7: .asciz "wd_reset_zeros_consec_timeouts"

/* test_wd_reset_preserves_other_state
 *   Pre:  Sentinels in every non-WD field
 *   Call: genet_wd_record_reset(&state)
 *   Post: Only WD_RESET_COUNT and TX_CONSEC_TIMEOUTS changed.
 */
.balign 4
test_wd_reset_preserves_other_state:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    mov     w1, #0xAA
    str     w1, [x0, #GENET_STATE_RX_CIDX]
    mov     w1, #0xBB
    str     w1, [x0, #GENET_STATE_RX_RIDX]
    mov     w1, #0xCC
    str     w1, [x0, #GENET_STATE_TX_PIDX]
    mov     w1, #0xDD
    str     w1, [x0, #GENET_STATE_TX_RIDX]
    ldr     x1, =0x99AABBCCDDEEFF00
    str     x1, [x0, #GENET_STATE_RX_POOL]
    mov     w1, #0xEE
    str     w1, [x0, #GENET_STATE_PHY_SPEED]
    bl      genet_wd_record_reset
    bl      .Lload_state
    ldr     w0, [x19, #GENET_STATE_RX_CIDX]
    cmp     w0, #0xAA
    b.ne    .Lt8_fail
    ldr     w0, [x19, #GENET_STATE_RX_RIDX]
    cmp     w0, #0xBB
    b.ne    .Lt8_fail
    ldr     w0, [x19, #GENET_STATE_TX_PIDX]
    cmp     w0, #0xCC
    b.ne    .Lt8_fail
    ldr     w0, [x19, #GENET_STATE_TX_RIDX]
    cmp     w0, #0xDD
    b.ne    .Lt8_fail
    ldr     x0, [x19, #GENET_STATE_RX_POOL]
    ldr     x1, =0x99AABBCCDDEEFF00
    cmp     x0, x1
    b.ne    .Lt8_fail
    ldr     w0, [x19, #GENET_STATE_PHY_SPEED]
    cmp     w0, #0xEE
    b.ne    .Lt8_fail
    ldr     x0, =.Lname_t8
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt8_fail:
    ldr     x0, =.Lname_t8
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t8: .asciz "wd_reset_preserves_other_state"

/* test_wd_reset_count_accumulates_across_calls
 *   Three resets back to back must leave WD_RESET_COUNT at 3,
 *   pinning that the counter is monotonic-since-boot and not
 *   recomputed from some local state.
 */
.balign 4
test_wd_reset_count_accumulates_across_calls:
    stp     x29, x30, [sp, #-16]!
    bl      .Lzero_state
    ldr     x0, =fake_state
    bl      genet_wd_record_reset
    ldr     x0, =fake_state
    bl      genet_wd_record_reset
    ldr     x0, =fake_state
    bl      genet_wd_record_reset
    bl      .Lload_state
    ldr     w0, [x19, #GENET_STATE_WD_RESET_COUNT]
    cmp     w0, #3
    b.ne    .Lt9_fail
    ldr     x0, =.Lname_t9
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lt9_fail:
    ldr     x0, =.Lname_t9
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lname_t9: .asciz "wd_reset_count_accumulates_across_calls"

/* ============================================================ */

.section .bss
.align 3
fake_state:
    .space  GENET_STATE_SIZE
