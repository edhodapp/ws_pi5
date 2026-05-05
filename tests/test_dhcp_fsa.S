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
.include "timer.inc"

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
.global test_dhcp_ack_commits_lease
.global test_dhcp_t1_drives_renew
.global test_dhcp_t2_drives_rebind
.global test_dhcp_rebind_to_different_ip_kicks_mdns

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


/* ========================================================================
 * test_dhcp_ack_commits_lease — REQUESTING + RX_ACK_VALID. The
 * commit handler stamps yiaddr → net_our_ip and the lease into
 * ctx.LEASE_TIME, then arms T1/T2/lease timers. State advances
 * to BOUND.
 *
 * Asserts:
 *   - state == S_BOUND
 *   - h_commit_lease_arm_timers counter == 1
 *   - net_our_ip = 10.0.0.100 (from dhcp_parsed.yiaddr)
 *   - ctx.LEASE_TIME == 3600
 *   - timer pool has at least 3 armed slots (T1/T2/lease) above
 *     whatever was armed before (we use a fresh pool here so
 *     count == 3).
 * ======================================================================== */
test_dhcp_ack_commits_lease:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset
    bl      _dhcp_send_capture_reset

    /* Save net_our_ip so we can restore it (the test mutates it). */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    ldr     w1, [x0]
    adrp    x2, _dhcp_saved_net_our_ip
    add     x2, x2, :lo12:_dhcp_saved_net_our_ip
    str     w1, [x2]

    /* Init a fresh timer pool. */
    ldr     x0, =_dhcp_test_tpool
    mov     w1, #8
    bl      timer_pool_init

    /* Cache timer_freq into ctx. */
    bl      timer_freq
    adrp    x1, dhcp_send_ctx
    add     x1, x1, :lo12:dhcp_send_ctx
    str     x0, [x1, #DHCPC_TIMER_FREQ]
    ldr     x2, =_dhcp_test_tpool
    str     x2, [x1, #DHCPC_TIMER_POOL]

    /* Pre-populate dhcp_parsed with an ACK. */
    adrp    x0, dhcp_parsed
    add     x0, x0, :lo12:dhcp_parsed
    mov     w1, #DHCP_MSG_ACK
    strb    w1, [x0, #DHCP_PARSED_MSG_TYPE]
    /* yiaddr = 10.0.0.100 wire-order */
    mov     w1, #10
    strb    w1, [x0, #(DHCP_PARSED_YIADDR + 0)]
    strb    wzr, [x0, #(DHCP_PARSED_YIADDR + 1)]
    strb    wzr, [x0, #(DHCP_PARSED_YIADDR + 2)]
    mov     w1, #100
    strb    w1, [x0, #(DHCP_PARSED_YIADDR + 3)]
    /* lease_time = 3600 (host-order u32) */
    movz    w1, #0x0E10
    str     w1, [x0, #DHCP_PARSED_LEASE_TIME]
    /* No subnet/router options (flags = 0) so commit doesn't stomp
     * on existing net_netmask / net_gw_ip. */
    strb    wzr, [x0, #DHCP_PARSED_FLAGS]

    /* state = REQUESTING. */
    adrp    x1, dhcp_fsa_state
    add     x1, x1, :lo12:dhcp_fsa_state
    mov     w2, #S_REQUESTING
    str     w2, [x1]

    /* Fire RX_ACK_VALID. */
    mov     w0, #E_RX_ACK_VALID
    bl      dhcp_fsa_step

    /* state advanced to BOUND. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #S_BOUND
    b.ne    .Ldal_fail

    /* commit counter == 1. */
    adrp    x0, dhcp_count_commit_lease_arm_timers
    add     x0, x0, :lo12:dhcp_count_commit_lease_arm_timers
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldal_fail

    /* net_our_ip[0] == 10, net_our_ip[3] == 100. */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    ldrb    w1, [x0, #0]
    cmp     w1, #10
    b.ne    .Ldal_fail
    ldrb    w1, [x0, #3]
    cmp     w1, #100
    b.ne    .Ldal_fail

    /* ctx.LEASE_TIME == 3600. */
    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    ldr     w1, [x0, #DHCPC_LEASE_TIME]
    movz    w2, #0x0E10
    cmp     w1, w2
    b.ne    .Ldal_fail

    /* Timer pool: at least 3 slots have non-zero callback (T1/T2/lease).
     * Walk the slots manually. Each slot is SLOT_SIZE bytes; the
     * callback field is at SLOT_CALLBACK = 8. */
    ldr     x0, =_dhcp_test_tpool
    add     x0, x0, #TPOOL_SLOTS
    mov     w1, #0                      /* armed count */
    mov     w2, #8                      /* slots remaining */
.Ldal_walk:
    cbz     w2, .Ldal_done_walk
    ldr     x3, [x0, #SLOT_CALLBACK]
    cbz     x3, .Ldal_walk_skip
    add     w1, w1, #1
.Ldal_walk_skip:
    add     x0, x0, #SLOT_SIZE
    sub     w2, w2, #1
    b       .Ldal_walk
.Ldal_done_walk:
    cmp     w1, #3
    b.lt    .Ldal_fail

    /* Restore net_our_ip. */
    adrp    x0, _dhcp_saved_net_our_ip
    add     x0, x0, :lo12:_dhcp_saved_net_our_ip
    ldr     w1, [x0]
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    str     w1, [x0]

    ldr     x0, =_dhcp_name_ack_commits
    bl      test_pass
    b       .Ldal_done
.Ldal_fail:
    /* Best-effort restore on fail. */
    adrp    x0, _dhcp_saved_net_our_ip
    add     x0, x0, :lo12:_dhcp_saved_net_our_ip
    ldr     w1, [x0]
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    str     w1, [x0]
    ldr     x0, =_dhcp_name_ack_commits
    bl      test_fail
.Ldal_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_t1_drives_renew — BOUND + E_TIMER_T1 dispatches
 * h_send_request_renew, which sends a renewing-shape REQUEST and
 * advances state to RENEWING. The captured frame's BOOTP body
 * has ciaddr = net_our_ip and msg-type option = REQUEST.
 * ======================================================================== */
test_dhcp_t1_drives_renew:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset
    bl      _dhcp_send_capture_reset

    /* Set net_our_ip = 10.0.0.100 so ciaddr in the renewing
     * REQUEST has a recognizable signature. Save + restore. */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    ldr     w1, [x0]
    adrp    x2, _dhcp_saved_net_our_ip
    add     x2, x2, :lo12:_dhcp_saved_net_our_ip
    str     w1, [x2]
    mov     w1, #10
    strb    w1, [x0, #0]
    strb    wzr, [x0, #1]
    strb    wzr, [x0, #2]
    mov     w1, #100
    strb    w1, [x0, #3]

    /* Pre-populate ctx with capture send_fn, no timer pool. */
    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    str     xzr, [x0, #DHCPC_DWC2_BASE]
    str     xzr, [x0, #DHCPC_ECM_STATE]
    ldr     x1, =_dhcp_test_tx_buf
    str     x1, [x0, #DHCPC_TX_BUF]
    str     xzr, [x0, #DHCPC_TIMER_POOL]
    ldr     x1, =_dhcp_send_capture
    str     x1, [x0, #DHCPC_SEND_FN]

    /* state = BOUND. */
    adrp    x1, dhcp_fsa_state
    add     x1, x1, :lo12:dhcp_fsa_state
    mov     w2, #S_BOUND
    str     w2, [x1]

    /* Fire T1. */
    mov     w0, #E_TIMER_T1
    bl      dhcp_fsa_step

    /* state advanced to RENEWING. */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #S_RENEWING
    b.ne    .Lhrenew_fail

    /* h_send_request_renew counter == 1. */
    adrp    x0, dhcp_count_send_request_renew
    add     x0, x0, :lo12:dhcp_count_send_request_renew
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lhrenew_fail

    /* send_count == 1. */
    adrp    x0, _dhcp_send_count
    add     x0, x0, :lo12:_dhcp_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lhrenew_fail

    /* Captured frame: ciaddr at BOOTP_CIADDR (offset 12 in BOOTP,
     * 42 + 12 = 54 from frame start) starts with 10. */
    adrp    x0, _dhcp_last_frame
    add     x0, x0, :lo12:_dhcp_last_frame
    ldr     x0, [x0]
    cbz     x0, .Lhrenew_fail
    ldrb    w1, [x0, #(42 + 12)]
    cmp     w1, #10
    b.ne    .Lhrenew_fail
    ldrb    w1, [x0, #(42 + 15)]
    cmp     w1, #100
    b.ne    .Lhrenew_fail
    /* Option 53 (msg-type) at BOOTP_OPTIONS+0..2 = 282..284. */
    ldrb    w1, [x0, #(42 + 240 + 2)]
    cmp     w1, #DHCP_MSG_REQUEST
    b.ne    .Lhrenew_fail

    /* Restore net_our_ip. */
    adrp    x0, _dhcp_saved_net_our_ip
    add     x0, x0, :lo12:_dhcp_saved_net_our_ip
    ldr     w1, [x0]
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    str     w1, [x0]

    ldr     x0, =_dhcp_name_t1_renew
    bl      test_pass
    b       .Lhrenew_done
.Lhrenew_fail:
    adrp    x0, _dhcp_saved_net_our_ip
    add     x0, x0, :lo12:_dhcp_saved_net_our_ip
    ldr     w1, [x0]
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    str     w1, [x0]
    ldr     x0, =_dhcp_name_t1_renew
    bl      test_fail
.Lhrenew_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_t2_drives_rebind — RENEWING + E_TIMER_T2 dispatches
 * h_send_request_rebind, advances state to REBINDING.
 * ======================================================================== */
test_dhcp_t2_drives_rebind:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset
    bl      _dhcp_send_capture_reset

    adrp    x0, dhcp_send_ctx
    add     x0, x0, :lo12:dhcp_send_ctx
    str     xzr, [x0, #DHCPC_DWC2_BASE]
    str     xzr, [x0, #DHCPC_ECM_STATE]
    ldr     x1, =_dhcp_test_tx_buf
    str     x1, [x0, #DHCPC_TX_BUF]
    str     xzr, [x0, #DHCPC_TIMER_POOL]
    ldr     x1, =_dhcp_send_capture
    str     x1, [x0, #DHCPC_SEND_FN]

    /* state = RENEWING. */
    adrp    x1, dhcp_fsa_state
    add     x1, x1, :lo12:dhcp_fsa_state
    mov     w2, #S_RENEWING
    str     w2, [x1]

    mov     w0, #E_TIMER_T2
    bl      dhcp_fsa_step

    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #S_REBINDING
    b.ne    .Ldtb_fail

    adrp    x0, dhcp_count_send_request_rebind
    add     x0, x0, :lo12:dhcp_count_send_request_rebind
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldtb_fail

    adrp    x0, _dhcp_send_count
    add     x0, x0, :lo12:_dhcp_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ldtb_fail

    ldr     x0, =_dhcp_name_t2_rebind
    bl      test_pass
    b       .Ldtb_done
.Ldtb_fail:
    ldr     x0, =_dhcp_name_t2_rebind
    bl      test_fail
.Ldtb_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_dhcp_rebind_to_different_ip_kicks_mdns — pins the
 * h_commit_lease_arm_timers → mdns_kick → re-announce path on a
 * rebind that lands on a DIFFERENT IP than the previous lease.
 *
 * Sequence simulated:
 *   - mdns_send_ctx is in LIVE state with ANNOUNCED_IP = IP_A.
 *   - net_our_ip == IP_A (the prior lease).
 *   - dhcp_fsa_state == S_RENEWING (we just got NAKed→DISCOVER→
 *     OFFER and are about to receive ACK from the rebind path; the
 *     test fires E_RX_ACK_VALID directly with yiaddr = IP_B in
 *     dhcp_parsed, simulating the late stage of the rebind flow).
 *
 * After firing E_RX_ACK_VALID:
 *   - state advances to S_BOUND.                     (FSA correct)
 *   - net_our_ip == IP_B.                            (commit handler
 *                                                     stamped yiaddr)
 *   - mdns_send_ctx.MDNSC_ANNOUNCED_IP == IP_B.      (mdns_kick fired
 *                                                     and detected the
 *                                                     IP change)
 *   - mdns_send_ctx.MDNSC_STATE == MDNS_STATE_PROBE_1. (kick re-armed
 *                                                       a fresh probe
 *                                                       cycle)
 *
 * If any of the last three assertions fails, the kernel will
 * announce an outdated IP to the LAN until the next reboot — which
 * is the hardware-side defect dhcp_dynamics' rebind test surfaced.
 * Test is RED until the chain works end-to-end.
 *
 * Uses IP_A = 10.0.0.100, IP_B = 10.0.0.105 to mirror the dynamics-
 * suite scenario (dhcp-host pinning the rig MAC to a different IP).
 * ======================================================================== */
test_dhcp_rebind_to_different_ip_kicks_mdns:
    stp     x29, x30, [sp, #-16]!

    bl      _dhcp_test_reset
    bl      _dhcp_send_capture_reset

    /* Save net_our_ip + net_hostname[_len] so we can restore them. */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    ldr     w1, [x0]
    adrp    x2, _dhcp_saved_net_our_ip
    add     x2, x2, :lo12:_dhcp_saved_net_our_ip
    str     w1, [x2]

    /* Initialise a fresh timer pool (cap 8). */
    ldr     x0, =_dhcp_test_tpool
    mov     w1, #8
    bl      timer_pool_init

    /* Cache timer_freq into the dhcp ctx + supply a timer pool. */
    bl      timer_freq
    adrp    x1, dhcp_send_ctx
    add     x1, x1, :lo12:dhcp_send_ctx
    str     x0, [x1, #DHCPC_TIMER_FREQ]
    ldr     x2, =_dhcp_test_tpool
    str     x2, [x1, #DHCPC_TIMER_POOL]

    /* Provide hostname so mdns_kick's _mdns_try_arm guards proceed.
     * Set net_hostname = "qemu", net_hostname_len = 4. */
    adrp    x0, net_hostname
    add     x0, x0, :lo12:net_hostname
    stp     xzr, xzr, [x0, #0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]
    stp     xzr, xzr, [x0, #48]
    mov     w1, #'q'
    strb    w1, [x0, #0]
    mov     w1, #'e'
    strb    w1, [x0, #1]
    mov     w1, #'m'
    strb    w1, [x0, #2]
    mov     w1, #'u'
    strb    w1, [x0, #3]
    adrp    x0, net_hostname_len
    add     x0, x0, :lo12:net_hostname_len
    mov     w1, #4
    str     w1, [x0]

    /* Set up the mdns context as if a prior probe + announce cycle
     * for IP_A had already completed: state = LIVE, ANNOUNCED_IP =
     * 10.0.0.100, timer pool wired. TX_BUF / SEND_FN are only read
     * by mdns_timer_cb, which the test doesn't drive — leaving them
     * 0 keeps the test's scope tight to the kick path. */
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    /* Zero context first. */
    stp     xzr, xzr, [x0, #0]              /* DWC2_BASE, ECM_STATE */
    stp     xzr, xzr, [x0, #16]             /* TX_BUF, TIMER_POOL */
    stp     xzr, xzr, [x0, #32]             /* TIMER_FREQ, SEND_FN */
    stp     xzr, xzr, [x0, #48]             /* STATE/TIMER_SLOT, ANNOUNCED_IP/pad */
    /* TIMER_POOL is the only field _mdns_try_arm requires non-zero. */
    ldr     x1, =_dhcp_test_tpool
    str     x1, [x0, #24]                   /* MDNSC_TIMER_POOL */
    /* state = LIVE. */
    mov     w1, #6                          /* MDNS_STATE_LIVE */
    str     w1, [x0, #48]                   /* MDNSC_STATE */
    /* TIMER_SLOT = -1 (unarmed; LIVE has no active timer). */
    mov     w1, #-1
    str     w1, [x0, #52]                   /* MDNSC_TIMER_SLOT */
    /* ANNOUNCED_IP = 10.0.0.100 wire-order. */
    adrp    x1, net_our_ip
    add     x1, x1, :lo12:net_our_ip
    mov     w2, #10
    strb    w2, [x1, #0]
    strb    wzr, [x1, #1]
    strb    wzr, [x1, #2]
    mov     w2, #100
    strb    w2, [x1, #3]
    /* Copy net_our_ip → MDNSC_ANNOUNCED_IP. */
    ldr     w2, [x1]
    str     w2, [x0, #56]                   /* MDNSC_ANNOUNCED_IP */

    /* Stage an ACK with yiaddr = 10.0.0.105 (IP_B, different). */
    adrp    x0, dhcp_parsed
    add     x0, x0, :lo12:dhcp_parsed
    mov     w1, #DHCP_MSG_ACK
    strb    w1, [x0, #DHCP_PARSED_MSG_TYPE]
    mov     w1, #10
    strb    w1, [x0, #(DHCP_PARSED_YIADDR + 0)]
    strb    wzr, [x0, #(DHCP_PARSED_YIADDR + 1)]
    strb    wzr, [x0, #(DHCP_PARSED_YIADDR + 2)]
    mov     w1, #105
    strb    w1, [x0, #(DHCP_PARSED_YIADDR + 3)]
    /* Lease time 3600. */
    movz    w1, #0x0E10
    str     w1, [x0, #DHCP_PARSED_LEASE_TIME]
    /* No subnet/router. */
    strb    wzr, [x0, #DHCP_PARSED_FLAGS]

    /* state = RENEWING (rebind path lands here too via the FSA). */
    adrp    x1, dhcp_fsa_state
    add     x1, x1, :lo12:dhcp_fsa_state
    mov     w2, #S_RENEWING
    str     w2, [x1]

    /* Fire E_RX_ACK_VALID. h_commit_lease_arm_timers runs;
     * net_our_ip should become 10.0.0.105; mdns_kick should detect
     * the IP change and re-arm a fresh probe cycle. */
    mov     w0, #E_RX_ACK_VALID
    bl      dhcp_fsa_step

    /* === Verify FSA advanced to BOUND. === */
    adrp    x0, dhcp_fsa_state
    add     x0, x0, :lo12:dhcp_fsa_state
    ldr     w0, [x0]
    cmp     w0, #S_BOUND
    b.ne    .Ldrk_fail

    /* === net_our_ip == 10.0.0.105. === */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    ldrb    w1, [x0, #0]
    cmp     w1, #10
    b.ne    .Ldrk_fail
    ldrb    w1, [x0, #3]
    cmp     w1, #105
    b.ne    .Ldrk_fail

    /* === MDNSC_ANNOUNCED_IP == net_our_ip (mdns_kick fired). === */
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    ldr     w1, [x0, #56]                   /* MDNSC_ANNOUNCED_IP */
    adrp    x2, net_our_ip
    add     x2, x2, :lo12:net_our_ip
    ldr     w2, [x2]
    cmp     w1, w2
    b.ne    .Ldrk_fail

    /* === MDNSC_STATE == PROBE_1 (cycle restarted). === */
    ldr     w1, [x0, #48]                   /* MDNSC_STATE */
    cmp     w1, #1                          /* MDNS_STATE_PROBE_1 */
    b.ne    .Ldrk_fail

    /* Restore net_our_ip. */
    adrp    x0, _dhcp_saved_net_our_ip
    add     x0, x0, :lo12:_dhcp_saved_net_our_ip
    ldr     w1, [x0]
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    str     w1, [x0]

    ldr     x0, =_dhcp_name_rebind_kicks_mdns
    bl      test_pass
    b       .Ldrk_done
.Ldrk_fail:
    /* Best-effort restore on fail. */
    adrp    x0, _dhcp_saved_net_our_ip
    add     x0, x0, :lo12:_dhcp_saved_net_our_ip
    ldr     w1, [x0]
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    str     w1, [x0]
    ldr     x0, =_dhcp_name_rebind_kicks_mdns
    bl      test_fail
.Ldrk_done:
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
_dhcp_name_ack_commits:        .asciz "dhcp_ack_commits_lease"
_dhcp_name_t1_renew:           .asciz "dhcp_t1_drives_renew"
_dhcp_name_t2_rebind:          .asciz "dhcp_t2_drives_rebind"
_dhcp_name_rebind_kicks_mdns:  .asciz "dhcp_rebind_to_different_ip_kicks_mdns"


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

.balign 8
_dhcp_test_tpool:
    .space 520                          /* TPOOL_DEFAULT_SIZE = 8 + 16*32 */

.balign 4
_dhcp_saved_net_our_ip:
    .space 4
