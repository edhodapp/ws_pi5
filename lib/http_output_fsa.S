/*
 * http_output_fsa.S — VMIO-driven HTTP response send path.
 *
 * Parallel build behind --defsym HTTP_OUTPUT_FSA=1. When the flag is
 * off this file is not linked at all (see Makefile SHARED_OBJS
 * conditional); the legacy send path in lib/http.S is untouched.
 *
 * States / events are named in include/http.inc (O_*, E_*, FSA_*).
 *
 * Data-flow summary:
 *   http_fsa_init              — populate ctx, init queues + engine,
 *                                zero ostate + evt_pending arrays.
 *   http_fsa_post(way, code)   — gated enqueue: drops redundant posts
 *                                via http_fsa_evt_pending[way]. Chooses
 *                                hi vs lo queue by event code.
 *   http_fsa_step              — one engine step; clears the pending
 *                                bit BEFORE dispatching the handler so
 *                                handlers can re-post their own type.
 *   Handlers                   — 7 of them (see DESIGN). This commit
 *                                lands the scaffolding and stub handlers
 *                                that only record dispatch (for tests).
 *                                Commit 3 replaces stubs with real
 *                                send / decide / close / keepalive.
 */

.include "vmio.inc"
.include "http.inc"
.include "tcp.inc"

.ifdef HTTP_OUTPUT_FSA

.global http_fsa_init
.global http_fsa_post
.global http_fsa_step
.global http_fsa_ctx
.global http_fsa_engine
.global http_fsa_hi_queue
.global http_fsa_lo_queue
.global http_fsa_ostate
.global http_fsa_evt_pending
.global http_fsa_trans_table

/* Debug/test counters — one per handler, bumped on dispatch. Tests
 * observe dispatch by reading these; real handlers bump them too for
 * production telemetry. */
.global http_fsa_count_install
.global http_fsa_count_send
.global http_fsa_count_noop
.global http_fsa_count_decide
.global http_fsa_count_reset
.global http_fsa_count_close
.global http_fsa_count_keepalive

/* Handler symbols are .global so tests can pin table cells against
 * them (ldr x,=h_install then compare to TRANS_HANDLER entry). */
.global h_install
.global h_send
.global h_noop
.global h_decide
.global h_reset
.global h_close
.global h_keepalive

/* ========================================================================
 * ctx struct layout (24 B).
 * Handlers derive per-way HCONN/TCONN pointers by shifting the event's
 * way field and adding the table base from ctx.
 * ======================================================================== */
.equ FSA_CTX_HCONN_TABLE,  0     /* u64 — http_conn_table base */
.equ FSA_CTX_TCP_TABLE,    8     /* u64 — tcp_conn_table base */
.equ FSA_CTX_SEND_CTX,    16     /* u64 — http_send_ctx ptr */
.equ FSA_CTX_SIZE,        24

/* Priority classification — which queue an event goes to.
 * Hi: RESP_READY, TCP_CLOSED, DO_CLOSE, DO_KEEPALIVE.
 * Lo: WIN_OPEN, CHUNK_SENT, ALL_QUEUED, ALL_DRAINED.
 * Encoded as a bitmask so the post helper is one `lsr + tst`. */
.equ HTTP_FSA_HI_MASK,  ((1 << E_RESP_READY) | (1 << E_TCP_CLOSED) | (1 << E_DO_CLOSE) | (1 << E_DO_KEEPALIVE))

.section .text

/* ------------------------------------------------------------------------
 * http_fsa_init — wire the engine to the canonical queues + table +
 * ctx struct. Called from http_init when HTTP_OUTPUT_FSA=1.
 * Clobbers: x0-x7, x30.
 * ------------------------------------------------------------------------ */
http_fsa_init:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    /* Populate ctx: {hconn_table, tcp_conn_table, http_send_ctx}. */
    ldr     x0, =http_fsa_ctx
    ldr     x1, =http_conn_table
    str     x1, [x0, #FSA_CTX_HCONN_TABLE]
    ldr     x1, =tcp_conn_table
    str     x1, [x0, #FSA_CTX_TCP_TABLE]
    ldr     x1, =http_send_ctx
    str     x1, [x0, #FSA_CTX_SEND_CTX]

    /* Initialize both queues. */
    ldr     x0, =http_fsa_hi_queue
    mov     w1, #HTTP_FSA_Q_CAP
    bl      vmio_queue_init
    ldr     x0, =http_fsa_lo_queue
    mov     w1, #HTTP_FSA_Q_CAP
    bl      vmio_queue_init

    /* Initialize engine:
     *   state = O_IDLE (single engine drives all ways — per-way state
     *   lives in http_fsa_ostate, distinct from ENG_STATE which is
     *   unused for this use of the engine beyond table indexing).
     *
     * The engine's table lookup is state * n_events + evt_code. We want
     * the table lookup to use the PER-WAY state, not ENG_STATE. The
     * per-step wrapper http_fsa_step handles that by copying ostate[way]
     * into ENG_STATE before calling vmio_engine_step, then copying back
     * the new state. Commit 3 implements that wrapper.
     */
    ldr     x0, =http_fsa_engine
    mov     w1, #O_IDLE                          /* initial_state */
    mov     w2, #FSA_NSTATES                     /* n_states */
    mov     w3, #FSA_NEVENTS                     /* n_events */
    ldr     x4, =http_fsa_trans_table            /* table_ptr */
    ldr     x5, =http_fsa_hi_queue               /* hi queue */
    ldr     x6, =http_fsa_lo_queue               /* lo queue */
    ldr     x7, =http_fsa_ctx                    /* ctx */
    bl      vmio_engine_init

    /* Zero ostate (O_IDLE = 0) and evt_pending. 128 bytes each. */
    ldr     x0, =http_fsa_ostate
    ldr     x1, =http_fsa_evt_pending
    mov     w2, #HTTP_MAX_CONNS / 16             /* 8 iterations × 16 B */
.Lhfi_zero:
    stp     xzr, xzr, [x0], #16
    stp     xzr, xzr, [x1], #16
    subs    w2, w2, #1
    b.ne    .Lhfi_zero

    /* Zero dispatch counters — 8 consecutive u32s = 32 bytes. */
    ldr     x0, =http_fsa_count_install
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]

    ldp     x29, x30, [sp], #16
    ret

/* ------------------------------------------------------------------------
 * http_fsa_post — gated enqueue.
 *
 *   w0 = way (HCONN index, 0..HTTP_MAX_CONNS-1)
 *   w1 = evt_code (E_*)
 *
 * If http_fsa_evt_pending[way] already has bit evt_code set, the post
 * is a no-op — the outstanding event will be dispatched in due course.
 * Otherwise: set the bit, build an EVT struct on the stack, enqueue to
 * hi or lo queue based on HTTP_FSA_HI_MASK.
 *
 * Returns: w0 = 1 if enqueued, 0 if dropped as duplicate.
 * Clobbers: x0-x9, x30.
 * ------------------------------------------------------------------------ */
http_fsa_post:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp

    /* Bounds check way — silent no-op if out of range. */
    cmp     w0, #HTTP_MAX_CONNS
    b.hs    .Lhfp_drop
    cmp     w1, #FSA_NEVENTS
    b.hs    .Lhfp_drop

    /* Load pending byte for this way. */
    ldr     x2, =http_fsa_evt_pending
    ldrb    w3, [x2, w0, uxtw]             /* w3 = pending[way] */
    mov     w4, #1
    lsl     w4, w4, w1                     /* w4 = (1 << evt_code) */
    tst     w3, w4
    b.ne    .Lhfp_drop                     /* bit already set */

    /* Set the bit and store back. */
    orr     w3, w3, w4
    strb    w3, [x2, w0, uxtw]

    /* Build EVT on stack. Zero all fields first. */
    sub     sp, sp, #EVT_SIZE
    stp     xzr, xzr, [sp]
    stp     xzr, xzr, [sp, #16]
    strh    w0, [sp, #EVT_WAY]             /* EVT_WAY = way */
    strh    w1, [sp, #EVT_CODE]            /* EVT_CODE = evt_code */

    /* Pick queue by mask. */
    mov     w5, #HTTP_FSA_HI_MASK
    lsr     w6, w5, w1
    and     w6, w6, #1
    cbz     w6, .Lhfp_enq_lo
    ldr     x6, =http_fsa_hi_queue
    b       .Lhfp_enq

.Lhfp_enq_lo:
    ldr     x6, =http_fsa_lo_queue
.Lhfp_enq:
    mov     x0, x6
    mov     x1, sp
    bl      vmio_queue_enqueue
    /* vmio_queue_enqueue returns 0 on success, negative on full. If
     * full, clear the pending bit so a future re-post is allowed. */
    cbz     w0, .Lhfp_ok

    /* Enqueue failed (queue full). Roll back the pending bit. */
    ldr     x2, =http_fsa_evt_pending
    /* w0 from helper clobbered EVT_WAY; re-derive from stack event. */
    ldrh    w0, [sp, #EVT_WAY]
    ldrh    w1, [sp, #EVT_CODE]
    ldrb    w3, [x2, w0, uxtw]
    mov     w4, #1
    lsl     w4, w4, w1
    bic     w3, w3, w4
    strb    w3, [x2, w0, uxtw]
    add     sp, sp, #EVT_SIZE
    mov     w0, #0
    b       .Lhfp_ret

.Lhfp_ok:
    add     sp, sp, #EVT_SIZE
    mov     w0, #1
    b       .Lhfp_ret

.Lhfp_drop:
    mov     w0, #0

.Lhfp_ret:
    ldp     x29, x30, [sp], #48
    ret

/* ------------------------------------------------------------------------
 * http_fsa_step — one engine step with per-way state plumbing.
 *
 * vmio_engine_step owns a single ENG_STATE field but our FSA has N
 * logical state variables — one per way. We fix that by peeking the
 * next event, resolving ostate[way] as the "real" current state,
 * copying it into ENG_STATE before the engine runs, and copying the
 * engine's post-step ENG_STATE back into ostate[way] after.
 *
 * Pending-bit clear happens BEFORE the engine runs, so a handler that
 * re-posts its own event type lands a fresh enqueue (the old one is
 * already in-hand as the dequeued event we're servicing).
 *
 * Peek semantics: both queues might hold events; priority is hi first.
 * The peek reads EVT_WAY without dequeuing — vmio_engine_step will do
 * the actual dequeue via its vmio_dequeue_priority call.
 *
 * Returns: w0 = STEP_OK / STEP_IDLE / STEP_NO_TRANS.
 * Clobbers: x0-x9, x19-x22, x30.
 * ------------------------------------------------------------------------ */
http_fsa_step:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    /* Peek the queue pair for the next event's way + code without
     * dequeuing. Peek order must match vmio_dequeue_priority: hi first,
     * then lo. If both are empty we still call vmio_engine_step — it
     * returns STEP_IDLE cleanly. */
    ldr     x19, =http_fsa_hi_queue
    ldr     x20, =http_fsa_lo_queue

    /* hi queue: head == tail means empty. */
    ldr     w0, [x19, #Q_HEAD]
    ldr     w1, [x19, #Q_TAIL]
    cmp     w0, w1
    b.ne    .Lhfs_peek_hi
    /* lo queue empty check */
    ldr     w0, [x20, #Q_HEAD]
    ldr     w1, [x20, #Q_TAIL]
    cmp     w0, w1
    b.eq    .Lhfs_idle            /* both empty — straight to engine for STEP_IDLE */
    mov     x19, x20               /* x19 = lo queue (has the event) */

.Lhfs_peek_hi:
    /* Slot address: &q_slots[head * EVT_SIZE] */
    ldr     w0, [x19, #Q_HEAD]
    add     x1, x19, #Q_SLOTS
    lsl     w2, w0, #5             /* head * 32 */
    add     x1, x1, x2
    ldrh    w19, [x1, #EVT_WAY]    /* w19 = way */
    ldrh    w20, [x1, #EVT_CODE]   /* w20 = evt_code (for pending-clear) */

    /* Bounds check the way — if garbage, skip the state swap and let
     * the engine reject via STEP_NO_TRANS or its own bounds checks. */
    cmp     w19, #HTTP_MAX_CONNS
    b.hs    .Lhfs_engine

    /* Load per-way state into ENG_STATE. */
    ldr     x2, =http_fsa_ostate
    ldrb    w3, [x2, w19, uxtw]
    ldr     x4, =http_fsa_engine
    str     w3, [x4, #ENG_STATE]

    /* Clear the pending bit for (way, evt_code). Done BEFORE dispatch
     * so a handler that re-posts its own type gets a fresh slot. */
    ldr     x2, =http_fsa_evt_pending
    ldrb    w5, [x2, w19, uxtw]
    mov     w6, #1
    lsl     w6, w6, w20
    bic     w5, w5, w6
    strb    w5, [x2, w19, uxtw]

.Lhfs_engine:
    ldr     x0, =http_fsa_engine
    bl      vmio_engine_step

    /* If the engine reported no valid dispatch, skip the state
     * writeback — ENG_STATE may have been left at a stale value. */
    cmp     w0, #STEP_OK
    b.ne    .Lhfs_ret

    /* Write engine.state back to ostate[way]. */
    cmp     w19, #HTTP_MAX_CONNS
    b.hs    .Lhfs_ret
    ldr     x4, =http_fsa_engine
    ldr     w5, [x4, #ENG_STATE]
    ldr     x2, =http_fsa_ostate
    strb    w5, [x2, w19, uxtw]

.Lhfs_ret:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

.Lhfs_idle:
    ldr     x0, =http_fsa_engine
    bl      vmio_engine_step
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * Handler stubs. Each increments its dispatch counter and returns.
 * Real logic lands in commit 3 (happy path) + later (error/close paths).
 * All handlers share the same signature:
 *   x0 = event_ptr, x1 = engine_ptr, x2 = ctx_ptr
 * ======================================================================== */

.macro FSA_STUB name, counter
\name:
    ldr     x3, =\counter
    ldr     w4, [x3]
    add     w4, w4, #1
    str     w4, [x3]
    ret
.endm

FSA_STUB h_install,   http_fsa_count_install
FSA_STUB h_send,      http_fsa_count_send
FSA_STUB h_noop,      http_fsa_count_noop
FSA_STUB h_decide,    http_fsa_count_decide
FSA_STUB h_reset,     http_fsa_count_reset
FSA_STUB h_close,     http_fsa_count_close
FSA_STUB h_keepalive, http_fsa_count_keepalive

/* ========================================================================
 * Transition table — 32 entries (4 states × 8 events) × 16 B = 512 B.
 * Layout per entry: u32 next_state, u32 pad, u64 handler_ptr.
 * Entries with handler_ptr = 0 yield STEP_NO_TRANS at runtime.
 *
 * Authored as a 32-entry .rodata block; the row index is state and the
 * column index within a row is evt_code. Zero rows / zero cells produce
 * STEP_NO_TRANS which the engine reports but doesn't fault on — so
 * stale events (e.g., WIN_OPEN for an IDLE way) are silently ignored.
 * ======================================================================== */
.section .rodata
.balign 16

http_fsa_trans_table:
    /* State O_IDLE (0) ------------------------------------------------ */
    /* IDLE + RESP_READY   → SETUP / h_install */
    .word   O_SETUP
    .word   0
    .quad   h_install
    /* IDLE + WIN_OPEN     → — */
    .word   0
    .word   0
    .quad   0
    /* IDLE + CHUNK_SENT   → — */
    .word   0
    .word   0
    .quad   0
    /* IDLE + ALL_QUEUED   → — */
    .word   0
    .word   0
    .quad   0
    /* IDLE + ALL_DRAINED  → — */
    .word   0
    .word   0
    .quad   0
    /* IDLE + TCP_CLOSED   → — (already idle, nothing to reset) */
    .word   0
    .word   0
    .quad   0
    /* IDLE + DO_CLOSE     → — */
    .word   0
    .word   0
    .quad   0
    /* IDLE + DO_KEEPALIVE → — */
    .word   0
    .word   0
    .quad   0

    /* State O_SETUP (1) ----------------------------------------------- */
    /* SETUP + RESP_READY  → — (already have a response; drop) */
    .word   0
    .word   0
    .quad   0
    /* SETUP + WIN_OPEN    → TX / h_send */
    .word   O_TX
    .word   0
    .quad   h_send
    /* SETUP + CHUNK_SENT  → — */
    .word   0
    .word   0
    .quad   0
    /* SETUP + ALL_QUEUED  → — */
    .word   0
    .word   0
    .quad   0
    /* SETUP + ALL_DRAINED → — */
    .word   0
    .word   0
    .quad   0
    /* SETUP + TCP_CLOSED  → IDLE / h_reset */
    .word   O_IDLE
    .word   0
    .quad   h_reset
    /* SETUP + DO_CLOSE    → — */
    .word   0
    .word   0
    .quad   0
    /* SETUP + DO_KEEP     → — */
    .word   0
    .word   0
    .quad   0

    /* State O_TX (2) -------------------------------------------------- */
    /* TX + RESP_READY     → — */
    .word   0
    .word   0
    .quad   0
    /* TX + WIN_OPEN       → TX / h_send */
    .word   O_TX
    .word   0
    .quad   h_send
    /* TX + CHUNK_SENT     → TX / h_send */
    .word   O_TX
    .word   0
    .quad   h_send
    /* TX + ALL_QUEUED     → DRAINING / h_noop */
    .word   O_DRAINING
    .word   0
    .quad   h_noop
    /* TX + ALL_DRAINED    → — */
    .word   0
    .word   0
    .quad   0
    /* TX + TCP_CLOSED     → IDLE / h_reset */
    .word   O_IDLE
    .word   0
    .quad   h_reset
    /* TX + DO_CLOSE       → — */
    .word   0
    .word   0
    .quad   0
    /* TX + DO_KEEP        → — */
    .word   0
    .word   0
    .quad   0

    /* State O_DRAINING (3) -------------------------------------------- */
    /* DRAINING + RESP_READY  → — */
    .word   0
    .word   0
    .quad   0
    /* DRAINING + WIN_OPEN    → — */
    .word   0
    .word   0
    .quad   0
    /* DRAINING + CHUNK_SENT  → — */
    .word   0
    .word   0
    .quad   0
    /* DRAINING + ALL_QUEUED  → — */
    .word   0
    .word   0
    .quad   0
    /* DRAINING + ALL_DRAINED → DRAINING / h_decide
     * h_decide posts DO_CLOSE or DO_KEEP back to hi, keeping the state
     * at DRAINING until the follow-up event routes us out. */
    .word   O_DRAINING
    .word   0
    .quad   h_decide
    /* DRAINING + TCP_CLOSED  → IDLE / h_reset */
    .word   O_IDLE
    .word   0
    .quad   h_reset
    /* DRAINING + DO_CLOSE    → IDLE / h_close */
    .word   O_IDLE
    .word   0
    .quad   h_close
    /* DRAINING + DO_KEEP     → IDLE / h_keepalive */
    .word   O_IDLE
    .word   0
    .quad   h_keepalive

.equ http_fsa_trans_table_entries, (. - http_fsa_trans_table) / TRANS_SIZE
.if http_fsa_trans_table_entries != (FSA_NSTATES * FSA_NEVENTS)
.error "http_fsa_trans_table size drift — update FSA_NSTATES or FSA_NEVENTS"
.endif

/* ========================================================================
 * .data — fsa state and queues. Sized for HTTP_MAX_CONNS (128).
 * ======================================================================== */
.section .data
.balign 16

/* ctx struct */
http_fsa_ctx:
    .skip FSA_CTX_SIZE

/* Engine (48 B) */
http_fsa_engine:
    .skip ENG_SIZE

/* Hi queue: 16 B header + 128 × 32 B slots = 4112 B */
http_fsa_hi_queue:
    .skip Q_SLOTS + HTTP_FSA_Q_CAP * EVT_SIZE

/* Lo queue */
http_fsa_lo_queue:
    .skip Q_SLOTS + HTTP_FSA_Q_CAP * EVT_SIZE

/* Per-way state + event-pending bitmask (one byte each). */
http_fsa_ostate:
    .skip HTTP_MAX_CONNS

http_fsa_evt_pending:
    .skip HTTP_MAX_CONNS

/* Dispatch counters — eight consecutive u32s so test init can zero
 * them with three 16-byte stores (stp xzr,xzr). */
http_fsa_count_install:    .word 0
http_fsa_count_send:       .word 0
http_fsa_count_noop:       .word 0
http_fsa_count_decide:     .word 0
http_fsa_count_reset:      .word 0
http_fsa_count_close:      .word 0
http_fsa_count_keepalive:  .word 0
http_fsa_count_pad:        .word 0   /* keep block 16-byte aligned */

.endif
