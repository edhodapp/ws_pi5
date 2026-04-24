/*
 * test_http_output_fsa — unit tests for the FSA scaffolding.
 *
 * Compiled and linked only when HTTP_OUTPUT_FSA=1. The suite pins:
 *   - post gating (dedupes same (way, code), independent across
 *     ways or codes)
 *   - init state (ostate all O_IDLE, evt_pending all zero)
 *   - transition-table shape (handler pointers at expected entries,
 *     STEP_NO_TRANS cells are zero)
 *   - engine dispatch reaches the correct stub handler and bumps the
 *     correct dispatch counter
 *
 * Handlers are stubs in commit 2, so tests check counters, not side
 * effects. Commit 3 layers real behavior on top and extends the suite.
 */

.include "vmio.inc"
.include "http.inc"

.ifdef HTTP_OUTPUT_FSA

.global test_http_output_fsa

.section .text

test_http_output_fsa:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      test_fsa_init_zeroes_state
    bl      test_fsa_post_enqueues_once
    bl      test_fsa_post_dedupes
    bl      test_fsa_post_different_events_same_way
    bl      test_fsa_post_same_event_different_ways
    bl      test_fsa_post_out_of_range_way
    bl      test_fsa_post_out_of_range_code
    bl      test_fsa_table_has_expected_handlers
    bl      test_fsa_table_no_trans_cells
    bl      test_fsa_step_dispatches_handler
    bl      test_fsa_step_clears_pending_bit
    bl      test_fsa_step_advances_ostate
    bl      test_fsa_step_preserves_other_way_state
    bl      test_fsa_step_idle_on_empty
    bl      test_fsa_step_no_trans_leaves_state

    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_init_zeroes_state
 * ====================================================================== */
test_fsa_init_zeroes_state:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    /* All 128 ostate bytes must be O_IDLE (0). */
    ldr     x0, =http_fsa_ostate
    mov     w1, #HTTP_MAX_CONNS
.Lfiz_os:
    ldrb    w2, [x0], #1
    cbnz    w2, .Lfiz_fail
    subs    w1, w1, #1
    b.ne    .Lfiz_os

    /* All 128 evt_pending bytes must be 0. */
    ldr     x0, =http_fsa_evt_pending
    mov     w1, #HTTP_MAX_CONNS
.Lfiz_ep:
    ldrb    w2, [x0], #1
    cbnz    w2, .Lfiz_fail
    subs    w1, w1, #1
    b.ne    .Lfiz_ep

    ldr     x0, =name_fiz
    bl      test_pass
    b       .Lfiz_done
.Lfiz_fail:
    ldr     x0, =name_fiz
    bl      test_fail
.Lfiz_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_post_enqueues_once — first post returns 1, pending bit set,
 * hi queue has one element.
 * ====================================================================== */
test_fsa_post_enqueues_once:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #42                      /* way 42 */
    mov     w1, #E_RESP_READY            /* hi queue */
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfpeo_fail

    /* evt_pending[42] must have bit 0 set. */
    ldr     x0, =http_fsa_evt_pending
    ldrb    w1, [x0, #42]
    cmp     w1, #1
    b.ne    .Lfpeo_fail

    /* Hi queue must have tail = 1. */
    ldr     x0, =http_fsa_hi_queue
    ldr     w1, [x0, #Q_TAIL]
    cmp     w1, #1
    b.ne    .Lfpeo_fail

    ldr     x0, =name_fpeo
    bl      test_pass
    b       .Lfpeo_done
.Lfpeo_fail:
    ldr     x0, =name_fpeo
    bl      test_fail
.Lfpeo_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_post_dedupes — second post of same (way, code) must return
 * 0 and NOT re-enqueue.
 * ====================================================================== */
test_fsa_post_dedupes:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #3
    mov     w1, #E_WIN_OPEN              /* lo queue */
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfpd_fail

    mov     w0, #3
    mov     w1, #E_WIN_OPEN
    bl      http_fsa_post
    cbnz    w0, .Lfpd_fail               /* must return 0 (dropped) */

    /* Lo queue tail must still be 1 (second post dropped). */
    ldr     x0, =http_fsa_lo_queue
    ldr     w1, [x0, #Q_TAIL]
    cmp     w1, #1
    b.ne    .Lfpd_fail

    ldr     x0, =name_fpd
    bl      test_pass
    b       .Lfpd_done
.Lfpd_fail:
    ldr     x0, =name_fpd
    bl      test_fail
.Lfpd_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_post_different_events_same_way — two distinct event codes
 * for the same way must both enqueue.
 * ====================================================================== */
test_fsa_post_different_events_same_way:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #7
    mov     w1, #E_WIN_OPEN              /* lo */
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfpde_fail

    mov     w0, #7
    mov     w1, #E_CHUNK_SENT            /* lo */
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfpde_fail

    /* Lo queue tail must be 2. */
    ldr     x0, =http_fsa_lo_queue
    ldr     w1, [x0, #Q_TAIL]
    cmp     w1, #2
    b.ne    .Lfpde_fail

    /* evt_pending[7] must have bits 1 and 2 set → value 6. */
    ldr     x0, =http_fsa_evt_pending
    ldrb    w1, [x0, #7]
    cmp     w1, #6
    b.ne    .Lfpde_fail

    ldr     x0, =name_fpde
    bl      test_pass
    b       .Lfpde_done
.Lfpde_fail:
    ldr     x0, =name_fpde
    bl      test_fail
.Lfpde_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_post_same_event_different_ways — same code, two ways, both
 * must enqueue independently.
 * ====================================================================== */
test_fsa_post_same_event_different_ways:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #1
    mov     w1, #E_RESP_READY            /* hi */
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfpsed_fail

    mov     w0, #2
    mov     w1, #E_RESP_READY            /* hi */
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfpsed_fail

    /* Hi queue tail must be 2. */
    ldr     x0, =http_fsa_hi_queue
    ldr     w1, [x0, #Q_TAIL]
    cmp     w1, #2
    b.ne    .Lfpsed_fail

    ldr     x0, =name_fpsed
    bl      test_pass
    b       .Lfpsed_done
.Lfpsed_fail:
    ldr     x0, =name_fpsed
    bl      test_fail
.Lfpsed_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_post_out_of_range_way — way >= HTTP_MAX_CONNS must be
 * rejected with w0 = 0 and leave pending untouched.
 * ====================================================================== */
test_fsa_post_out_of_range_way:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #HTTP_MAX_CONNS
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    cbnz    w0, .Lfpoor_fail

    /* Pending array must be all zero. */
    ldr     x0, =http_fsa_evt_pending
    ldr     x1, [x0]
    cbnz    x1, .Lfpoor_fail

    ldr     x0, =name_fpoor
    bl      test_pass
    b       .Lfpoor_done
.Lfpoor_fail:
    ldr     x0, =name_fpoor
    bl      test_fail
.Lfpoor_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_post_out_of_range_code — code >= FSA_NEVENTS must be
 * rejected.
 * ====================================================================== */
test_fsa_post_out_of_range_code:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #0
    mov     w1, #FSA_NEVENTS
    bl      http_fsa_post
    cbnz    w0, .Lfpoorc_fail

    ldr     x0, =name_fpoorc
    bl      test_pass
    b       .Lfpoorc_done
.Lfpoorc_fail:
    ldr     x0, =name_fpoorc
    bl      test_fail
.Lfpoorc_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_table_has_expected_handlers — spot-check 3 key cells:
 *   [O_IDLE, E_RESP_READY] → h_install
 *   [O_SETUP, E_WIN_OPEN] → h_send
 *   [O_DRAINING, E_ALL_DRAINED] → h_decide
 * ====================================================================== */
test_fsa_table_has_expected_handlers:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    /* Entry index = state * FSA_NEVENTS + event_code */
    ldr     x0, =http_fsa_trans_table

    /* [IDLE(0), RESP_READY(0)] — offset 0 */
    ldr     x1, [x0, #TRANS_HANDLER]
    ldr     x2, =h_install
    cmp     x1, x2
    b.ne    .Lftheh_fail

    /* [SETUP(1), WIN_OPEN(1)] — entry 9 → offset 9*16 = 144 */
    ldr     x1, [x0, #(9 * TRANS_SIZE) + TRANS_HANDLER]
    ldr     x2, =h_send
    cmp     x1, x2
    b.ne    .Lftheh_fail

    /* [DRAINING(3), ALL_DRAINED(4)] — entry 3*8+4 = 28 → offset 28*16 */
    ldr     x1, [x0, #(28 * TRANS_SIZE) + TRANS_HANDLER]
    ldr     x2, =h_decide
    cmp     x1, x2
    b.ne    .Lftheh_fail

    ldr     x0, =name_ftheh
    bl      test_pass
    b       .Lftheh_done
.Lftheh_fail:
    ldr     x0, =name_ftheh
    bl      test_fail
.Lftheh_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_table_no_trans_cells — [IDLE, WIN_OPEN] should have
 * handler == 0 (no transition → STEP_NO_TRANS).
 * ====================================================================== */
test_fsa_table_no_trans_cells:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =http_fsa_trans_table
    /* [IDLE(0), WIN_OPEN(1)] — entry 1 */
    ldr     x1, [x0, #(1 * TRANS_SIZE) + TRANS_HANDLER]
    cbnz    x1, .Lftnc_fail

    /* [SETUP(1), RESP_READY(0)] — entry 8 */
    ldr     x1, [x0, #(8 * TRANS_SIZE) + TRANS_HANDLER]
    cbnz    x1, .Lftnc_fail

    ldr     x0, =name_ftnc
    bl      test_pass
    b       .Lftnc_done
.Lftnc_fail:
    ldr     x0, =name_ftnc
    bl      test_fail
.Lftnc_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_step_dispatches_handler — post RESP_READY for way 0, then
 * http_fsa_step must run h_install (counter becomes 1).
 * ====================================================================== */
test_fsa_step_dispatches_handler:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfsdh_fail

    bl      http_fsa_step
    cmp     w0, #STEP_OK
    b.ne    .Lfsdh_fail

    ldr     x0, =http_fsa_count_install
    ldr     w1, [x0]
    cmp     w1, #1
    b.ne    .Lfsdh_fail

    ldr     x0, =name_fsdh
    bl      test_pass
    b       .Lfsdh_done
.Lfsdh_fail:
    ldr     x0, =name_fsdh
    bl      test_fail
.Lfsdh_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_step_clears_pending_bit — after a successful dispatch the
 * wrapper MUST clear the pending bit so a follow-up post of the same
 * (way, code) can enqueue a fresh event. This is the commit-3
 * contract; handlers rely on it when they re-post their own type
 * (notably h_send looping via E_CHUNK_SENT).
 * ====================================================================== */
test_fsa_step_clears_pending_bit:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #5
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfscp_fail

    bl      http_fsa_step
    cmp     w0, #STEP_OK
    b.ne    .Lfscp_fail

    /* Pending bit for way 5, E_RESP_READY (bit 0) must now be 0.
     * h_install posts E_WIN_OPEN as a follow-up, so bit 1 may be set —
     * check bit 0 specifically, not the whole byte. */
    ldr     x0, =http_fsa_evt_pending
    ldrb    w1, [x0, #5]
    tst     w1, #(1 << E_RESP_READY)
    b.ne    .Lfscp_fail

    /* And posting the same (way, code) again MUST succeed. */
    mov     w0, #5
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfscp_fail

    ldr     x0, =name_fscp
    bl      test_pass
    b       .Lfscp_done
.Lfscp_fail:
    ldr     x0, =name_fscp
    bl      test_fail
.Lfscp_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_step_advances_ostate — RESP_READY on an IDLE way MUST
 * leave ostate[way] = O_SETUP after dispatch.
 * ====================================================================== */
test_fsa_step_advances_ostate:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #9
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfsao_fail

    bl      http_fsa_step
    cmp     w0, #STEP_OK
    b.ne    .Lfsao_fail

    ldr     x0, =http_fsa_ostate
    ldrb    w1, [x0, #9]
    cmp     w1, #O_SETUP
    b.ne    .Lfsao_fail

    ldr     x0, =name_fsao
    bl      test_pass
    b       .Lfsao_done
.Lfsao_fail:
    ldr     x0, =name_fsao
    bl      test_fail
.Lfsao_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_step_preserves_other_way_state — way 10 advances to
 * O_SETUP via RESP_READY; way 11 must remain at O_IDLE. Pins the
 * per-way state plumbing: the wrapper must swap ostate[way], not
 * leak ENG_STATE across ways.
 * ====================================================================== */
test_fsa_step_preserves_other_way_state:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    bl      http_fsa_init

    /* Advance way 10 via RESP_READY + step — ostate[10] → O_SETUP. */
    mov     w0, #10
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    bl      http_fsa_step
    cmp     w0, #STEP_OK
    b.ne    .Lfspos_fail

    ldr     x0, =http_fsa_ostate
    ldrb    w1, [x0, #10]
    cmp     w1, #O_SETUP
    b.ne    .Lfspos_fail
    ldrb    w1, [x0, #11]
    cbnz    w1, .Lfspos_fail                      /* way 11 untouched */

    /* Drain any handler follow-ups (h_install posted E_WIN_OPEN for
     * way 10) until STEP_IDLE so only the events we explicitly post
     * below are pending. */
.Lfspos_drain1:
    bl      http_fsa_step
    cmp     w0, #STEP_IDLE
    b.ne    .Lfspos_drain1

    /* Snapshot ostate[10] into w19. */
    ldr     x0, =http_fsa_ostate
    ldrb    w19, [x0, #10]

    /* Post+step for way 11. WIN_OPEN from O_IDLE has no table entry
     * → STEP_NO_TRANS, no handler runs. */
    mov     w0, #11
    mov     w1, #E_WIN_OPEN
    bl      http_fsa_post
    bl      http_fsa_step

    /* ostate[10] must equal the snapshot; ostate[11] must still be 0. */
    ldr     x0, =http_fsa_ostate
    ldrb    w1, [x0, #10]
    cmp     w1, w19
    b.ne    .Lfspos_fail
    ldrb    w1, [x0, #11]
    cbnz    w1, .Lfspos_fail

    ldr     x0, =name_fspos
    bl      test_pass
    b       .Lfspos_done
    /* .Lfspos_fail unreached from this point; falls through otherwise */
.Lfspos_fail:
    ldr     x0, =name_fspos
    bl      test_fail
.Lfspos_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ======================================================================
 * test_fsa_step_idle_on_empty — both queues empty must return
 * STEP_IDLE without touching ostate.
 * ====================================================================== */
test_fsa_step_idle_on_empty:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    bl      http_fsa_step
    cmp     w0, #STEP_IDLE
    b.ne    .Lfsioe_fail

    /* ostate[0] must still be O_IDLE. */
    ldr     x0, =http_fsa_ostate
    ldrb    w1, [x0]
    cbnz    w1, .Lfsioe_fail

    ldr     x0, =name_fsioe
    bl      test_pass
    b       .Lfsioe_done
.Lfsioe_fail:
    ldr     x0, =name_fsioe
    bl      test_fail
.Lfsioe_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_step_no_trans_leaves_state — post an event that has no
 * table entry for the current state (IDLE + WIN_OPEN). The wrapper
 * must return STEP_NO_TRANS and leave ostate[way] unchanged.
 * ====================================================================== */
test_fsa_step_no_trans_leaves_state:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      http_fsa_init

    mov     w0, #13
    mov     w1, #E_WIN_OPEN            /* no table entry from O_IDLE */
    bl      http_fsa_post
    bl      http_fsa_step
    cmp     w0, #STEP_NO_TRANS
    b.ne    .Lfsntls_fail

    /* ostate[13] must still be O_IDLE. */
    ldr     x0, =http_fsa_ostate
    ldrb    w1, [x0, #13]
    cbnz    w1, .Lfsntls_fail

    /* Pending bit for WIN_OPEN was still cleared by the wrapper (we
     * clear pre-dispatch, and that clear fires regardless of STEP_OK
     * vs STEP_NO_TRANS). */
    ldr     x0, =http_fsa_evt_pending
    ldrb    w1, [x0, #13]
    cbnz    w1, .Lfsntls_fail

    ldr     x0, =name_fsntls
    bl      test_pass
    b       .Lfsntls_done
.Lfsntls_fail:
    ldr     x0, =name_fsntls
    bl      test_fail
.Lfsntls_done:
    ldp     x29, x30, [sp], #16
    ret

/* ====================================================================== */
.section .rodata
name_fiz:    .asciz "fsa_init_zeroes_state"
name_fpeo:   .asciz "fsa_post_enqueues_once"
name_fpd:    .asciz "fsa_post_dedupes"
name_fpde:   .asciz "fsa_post_different_events_same_way"
name_fpsed:  .asciz "fsa_post_same_event_different_ways"
name_fpoor:  .asciz "fsa_post_out_of_range_way"
name_fpoorc: .asciz "fsa_post_out_of_range_code"
name_ftheh:  .asciz "fsa_table_has_expected_handlers"
name_ftnc:   .asciz "fsa_table_no_trans_cells"
name_fsdh:   .asciz "fsa_step_dispatches_handler"
name_fscp:   .asciz "fsa_step_clears_pending_bit"
name_fsao:   .asciz "fsa_step_advances_ostate"
name_fspos:  .asciz "fsa_step_preserves_other_way_state"
name_fsioe:  .asciz "fsa_step_idle_on_empty"
name_fsntls: .asciz "fsa_step_no_trans_leaves_state"

.endif
