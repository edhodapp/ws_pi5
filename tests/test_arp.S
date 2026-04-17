/*
 * test_arp.S — Tests for ARP handler, request builder, and timer
 *
 * Tests:
 *   1. test_arp_request_for_us    — ARP request for 10.0.2.15 → reply + cache
 *   2. test_arp_request_other_ip  — ARP request for 10.0.2.99 → ignored
 *   3. test_arp_reply_learned     — ARP reply from gateway → caches MAC
 *   4. test_arp_truncated         — 41-byte frame → ignored
 *   5. test_arp_spa_zero          — SPA=0.0.0.0 → rejected
 *   6. test_arp_spa_broadcast     — SPA=255.255.255.255 → rejected
 *   7. test_arp_spa_multicast     — SPA=224.0.0.1 → rejected
 *   8. test_arp_reply_not_gw      — reply from non-gateway → ignored
 *   9. test_arp_reply_not_ours    — reply with TPA != our IP → ignored
 *  10. test_arp_bad_oper          — OPER=3 (invalid) → ignored
 *  11. test_arp_build_request     — field verification (broadcast)
 *  12. test_arp_build_req_unicast — field verification (unicast refresh)
 *  13. test_arp_gw_mac_cache      — gateway MAC cached on request
 *  14. test_arp_non_gw_no_cache   — non-gateway request → no cache
 *  15. test_arp_timer_cb_send     — timer builds request and sends
 *  16. test_arp_timer_cb_no_send  — timer with NULL send_fn → skip send
 *  17. test_arp_bad_htype         — HTYPE=2 (not Ethernet) → ignored
 *  18. test_arp_bad_hlen          — HLEN=4 (not 6) → ignored
 *  19. test_arp_timer_cb_rearm    — timer re-arm with pool → timer_set called
 */

.include "net.inc"
.include "timer.inc"

.global test_arp_request_for_us
.global test_arp_request_other_ip
.global test_arp_reply_learned
.global test_arp_truncated
.global test_arp_spa_zero
.global test_arp_spa_broadcast
.global test_arp_spa_multicast
.global test_arp_reply_not_gw
.global test_arp_reply_not_ours
.global test_arp_bad_oper
.global test_arp_build_request
.global test_arp_build_req_unicast
.global test_arp_gw_mac_cache
.global test_arp_non_gw_no_cache
.global test_arp_timer_cb_send
.global test_arp_timer_cb_no_send
.global test_arp_bad_htype
.global test_arp_bad_hlen
.global test_arp_timer_cb_rearm

.section .text

/* === Helper: copy 42 bytes from x0 to x1 === */
arp_copy42:
    ldr     x2, [x0, #0]
    str     x2, [x1, #0]
    ldr     x2, [x0, #8]
    str     x2, [x1, #8]
    ldr     x2, [x0, #16]
    str     x2, [x1, #16]
    ldr     x2, [x0, #24]
    str     x2, [x1, #24]
    ldr     x2, [x0, #32]
    str     x2, [x1, #32]
    ldrh    w2, [x0, #40]
    strh    w2, [x1, #40]
    ret

/* === Helper: clear net_gw_mac_valid === */
arp_clear_gw_cache:
    ldr     x0, =net_gw_mac_valid
    str     wzr, [x0]
    ret

/* ========================================================================
 * test_arp_request_for_us — full validation of in-place reply
 * ======================================================================== */
test_arp_request_for_us:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_req_template
    ldr     x1, =arp_req_buf
    bl      arp_copy42

    ldr     x0, =arp_req_buf
    mov     w1, #42
    bl      arp_handle

    cmp     w0, #42
    b.ne    .Lfail_arp_for_us

    /* Check ETH dst == sender MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_DST
    ldr     x1, =arp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_for_us

    /* Check ETH src == our MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_for_us

    /* Check ARP OPER == reply (0x00 0x02 on wire) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_OPER]
    cbnz    w1, .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_OPER + 1]
    cmp     w1, #2
    b.ne    .Lfail_arp_for_us

    /* Check ARP SHA == our MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_PAYLOAD + ARP_SHA
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_for_us

    /* Check ARP SPA == our IP (wire: 0A 00 02 0F) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_SPA]
    cmp     w1, #0x0A
    b.ne    .Lfail_arp_for_us
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_SPA + 3]
    cmp     w1, #0x0F
    b.ne    .Lfail_arp_for_us

    /* Check ARP THA == sender MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_PAYLOAD + ARP_THA
    ldr     x1, =arp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_for_us

    /* Check ARP TPA == sender IP (wire: 0A 00 02 02) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_TPA + 3]
    cmp     w1, #0x02
    b.ne    .Lfail_arp_for_us

    ldr     x0, =name_arp_for_us
    bl      test_pass
    b       .Ldone_arp_for_us

.Lfail_arp_for_us:
    ldr     x0, =name_arp_for_us
    bl      test_fail

.Ldone_arp_for_us:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_request_other_ip — ARP request for 10.0.2.99 → returns 0
 * ======================================================================== */
test_arp_request_other_ip:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_req_other_ip
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_arp_other_ip

    ldr     x0, =name_arp_other_ip
    bl      test_pass
    b       .Ldone_arp_other_ip

.Lfail_arp_other_ip:
    ldr     x0, =name_arp_other_ip
    bl      test_fail

.Ldone_arp_other_ip:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_reply_learned — ARP reply from gateway → caches MAC, returns 0
 * ======================================================================== */
test_arp_reply_learned:
    stp     x29, x30, [sp, #-16]!

    bl      arp_clear_gw_cache

    ldr     x0, =arp_reply_gw
    mov     w1, #42
    bl      arp_handle

    /* Should return 0 (no response frame) */
    cbnz    w0, .Lfail_arp_reply_learned

    /* Gateway MAC should now be cached */
    ldr     x0, =net_gw_mac_valid
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_arp_reply_learned

    /* Cached MAC should be AA:BB:CC:DD:EE:FF */
    ldr     x0, =net_gw_mac
    ldr     x1, =arp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_arp_reply_learned

    ldr     x0, =name_arp_reply_learned
    bl      test_pass
    b       .Ldone_arp_reply_learned

.Lfail_arp_reply_learned:
    ldr     x0, =name_arp_reply_learned
    bl      test_fail

.Ldone_arp_reply_learned:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_truncated — 41-byte frame → returns 0
 * ======================================================================== */
test_arp_truncated:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_req_template
    mov     w1, #41
    bl      arp_handle

    cbnz    w0, .Lfail_arp_trunc

    ldr     x0, =name_arp_trunc
    bl      test_pass
    b       .Ldone_arp_trunc

.Lfail_arp_trunc:
    ldr     x0, =name_arp_trunc
    bl      test_fail

.Ldone_arp_trunc:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_spa_zero — SPA=0.0.0.0 → rejected
 * ======================================================================== */
test_arp_spa_zero:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_spa_zero
    ldr     x1, =arp_req_buf
    bl      arp_copy42

    ldr     x0, =arp_req_buf
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_spa_zero

    ldr     x0, =name_spa_zero
    bl      test_pass
    b       .Ldone_spa_zero

.Lfail_spa_zero:
    ldr     x0, =name_spa_zero
    bl      test_fail

.Ldone_spa_zero:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_spa_broadcast — SPA=255.255.255.255 → rejected
 * ======================================================================== */
test_arp_spa_broadcast:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_spa_bcast
    ldr     x1, =arp_req_buf
    bl      arp_copy42

    ldr     x0, =arp_req_buf
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_spa_bcast

    ldr     x0, =name_spa_bcast
    bl      test_pass
    b       .Ldone_spa_bcast

.Lfail_spa_bcast:
    ldr     x0, =name_spa_bcast
    bl      test_fail

.Ldone_spa_bcast:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_spa_multicast — SPA=224.0.0.1 → rejected
 * ======================================================================== */
test_arp_spa_multicast:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_spa_mcast
    ldr     x1, =arp_req_buf
    bl      arp_copy42

    ldr     x0, =arp_req_buf
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_spa_mcast

    ldr     x0, =name_spa_mcast
    bl      test_pass
    b       .Ldone_spa_mcast

.Lfail_spa_mcast:
    ldr     x0, =name_spa_mcast
    bl      test_fail

.Ldone_spa_mcast:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_reply_not_gw — reply from non-gateway → ignored (no cache)
 * ======================================================================== */
test_arp_reply_not_gw:
    stp     x29, x30, [sp, #-16]!

    bl      arp_clear_gw_cache

    ldr     x0, =arp_reply_nongw
    mov     w1, #42
    bl      arp_handle

    /* Returns 0 */
    cbnz    w0, .Lfail_reply_not_gw

    /* Gateway MAC should NOT be cached */
    ldr     x0, =net_gw_mac_valid
    ldr     w0, [x0]
    cbnz    w0, .Lfail_reply_not_gw

    ldr     x0, =name_reply_not_gw
    bl      test_pass
    b       .Ldone_reply_not_gw

.Lfail_reply_not_gw:
    ldr     x0, =name_reply_not_gw
    bl      test_fail

.Ldone_reply_not_gw:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_reply_not_ours — reply with TPA != our IP → ignored
 * ======================================================================== */
test_arp_reply_not_ours:
    stp     x29, x30, [sp, #-16]!

    bl      arp_clear_gw_cache

    ldr     x0, =arp_reply_not_ours
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_reply_not_ours

    /* Gateway MAC should NOT be cached */
    ldr     x0, =net_gw_mac_valid
    ldr     w0, [x0]
    cbnz    w0, .Lfail_reply_not_ours

    ldr     x0, =name_reply_not_ours
    bl      test_pass
    b       .Ldone_reply_not_ours

.Lfail_reply_not_ours:
    ldr     x0, =name_reply_not_ours
    bl      test_fail

.Ldone_reply_not_ours:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_bad_oper — OPER=3 (invalid) → ignored
 * ======================================================================== */
test_arp_bad_oper:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_bad_oper
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_bad_oper

    ldr     x0, =name_bad_oper
    bl      test_pass
    b       .Ldone_bad_oper

.Lfail_bad_oper:
    ldr     x0, =name_bad_oper
    bl      test_fail

.Ldone_bad_oper:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_build_request — broadcast ARP request field verification
 * ======================================================================== */
test_arp_build_request:
    stp     x29, x30, [sp, #-16]!

    bl      arp_clear_gw_cache

    ldr     x0, =arp_req_buf
    bl      arp_build_request

    /* Returns 42 */
    cmp     w0, #42
    b.ne    .Lfail_build_req

    /* ETH dst should be broadcast */
    ldr     x0, =arp_req_buf
    ldr     x1, =net_broadcast_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_build_req

    /* ETH src should be our MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_build_req

    /* OPER should be request (wire: 00 01) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_OPER]
    cbnz    w1, .Lfail_build_req
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_OPER + 1]
    cmp     w1, #1
    b.ne    .Lfail_build_req

    /* SHA should be our MAC */
    ldr     x0, =arp_req_buf
    add     x0, x0, #ETH_PAYLOAD + ARP_SHA
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_build_req

    /* SPA should be our IP (wire: 0A 00 02 0F) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_SPA]
    cmp     w1, #0x0A
    b.ne    .Lfail_build_req
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_SPA + 3]
    cmp     w1, #0x0F
    b.ne    .Lfail_build_req

    /* TPA should be gateway IP (wire: 0A 00 02 02) */
    ldr     x0, =arp_req_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_TPA]
    cmp     w1, #0x0A
    b.ne    .Lfail_build_req
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_TPA + 3]
    cmp     w1, #0x02
    b.ne    .Lfail_build_req

    ldr     x0, =name_build_req
    bl      test_pass
    b       .Ldone_build_req

.Lfail_build_req:
    ldr     x0, =name_build_req
    bl      test_fail

.Ldone_build_req:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_build_req_unicast — unicast when gateway MAC known
 * ======================================================================== */
test_arp_build_req_unicast:
    stp     x29, x30, [sp, #-16]!

    /* Pre-set gateway MAC as known */
    ldr     x0, =net_gw_mac
    ldr     x1, =arp_sender_mac
    ldr     w2, [x1]
    str     w2, [x0]
    ldrh    w2, [x1, #4]
    strh    w2, [x0, #4]
    ldr     x0, =net_gw_mac_valid
    mov     w1, #1
    str     w1, [x0]

    ldr     x0, =arp_req_buf
    bl      arp_build_request

    cmp     w0, #42
    b.ne    .Lfail_build_uni

    /* ETH dst should be gateway MAC (unicast), not broadcast */
    ldr     x0, =arp_req_buf
    ldr     x1, =arp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_build_uni

    ldr     x0, =name_build_uni
    bl      test_pass
    b       .Ldone_build_uni

.Lfail_build_uni:
    ldr     x0, =name_build_uni
    bl      test_fail

.Ldone_build_uni:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_gw_mac_cache — request from gateway caches MAC
 * ======================================================================== */
test_arp_gw_mac_cache:
    stp     x29, x30, [sp, #-16]!

    bl      arp_clear_gw_cache

    ldr     x0, =arp_req_template
    ldr     x1, =arp_req_buf
    bl      arp_copy42

    ldr     x0, =arp_req_buf
    mov     w1, #42
    bl      arp_handle

    /* Should have cached gateway MAC */
    ldr     x0, =net_gw_mac_valid
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_gw_cache

    ldr     x0, =net_gw_mac
    ldr     x1, =arp_sender_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_gw_cache

    ldr     x0, =name_gw_cache
    bl      test_pass
    b       .Ldone_gw_cache

.Lfail_gw_cache:
    ldr     x0, =name_gw_cache
    bl      test_fail

.Ldone_gw_cache:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_non_gw_no_cache — request from non-gateway → no cache
 * ======================================================================== */
test_arp_non_gw_no_cache:
    stp     x29, x30, [sp, #-16]!

    bl      arp_clear_gw_cache

    ldr     x0, =arp_req_nongw
    ldr     x1, =arp_req_buf
    bl      arp_copy42

    ldr     x0, =arp_req_buf
    mov     w1, #42
    bl      arp_handle

    /* Returns 42 (reply built) */
    cmp     w0, #42
    b.ne    .Lfail_non_gw

    /* Gateway MAC should NOT be cached */
    ldr     x0, =net_gw_mac_valid
    ldr     w0, [x0]
    cbnz    w0, .Lfail_non_gw

    ldr     x0, =name_non_gw
    bl      test_pass
    b       .Ldone_non_gw

.Lfail_non_gw:
    ldr     x0, =name_non_gw
    bl      test_fail

.Ldone_non_gw:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_timer_cb_send — timer builds ARP request and sends
 * ======================================================================== */
test_arp_timer_cb_send:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      arp_clear_gw_cache

    /* Set up arp_send_ctx with fake send function */
    ldr     x19, =arp_send_ctx
    str     xzr, [x19, #ARPC_DWC2_BASE]
    str     xzr, [x19, #ARPC_ECM_STATE]
    ldr     x0, =arp_timer_tx_buf
    str     x0, [x19, #ARPC_TX_BUF]
    /* Use a real (but no-op) timer pool for re-arm — set to 0 to skip re-arm */
    str     xzr, [x19, #ARPC_TIMER_POOL]
    ldr     x0, =fake_arp_send
    str     x0, [x19, #ARPC_SEND_FN]
    bl      timer_freq
    str     x0, [x19, #ARPC_TIMER_FREQ]

    /* Clear send counter */
    ldr     x0, =arp_send_count
    str     wzr, [x0]

    /* Call timer callback */
    ldr     x0, =arp_send_ctx
    bl      arp_timer_cb

    /* Send should have been called once */
    ldr     x0, =arp_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_tcb_send

    /* tx_buf should contain a valid ARP request (OPER=request) */
    ldr     x0, =arp_timer_tx_buf
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_OPER]
    cbnz    w1, .Lfail_tcb_send
    ldrb    w1, [x0, #ETH_PAYLOAD + ARP_OPER + 1]
    cmp     w1, #1
    b.ne    .Lfail_tcb_send

    ldr     x0, =name_tcb_send
    bl      test_pass
    b       .Ldone_tcb_send

.Lfail_tcb_send:
    ldr     x0, =name_tcb_send
    bl      test_fail

.Ldone_tcb_send:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_arp_timer_cb_no_send — NULL send_fn → skip send, no crash
 * ======================================================================== */
test_arp_timer_cb_no_send:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    ldr     x19, =arp_send_ctx
    str     xzr, [x19, #ARPC_DWC2_BASE]
    str     xzr, [x19, #ARPC_ECM_STATE]
    ldr     x0, =arp_timer_tx_buf
    str     x0, [x19, #ARPC_TX_BUF]
    str     xzr, [x19, #ARPC_TIMER_POOL]
    str     xzr, [x19, #ARPC_SEND_FN]     /* NULL send_fn */
    bl      timer_freq
    str     x0, [x19, #ARPC_TIMER_FREQ]

    ldr     x0, =arp_send_count
    str     wzr, [x0]

    ldr     x0, =arp_send_ctx
    bl      arp_timer_cb

    /* Send should NOT have been called */
    ldr     x0, =arp_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_tcb_nosend

    ldr     x0, =name_tcb_nosend
    bl      test_pass
    b       .Ldone_tcb_nosend

.Lfail_tcb_nosend:
    ldr     x0, =name_tcb_nosend
    bl      test_fail

.Ldone_tcb_nosend:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_arp_bad_htype — HTYPE=2 (not Ethernet) → ignored
 * ======================================================================== */
test_arp_bad_htype:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_bad_htype
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_bad_htype

    ldr     x0, =name_bad_htype
    bl      test_pass
    b       .Ldone_bad_htype

.Lfail_bad_htype:
    ldr     x0, =name_bad_htype
    bl      test_fail

.Ldone_bad_htype:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_bad_hlen — HLEN=4 (not 6) → ignored
 * ======================================================================== */
test_arp_bad_hlen:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arp_bad_hlen
    mov     w1, #42
    bl      arp_handle

    cbnz    w0, .Lfail_bad_hlen

    ldr     x0, =name_bad_hlen
    bl      test_pass
    b       .Ldone_bad_hlen

.Lfail_bad_hlen:
    ldr     x0, =name_bad_hlen
    bl      test_fail

.Ldone_bad_hlen:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_arp_timer_cb_rearm — timer re-arm with real pool
 *
 * Sets ARPC_TIMER_POOL to a fake timer pool with 1 free slot.
 * After arp_timer_cb returns, the slot's CALLBACK should be
 * non-zero (timer_set wrote to it). This pins the cbz x0 branch
 * at arp.S:327 (the fall-through path: pool != NULL → call
 * timer_set).
 * ======================================================================== */
test_arp_timer_cb_rearm:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    /* Zero the fake timer pool: 1 slot, all clear */
    ldr     x0, =fake_timer_pool
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #24]
    /* Set capacity = 1 */
    mov     w1, #1
    str     w1, [x0, #TPOOL_CAP]

    /* Set up arp_send_ctx with pool + NULL send_fn (skip send) */
    ldr     x19, =arp_send_ctx
    str     xzr, [x19, #ARPC_DWC2_BASE]
    str     xzr, [x19, #ARPC_ECM_STATE]
    ldr     x0, =arp_timer_tx_buf
    str     x0, [x19, #ARPC_TX_BUF]
    ldr     x0, =fake_timer_pool
    str     x0, [x19, #ARPC_TIMER_POOL]
    str     xzr, [x19, #ARPC_SEND_FN]
    bl      timer_freq
    str     x0, [x19, #ARPC_TIMER_FREQ]

    /* Call timer callback */
    ldr     x0, =arp_send_ctx
    bl      arp_timer_cb

    /* The fake pool's slot 0 should have CALLBACK == arp_timer_cb
     * (timer_set wrote the re-arm callback there). */
    ldr     x0, =fake_timer_pool
    ldr     x1, [x0, #(TPOOL_SLOTS + SLOT_CALLBACK)]
    ldr     x2, =arp_timer_cb
    cmp     x1, x2
    b.ne    .Lfail_tcb_rearm

    ldr     x0, =name_tcb_rearm
    bl      test_pass
    b       .Ldone_tcb_rearm

.Lfail_tcb_rearm:
    ldr     x0, =name_tcb_rearm
    bl      test_fail

.Ldone_tcb_rearm:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * Fake send function — just increments counter
 * x0: dwc2_base, x1: ecm_state, x2: buf, w3: len
 * Returns: w0 = 0 (success)
 * ======================================================================== */
fake_arp_send:
    ldr     x9, =arp_send_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]
    mov     w0, #0
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

arp_sender_mac:
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF

/* ARP request: who has 10.0.2.15? Tell 10.0.2.2 (gateway) */
.balign 4
arp_req_template:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF     /* dst: broadcast */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: sender */
    .byte   0x08, 0x06                               /* EtherType: ARP */
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04      /* HTYPE/PTYPE/HLEN/PLEN */
    .byte   0x00, 0x01                               /* OPER: request */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* SHA: sender MAC */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* SPA: 10.0.2.2 */
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00     /* THA: unknown */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* TPA: 10.0.2.15 */

/* ARP request for 10.0.2.99 (not our IP) */
.balign 4
arp_req_other_ip:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x63                   /* TPA: 10.0.2.99 */

/* ARP reply from gateway: 10.0.2.2 is at AA:BB:CC:DD:EE:FF */
.balign 4
arp_reply_gw:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* src: gateway */
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04
    .byte   0x00, 0x02                               /* OPER: reply */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF     /* SHA: gateway MAC */
    .byte   0x0A, 0x00, 0x02, 0x02                   /* SPA: 10.0.2.2 */
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* THA: our MAC */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* TPA: 10.0.2.15 */

/* ARP reply from non-gateway (10.0.2.99) */
.balign 4
arp_reply_nongw:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04
    .byte   0x00, 0x02
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66     /* SHA */
    .byte   0x0A, 0x00, 0x02, 0x63                   /* SPA: 10.0.2.99 (not gw) */
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* THA: our MAC */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* TPA: our IP */

/* ARP reply with TPA != our IP */
.balign 4
arp_reply_not_ours:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04
    .byte   0x00, 0x02
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
    .byte   0x0A, 0x00, 0x02, 0x63                   /* TPA: 10.0.2.99 (not us) */

/* ARP request with SPA=0.0.0.0 */
.balign 4
arp_spa_zero:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x00, 0x00, 0x00, 0x00                   /* SPA: 0.0.0.0 */
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x0F

/* ARP request with SPA=255.255.255.255 */
.balign 4
arp_spa_bcast:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0xFF, 0xFF, 0xFF, 0xFF                   /* SPA: 255.255.255.255 */
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x0F

/* ARP request with SPA=224.0.0.1 (multicast) */
.balign 4
arp_spa_mcast:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0xE0, 0x00, 0x00, 0x01                   /* SPA: 224.0.0.1 */
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x0F

/* ARP with OPER=3 (invalid) */
.balign 4
arp_bad_oper:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04
    .byte   0x00, 0x03                               /* OPER: 3 (invalid) */
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x0F

/* ARP request from non-gateway host (10.0.2.99) for our IP */
.balign 4
arp_req_nongw:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66     /* src: different host */
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66     /* SHA */
    .byte   0x0A, 0x00, 0x02, 0x63                   /* SPA: 10.0.2.99 */
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* TPA: our IP */

/* ARP with HTYPE=2 (not Ethernet=1) */
.balign 4
arp_bad_htype:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x02                               /* HTYPE: 2 (not Ethernet) */
    .byte   0x08, 0x00, 0x06, 0x04, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x0F

/* ARP with HLEN=4 (not 6) */
.balign 4
arp_bad_hlen:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x08, 0x06
    .byte   0x00, 0x01, 0x08, 0x00
    .byte   0x04                                     /* HLEN: 4 (not 6) */
    .byte   0x04, 0x00, 0x01
    .byte   0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
    .byte   0x0A, 0x00, 0x02, 0x02
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte   0x0A, 0x00, 0x02, 0x0F

name_arp_for_us:        .asciz "arp_request_for_us"
name_arp_other_ip:      .asciz "arp_request_other_ip"
name_arp_reply_learned: .asciz "arp_reply_learned"
name_arp_trunc:         .asciz "arp_truncated"
name_spa_zero:          .asciz "arp_spa_zero"
name_spa_bcast:         .asciz "arp_spa_broadcast"
name_spa_mcast:         .asciz "arp_spa_multicast"
name_reply_not_gw:      .asciz "arp_reply_not_gw"
name_reply_not_ours:    .asciz "arp_reply_not_ours"
name_bad_oper:          .asciz "arp_bad_oper"
name_build_req:         .asciz "arp_build_request"
name_build_uni:         .asciz "arp_build_req_unicast"
name_gw_cache:          .asciz "arp_gw_mac_cache"
name_non_gw:            .asciz "arp_non_gw_no_cache"
name_tcb_send:          .asciz "arp_timer_cb_send"
name_tcb_nosend:        .asciz "arp_timer_cb_no_send"
name_bad_htype:         .asciz "arp_bad_htype"
name_bad_hlen:          .asciz "arp_bad_hlen"
name_tcb_rearm:         .asciz "arp_timer_cb_rearm"

.section .data
.balign 4
arp_req_buf:
    .space  42

.balign 16
arp_timer_tx_buf:
    .space  42

.balign 4
arp_send_count:
    .word   0

/* Fake timer pool: header (8 bytes) + 1 slot (32 bytes) = 40 bytes */
.balign 8
fake_timer_pool:
    .space  40
