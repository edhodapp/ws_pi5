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
.global dhcp_retrans_cb
.global dhcp_t1_cb
.global dhcp_t2_cb
.global dhcp_lease_cb

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
    mov     w0, #DHCP_MAX_RETRIES
    str     w0, [x5, #DHCPC_RETRIES]

    /* Mark T1/T2/LEASE slots as unarmed (-1). h_commit_lease_arm_timers
     * cancels any pre-existing slot before re-arming on each ACK. */
    mov     w0, #-1
    str     w0, [x5, #DHCPC_T1_SLOT]
    str     w0, [x5, #DHCPC_T2_SLOT]
    str     w0, [x5, #DHCPC_LEASE_SLOT]

    /* Cache timer_freq. (Pure read of CNTFRQ_EL0; clobbers x0..x18.) */
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

/* _dhcp_discover_send_arm — shared body for h_send_discover and
 * h_resend_discover. Builds a DHCPDISCOVER (using the xid currently
 * in ctx.XID), wraps it in an Eth+IP+UDP broadcast, hands the frame
 * to ctx.send_fn, then arms the retrans timer at +4 s.
 *
 * Caller MUST set x19 = &dhcp_send_ctx and have already verified
 * ctx.send_fn != 0. Clobbers x0..x18 and x30; preserves x19..x28.
 * --------------------------------------------------------------------------- */
_dhcp_discover_send_arm:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x20, [sp, #16]

    /* Build payload at frame[42..]. */
    ldr     x0, [x19, #DHCPC_TX_BUF]
    add     x0, x0, #42
    ldr     w1, [x19, #DHCPC_XID]
    bl      dhcp_build_discover
    mov     w20, w0

    /* Wrap broadcast Eth+IP+UDP. */
    ldr     x0, [x19, #DHCPC_TX_BUF]
    mov     w1, w20
    bl      dhcp_wrap_broadcast

    /* send_fn(dwc2_base, ecm_state, frame, frame_len). */
    ldr     x5, [x19, #DHCPC_SEND_FN]
    ldr     x0, [x19, #DHCPC_DWC2_BASE]
    ldr     x1, [x19, #DHCPC_ECM_STATE]
    ldr     x2, [x19, #DHCPC_TX_BUF]
    add     w3, w20, #42
    blr     x5

    /* Arm retrans timer at now + 4 s. Skip if no timer pool (test
     * mode without a pool). RFC 2131 §4.1 RECOMMENDS exponential
     * backoff (4 / 8 / 16 s); v1 uses fixed 4 s — adequate against
     * the panic_d budget of 3 retries. Backoff is a follow-up. */
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    cbz     x0, .Ldsa_done
    bl      timer_now
    mov     x1, x0                          /* now */
    ldr     x2, [x19, #DHCPC_TIMER_FREQ]
    mov     x3, #4
    mul     x2, x2, x3                      /* 4 * freq */
    add     x1, x1, x2                      /* expiry = now + 4 s */
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     x2, =dhcp_retrans_cb
    mov     x3, x19
    bl      timer_set

.Ldsa_done:
    ldr     x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* h_send_discover — initial DISCOVER (or fresh restart from S_INIT
 * via the NAK→S_INIT→E_START loop). Picks a new xid, resets the
 * retry budget, then delegates send + timer arming to
 * _dhcp_discover_send_arm. Bumps dhcp_count_send_discover; pollutes
 * x3 with 0xDEAD as a regression guard. */
h_send_discover:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    movz    x3, #0xDEAD                     /* regression poison */

    adrp    x0, dhcp_count_send_discover
    add     x0, x0, :lo12:dhcp_count_send_discover
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     x5, [x19, #DHCPC_SEND_FN]
    cbz     x5, .Lhsd_done

    mrs     x0, CNTPCT_EL0
    str     w0, [x19, #DHCPC_XID]
    mov     w0, #DHCP_MAX_RETRIES
    str     w0, [x19, #DHCPC_RETRIES]

    bl      _dhcp_discover_send_arm

.Lhsd_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* h_resend_discover — retransmit DISCOVER with the SAME xid (so the
 * server's eventual OFFER is recognized as belonging to our active
 * transaction). Retry budget already decremented by dhcp_retrans_cb
 * before this handler ran. */
h_resend_discover:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    movz    x3, #0xDEAD

    adrp    x0, dhcp_count_resend_discover
    add     x0, x0, :lo12:dhcp_count_resend_discover
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     x5, [x19, #DHCPC_SEND_FN]
    cbz     x5, .Lhrd_done

    bl      _dhcp_discover_send_arm

.Lhrd_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* dhcp_retrans_cb — timer callback fired by timer_check when the
 * retrans timer expires. Decides which event to push into the FSA
 * based on remaining retry budget:
 *
 *   ctx.retries  > 0  →  decrement, fire E_TIMER_RETRANS_RETRY
 *                          (table dispatches h_resend_discover or
 *                           h_resend_request_selecting depending
 *                           on current state)
 *   ctx.retries == 0  →  fire E_TIMER_RETRANS_GIVEUP
 *                          (dispatches h_panic_d in SELECTING /
 *                           REQUESTING)
 *
 *   x0 = ctx pointer (timer_set wrote this when arming).
 */
dhcp_retrans_cb:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     w1, [x0, #DHCPC_RETRIES]
    cbz     w1, .Lcb_giveup
    sub     w1, w1, #1
    str     w1, [x0, #DHCPC_RETRIES]
    mov     w0, #E_TIMER_RETRANS_RETRY
    bl      dhcp_fsa_step
    b       .Lcb_done
.Lcb_giveup:
    mov     w0, #E_TIMER_RETRANS_GIVEUP
    bl      dhcp_fsa_step
.Lcb_done:
    ldp     x29, x30, [sp], #16
    ret
/* _dhcp_request_selecting_send_arm — shared body for
 * h_record_offer_send_request and h_resend_request_selecting.
 * Builds a SELECTING-state REQUEST (option 50 = ctx.REQUESTED_IP,
 * option 54 = ctx.SERVER_ID per RFC 2131 §4.4.1), wraps in
 * Eth+IP+UDP broadcast, sends, arms the retrans timer at +4 s.
 *
 * Caller MUST set x19 = &dhcp_send_ctx with SERVER_ID, REQUESTED_IP,
 * and XID populated, AND must have already verified send_fn != 0. */
_dhcp_request_selecting_send_arm:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x20, [sp, #16]

    /* dhcp_build_request_selecting(buf, xid, server_id, requested_ip) */
    ldr     x0, [x19, #DHCPC_TX_BUF]
    add     x0, x0, #42
    ldr     w1, [x19, #DHCPC_XID]
    ldr     w2, [x19, #DHCPC_SERVER_ID]
    ldr     w3, [x19, #DHCPC_REQUESTED_IP]
    bl      dhcp_build_request_selecting
    mov     w20, w0

    /* Wrap broadcast Eth+IP+UDP. */
    ldr     x0, [x19, #DHCPC_TX_BUF]
    mov     w1, w20
    bl      dhcp_wrap_broadcast

    /* send_fn(...) */
    ldr     x5, [x19, #DHCPC_SEND_FN]
    ldr     x0, [x19, #DHCPC_DWC2_BASE]
    ldr     x1, [x19, #DHCPC_ECM_STATE]
    ldr     x2, [x19, #DHCPC_TX_BUF]
    add     w3, w20, #42
    blr     x5

    /* Arm retrans timer at +4 s (skip if no pool). */
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    cbz     x0, .Lrssa_done
    bl      timer_now
    mov     x1, x0
    ldr     x2, [x19, #DHCPC_TIMER_FREQ]
    mov     x3, #4
    mul     x2, x2, x3
    add     x1, x1, x2
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     x2, =dhcp_retrans_cb
    mov     x3, x19
    bl      timer_set

.Lrssa_done:
    ldr     x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* h_record_offer_send_request — SELECTING + RX_OFFER_VALID.
 * Captures the OFFER's server_id + yiaddr from dhcp_parsed into
 * ctx (so subsequent SELECTING-state REQUEST retransmits don't
 * depend on dhcp_parsed surviving), resets the retry budget for
 * the REQUESTING phase, and sends the SELECTING-shape REQUEST. */
h_record_offer_send_request:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    movz    x3, #0xDEAD

    adrp    x0, dhcp_count_record_offer_send_request
    add     x0, x0, :lo12:dhcp_count_record_offer_send_request
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     x5, [x19, #DHCPC_SEND_FN]
    cbz     x5, .Lhrosr_done

    /* Cache server_id + yiaddr from the OFFER. */
    adrp    x0, dhcp_parsed
    add     x0, x0, :lo12:dhcp_parsed
    ldr     w1, [x0, #DHCP_PARSED_SERVER_ID]
    str     w1, [x19, #DHCPC_SERVER_ID]
    ldr     w1, [x0, #DHCP_PARSED_YIADDR]
    str     w1, [x19, #DHCPC_REQUESTED_IP]

    /* Fresh retry budget for the REQUESTING phase. */
    mov     w0, #DHCP_MAX_RETRIES
    str     w0, [x19, #DHCPC_RETRIES]

    bl      _dhcp_request_selecting_send_arm

.Lhrosr_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* h_resend_request_selecting — REQUESTING + TIMER_RETRANS_RETRY.
 * Re-sends the SELECTING-shape REQUEST with the cached
 * server_id / requested_ip / xid. Retry budget already decremented
 * by the cb. */
h_resend_request_selecting:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    movz    x3, #0xDEAD

    adrp    x0, dhcp_count_resend_request_selecting
    add     x0, x0, :lo12:dhcp_count_resend_request_selecting
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     x5, [x19, #DHCPC_SEND_FN]
    cbz     x5, .Lhrrs_done

    bl      _dhcp_request_selecting_send_arm

.Lhrrs_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
/* h_commit_lease_arm_timers — REQUESTING + RX_ACK_VALID, or
 * RENEWING/REBINDING + RX_ACK_VALID. Stamps the assigned IP,
 * netmask, and gateway from dhcp_parsed into the net_cfg globals
 * the rest of the stack reads, caches the lease time in ctx, and
 * arms three one-shot timers (T1 = lease/2, T2 = lease*7/8, full
 * lease expiry). The cbs fire the corresponding FSA events.
 *
 * Subtleties:
 *   - We only stamp net_netmask / net_gw_ip if the OFFER carried
 *     them (dhcp_parsed.flags). Missing options leave the existing
 *     globals alone.
 *   - Old T1/T2/lease timers from a prior BOUND→RENEWING→BOUND
 *     cycle ARE cancelled before re-arming, using the slot indices
 *     stored in ctx (DHCPC_T1_SLOT / _T2_SLOT / _LEASE_SLOT). Skips
 *     cancellation if the slot is the -1 sentinel (never armed).
 *
 *   - Timer arming converts host-order seconds → ticks via
 *     ctx.timer_freq. lease*freq fits in 64 bits comfortably even
 *     for 0xFFFFFFFF leases (~2^32 × 5×10^7 ≈ 2×10^17 < 2^63), so
 *     the existing 64-bit `mul` is enough — no overflow check
 *     needed. The intermediate `lease*7` (computed for T2 below)
 *     uses a 64-bit umull so the 7 × 2^32 case doesn't wrap. */
h_commit_lease_arm_timers:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    movz    x3, #0xDEAD

    adrp    x0, dhcp_count_commit_lease_arm_timers
    add     x0, x0, :lo12:dhcp_count_commit_lease_arm_timers
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    /* Apply the assigned IP from dhcp_parsed.yiaddr into
     * net_our_ip. yiaddr is wire-order bytes; copy verbatim. */
    adrp    x19, dhcp_parsed
    add     x19, x19, :lo12:dhcp_parsed
    adrp    x20, net_our_ip
    add     x20, x20, :lo12:net_our_ip
    ldrb    w0, [x19, #(DHCP_PARSED_YIADDR + 0)]; strb w0, [x20, #0]
    ldrb    w0, [x19, #(DHCP_PARSED_YIADDR + 1)]; strb w0, [x20, #1]
    ldrb    w0, [x19, #(DHCP_PARSED_YIADDR + 2)]; strb w0, [x20, #2]
    ldrb    w0, [x19, #(DHCP_PARSED_YIADDR + 3)]; strb w0, [x20, #3]

    ldrb    w0, [x19, #DHCP_PARSED_FLAGS]
    /* If subnet mask was seen, copy to net_netmask. */
    tst     w0, #DHCP_FLAG_SEEN_SUBNET
    b.eq    .Lcl_no_subnet
    adrp    x20, net_netmask
    add     x20, x20, :lo12:net_netmask
    ldrb    w1, [x19, #(DHCP_PARSED_SUBNET_MASK + 0)]; strb w1, [x20, #0]
    ldrb    w1, [x19, #(DHCP_PARSED_SUBNET_MASK + 1)]; strb w1, [x20, #1]
    ldrb    w1, [x19, #(DHCP_PARSED_SUBNET_MASK + 2)]; strb w1, [x20, #2]
    ldrb    w1, [x19, #(DHCP_PARSED_SUBNET_MASK + 3)]; strb w1, [x20, #3]
.Lcl_no_subnet:
    /* If router was seen, copy to net_gw_ip. */
    tst     w0, #DHCP_FLAG_SEEN_ROUTER
    b.eq    .Lcl_no_router
    adrp    x20, net_gw_ip
    add     x20, x20, :lo12:net_gw_ip
    ldrb    w1, [x19, #(DHCP_PARSED_ROUTER_IP + 0)]; strb w1, [x20, #0]
    ldrb    w1, [x19, #(DHCP_PARSED_ROUTER_IP + 1)]; strb w1, [x20, #1]
    ldrb    w1, [x19, #(DHCP_PARSED_ROUTER_IP + 2)]; strb w1, [x20, #2]
    ldrb    w1, [x19, #(DHCP_PARSED_ROUTER_IP + 3)]; strb w1, [x20, #3]
.Lcl_no_router:

    /* Cache lease time in ctx. */
    ldr     w0, [x19, #DHCP_PARSED_LEASE_TIME]
    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    str     w0, [x19, #DHCPC_LEASE_TIME]

    /* Now that net_our_ip is committed, kick the mDNS state machine.
     * In DHCP mode mdns_start ran at boot before this commit, found
     * net_our_ip == 0, and deferred its arm. mdns_kick performs that
     * arm now so the probe + announce phases carry the correct IP.
     * No-op if mDNS isn't IDLE (renewal on existing lease, static
     * mode, or mdns_start was never called). */
    bl      mdns_kick

    /* Arm timers: T1=lease/2, T2=lease*7/8, full=lease.
     * Skip if no timer pool (test mode without pool). */
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    cbz     x0, .Lcl_done

    /* Cancel any pre-existing T1/T2/lease slots from a prior cycle.
     * timer_cancel ignores out-of-range indices (incl. -1 sentinel
     * stored at boot), so the unarmed case is harmless. */
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     w1, [x19, #DHCPC_T1_SLOT]
    bl      timer_cancel
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     w1, [x19, #DHCPC_T2_SLOT]
    bl      timer_cancel
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     w1, [x19, #DHCPC_LEASE_SLOT]
    bl      timer_cancel

    /* Compute now (ticks). Stash in x20. */
    bl      timer_now
    mov     x20, x0

    /* T1 = now + (lease/2) * freq. */
    ldr     w0, [x19, #DHCPC_LEASE_TIME]
    lsr     w0, w0, #1
    ldr     x1, [x19, #DHCPC_TIMER_FREQ]
    mul     x0, x0, x1
    add     x1, x20, x0
    str     x1, [x19, #DHCPC_T1_DEADLINE]
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     x2, =dhcp_t1_cb
    mov     x3, x19
    bl      timer_set
    str     w0, [x19, #DHCPC_T1_SLOT]   /* capture returned slot */

    /* T2 = now + (lease * 7 / 8) * freq. */
    ldr     w0, [x19, #DHCPC_LEASE_TIME]
    mov     x1, #7
    umull   x0, w0, w1
    lsr     x0, x0, #3
    ldr     x1, [x19, #DHCPC_TIMER_FREQ]
    mul     x0, x0, x1
    add     x1, x20, x0
    str     x1, [x19, #DHCPC_T2_DEADLINE]
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     x2, =dhcp_t2_cb
    mov     x3, x19
    bl      timer_set
    str     w0, [x19, #DHCPC_T2_SLOT]

    /* Lease expiry = now + lease * freq. */
    ldr     w0, [x19, #DHCPC_LEASE_TIME]
    ldr     x1, [x19, #DHCPC_TIMER_FREQ]
    mul     x0, x0, x1
    add     x1, x20, x0
    str     x1, [x19, #DHCPC_LEASE_DEADLINE]
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     x2, =dhcp_lease_cb
    mov     x3, x19
    bl      timer_set
    str     w0, [x19, #DHCPC_LEASE_SLOT]

.Lcl_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* Timer callbacks for the three lease-cycle events. Each just fires
 * the corresponding FSA event; the engine's table dispatches the
 * right action handler. x0 = ctx pointer (set by timer_set). */
dhcp_t1_cb:
    stp     x29, x30, [sp, #-16]!
    mov     w0, #E_TIMER_T1
    bl      dhcp_fsa_step
    ldp     x29, x30, [sp], #16
    ret

dhcp_t2_cb:
    stp     x29, x30, [sp, #-16]!
    mov     w0, #E_TIMER_T2
    bl      dhcp_fsa_step
    ldp     x29, x30, [sp], #16
    ret

dhcp_lease_cb:
    stp     x29, x30, [sp, #-16]!
    mov     w0, #E_TIMER_LEASE
    bl      dhcp_fsa_step
    ldp     x29, x30, [sp], #16
    ret
/* _dhcp_request_renewing_send_arm — shared body for the four
 * BOUND-state outbound handlers (renew + rebind, send + resend).
 * Builds a renewing-shape REQUEST (no opt 50, no opt 54, ciaddr =
 * net_our_ip per RFC 2131 §4.3.6), wraps in Eth+IP+UDP broadcast,
 * sends, arms retrans at +4 s.
 *
 * v1 deviation: RFC 2131 §4.4.5 specifies RENEWING uses unicast to
 * the leasing server, REBINDING uses broadcast. We broadcast in
 * both cases — the original server still answers (it sees the
 * BOOTREQUEST in ciaddr scope), and a unicast variant requires
 * resolving the server's MAC via ARP first. v2 can split the
 * helpers if a deployment shows the unicast distinction matters.
 *
 * Caller MUST set x19 = &dhcp_send_ctx with XID populated and
 * have already verified send_fn != 0. */
_dhcp_request_renewing_send_arm:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x20, [sp, #16]

    /* dhcp_build_request_renewing(buf, xid, ciaddr=net_our_ip) */
    ldr     x0, [x19, #DHCPC_TX_BUF]
    add     x0, x0, #42
    ldr     w1, [x19, #DHCPC_XID]
    adrp    x2, net_our_ip
    add     x2, x2, :lo12:net_our_ip
    ldr     w2, [x2]
    bl      dhcp_build_request_renewing
    mov     w20, w0

    ldr     x0, [x19, #DHCPC_TX_BUF]
    mov     w1, w20
    bl      dhcp_wrap_broadcast

    ldr     x5, [x19, #DHCPC_SEND_FN]
    ldr     x0, [x19, #DHCPC_DWC2_BASE]
    ldr     x1, [x19, #DHCPC_ECM_STATE]
    ldr     x2, [x19, #DHCPC_TX_BUF]
    add     w3, w20, #42
    blr     x5

    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    cbz     x0, .Lrnsa_done
    bl      timer_now
    mov     x1, x0
    ldr     x2, [x19, #DHCPC_TIMER_FREQ]
    mov     x3, #4
    mul     x2, x2, x3
    add     x1, x1, x2
    ldr     x0, [x19, #DHCPC_TIMER_POOL]
    ldr     x2, =dhcp_retrans_cb
    mov     x3, x19
    bl      timer_set

.Lrnsa_done:
    ldr     x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* h_send_request_renew — BOUND + T1. Initial RENEWING-state send.
 * Picks a fresh xid (new transaction) and resets the retry budget. */
h_send_request_renew:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    movz    x3, #0xDEAD

    adrp    x0, dhcp_count_send_request_renew
    add     x0, x0, :lo12:dhcp_count_send_request_renew
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     x5, [x19, #DHCPC_SEND_FN]
    cbz     x5, .Lhsrn_done

    mrs     x0, CNTPCT_EL0
    str     w0, [x19, #DHCPC_XID]
    mov     w0, #DHCP_MAX_RETRIES
    str     w0, [x19, #DHCPC_RETRIES]

    bl      _dhcp_request_renewing_send_arm

.Lhsrn_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* h_resend_request_renew — RENEWING + TIMER_RETRANS_RETRY. Re-sends
 * the renewing-shape REQUEST with the same xid; cb already
 * decremented retries. */
h_resend_request_renew:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    movz    x3, #0xDEAD

    adrp    x0, dhcp_count_resend_request_renew
    add     x0, x0, :lo12:dhcp_count_resend_request_renew
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     x5, [x19, #DHCPC_SEND_FN]
    cbz     x5, .Lhrrn_done

    bl      _dhcp_request_renewing_send_arm

.Lhrrn_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* h_send_request_rebind — BOUND/RENEWING + T2. Initial REBINDING
 * send. Picks fresh xid and resets retry budget. */
h_send_request_rebind:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    movz    x3, #0xDEAD

    adrp    x0, dhcp_count_send_request_rebind
    add     x0, x0, :lo12:dhcp_count_send_request_rebind
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     x5, [x19, #DHCPC_SEND_FN]
    cbz     x5, .Lhsrb_done

    mrs     x0, CNTPCT_EL0
    str     w0, [x19, #DHCPC_XID]
    mov     w0, #DHCP_MAX_RETRIES
    str     w0, [x19, #DHCPC_RETRIES]

    bl      _dhcp_request_renewing_send_arm

.Lhsrb_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


/* h_resend_request_rebind — REBINDING + TIMER_RETRANS_RETRY. */
h_resend_request_rebind:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    movz    x3, #0xDEAD

    adrp    x0, dhcp_count_resend_request_rebind
    add     x0, x0, :lo12:dhcp_count_resend_request_rebind
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    adrp    x19, dhcp_send_ctx
    add     x19, x19, :lo12:dhcp_send_ctx
    ldr     x5, [x19, #DHCPC_SEND_FN]
    cbz     x5, .Lhrrb_done

    bl      _dhcp_request_renewing_send_arm

.Lhrrb_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
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
CELL S_SELECTING,    h_send_discover           /* E_RX_NAK_VALID */

/* --- S_BOUND --- */
CELL DHCP_NEXT_NONE, 0                         /* E_START */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_GIVEUP */
CELL S_RENEWING,     h_send_request_renew      /* E_TIMER_T1 */
CELL S_REBINDING,    h_send_request_rebind     /* E_TIMER_T2 */
CELL S_SELECTING,    h_send_discover           /* E_TIMER_LEASE */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_OFFER_VALID */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_ACK_VALID */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_NAK_VALID */

/* --- S_RENEWING --- */
CELL DHCP_NEXT_NONE, 0                         /* E_START */
CELL S_RENEWING,     h_resend_request_renew    /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_GIVEUP */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T1 */
CELL S_REBINDING,    h_send_request_rebind     /* E_TIMER_T2 */
CELL S_SELECTING,    h_send_discover           /* E_TIMER_LEASE */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_OFFER_VALID */
CELL S_BOUND,        h_commit_lease_arm_timers /* E_RX_ACK_VALID */
CELL S_SELECTING,    h_send_discover           /* E_RX_NAK_VALID */

/* --- S_REBINDING --- */
CELL DHCP_NEXT_NONE, 0                         /* E_START */
CELL S_REBINDING,    h_resend_request_rebind   /* E_TIMER_RETRANS_RETRY */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_RETRANS_GIVEUP */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T1 */
CELL DHCP_NEXT_NONE, 0                         /* E_TIMER_T2 */
CELL S_SELECTING,    h_send_discover           /* E_TIMER_LEASE */
CELL DHCP_NEXT_NONE, 0                         /* E_RX_OFFER_VALID */
CELL S_BOUND,        h_commit_lease_arm_timers /* E_RX_ACK_VALID */
CELL S_SELECTING,    h_send_discover           /* E_RX_NAK_VALID */

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

/* Per-handler dispatch counters. The block is bracketed by
 * dhcp_count_block_start/_end so test setup can zero the whole
 * range without naming each counter — adding a new handler in
 * future commits is a no-op for the test reset path. */
.global dhcp_count_block_start
.global dhcp_count_block_end
.balign 4
dhcp_count_block_start:
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
dhcp_count_block_end:
