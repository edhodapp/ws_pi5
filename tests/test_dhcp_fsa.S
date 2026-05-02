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
.global test_dhcp_start_sends_discover_broadcast
.global test_dhcp_retrans_cb_fires_retry
.global test_dhcp_retrans_cb_fires_giveup
.global test_dhcp_offer_drives_request

.section .text

/* Reset FSA state + zero the entire handler-counter block. Uses
 * the dhcp_count_block_start/_end symbols from lib/dhcp_fsa.S so
 * adding a new handler counter in a future commit doesn't require
 * touching this function. */
_dhcp_test_reset:
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    str     wzr, [x0]
    adrp    x0, dhcp_count_block_start
    add     x0, x0, :lo12:dhcp_count_block_start
    adrp    x1, dhcp_count_block_end
    add     x1, x1, :lo12:dhcp_count_block_end
.Ldtr_loop:
    cmp     x0, x1
    b.hs    .Ldtr_done
    str     wzr, [x0], #4
    b       .Ldtr_loop
.Ldtr_done:
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


/* Fake send_fn used by dhcp_start tests. Captures (frame_ptr,
 * frame_len) into BSS globals so tests can assert on the wire-
 * format bytes of the emitted DISCOVER. Args:
 *   x0 = dwc2_base (ignored), x1 = ecm_state (ignored),
 *   x2 = frame ptr,           w3 = frame length.
 */
_dhcp_send_capture:
    adrp    x4, _dhcp_send_count
    add     x4, x4, :lo12:_dhcp_send_count
    ldr     w5, [x4]
    add     w5, w5, #1
    str     w5, [x4]
    adrp    x4, _dhcp_last_frame
    add     x4, x4, :lo12:_dhcp_last_frame
    str     x2, [x4]
    str     w3, [x4, #8]
    mov     w0, #0
    ret

_dhcp_send_capture_reset:
    adrp    x0, _dhcp_send_count
    add     x0, x0, :lo12:_dhcp_send_count
    str     wzr, [x0]
    adrp    x0, _dhcp_last_frame
    add     x0, x0, :lo12:_dhcp_last_frame
    str     xzr, [x0]
    str     wzr, [x0, #8]
    ret


/* ========================================================================
 * test_dhcp_start_populates_ctx_and_fires — dhcp_start writes its
 * args into dhcp_send_ctx, fires E_START, and the FSA advances
 * from S_INIT to S_SELECTING via the h_send_discover dispatch.
 * ======================================================================== */
test_dhcp_start_populates_ctx_and_fires:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset
    bl      _dhcp_send_capture_reset

    /* dwc2_base / ecm_state — distinctive sentinels (no deref).
     * tx_buf — real BSS scratch so h_send_discover can write.
     * timer_pool — sentinel (no deref; retrans timer arming
     *   doesn't land until I16-7).
     * send_fn — capture stub. */
    movz    x0, #0x1111
    movz    x1, #0x2222
    ldr     x2, =_dhcp_test_tx_buf
    movz    x3, #0x4444
    ldr     x4, =_dhcp_send_capture
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
    ldr     x2, =_dhcp_test_tx_buf
    cmp     x1, x2
    b.ne    .Ldsta_fail
    ldr     x1, [x0, #DHCPC_TIMER_POOL]
    movz    x2, #0x4444
    cmp     x1, x2
    b.ne    .Ldsta_fail
    ldr     x1, [x0, #DHCPC_SEND_FN]
    ldr     x2, =_dhcp_send_capture
    cmp     x1, x2
    b.ne    .Ldsta_fail
    ldr     w1, [x0, #DHCPC_RETRIES]
    cmp     w1, #DHCP_MAX_RETRIES
    b.ne    .Ldsta_fail
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


/* ========================================================================
 * test_dhcp_start_sends_discover_broadcast — once dhcp_start fires
 * E_START, the real h_send_discover handler builds a DISCOVER and
 * pushes a complete Eth+IP+UDP+BOOTP frame through send_fn. Asserts
 * the captured frame has the expected wire shape:
 *   Eth dst   = ff:ff:ff:ff:ff:ff (broadcast)
 *   Eth type  = 0x0800
 *   IP dst    = 255.255.255.255
 *   IP src    = 0.0.0.0
 *   IP proto  = 17 (UDP)
 *   IP TTL    = 64
 *   UDP sport = 68, dport = 67
 *   BOOTP op  = BOOTREQUEST at offset 42
 * ======================================================================== */
test_dhcp_start_sends_discover_broadcast:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset
    bl      _dhcp_send_capture_reset

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =_dhcp_test_tx_buf
    mov     x3, #0
    ldr     x4, =_dhcp_send_capture
    bl      dhcp_start

    /* send_fn invoked exactly once. */
    adrp    x0, _dhcp_send_count
    add     x0, x0, :lo12:_dhcp_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldsd_fail

    /* Captured frame is the tx_buf we passed in. */
    adrp    x0, _dhcp_last_frame
    add     x0, x0, :lo12:_dhcp_last_frame
    ldr     x0, [x0]
    cbz     x0, .Ldsd_fail
    ldr     x1, =_dhcp_test_tx_buf
    cmp     x0, x1
    b.ne    .Ldsd_fail

    /* Eth dst[0] == 0xFF, Eth dst[5] == 0xFF (broadcast). */
    ldrb    w1, [x0, #0]
    cmp     w1, #0xFF
    b.ne    .Ldsd_fail
    ldrb    w1, [x0, #5]
    cmp     w1, #0xFF
    b.ne    .Ldsd_fail

    /* Eth type = 0x0800. */
    ldrb    w1, [x0, #12]
    cmp     w1, #0x08
    b.ne    .Ldsd_fail
    ldrb    w1, [x0, #13]
    cbnz    w1, .Ldsd_fail

    /* IP src = 0.0.0.0 (offsets 14+12..14+15). */
    ldrb    w1, [x0, #(14 + 12)]
    cbnz    w1, .Ldsd_fail
    ldrb    w1, [x0, #(14 + 15)]
    cbnz    w1, .Ldsd_fail

    /* IP dst = 255.255.255.255. */
    ldrb    w1, [x0, #(14 + 16)]
    cmp     w1, #0xFF
    b.ne    .Ldsd_fail
    ldrb    w1, [x0, #(14 + 19)]
    cmp     w1, #0xFF
    b.ne    .Ldsd_fail

    /* IP proto = 17, IP TTL = 64. */
    ldrb    w1, [x0, #(14 + 8)]
    cmp     w1, #64
    b.ne    .Ldsd_fail
    ldrb    w1, [x0, #(14 + 9)]
    cmp     w1, #17
    b.ne    .Ldsd_fail

    /* UDP sport = 68 (low byte 0x44 at offset 14+21). */
    ldrb    w1, [x0, #(14 + 20)]
    cbnz    w1, .Ldsd_fail
    ldrb    w1, [x0, #(14 + 21)]
    cmp     w1, #68
    b.ne    .Ldsd_fail
    /* UDP dport = 67. */
    ldrb    w1, [x0, #(14 + 22)]
    cbnz    w1, .Ldsd_fail
    ldrb    w1, [x0, #(14 + 23)]
    cmp     w1, #67
    b.ne    .Ldsd_fail

    /* BOOTP op at offset 42 == BOOTREQUEST (1). */
    ldrb    w1, [x0, #42]
    cmp     w1, #1
    b.ne    .Ldsd_fail

    ldr     x0, =_dhcp_name_start_sends
    bl      test_pass
    b       .Ldsd_done
.Ldsd_fail:
    ldr     x0, =_dhcp_name_start_sends
    bl      test_fail
.Ldsd_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_retrans_cb_fires_retry — with retries > 0, the callback
 * decrements retries and fires E_TIMER_RETRANS_RETRY, which (in
 * S_SELECTING) dispatches h_resend_discover.
 * ======================================================================== */
test_dhcp_retrans_cb_fires_retry:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset
    bl      _dhcp_send_capture_reset

    /* Pre-populate dhcp_send_ctx so h_resend_discover can run.
     * State = S_SELECTING; retries = 2; tx_buf + send_fn real. */
    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    str     xzr, [x0, #DHCPC_DWC2_BASE]
    str     xzr, [x0, #DHCPC_ECM_STATE]
    ldr     x1, =_dhcp_test_tx_buf
    str     x1, [x0, #DHCPC_TX_BUF]
    str     xzr, [x0, #DHCPC_TIMER_POOL]   /* no pool — skip arming */
    ldr     x1, =_dhcp_send_capture
    str     x1, [x0, #DHCPC_SEND_FN]
    /* xid for build_discover */
    movz    w1, #0x1234
    str     w1, [x0, #DHCPC_XID]
    mov     w1, #2
    str     w1, [x0, #DHCPC_RETRIES]

    adrp    x1, dhcp_fsa_state
    add     x1, x1, :lo12:dhcp_fsa_state
    mov     w2, #S_SELECTING
    str     w2, [x1]

    /* Fire callback with ctx pointer. */
    bl      dhcp_retrans_cb

    /* Retries decremented to 1. */
    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    ldr     w0, [x0, #DHCPC_RETRIES]
    cmp     w0, #1
    b.ne    .Ldcb_fail

    /* h_resend_discover counter == 1 (proves RETRY event fired). */
    adrp    x0, dhcp_count_resend_discover
    add     x0, x0, :lo12:dhcp_count_resend_discover
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldcb_fail

    /* h_panic_d counter == 0 (GIVEUP did NOT fire). */
    adrp    x0, dhcp_count_panic_d
    add     x0, x0, :lo12:dhcp_count_panic_d
    ldr     w0, [x0]
    cbnz    w0, .Ldcb_fail

    ldr     x0, =_dhcp_name_cb_retry
    bl      test_pass
    b       .Ldcb_done
.Ldcb_fail:
    ldr     x0, =_dhcp_name_cb_retry
    bl      test_fail
.Ldcb_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_retrans_cb_fires_giveup — with retries == 0, the
 * callback fires E_TIMER_RETRANS_GIVEUP, which (in S_SELECTING)
 * dispatches h_panic_d (stub bumps counter, returns).
 * ======================================================================== */
test_dhcp_retrans_cb_fires_giveup:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset

    /* state = SELECTING; retries = 0. */
    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    str     wzr, [x0, #DHCPC_RETRIES]
    adrp    x1, dhcp_fsa_state
    add     x1, x1, :lo12:dhcp_fsa_state
    mov     w2, #S_SELECTING
    str     w2, [x1]

    bl      dhcp_retrans_cb

    /* h_panic_d counter == 1. */
    adrp    x0, dhcp_count_panic_d
    add     x0, x0, :lo12:dhcp_count_panic_d
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldgu_fail

    /* h_resend_discover counter == 0. */
    adrp    x0, dhcp_count_resend_discover
    add     x0, x0, :lo12:dhcp_count_resend_discover
    ldr     w0, [x0]
    cbnz    w0, .Ldgu_fail

    ldr     x0, =_dhcp_name_cb_giveup
    bl      test_pass
    b       .Ldgu_done
.Ldgu_fail:
    ldr     x0, =_dhcp_name_cb_giveup
    bl      test_fail
.Ldgu_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_offer_drives_request — wire dhcp_parsed with an OFFER
 * payload, set state=SELECTING, fire E_RX_OFFER_VALID. The FSA
 * dispatches h_record_offer_send_request, which caches server_id
 * + yiaddr in ctx, sends a REQUEST, and transitions the FSA to
 * REQUESTING. Asserts:
 *   - state == S_REQUESTING
 *   - ctx.server_id / ctx.requested_ip captured from dhcp_parsed
 *   - send_count == 1
 *   - captured frame's BOOTP options include opt 53=REQUEST,
 *     opt 50=requested_ip, opt 54=server_id (validated by the
 *     existing builder tests; here we just sanity-check opt 53).
 * ======================================================================== */
test_dhcp_offer_drives_request:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset
    bl      _dhcp_send_capture_reset

    /* Pre-populate ctx (no timer pool — skip arming). */
    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    str     xzr, [x0, #DHCPC_DWC2_BASE]
    str     xzr, [x0, #DHCPC_ECM_STATE]
    ldr     x1, =_dhcp_test_tx_buf
    str     x1, [x0, #DHCPC_TX_BUF]
    str     xzr, [x0, #DHCPC_TIMER_POOL]
    ldr     x1, =_dhcp_send_capture
    str     x1, [x0, #DHCPC_SEND_FN]
    movz    w1, #0x1234
    str     w1, [x0, #DHCPC_XID]
    mov     w1, #DHCP_MAX_RETRIES
    str     w1, [x0, #DHCPC_RETRIES]
    /* net_our_mac default 02:00:00:00:00:01 is fine — required by
     * dhcp_build_request_selecting via _dhcp_zero_header. */

    /* Pre-populate dhcp_parsed with an OFFER's relevant fields.
     * yiaddr = 10.0.0.100 (wire bytes 0x0a000064 stored LE),
     * server_id = 10.0.0.1 (0x0a000001 LE). */
    adrp    x0, dhcp_parsed
    add     x0, x0, :lo12:dhcp_parsed
    mov     w1, #DHCP_MSG_OFFER
    strb    w1, [x0, #DHCP_PARSED_MSG_TYPE]
    /* yiaddr bytes wire-order: 10, 0, 0, 100 */
    mov     w1, #10
    strb    w1, [x0, #(DHCP_PARSED_YIADDR + 0)]
    strb    wzr, [x0, #(DHCP_PARSED_YIADDR + 1)]
    strb    wzr, [x0, #(DHCP_PARSED_YIADDR + 2)]
    mov     w1, #100
    strb    w1, [x0, #(DHCP_PARSED_YIADDR + 3)]
    /* server_id bytes wire-order: 10, 0, 0, 1 */
    mov     w1, #10
    strb    w1, [x0, #(DHCP_PARSED_SERVER_ID + 0)]
    strb    wzr, [x0, #(DHCP_PARSED_SERVER_ID + 1)]
    strb    wzr, [x0, #(DHCP_PARSED_SERVER_ID + 2)]
    mov     w1, #1
    strb    w1, [x0, #(DHCP_PARSED_SERVER_ID + 3)]

    /* state = SELECTING. */
    adrp    x1, dhcp_fsa_state
    add     x1, x1, :lo12:dhcp_fsa_state
    mov     w2, #S_SELECTING
    str     w2, [x1]

    /* Fire RX_OFFER_VALID. */
    mov     w0, #E_RX_OFFER_VALID
    bl      dhcp_fsa_step

    /* state advanced to REQUESTING. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #S_REQUESTING
    b.ne    .Ldor_fail

    /* h_record_offer_send_request counter == 1. */
    adrp    x0, dhcp_count_record_offer_send_request
    add     x0, x0, :lo12:dhcp_count_record_offer_send_request
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldor_fail

    /* ctx.server_id == 10 in low byte. */
    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    ldrb    w1, [x0, #(DHCPC_SERVER_ID + 0)]
    cmp     w1, #10
    b.ne    .Ldor_fail
    ldrb    w1, [x0, #(DHCPC_SERVER_ID + 3)]
    cmp     w1, #1
    b.ne    .Ldor_fail
    /* ctx.requested_ip == 10.0.0.100. */
    ldrb    w1, [x0, #(DHCPC_REQUESTED_IP + 0)]
    cmp     w1, #10
    b.ne    .Ldor_fail
    ldrb    w1, [x0, #(DHCPC_REQUESTED_IP + 3)]
    cmp     w1, #100
    b.ne    .Ldor_fail

    /* send_count == 1. */
    adrp    x0, _dhcp_send_count
    add     x0, x0, :lo12:_dhcp_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldor_fail

    /* Captured frame's BOOTP message-type option == REQUEST.
     * Option 53 lives at frame[42 + BOOTP_OPTIONS + 0..2] =
     * frame[42 + 240 + 2] = frame[284]. */
    adrp    x0, _dhcp_last_frame
    add     x0, x0, :lo12:_dhcp_last_frame
    ldr     x0, [x0]
    cbz     x0, .Ldor_fail
    /* Option 53 code at offset 282, len at 283, value at 284. */
    ldrb    w1, [x0, #(42 + 240 + 0)]
    cmp     w1, #DHCP_OPT_MSG_TYPE
    b.ne    .Ldor_fail
    ldrb    w1, [x0, #(42 + 240 + 2)]
    cmp     w1, #DHCP_MSG_REQUEST
    b.ne    .Ldor_fail

    ldr     x0, =_dhcp_name_offer_drives
    bl      test_pass
    b       .Ldor_done
.Ldor_fail:
    ldr     x0, =_dhcp_name_offer_drives
    bl      test_fail
.Ldor_done:
    ldp     x29, x30, [sp], #16
    ret


.section .rodata
_dhcp_name_step_init_start:    .asciz "dhcp_fsa_step_init_start"
_dhcp_name_step_no_handler:    .asciz "dhcp_fsa_step_no_handler"
_dhcp_name_step_oob_event:     .asciz "dhcp_fsa_step_oob_event"
_dhcp_name_step_oob_state:     .asciz "dhcp_fsa_step_oob_state"
_dhcp_name_step_panic_d_runs:  .asciz "dhcp_fsa_step_panic_d_runs"
_dhcp_name_start:              .asciz "dhcp_start_populates_ctx_and_fires"
_dhcp_name_start_sends:        .asciz "dhcp_start_sends_discover_broadcast"
_dhcp_name_cb_retry:           .asciz "dhcp_retrans_cb_fires_retry"
_dhcp_name_cb_giveup:          .asciz "dhcp_retrans_cb_fires_giveup"
_dhcp_name_offer_drives:       .asciz "dhcp_offer_drives_request"


.section .bss
.balign 8
_dhcp_test_tx_buf:
    .space 512                          /* room for Eth+IP+UDP+BOOTP */

.balign 8
_dhcp_send_count:
    .space 4
.balign 8
_dhcp_last_frame:
    .space 8                            /* captured frame ptr */
    .space 8                            /* captured len + pad */
