/*
 * test_http_output_fsa — unit tests for the output FSA.
 *
 * Covers: post gating, init state, transition-table shape, engine
 * dispatch, per-way state plumbing, send-path functional behavior
 * (RESP_READY → SETUP → TX → DRAINING → keepalive/close), engine
 * telemetry counters, and the /fsa_stats generator.
 */

.include "vmio.inc"
.include "http.inc"
.include "tcp.inc"
.include "net.inc"

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
    /* ---- send-path functional tests ---- */
    bl      test_fsa_send_one_chunk
    bl      test_fsa_response_drains_keepalive
    bl      test_fsa_response_drains_close
    bl      test_fsa_tcp_reset_during_tx
    /* ---- engine-level counters ---- */
    bl      test_fsa_events_posted_counter
    bl      test_fsa_events_dropped_counter_on_dup
    bl      test_fsa_step_counters
    /* ---- /fsa_stats generator ---- */
    bl      test_fsa_stats_generator

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

/* ======================================================================
 * Shared setup helpers for send-path tests.
 * Each helper leaves state in a known shape so individual tests stay
 * short and read linearly.
 * ======================================================================
 */

/* tfsa_seed_established(way=w0)
 * Put tcp_conn[way] in ESTABLISHED with a large send window and a
 * SND_UNA == SND_NXT invariant so tcp_send works and h_send can loop.
 * Clobbers x0-x9.
 */
tfsa_seed_established:
    stp     x29, x30, [sp, #-16]!
    mov     w9, w0                                 /* w9 = way */

    ldr     x1, =tcp_conn_table
    lsl     w2, w9, #TCONN_SHIFT
    add     x1, x1, x2
    /* x1 = tcp_conn */

    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x1, #TCONN_STATE]
    mov     w0, #0x5000
    add     w0, w0, w9                             /* unique LPORT */
    strh    w0, [x1, #TCONN_LPORT]
    mov     w0, #2000
    str     w0, [x1, #TCONN_SND_WND]
    mov     w0, #100
    str     w0, [x1, #TCONN_SND_UNA]
    str     w0, [x1, #TCONN_SND_NXT]
    mov     w0, #TCP_OUR_MSS
    strh    w0, [x1, #TCONN_PEER_MSS]
    mov     w0, #0x40000
    str     w0, [x1, #TCONN_CWND]
    ldr     x0, =net_our_mac
    ldr     w2, [x0]
    str     w2, [x1, #TCONN_RMAC]
    ldrh    w2, [x0, #4]
    strh    w2, [x1, #(TCONN_RMAC + 4)]
    ldr     x0, =net_our_ip
    ldr     w0, [x0]
    str     w0, [x1, #TCONN_RIP]
    mov     w0, #1
    str     w0, [x1, #TCONN_RCV_NXT]
    mov     w0, #-1
    str     w0, [x1, #TCONN_TIMER_SLOT]

    ldp     x29, x30, [sp], #16
    ret

/* tfsa_seed_response(way=w0)
 * Populate HCONN[way] with a 200-response shape using http_200_hdr /
 * http_200_body. HCONN_STATE → HTTPS_SENDING so the input-side poll
 * dispatch skips this HCONN. Caller is responsible for posting
 * E_RESP_READY via http_fsa_post to kick the FSA.
 */
tfsa_seed_response:
    mov     w9, w0                                 /* way */

    ldr     x1, =http_conn_table
    lsl     w2, w9, #HCONN_SHIFT
    add     x1, x1, x2

    mov     w0, #HTTPS_SENDING
    strb    w0, [x1, #HCONN_STATE]
    strb    wzr, [x1, #HCONN_STATUS]
    str     wzr, [x1, #HCONN_RESP_PTR]
    /* HFLAG_HTTP11 so h_decide posts DO_KEEPALIVE (default persistent) */
    mov     w0, #HFLAG_HTTP11
    strb    w0, [x1, #HCONN_FLAGS]

    ldr     x0, =http_200_body
    str     x0, [x1, #HCONN_BODY_PTR]
    /* http_200_body_len / _hdr_len are .equ symbols local to http.S
     * (assembler gotcha: .equ cannot be .global). The legacy test in
     * test_http.S hardcodes the same numbers; the Content-Length: 158
     * value baked into http_200_hdr pins the body length. */
    mov     w0, #158                                /* http_200_body_len */
    str     w0, [x1, #HCONN_BODY_LEN]
    ldr     x3, =http_200_hdr
    str     x3, [x1, #HCONN_HDR_SRC_PTR]
    mov     w2, #133                                /* http_200_hdr_len */
    str     w2, [x1, #HCONN_HDR_SRC_LEN]
    str     w2, [x1, #HCONN_HDR_LEN]
    add     w3, w0, w2                              /* hdr + body = 291 */
    str     w3, [x1, #HCONN_RESP_LEN]
    ret

/* tfsa_mock_send_install — install tfsa_counting_send as the TX function
 * so h_send's frame emission increments tfsa_send_count without
 * touching real hardware. Also zeros the counter. */
tfsa_mock_send_install:
    stp     x29, x30, [sp, #-16]!
    ldr     x0, =tfsa_send_count
    str     wzr, [x0]
    mov     x0, #0                                 /* dwc2_base */
    mov     x1, #0                                 /* ecm_state */
    ldr     x2, =tfsa_tx_buf
    ldr     x3, =tfsa_counting_send
    bl      http_set_send_ctx
    ldp     x29, x30, [sp], #16
    ret

/* tfsa_counting_send — mock send_fn, just bumps the counter. */
tfsa_counting_send:
    ldr     x4, =tfsa_send_count
    ldr     w5, [x4]
    add     w5, w5, #1
    str     w5, [x4]
    mov     w0, #0
    ret

/* ======================================================================
 * test_fsa_send_one_chunk — equivalent to legacy test_http_send_chunk.
 * After seeding + posting E_RESP_READY + http_poll, the mock send must
 * have been invoked at least once and HCONN_RESP_PTR must have moved.
 * ====================================================================== */
test_fsa_send_one_chunk:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init
    bl      http_init

    mov     w0, #0
    bl      tfsa_seed_established
    mov     w0, #0
    bl      tfsa_seed_response
    bl      tfsa_mock_send_install

    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    cmp     w0, #1
    b.ne    .Lfsc_fail

    bl      http_poll

    /* Mock send MUST have fired at least once. */
    ldr     x0, =tfsa_send_count
    ldr     w0, [x0]
    cbz     w0, .Lfsc_fail

    /* HCONN_RESP_PTR must have advanced from 0. */
    ldr     x0, =http_conn_table
    ldr     w0, [x0, #HCONN_RESP_PTR]
    cbz     w0, .Lfsc_fail

    ldr     x0, =name_fsc
    bl      test_pass
    b       .Lfsc_done
.Lfsc_fail:
    ldr     x0, =name_fsc
    bl      test_fail
.Lfsc_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_response_drains_keepalive — full happy path with
 * HFLAG_HTTP11 set: response drains, DRAINING + ALL_DRAINED fires
 * h_decide → DO_KEEPALIVE → h_keepalive → HCONN_STATE back to
 * HTTPS_RECV_HDR for next pipelined request. ostate must be O_IDLE.
 * ====================================================================== */
test_fsa_response_drains_keepalive:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    mov     w0, #0
    bl      tfsa_seed_established
    mov     w0, #0
    bl      tfsa_seed_response
    bl      tfsa_mock_send_install

    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post

    /* Pump http_poll to exhaust bytes → O_DRAINING. Mock send_fn is
     * silent (never advances SND_UNA), so simulate "ACKs arrived for
     * all transmitted data" by forcing SND_UNA = SND_NXT. Then another
     * http_poll picks up E_ALL_DRAINED via the polling pass. Cap
     * outer iterations at 16 so a broken FSA can't hang. */
    mov     w19, #16
.Lfdk_pump:
    bl      http_poll
    /* Simulate ACK arrival so DRAINING can fire. */
    ldr     x0, =tcp_conn_table
    ldr     w1, [x0, #TCONN_SND_NXT]
    str     w1, [x0, #TCONN_SND_UNA]
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATE]
    cmp     w0, #HTTPS_RECV_HDR
    b.eq    .Lfdk_check
    subs    w19, w19, #1
    b.ne    .Lfdk_pump
    b       .Lfdk_fail

.Lfdk_check:
    /* ostate[0] must be O_IDLE after h_keepalive completes. */
    ldr     x0, =http_fsa_ostate
    ldrb    w0, [x0]
    cbnz    w0, .Lfdk_fail

    /* h_keepalive dispatch count must be exactly 1. */
    ldr     x0, =http_fsa_count_keepalive
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfdk_fail

    /* h_close must NOT have run (HTTP/1.1 → keepalive). */
    ldr     x0, =http_fsa_count_close
    ldr     w0, [x0]
    cbnz    w0, .Lfdk_fail

    ldr     x0, =name_fdk
    bl      test_pass
    b       .Lfdk_done
.Lfdk_fail:
    ldr     x0, =name_fdk
    bl      test_fail
.Lfdk_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ======================================================================
 * test_fsa_response_drains_close — same shape as keepalive, but with
 * HFLAG_CLOSE set: h_decide must post DO_CLOSE, h_close runs (tcp_close
 * builds FIN which mock_send transmits), HCONN_STATE ends at IDLE (0),
 * not RECV_HDR.
 * ====================================================================== */
test_fsa_response_drains_close:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    mov     w0, #0
    bl      tfsa_seed_established
    mov     w0, #0
    bl      tfsa_seed_response
    /* Override FLAGS: HTTP11 + CLOSE → close path. */
    ldr     x0, =http_conn_table
    mov     w1, #(HFLAG_HTTP11 | HFLAG_CLOSE)
    strb    w1, [x0, #HCONN_FLAGS]
    bl      tfsa_mock_send_install

    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post

    mov     w19, #16
.Lfdc_pump:
    bl      http_poll
    /* Simulate ACK arrival so DRAINING can fire (see keepalive test). */
    ldr     x0, =tcp_conn_table
    ldr     w1, [x0, #TCONN_SND_NXT]
    str     w1, [x0, #TCONN_SND_UNA]
    ldr     x0, =http_fsa_count_close
    ldr     w0, [x0]
    cbnz    w0, .Lfdc_check
    subs    w19, w19, #1
    b.ne    .Lfdc_pump
    b       .Lfdc_fail

.Lfdc_check:
    /* h_close must have run exactly once. */
    ldr     x0, =http_fsa_count_close
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfdc_fail

    /* h_keepalive must NOT have run. */
    ldr     x0, =http_fsa_count_keepalive
    ldr     w0, [x0]
    cbnz    w0, .Lfdc_fail

    /* HCONN_STATE must be IDLE (0), not RECV_HDR. */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATE]
    cbnz    w0, .Lfdc_fail

    ldr     x0, =name_fdc
    bl      test_pass
    b       .Lfdc_done
.Lfdc_fail:
    ldr     x0, =name_fdc
    bl      test_fail
.Lfdc_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ======================================================================
 * test_fsa_tcp_reset_during_tx — TCP transitions out of ESTABLISHED
 * while the FSA is mid-send. The next http_fsa_poll_tcp_events pass
 * must post E_TCP_CLOSED; the engine routes that to h_reset, which
 * wipes HCONN and leaves ostate at O_IDLE.
 * ====================================================================== */
test_fsa_tcp_reset_during_tx:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init
    bl      http_init

    mov     w0, #0
    bl      tfsa_seed_established
    mov     w0, #0
    bl      tfsa_seed_response
    bl      tfsa_mock_send_install

    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    bl      http_poll                              /* advances through h_install,
                                                    * h_send emits frame,
                                                    * ostate[0] should be O_TX */

    /* Force TCP out of ESTABLISHED (simulates RST). */
    ldr     x0, =tcp_conn_table
    mov     w1, #TCPS_CLOSED
    strb    w1, [x0, #TCONN_STATE]

    bl      http_poll                              /* poll_tcp_events posts
                                                    * E_TCP_CLOSED; engine
                                                    * dispatches h_reset */

    /* ostate[0] must now be O_IDLE. */
    ldr     x0, =http_fsa_ostate
    ldrb    w0, [x0]
    cbnz    w0, .Lftrdt_fail

    /* HCONN fields wiped by h_reset (STATE + FLAGS at least). */
    ldr     x0, =http_conn_table
    ldrb    w1, [x0, #HCONN_STATE]
    cbnz    w1, .Lftrdt_fail
    ldrb    w1, [x0, #HCONN_FLAGS]
    cbnz    w1, .Lftrdt_fail

    /* h_reset counter must be >= 1 (may fire again on subsequent
     * pumps if the FSA double-polls; >= 1 is the invariant). */
    ldr     x0, =http_fsa_count_reset
    ldr     w0, [x0]
    cbz     w0, .Lftrdt_fail

    ldr     x0, =name_ftrdt
    bl      test_pass
    b       .Lftrdt_done
.Lftrdt_fail:
    ldr     x0, =name_ftrdt
    bl      test_fail
.Lftrdt_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_events_posted_counter — three successful posts must leave
 * http_fsa_events_posted at exactly 3.
 * ====================================================================== */
test_fsa_events_posted_counter:
    stp     x29, x30, [sp, #-16]!

    bl      http_fsa_init

    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    mov     w0, #1
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    mov     w0, #2
    mov     w1, #E_RESP_READY
    bl      http_fsa_post

    ldr     x0, =http_fsa_events_posted
    ldr     w0, [x0]
    cmp     w0, #3
    b.ne    .Lfec_fail

    /* Dropped counter must still be 0 — no dup/full in this test. */
    ldr     x0, =http_fsa_events_dropped
    ldr     w0, [x0]
    cbnz    w0, .Lfec_fail

    ldr     x0, =name_fec
    bl      test_pass
    b       .Lfec_done
.Lfec_fail:
    ldr     x0, =name_fec
    bl      test_fail
.Lfec_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_events_dropped_counter_on_dup — dup post bumps
 * events_dropped, not events_posted.
 * ====================================================================== */
test_fsa_events_dropped_counter_on_dup:
    stp     x29, x30, [sp, #-16]!

    bl      http_fsa_init

    mov     w0, #7
    mov     w1, #E_RESP_READY
    bl      http_fsa_post                          /* posts 1 */
    mov     w0, #7
    mov     w1, #E_RESP_READY
    bl      http_fsa_post                          /* dup → dropped */

    ldr     x0, =http_fsa_events_posted
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfedc_fail

    ldr     x0, =http_fsa_events_dropped
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfedc_fail

    ldr     x0, =name_fedc
    bl      test_pass
    b       .Lfedc_done
.Lfedc_fail:
    ldr     x0, =name_fedc
    bl      test_fail
.Lfedc_done:
    ldp     x29, x30, [sp], #16
    ret

/* ======================================================================
 * test_fsa_step_counters — step_ok bumps on successful dispatch,
 * step_no_trans bumps on a zero-handler cell, STEP_IDLE bumps neither.
 * ====================================================================== */
test_fsa_step_counters:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      http_fsa_init

    /* Simplest path first: post RESP_READY for way 0. h_install is the
     * only handler that runs (it posts E_WIN_OPEN follow-up, but we
     * only step ONCE). Result: step_ok == 1. */
    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post
    bl      http_fsa_step
    cmp     w0, #STEP_OK
    b.ne    .Lfsco_fail
    ldr     x0, =http_fsa_step_ok
    ldr     w19, [x0]
    cmp     w19, #1
    b.ne    .Lfsco_fail

    /* step_no_trans still 0. */
    ldr     x0, =http_fsa_step_no_trans
    ldr     w1, [x0]
    cbnz    w1, .Lfsco_fail

    /* Re-init to clear all state; then drive a STEP_NO_TRANS event. */
    bl      http_fsa_init

    /* WIN_OPEN for way 10: ostate[10] = IDLE + no table entry →
     * STEP_NO_TRANS. step_ok stays 0, step_no_trans becomes 1. */
    mov     w0, #10
    mov     w1, #E_WIN_OPEN
    bl      http_fsa_post
    bl      http_fsa_step
    cmp     w0, #STEP_NO_TRANS
    b.ne    .Lfsco_fail
    ldr     x0, =http_fsa_step_no_trans
    ldr     w1, [x0]
    cmp     w1, #1
    b.ne    .Lfsco_fail
    ldr     x0, =http_fsa_step_ok
    ldr     w1, [x0]
    cbnz    w1, .Lfsco_fail

    /* STEP_IDLE path: re-init, step with empty queue, neither counter
     * should move. */
    bl      http_fsa_init
    bl      http_fsa_step
    cmp     w0, #STEP_IDLE
    b.ne    .Lfsco_fail
    ldr     x0, =http_fsa_step_ok
    ldr     w1, [x0]
    cbnz    w1, .Lfsco_fail
    ldr     x0, =http_fsa_step_no_trans
    ldr     w1, [x0]
    cbnz    w1, .Lfsco_fail

    ldr     x0, =name_fsco
    bl      test_pass
    b       .Lfsco_done
.Lfsco_fail:
    ldr     x0, =name_fsco
    bl      test_fail
.Lfsco_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ======================================================================
 * test_fsa_stats_generator — after posting a known number of events,
 * the generator's output MUST contain the expected counter labels and
 * the matching decimal values. Tests don't parse HTTP — they call the
 * generator directly with a scratch buffer.
 * ====================================================================== */
test_fsa_stats_generator:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      http_fsa_init

    /* Drive counters to known values:
     *   events_posted = 2 (two unique posts)
     *   events_dropped = 1 (one dup)
     *   events posted: RESP_READY for way 0 + RESP_READY for way 0 (dup)
     *                  WIN_OPEN for way 5
     */
    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post                         /* posted=1 */
    mov     w0, #0
    mov     w1, #E_RESP_READY
    bl      http_fsa_post                         /* dropped=1 */
    mov     w0, #5
    mov     w1, #E_WIN_OPEN
    bl      http_fsa_post                         /* posted=2 */

    /* Generate into scratch buf. */
    ldr     x0, =tfsa_tx_buf
    mov     w1, #256
    mov     x2, #0                                /* HCONN unused */
    bl      http_fsa_stats_generate
    cmp     w0, #0
    b.le    .Lfsg_fail
    mov     w19, w0                               /* w19 = len */

    /* Verify: output must contain "events_posted 2\n" — search for
     * "events_posted " label, then a byte that is ASCII '2'. */
    ldr     x20, =tfsa_tx_buf
    ldr     x0, =tlbl_events_posted
    mov     w1, #tlbl_events_posted_len
    mov     x2, x20
    mov     w3, w19
    bl      tfsa_find_substr
    cbz     x0, .Lfsg_fail                        /* label not found */
    /* x0 points at the byte AFTER the label (the value digit). */
    ldrb    w1, [x0]
    cmp     w1, #'2'
    b.ne    .Lfsg_fail
    ldrb    w1, [x0, #1]
    cmp     w1, #0x0a                             /* \n */
    b.ne    .Lfsg_fail

    /* Verify: events_dropped 1\n */
    ldr     x0, =tlbl_events_dropped
    mov     w1, #tlbl_events_dropped_len
    mov     x2, x20
    mov     w3, w19
    bl      tfsa_find_substr
    cbz     x0, .Lfsg_fail
    ldrb    w1, [x0]
    cmp     w1, #'1'
    b.ne    .Lfsg_fail

    ldr     x0, =name_fsg
    bl      test_pass
    b       .Lfsg_done
.Lfsg_fail:
    ldr     x0, =name_fsg
    bl      test_fail
.Lfsg_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * tfsa_find_substr — naive substring search.
 *   x0: needle
 *   w1: needle length
 *   x2: haystack
 *   w3: haystack length
 * Returns: x0 = pointer INTO haystack at the byte AFTER the first
 *          match (so the caller can read the value that follows the
 *          label), or 0 if not found.
 */
tfsa_find_substr:
    mov     x4, x2                                /* hs cursor */
.Ltfs_scan:
    cmp     w3, w1
    b.lo    .Ltfs_miss                            /* too little left */
    mov     x5, x0                                /* needle cursor */
    mov     x6, x4                                /* test cursor */
    mov     w7, w1                                /* bytes to match */
.Ltfs_cmp:
    cbz     w7, .Ltfs_hit
    ldrb    w8, [x5], #1
    ldrb    w9, [x6], #1
    cmp     w8, w9
    b.ne    .Ltfs_next
    sub     w7, w7, #1
    b       .Ltfs_cmp
.Ltfs_next:
    add     x4, x4, #1
    sub     w3, w3, #1
    b       .Ltfs_scan
.Ltfs_hit:
    mov     x0, x6                                /* first byte past label */
    ret
.Ltfs_miss:
    mov     x0, #0
    ret

.section .rodata
tlbl_events_posted:    .ascii "events_posted "
tlbl_events_posted_end:
.equ tlbl_events_posted_len, tlbl_events_posted_end - tlbl_events_posted

tlbl_events_dropped:   .ascii "events_dropped "
tlbl_events_dropped_end:
.equ tlbl_events_dropped_len, tlbl_events_dropped_end - tlbl_events_dropped

/* ======================================================================
 * Test data / buffers for the send-path tests.
 * ====================================================================== */
.section .data
.balign 16
tfsa_tx_buf:
    .space ETH_FRAME_MAX

.balign 4
tfsa_send_count:
    .word 0

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
name_fsc:    .asciz "fsa_send_one_chunk"
name_fdk:    .asciz "fsa_response_drains_keepalive"
name_fdc:    .asciz "fsa_response_drains_close"
name_ftrdt:  .asciz "fsa_tcp_reset_during_tx"
name_fec:    .asciz "fsa_events_posted_counter"
name_fedc:   .asciz "fsa_events_dropped_counter_on_dup"
name_fsco:   .asciz "fsa_step_counters"
name_fsg:    .asciz "fsa_stats_generator"
