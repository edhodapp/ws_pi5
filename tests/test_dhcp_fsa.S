/*
 * test_dhcp_fsa.S — engine-level smoke tests for lib/dhcp_fsa.S.
 *
 * The TABLE itself is verified against the TSV by
 *   make verify-dhcp-fsa-table
 * (which runs scripts/verify_dhcp_fsa_table.py against the kernel ELF).
 * These tests instead exercise the STEP function: given a (state, event)
 * pair, does the engine read the right cell, dispatch the handler, and
 * update the state correctly?
 *
 * The handlers in lib/dhcp_fsa.S are stubs that bump per-handler
 * counters. Tests reset the counters + state, fire one event, and
 * assert on (next state, counter delta).
 */

.include "dhcp.inc"

.global test_dhcp_fsa_step_init_start
.global test_dhcp_fsa_step_no_handler
.global test_dhcp_fsa_step_oob_event
.global test_dhcp_fsa_step_oob_state
.global test_dhcp_fsa_step_panic_d_runs
.global test_dhcp_start_populates_ctx_and_fires

.section .text

/* Reset state + counters. Macros emitted inline avoid pulling in
 * another include just for this test file. */
_dhcp_test_reset:
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    str     wzr, [x0]
    /* Zero all 10 handler counters. They live contiguously after
     * dhcp_fsa_state in BSS, but for clarity zero each by name. */
    adrp    x0, dhcp_count_send_discover
    add     x0, x0, :lo12:dhcp_count_send_discover
    str     wzr, [x0]
    adrp    x0, dhcp_count_resend_discover
    add     x0, x0, :lo12:dhcp_count_resend_discover
    str     wzr, [x0]
    adrp    x0, dhcp_count_record_offer_send_request
    add     x0, x0, :lo12:dhcp_count_record_offer_send_request
    str     wzr, [x0]
    adrp    x0, dhcp_count_resend_request_selecting
    add     x0, x0, :lo12:dhcp_count_resend_request_selecting
    str     wzr, [x0]
    adrp    x0, dhcp_count_commit_lease_arm_timers
    add     x0, x0, :lo12:dhcp_count_commit_lease_arm_timers
    str     wzr, [x0]
    adrp    x0, dhcp_count_send_request_renew
    add     x0, x0, :lo12:dhcp_count_send_request_renew
    str     wzr, [x0]
    adrp    x0, dhcp_count_resend_request_renew
    add     x0, x0, :lo12:dhcp_count_resend_request_renew
    str     wzr, [x0]
    adrp    x0, dhcp_count_send_request_rebind
    add     x0, x0, :lo12:dhcp_count_send_request_rebind
    str     wzr, [x0]
    adrp    x0, dhcp_count_resend_request_rebind
    add     x0, x0, :lo12:dhcp_count_resend_request_rebind
    str     wzr, [x0]
    adrp    x0, dhcp_count_panic_d
    add     x0, x0, :lo12:dhcp_count_panic_d
    str     wzr, [x0]
    ret


/* ========================================================================
 * test_dhcp_fsa_step_init_start — INIT + E_START dispatches
 * h_send_discover and advances state to SELECTING.
 * ======================================================================== */
test_dhcp_fsa_step_init_start:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset

    /* state already INIT (0) post-reset; fire E_START. */
    mov     w0, #E_START
    bl      dhcp_fsa_step

    /* Expect state == S_SELECTING. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #S_SELECTING
    b.ne    .Ldis_fail

    /* Expect h_send_discover counter == 1. */
    adrp    x0, dhcp_count_send_discover
    add     x0, x0, :lo12:dhcp_count_send_discover
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldis_fail

    ldr     x0, =_dhcp_name_step_init_start
    bl      test_pass
    b       .Ldis_done
.Ldis_fail:
    ldr     x0, =_dhcp_name_step_init_start
    bl      test_fail
.Ldis_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_fsa_step_no_handler — INIT + E_TIMER_T1 has handler=NONE
 * and NextState=NONE. Engine must leave state unchanged and run no
 * handler.
 * ======================================================================== */
test_dhcp_fsa_step_no_handler:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset

    /* state INIT, fire E_TIMER_T1. */
    mov     w0, #E_TIMER_T1
    bl      dhcp_fsa_step

    /* state must still be INIT. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cbnz    w0, .Lnh_fail

    /* h_send_discover counter must still be 0. */
    adrp    x0, dhcp_count_send_discover
    add     x0, x0, :lo12:dhcp_count_send_discover
    ldr     w0, [x0]
    cbnz    w0, .Lnh_fail

    ldr     x0, =_dhcp_name_step_no_handler
    bl      test_pass
    b       .Lnh_done
.Lnh_fail:
    ldr     x0, =_dhcp_name_step_no_handler
    bl      test_fail
.Lnh_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_fsa_step_oob_event — event >= DHCP_NEVENTS is a silent
 * no-op (defence in depth).
 * ======================================================================== */
test_dhcp_fsa_step_oob_event:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset

    /* Fire bogus event 99. */
    mov     w0, #99
    bl      dhcp_fsa_step

    /* state must still be INIT. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cbnz    w0, .Loe_fail

    ldr     x0, =_dhcp_name_step_oob_event
    bl      test_pass
    b       .Loe_done
.Loe_fail:
    ldr     x0, =_dhcp_name_step_oob_event
    bl      test_fail
.Loe_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_fsa_step_oob_state — state >= DHCP_NSTATES is a silent
 * no-op even with a valid event.
 * ======================================================================== */
test_dhcp_fsa_step_oob_state:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset

    /* Force bogus state. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    mov     w1, #99
    str     w1, [x0]

    /* Fire E_START. */
    mov     w0, #E_START
    bl      dhcp_fsa_step

    /* No handler ran. */
    adrp    x0, dhcp_count_send_discover
    add     x0, x0, :lo12:dhcp_count_send_discover
    ldr     w0, [x0]
    cbnz    w0, .Los_fail

    /* state remains 99. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #99
    b.ne    .Los_fail

    ldr     x0, =_dhcp_name_step_oob_state
    bl      test_pass
    b       .Los_done
.Los_fail:
    ldr     x0, =_dhcp_name_step_oob_state
    bl      test_fail
.Los_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_fsa_step_panic_d_runs — SELECTING + E_TIMER_RETRANS_GIVEUP
 * runs h_panic_d (stub bumps counter, returns) and leaves state
 * unchanged because NextState=NONE for that cell.
 * ======================================================================== */
test_dhcp_fsa_step_panic_d_runs:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset

    /* Set state to SELECTING. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    mov     w1, #S_SELECTING
    str     w1, [x0]

    /* Fire E_TIMER_RETRANS_GIVEUP. */
    mov     w0, #E_TIMER_RETRANS_GIVEUP
    bl      dhcp_fsa_step

    /* h_panic_d stub bumped its counter. */
    adrp    x0, dhcp_count_panic_d
    add     x0, x0, :lo12:dhcp_count_panic_d
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lpd_fail

    /* State stayed at SELECTING (NextState=NONE). */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #S_SELECTING
    b.ne    .Lpd_fail

    ldr     x0, =_dhcp_name_step_panic_d_runs
    bl      test_pass
    b       .Lpd_done
.Lpd_fail:
    ldr     x0, =_dhcp_name_step_panic_d_runs
    bl      test_fail
.Lpd_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_start_populates_ctx_and_fires — dhcp_start writes its
 * args into dhcp_send_ctx, fires E_START, and the FSA advances
 * from S_INIT to S_SELECTING via the h_send_discover dispatch.
 * ======================================================================== */
test_dhcp_start_populates_ctx_and_fires:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset

    /* Args: dwc2_base / ecm_state / tx_buf / timer_pool / send_fn.
     * Use easily-recognizable sentinels (low addresses) — dhcp_start
     * just stores them; no dereference. */
    movz    x0, #0x1111
    movz    x1, #0x2222
    movz    x2, #0x3333
    movz    x3, #0x4444
    movz    x4, #0x5555
    bl      dhcp_start

    /* State should have advanced to S_SELECTING via h_send_discover. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #S_SELECTING
    b.ne    .Ldsta_fail

    /* h_send_discover dispatch counter == 1. */
    adrp    x0, dhcp_count_send_discover
    add     x0, x0, :lo12:dhcp_count_send_discover
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldsta_fail

    /* ctx fields populated. cmp with immediates > 4095 doesn't fit
     * the 12-bit cmp encoding, so build the expected value in a
     * scratch reg first. */
    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    ldr     x1, [x0, #DHCPC_DWC2_BASE]
    movz    x2, #0x1111
    cmp     x1, x2
    b.ne    .Ldsta_fail
    ldr     x1, [x0, #DHCPC_ECM_STATE]
    movz    x2, #0x2222
    cmp     x1, x2
    b.ne    .Ldsta_fail
    ldr     x1, [x0, #DHCPC_TX_BUF]
    movz    x2, #0x3333
    cmp     x1, x2
    b.ne    .Ldsta_fail
    ldr     x1, [x0, #DHCPC_TIMER_POOL]
    movz    x2, #0x4444
    cmp     x1, x2
    b.ne    .Ldsta_fail
    ldr     x1, [x0, #DHCPC_SEND_FN]
    movz    x2, #0x5555
    cmp     x1, x2
    b.ne    .Ldsta_fail
    ldr     w1, [x0, #DHCPC_RETRIES]
    cmp     w1, #DHCP_MAX_RETRIES
    b.ne    .Ldsta_fail
    /* timer_freq is read from CNTFRQ_EL0; on QEMU this is non-zero
     * (typical 62.5 MHz). Just assert non-zero. */
    ldr     x1, [x0, #DHCPC_TIMER_FREQ]
    cbz     x1, .Ldsta_fail

    ldr     x0, =_dhcp_name_start
    bl      test_pass
    b       .Ldsta_done
.Ldsta_fail:
    ldr     x0, =_dhcp_name_start
    bl      test_fail
.Ldsta_done:
    ldp     x29, x30, [sp], #16
    ret


.section .rodata
_dhcp_name_step_init_start:    .asciz "dhcp_fsa_step_init_start"
_dhcp_name_step_no_handler:    .asciz "dhcp_fsa_step_no_handler"
_dhcp_name_step_oob_event:     .asciz "dhcp_fsa_step_oob_event"
_dhcp_name_step_oob_state:     .asciz "dhcp_fsa_step_oob_state"
_dhcp_name_step_panic_d_runs:  .asciz "dhcp_fsa_step_panic_d_runs"
_dhcp_name_start:              .asciz "dhcp_start_populates_ctx_and_fires"
