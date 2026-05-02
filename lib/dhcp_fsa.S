/*
 * lib/dhcp_fsa.S — DHCP client state machine (D017).
 *
 * Table-driven FSA, locked to tests/func/dhcp_fsa_vectors.tsv via
 *   make verify-dhcp-fsa-table
 *
 * Single-instance (one DHCP client, one state). Handlers in this
 * file are STUB implementations that bump per-handler counters so
 * tests can observe dispatch — the real implementations land in
 * I16-3 (builders), I16-4 (parsers), and I16-5 (action glue). The
 * stubs DO NOT send packets or arm timers; they only count.
 *
 * Public entry points:
 *
 *   dhcp_fsa_step(w0=event)
 *     One step of the engine. Reads the (state, event) cell from
 *     dhcp_fsa_trans_table, dispatches the handler if non-zero, and
 *     updates dhcp_fsa_state if the cell's next-state is not the
 *     DHCP_NEXT_NONE sentinel. Out-of-range state or event is a
 *     silent no-op (defensive — should never happen at runtime).
 *
 *   dhcp_fsa_state (BSS u32) — current state. Tests overwrite it
 *     directly to walk the matrix; production code touches it only
 *     through dhcp_fsa_step.
 *
 *   dhcp_fsa_trans_table (.rodata) — 6 × 9 = 54 entries × 16 B.
 *     Indexed by (state * DHCP_NEVENTS + event). Verified against
 *     the TSV by scripts/verify_dhcp_fsa_table.py.
 */

.include "dhcp.inc"

.global dhcp_fsa_step
.global dhcp_fsa_state
.global dhcp_fsa_trans_table
.global dhcp_send_ctx
.global dhcp_start

/* Handler symbols are .global so the verify script can resolve
 * (state, event) → expected handler via the ELF symbol table. */
.global h_send_discover
.global h_resend_discover
.global h_record_offer_send_request
.global h_resend_request_selecting
.global h_commit_lease_arm_timers
.global h_send_request_renew
.global h_resend_request_renew
.global h_send_request_rebind
.global h_resend_request_rebind
.global h_panic_d

/* Per-handler dispatch counters — tests assert against these to
 * confirm the engine reached the right cell. One u32 each. */
.global dhcp_count_send_discover
.global dhcp_count_resend_discover
.global dhcp_count_record_offer_send_request
.global dhcp_count_resend_request_selecting
.global dhcp_count_commit_lease_arm_timers
.global dhcp_count_send_request_renew
.global dhcp_count_resend_request_renew
.global dhcp_count_send_request_rebind
.global dhcp_count_resend_request_rebind
.global dhcp_count_panic_d


.section .text

/* ---------------------------------------------------------------------------
 * dhcp_fsa_step — one engine step.
 *
 *   w0 = event ordinal (E_*)
 *
 * Returns: nothing.
 * Clobbers: x0..x5, x30 (handlers may clobber more — see their docs).
 *
 * Bounds checks: out-of-range state OR event is a silent no-op.
 * Production code should never produce one; the check is defence in
 * depth against a stale event slipping through.
 * --------------------------------------------------------------------------- */
dhcp_fsa_step:
    /* x19 holds the table entry pointer across the handler call.
     * Caller-saved x0..x18 are not safe to keep state in across
     * `blr x5`, so we use a callee-saved register and stack it. */
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x19, [sp, #16]

    cmp     w0, #DHCP_NEVENTS
    b.hs    .Lstep_done                /* event out of range — drop */
    mov     w1, w0                     /* w1 = event */

    adrp    x2, dhcp_fsa_state
    add     x2, x2, :lo12:dhcp_fsa_state
    ldr     w0, [x2]                   /* w0 = state */
    cmp     w0, #DHCP_NSTATES
    b.hs    .Lstep_done                /* state out of range — drop */

    /* idx = state * DHCP_NEVENTS + event */
    mov     w3, #DHCP_NEVENTS
    madd    w3, w0, w3, w1             /* w3 = idx */

    /* x19 = entry pointer = table_base + idx * DHCP_TRANS_SIZE */
    lsl     w3, w3, #4                 /* TRANS_SIZE = 16 */
    adrp    x19, dhcp_fsa_trans_table
    add     x19, x19, :lo12:dhcp_fsa_trans_table
    add     x19, x19, w3, uxtw

    ldr     x5, [x19, #DHCP_TRANS_HANDLER]
    cbz     x5, .Lstep_maybe_state     /* no handler — state may still update */
    blr     x5                         /* run handler (may clobber x0..x18) */

.Lstep_maybe_state:
    /* x19 (callee-saved) survived the blr; reuse it to read NEXT. */
    ldr     w0, [x19, #DHCP_TRANS_NEXT]
    cmn     w0, #1                     /* w0 == DHCP_NEXT_NONE (0xFFFFFFFF)? */
    b.eq    .Lstep_done
    adrp    x2, dhcp_fsa_state
    add     x2, x2, :lo12:dhcp_fsa_state
    str     w0, [x2]

.Lstep_done:
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* ---------------------------------------------------------------------------
 * dhcp_start — initialize dhcp_send_ctx and kick off the FSA.
 *
 *   x0 = DWC2 base address (0 in tests)
 *   x1 = ECM state pointer (0 in tests)
 *   x2 = TX buffer pointer (≥ 350 B; caller-owned)
 *   x3 = timer pool pointer
 *   x4 = send function pointer with arp_start's signature:
 *        send_fn(dwc2_base, ecm_state, frame, frame_len) → status
 *
 * Returns: nothing.
 *
 * Side effects:
 *   - dhcp_send_ctx fields populated.
 *   - dhcp_send_ctx.timer_freq cached from CNTFRQ_EL0 via timer_freq().
 *   - dhcp_send_ctx.retries = DHCP_MAX_RETRIES.
 *   - dhcp_fsa_state forced to S_INIT (defends against pre-existing
 *     state from a prior incarnation).
 *   - Fires E_START into the FSA, which drives the table to
 *     S_SELECTING via h_send_discover. (In I16-5 the handler is
 *     still a stub; in I16-6 the real handler will build a
 *     DISCOVER, send it via send_fn, and arm the retransmit timer.)
 * --------------------------------------------------------------------------- */
dhcp_start:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    adrp    x5, dhcp_send_ctx
    add     x5, x5, :lo12:dhcp_send_ctx
    str     x0, [x5, #DHCPC_DWC2_BASE]
    str     x1, [x5, #DHCPC_ECM_STATE]
    str     x2, [x5, #DHCPC_TX_BUF]
    str     x3, [x5, #DHCPC_TIMER_POOL]
    str     x4, [x5, #DHCPC_SEND_FN]
    /* Initial retry budget. */
    mov     w0, #DHCP_MAX_RETRIES
    str     w0, [x5, #DHCPC_RETRIES]

    /* Cache timer_freq. (Pure read of CNTFRQ_EL0; no clobber of x5
     * but reload it after to be safe.) */
    bl      timer_freq
    adrp    x5, dhcp_send_ctx
    add     x5, x5, :lo12:dhcp_send_ctx
    str     x0, [x5, #DHCPC_TIMER_FREQ]

    /* Reset the FSA state. */
    adrp    x5, dhcp_fsa_state
    add     x5, x5, :lo12:dhcp_fsa_state
    str     wzr, [x5]

    /* Fire E_START. Engine dispatches h_send_discover and advances
     * to S_SELECTING per the table. */
    mov     w0, #E_START
    bl      dhcp_fsa_step

    ldp     x29, x30, [sp], #16
    ret


/* ---------------------------------------------------------------------------
 * Handler stubs — bump counter, return. Real implementations land
 * in I16-3..I16-5; the stubs let the FSA engine + verify script
 * land cleanly in I16-2 with full test coverage of the table walk.
 *
 * Each stub deliberately poisons x3 with 0xDEAD before returning.
 * This is a regression guard: the engine MUST keep its state in
 * callee-saved registers across the blr to a handler. If a future
 * change reverts to holding the table-entry offset in caller-saved
 * w3 (the original design, fixed before merge), the existing tests
 * will start failing because the handler post-state would compute
 * an offset based on 0xDEAD and either fault or transition wrong.
 * --------------------------------------------------------------------------- */
.macro DHCP_STUB name, counter
\name:
    movz    x3, #0xDEAD
    adrp    x0, \counter
    add     x0, x0, :lo12:\counter
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]
    ret
.endm

DHCP_STUB h_send_discover,                dhcp_count_send_discover
DHCP_STUB h_resend_discover,              dhcp_count_resend_discover
DHCP_STUB h_record_offer_send_request,    dhcp_count_record_offer_send_request
DHCP_STUB h_resend_request_selecting,     dhcp_count_resend_request_selecting
DHCP_STUB h_commit_lease_arm_timers,      dhcp_count_commit_lease_arm_timers
DHCP_STUB h_send_request_renew,           dhcp_count_send_request_renew
DHCP_STUB h_resend_request_renew,         dhcp_count_resend_request_renew
DHCP_STUB h_send_request_rebind,          dhcp_count_send_request_rebind
DHCP_STUB h_resend_request_rebind,        dhcp_count_resend_request_rebind
DHCP_STUB h_panic_d,                      dhcp_count_panic_d
/* h_panic_d is a stub here so tests can observe dispatch. The real
 * panic_d (lib/panic.S) is invoked from action-handler glue in
 * I16-5; once that lands, this stub is replaced with a tail-call to
 * panic_n equivalent. The stub returns so tests can keep going. */


/* ===========================================================================
 * Transition table — 54 entries indexed by (state * DHCP_NEVENTS + event).
 *
 * Each entry: u32 next_state (or DHCP_NEXT_NONE), u32 pad, u64 handler_ptr.
 *
 * The exact (NextState, Handler) values mirror
 * tests/func/dhcp_fsa_vectors.tsv. scripts/verify_dhcp_fsa_table.py
 * cross-checks this binary against the TSV to catch silent drift.
 * =========================================================================== */
.section .rodata
.balign 16

dhcp_fsa_trans_table:

/* Helper: emit one entry. NEXT may be a state ordinal or
 * DHCP_NEXT_NONE; HANDLER is a label or 0. */
.macro CELL next, handler
    .word \next
    .word 0
    .quad \handler
.endm

/* --- S_INIT --- */
CELL S_SELECTING,    h_send_discover           /* E_START */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_GIVEUP */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T1 */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T2 */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_LEASE */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_OFFER_VALID */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_ACK_VALID */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_NAK_VALID */

/* --- S_SELECTING --- */
CELL DHCP_NEXT_NONE, 0                         /* E_START */
CELL S_SELECTING,    h_resend_discover         /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, h_panic_d                 /* E_TIMER_RETRANS_GIVEUP */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T1 */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T2 */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_LEASE */
CELL S_REQUESTING,   h_record_offer_send_request /* E_RX_OFFER_VALID */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_ACK_VALID */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_NAK_VALID */

/* --- S_REQUESTING --- */
CELL DHCP_NEXT_NONE, 0                         /* E_START */
CELL S_REQUESTING,   h_resend_request_selecting /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, h_panic_d                 /* E_TIMER_RETRANS_GIVEUP */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T1 */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T2 */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_LEASE */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_OFFER_VALID */
CELL S_BOUND,        h_commit_lease_arm_timers /* E_RX_ACK_VALID */
CELL S_INIT,         h_send_discover           /* E_RX_NAK_VALID */

/* --- S_BOUND --- */
CELL DHCP_NEXT_NONE, 0                         /* E_START */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_GIVEUP */
CELL S_RENEWING,     h_send_request_renew      /* E_TIMER_T1 */
CELL S_REBINDING,    h_send_request_rebind     /* E_TIMER_T2 */
CELL S_INIT,         h_send_discover           /* E_TIMER_LEASE */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_OFFER_VALID */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_ACK_VALID */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_NAK_VALID */

/* --- S_RENEWING --- */
CELL DHCP_NEXT_NONE, 0                         /* E_START */
CELL S_RENEWING,     h_resend_request_renew    /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_GIVEUP */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T1 */
CELL S_REBINDING,    h_send_request_rebind     /* E_TIMER_T2 */
CELL S_INIT,         h_send_discover           /* E_TIMER_LEASE */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_OFFER_VALID */
CELL S_BOUND,        h_commit_lease_arm_timers /* E_RX_ACK_VALID */
CELL S_INIT,         h_send_discover           /* E_RX_NAK_VALID */

/* --- S_REBINDING --- */
CELL DHCP_NEXT_NONE, 0                         /* E_START */
CELL S_REBINDING,    h_resend_request_rebind   /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_GIVEUP */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T1 */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T2 */
CELL S_INIT,         h_send_discover           /* E_TIMER_LEASE */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_OFFER_VALID */
CELL S_BOUND,        h_commit_lease_arm_timers /* E_RX_ACK_VALID */
CELL S_INIT,         h_send_discover           /* E_RX_NAK_VALID */

/* Build-time size guard: catch reorderings or missing rows that
 * would silently drift the table from the TSV. */
.equ dhcp_fsa_trans_table_entries, (. - dhcp_fsa_trans_table) / DHCP_TRANS_SIZE
.if dhcp_fsa_trans_table_entries != (DHCP_NSTATES * DHCP_NEVENTS)
.error "dhcp_fsa_trans_table size drift — check DHCP_NSTATES / DHCP_NEVENTS / row count"
.endif


.section .bss
.balign 8
dhcp_fsa_state:        .space 4

.balign 8
dhcp_send_ctx:         .space DHCPC_SIZE

.balign 4
dhcp_count_send_discover:                .space 4
dhcp_count_resend_discover:              .space 4
dhcp_count_record_offer_send_request:    .space 4
dhcp_count_resend_request_selecting:     .space 4
dhcp_count_commit_lease_arm_timers:      .space 4
dhcp_count_send_request_renew:           .space 4
dhcp_count_resend_request_renew:         .space 4
dhcp_count_send_request_rebind:          .space 4
dhcp_count_resend_request_rebind:        .space 4
dhcp_count_panic_d:                      .space 4
