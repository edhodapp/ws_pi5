/*
 * test_ntp.S — Tests for NTP client and gateway MAC caching
 *
 * Tests:
 *   1. test_ntp_build_request   — verify built frame fields + checksums
 *   2. test_ntp_handle_valid    — valid NTP response → synced
 *   3. test_ntp_handle_wrong_mode — mode=3 → ignored
 *   4. test_ntp_handle_kod      — stratum=0 → ignored
 *   5. test_ntp_handle_short    — payload < 48 → ignored
 *   6. test_ntp_time_synced     — known state → correct wall time
 *   7. test_ntp_time_not_synced — synced=0 → returns 0
 *   8. test_udp_ntp_dispatch    — UDP port 123 → ntp_handle called, synced
 */

.include "net.inc"
.include "ntp.inc"
.include "timer.inc"

.global test_ntp

.section .text

test_ntp:
    stp     x29, x30, [sp, #-16]!
    bl      test_ntp_build_request
    bl      test_ntp_handle_valid
    bl      test_ntp_handle_wrong_mode
    bl      test_ntp_handle_kod
    bl      test_ntp_handle_short
    bl      test_ntp_time_synced
    bl      test_ntp_time_not_synced
    bl      test_udp_ntp_dispatch
    bl      test_ntp_timer_cb_no_gw
    bl      test_ntp_timer_cb_send
    bl      test_ntp_handle_stratum16
    bl      test_ntp_auth_build
    bl      test_ntp_auth_accept
    bl      test_ntp_auth_reject
    bl      test_ntp_auth_short
    bl      test_ntp_auth_keyid_mismatch
    bl      test_ntp_auth_digest_half
    bl      test_ntp_handle_li3
    bl      test_ntp_handle_bad_version
    bl      test_ntp_handle_high_disp
    bl      test_ntp_handle_zero_ts
    bl      test_ntp_handle_backward
    bl      test_ntp_time_stale
    bl      test_ntp_poll_backoff
    ldp     x29, x30, [sp], #16
    ret

/* ---- Helper: zero ntp_state ---- */
tntp_reset_state:
    ldr     x0, =ntp_state
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    ret


/* ========================================================================
 * 1. test_ntp_build_request
 * ======================================================================== */
test_ntp_build_request:
    stp     x29, x30, [sp, #-16]!

    /* Build request into tntp_frame_buf using test gateway MAC */
    ldr     x0, =tntp_frame_buf
    ldr     x1, =tntp_gw_mac
    bl      ntp_build_request

    /* Returns 90 */
    cmp     w0, #NTP_FRAME_LEN
    b.ne    .Lfail_nbr

    /* Check ETH dst == gateway MAC */
    ldr     x0, =tntp_frame_buf
    add     x0, x0, #ETH_DST
    ldr     x1, =tntp_gw_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_nbr

    /* Check ETH src == our MAC */
    ldr     x0, =tntp_frame_buf
    add     x0, x0, #ETH_SRC
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbz     w0, .Lfail_nbr

    /* Check EtherType == 0x0800 (big-endian on wire: 08 00) */
    ldr     x0, =tntp_frame_buf
    ldrb    w1, [x0, #ETH_TYPE]
    cmp     w1, #0x08
    b.ne    .Lfail_nbr
    ldrb    w1, [x0, #ETH_TYPE + 1]
    cbnz    w1, .Lfail_nbr

    /* Check IP proto == UDP (17) */
    ldr     x0, =tntp_frame_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_PROTO)]
    cmp     w1, #IP_PROTO_UDP
    b.ne    .Lfail_nbr

    /* Check IP dst == net_ntp_ip */
    ldr     x0, =tntp_frame_buf
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_DST)]
    ldr     x2, =net_ntp_ip
    ldr     w2, [x2]
    cmp     w1, w2
    b.ne    .Lfail_nbr

    /* Check UDP dport == 123 (big-endian: 00 7B) */
    ldr     x0, =tntp_frame_buf
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_DPORT)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #NTP_PORT
    b.ne    .Lfail_nbr

    /* Check UDP sport == 12345 */
    ldr     x0, =tntp_frame_buf
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_SPORT)]
    rev16   w1, w1
    uxth    w1, w1
    mov     w2, #NTP_SPORT
    cmp     w1, w2
    b.ne    .Lfail_nbr

    /* Check NTP flags byte == 0x23 */
    ldr     x0, =tntp_frame_buf
    ldrb    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + NTP_FLAGS)]
    cmp     w1, #NTP_CLIENT_FLAGS
    b.ne    .Lfail_nbr

    /* Verify IP checksum (returns 0 on valid) */
    ldr     x0, =tntp_frame_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_nbr

    /* Verify UDP checksum (returns 0 on valid) */
    ldr     x0, =tntp_frame_buf
    mov     w1, #56                     /* UDP segment length */
    bl      udp_checksum
    cbnz    w0, .Lfail_nbr

    ldr     x0, =name_nbr
    bl      test_pass
    b       .Ldone_nbr
.Lfail_nbr:
    ldr     x0, =name_nbr
    bl      test_fail
.Ldone_nbr:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 2. test_ntp_handle_valid — mode=4, stratum=1, known TX timestamp
 *
 * TX timestamp seconds (BE) = 0x83AA7E80 + 1000000 = 0x83BDD100
 * → Unix seconds = 1000000 = 0x000F4240
 * ======================================================================== */
test_ntp_handle_valid:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_valid
    mov     w1, #NTP_PKT_LEN
    mov     x2, #5000                   /* current_ticks = 5000 */
    bl      ntp_handle

    /* Should return 1 */
    cmp     w0, #1
    b.ne    .Lfail_nhv

    /* Check ntp_state.synced == 1 */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cmp     w1, #1
    b.ne    .Lfail_nhv

    /* Check sync_secs == 1000000 (0xF4240) */
    ldr     x1, [x0, #NTPS_SYNC_SECS]
    ldr     x2, =1000000
    cmp     x1, x2
    b.ne    .Lfail_nhv

    /* Check sync_ticks == 5000 */
    ldr     x1, [x0, #NTPS_SYNC_TICKS]
    mov     x2, #5000
    cmp     x1, x2
    b.ne    .Lfail_nhv

    ldr     x0, =name_nhv
    bl      test_pass
    b       .Ldone_nhv
.Lfail_nhv:
    ldr     x0, =name_nhv
    bl      test_fail
.Ldone_nhv:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 3. test_ntp_handle_wrong_mode — mode=3 (client) → returns 0
 * ======================================================================== */
test_ntp_handle_wrong_mode:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_wrong_mode
    mov     w1, #NTP_PKT_LEN
    mov     x2, #1000
    bl      ntp_handle

    /* Should return 0 */
    cbnz    w0, .Lfail_nhwm

    /* synced should still be 0 */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cbnz    w1, .Lfail_nhwm

    ldr     x0, =name_nhwm
    bl      test_pass
    b       .Ldone_nhwm
.Lfail_nhwm:
    ldr     x0, =name_nhwm
    bl      test_fail
.Ldone_nhwm:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 4. test_ntp_handle_kod — stratum=0 (Kiss of Death) → returns 0
 * ======================================================================== */
test_ntp_handle_kod:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_kod
    mov     w1, #NTP_PKT_LEN
    mov     x2, #1000
    bl      ntp_handle

    cbnz    w0, .Lfail_nhk

    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cbnz    w1, .Lfail_nhk

    ldr     x0, =name_nhk
    bl      test_pass
    b       .Ldone_nhk
.Lfail_nhk:
    ldr     x0, =name_nhk
    bl      test_fail
.Ldone_nhk:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 5. test_ntp_handle_short — payload < 48 → returns 0
 * ======================================================================== */
test_ntp_handle_short:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_valid
    mov     w1, #47                     /* one byte short */
    mov     x2, #1000
    bl      ntp_handle

    cbnz    w0, .Lfail_nhs

    ldr     x0, =name_nhs
    bl      test_pass
    b       .Ldone_nhs
.Lfail_nhs:
    ldr     x0, =name_nhs
    bl      test_fail
.Ldone_nhs:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 6. test_ntp_time_synced — known state → correct wall time
 *
 * sync_secs=1000000, sync_ticks=100, freq=100
 * current_ticks=200 → elapsed=100/100=1 → wall=1000001
 * ======================================================================== */
test_ntp_time_synced:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    /* Set up known state */
    ldr     x0, =ntp_state
    ldr     x1, =1000000
    str     x1, [x0, #NTPS_SYNC_SECS]
    mov     x1, #100
    str     x1, [x0, #NTPS_SYNC_TICKS]
    mov     x1, #100
    str     x1, [x0, #NTPS_TIMER_FREQ]
    mov     w1, #1
    str     w1, [x0, #NTPS_SYNCED]

    /* Call ntp_time(200) */
    mov     x0, #200
    bl      ntp_time

    /* Expect 1000001 */
    ldr     x1, =1000001
    cmp     x0, x1
    b.ne    .Lfail_nts

    ldr     x0, =name_nts
    bl      test_pass
    b       .Ldone_nts
.Lfail_nts:
    ldr     x0, =name_nts
    bl      test_fail
.Ldone_nts:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 7. test_ntp_time_not_synced — synced=0 → returns 0
 * ======================================================================== */
test_ntp_time_not_synced:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    mov     x0, #9999
    bl      ntp_time

    cbnz    x0, .Lfail_ntns

    ldr     x0, =name_ntns
    bl      test_pass
    b       .Ldone_ntns
.Lfail_ntns:
    ldr     x0, =name_ntns
    bl      test_fail
.Ldone_ntns:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 8. test_udp_ntp_dispatch — UDP port 123 with valid NTP → synced
 *
 * Full frame: ETH(14) + IP(20) + UDP(8) + NTP(48) = 90 bytes
 * ======================================================================== */
test_udp_ntp_dispatch:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    /* Copy 90-byte template to mutable buffer */
    ldr     x0, =tntp_udp_ntp_template
    ldr     x1, =tntp_udp_ntp_buf
    mov     w2, #90
.Lcopy_udp_ntp:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lcopy_udp_ntp

    /* Call udp_handle(buf, 90) */
    ldr     x0, =tntp_udp_ntp_buf
    mov     w1, #NTP_FRAME_LEN
    bl      udp_handle

    /* Should return 0 (no reply frame) */
    cbnz    w0, .Lfail_und

    /* ntp_state.synced should be 1 */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cmp     w1, #1
    b.ne    .Lfail_und

    ldr     x0, =name_und
    bl      test_pass
    b       .Ldone_und
.Lfail_und:
    ldr     x0, =name_und
    bl      test_fail
.Ldone_und:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Stub: tntp_send_stub — increments tntp_send_count, returns 0
 * ======================================================================== */
tntp_send_stub:
    ldr     x4, =tntp_send_count
    ldr     w5, [x4]
    add     w5, w5, #1
    str     w5, [x4]
    mov     w0, #0
    ret

/* ========================================================================
 * Helper: tntp_setup_ctx — fill ntp_send_ctx for timer_cb tests
 *
 * Sets up: timer pool (init'd), tx_buf, send_fn=stub, timer_freq.
 * Caller must set net_gw_mac_valid separately.
 * Clobbers: x0-x4, x30
 * ======================================================================== */
tntp_setup_ctx:
    stp     x29, x30, [sp, #-16]!

    /* Init timer pool */
    ldr     x0, =tntp_timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init

    /* Cache timer freq in ntp_state */
    bl      timer_freq
    ldr     x1, =ntp_state
    str     x0, [x1, #NTPS_TIMER_FREQ]

    /* Fill ntp_send_ctx */
    ldr     x0, =ntp_send_ctx
    str     xzr, [x0, #NTPC_DWC2_BASE]
    str     xzr, [x0, #NTPC_ECM_STATE]
    ldr     x1, =tntp_cb_tx_buf
    str     x1, [x0, #NTPC_TX_BUF]
    ldr     x1, =tntp_timer_pool
    str     x1, [x0, #NTPC_TIMER_POOL]
    ldr     x1, =tntp_send_stub
    str     x1, [x0, #NTPC_SEND_FN]

    /* Zero send counter */
    ldr     x0, =tntp_send_count
    str     wzr, [x0]

    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 11. test_ntp_timer_cb_no_gw — gateway MAC unknown → skip send, re-arm
 * ======================================================================== */
test_ntp_timer_cb_no_gw:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_setup_ctx

    /* Gateway MAC not known */
    ldr     x0, =net_gw_mac_valid
    str     wzr, [x0]

    /* Call ntp_timer_cb(&ntp_send_ctx) */
    ldr     x0, =ntp_send_ctx
    bl      ntp_timer_cb

    /* Verify: send stub NOT called */
    ldr     x0, =tntp_send_count
    ldr     w0, [x0]
    cbnz    w0, .Lfail_ntcng

    /* Verify: timer re-armed — scan pool for non-zero callback */
    ldr     x0, =tntp_timer_pool
    ldr     w1, [x0, #TPOOL_CAP]
    add     x0, x0, #TPOOL_SLOTS
.Lscan_ng:
    cbz     w1, .Lfail_ntcng           /* no active slot found */
    ldr     x2, [x0, #SLOT_CALLBACK]
    cbnz    x2, .Lfound_ng
    add     x0, x0, #SLOT_SIZE
    sub     w1, w1, #1
    b       .Lscan_ng
.Lfound_ng:

    ldr     x0, =name_ntcng
    bl      test_pass
    b       .Ldone_ntcng
.Lfail_ntcng:
    ldr     x0, =name_ntcng
    bl      test_fail
.Ldone_ntcng:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 12. test_ntp_timer_cb_send — gateway MAC known → send called, re-arm
 * ======================================================================== */
test_ntp_timer_cb_send:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_setup_ctx

    /* Set gateway MAC as known */
    ldr     x0, =net_gw_mac_valid
    mov     w1, #1
    str     w1, [x0]

    /* Populate net_gw_mac with a dummy MAC */
    ldr     x0, =net_gw_mac
    mov     w1, #0xAABB
    movk    w1, #0xCCDD, lsl #16
    str     w1, [x0]
    mov     w1, #0xEEFF
    strh    w1, [x0, #4]

    /* Call ntp_timer_cb(&ntp_send_ctx) */
    ldr     x0, =ntp_send_ctx
    bl      ntp_timer_cb

    /* Verify: send stub called once */
    ldr     x0, =tntp_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Lfail_ntcs

    /* Verify: timer re-armed — scan pool for non-zero callback */
    ldr     x0, =tntp_timer_pool
    ldr     w1, [x0, #TPOOL_CAP]
    add     x0, x0, #TPOOL_SLOTS
.Lscan_s:
    cbz     w1, .Lfail_ntcs
    ldr     x2, [x0, #SLOT_CALLBACK]
    cbnz    x2, .Lfound_s
    add     x0, x0, #SLOT_SIZE
    sub     w1, w1, #1
    b       .Lscan_s
.Lfound_s:

    ldr     x0, =name_ntcs
    bl      test_pass
    b       .Ldone_ntcs
.Lfail_ntcs:
    ldr     x0, =name_ntcs
    bl      test_fail
.Ldone_ntcs:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 13. test_ntp_handle_stratum16 — stratum=16 (invalid per RFC 5905) → 0
 * ======================================================================== */
test_ntp_handle_stratum16:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_stratum16
    mov     w1, #NTP_PKT_LEN
    mov     x2, #1000
    bl      ntp_handle

    cbnz    w0, .Lfail_nhs16

    /* synced should still be 0 */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cbnz    w1, .Lfail_nhs16

    ldr     x0, =name_nhs16
    bl      test_pass
    b       .Ldone_nhs16
.Lfail_nhs16:
    ldr     x0, =name_nhs16
    bl      test_fail
.Ldone_nhs16:
    ldp     x29, x30, [sp], #16
    ret

/* ---- Helper: set auth key = 16 × 'A' (0x41), key_id = 1 ---- */
tntp_set_auth:
    ldr     x0, =ntp_auth_key
    ldr     x1, =tntp_auth_key_data
    ldp     x2, x3, [x1]
    stp     x2, x3, [x0]
    ldr     x0, =ntp_auth_key_id
    mov     w1, #1
    str     w1, [x0]
    ret

/* ---- Helper: clear auth key_id ---- */
tntp_clear_auth:
    ldr     x0, =ntp_auth_key_id
    str     wzr, [x0]
    ret

/* ========================================================================
 * 14. test_ntp_auth_build — authenticated request is 110 bytes, valid
 * ======================================================================== */
test_ntp_auth_build:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_set_auth

    /* Build request into auth frame buffer */
    ldr     x0, =tntp_auth_frame_buf
    ldr     x1, =tntp_gw_mac
    bl      ntp_build_request

    /* Returns 110 */
    cmp     w0, #NTP_AUTH_FRAME_LEN
    b.ne    .Lfail_nab

    /* Check IP total length = 96 */
    ldr     x0, =tntp_auth_frame_buf
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_TOTLEN)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #96
    b.ne    .Lfail_nab

    /* Check UDP length = 76 */
    ldrh    w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_LENGTH)]
    rev16   w1, w1
    uxth    w1, w1
    cmp     w1, #76
    b.ne    .Lfail_nab

    /* Check key_id at NTP+48 = 1 (big-endian) */
    ldr     w1, [x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + NTP_KEY_ID_OFF)]
    rev     w1, w1
    cmp     w1, #1
    b.ne    .Lfail_nab

    /* Check digest at NTP+52 matches expected */
    add     x0, x0, #(ETH_PAYLOAD + IP_HDR_MIN + UDP_HDR_LEN + NTP_DIGEST_OFF)
    ldr     x1, =tntp_expected_client_digest
    ldp     x2, x3, [x0]
    ldp     x4, x5, [x1]
    cmp     x2, x4
    b.ne    .Lfail_nab
    cmp     x3, x5
    b.ne    .Lfail_nab

    /* Verify IP checksum */
    ldr     x0, =tntp_auth_frame_buf
    add     x0, x0, #ETH_PAYLOAD
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    cbnz    w0, .Lfail_nab

    /* Verify UDP checksum */
    ldr     x0, =tntp_auth_frame_buf
    mov     w1, #76
    bl      udp_checksum
    cbnz    w0, .Lfail_nab

    bl      tntp_clear_auth
    ldr     x0, =name_nab
    bl      test_pass
    b       .Ldone_nab
.Lfail_nab:
    bl      tntp_clear_auth
    ldr     x0, =name_nab
    bl      test_fail
.Ldone_nab:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 15. test_ntp_auth_accept — valid authenticated response → synced
 * ======================================================================== */
test_ntp_auth_accept:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state
    bl      tntp_set_auth

    ldr     x0, =tntp_ntp_auth_valid
    mov     w1, #NTP_AUTH_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle

    /* Should return 1 */
    cmp     w0, #1
    b.ne    .Lfail_naa

    /* Check synced */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cmp     w1, #1
    b.ne    .Lfail_naa

    bl      tntp_clear_auth
    ldr     x0, =name_naa
    bl      test_pass
    b       .Ldone_naa
.Lfail_naa:
    bl      tntp_clear_auth
    ldr     x0, =name_naa
    bl      test_fail
.Ldone_naa:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 16. test_ntp_auth_reject — bad digest → ignored
 * ======================================================================== */
test_ntp_auth_reject:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state
    bl      tntp_set_auth

    ldr     x0, =tntp_ntp_auth_bad
    mov     w1, #NTP_AUTH_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle

    /* Should return 0 */
    cbnz    w0, .Lfail_nar

    /* synced should still be 0 */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cbnz    w1, .Lfail_nar

    bl      tntp_clear_auth
    ldr     x0, =name_nar
    bl      test_pass
    b       .Ldone_nar
.Lfail_nar:
    bl      tntp_clear_auth
    ldr     x0, =name_nar
    bl      test_fail
.Ldone_nar:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 17. test_ntp_auth_short — auth configured, payload only 48 → rejected
 * ======================================================================== */
test_ntp_auth_short:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state
    bl      tntp_set_auth

    /* Pass only 48-byte payload (no key_id/digest appended) */
    ldr     x0, =tntp_ntp_valid
    mov     w1, #NTP_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle

    cbnz    w0, .Lfail_nas

    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cbnz    w1, .Lfail_nas

    bl      tntp_clear_auth
    ldr     x0, =name_nas
    bl      test_pass
    b       .Ldone_nas
.Lfail_nas:
    bl      tntp_clear_auth
    ldr     x0, =name_nas
    bl      test_fail
.Ldone_nas:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 18. test_ntp_auth_keyid_mismatch — correct digest, wrong key_id → rejected
 * ======================================================================== */
test_ntp_auth_keyid_mismatch:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state
    bl      tntp_set_auth

    /* Payload has key_id=2 but we expect key_id=1 */
    ldr     x0, =tntp_ntp_auth_wrongkid
    mov     w1, #NTP_AUTH_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle

    cbnz    w0, .Lfail_nakm

    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_SYNCED]
    cbnz    w1, .Lfail_nakm

    bl      tntp_clear_auth
    ldr     x0, =name_nakm
    bl      test_pass
    b       .Ldone_nakm
.Lfail_nakm:
    bl      tntp_clear_auth
    ldr     x0, =name_nakm
    bl      test_fail
.Ldone_nakm:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * 19. test_ntp_auth_digest_half — first 8 bytes match, last 8 wrong → rejected
 * ======================================================================== */
test_ntp_auth_digest_half:
    stp     x29, x30, [sp, #-16]!

    bl      tntp_reset_state
    bl      tntp_set_auth

    ldr     x0, =tntp_ntp_auth_badhalf
    mov     w1, #NTP_AUTH_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle

    cbnz    w0, .Lfail_nadh

    bl      tntp_clear_auth
    ldr     x0, =name_nadh
    bl      test_pass
    b       .Ldone_nadh
.Lfail_nadh:
    bl      tntp_clear_auth
    ldr     x0, =name_nadh
    bl      test_fail
.Ldone_nadh:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ntp_handle_li3 — LI=3 (unsync) → rejected
 * ======================================================================== */
test_ntp_handle_li3:
    stp     x29, x30, [sp, #-16]!
    bl      tntp_reset_state

    /* Copy valid template to buf, set LI=3: flags = 0xE4 (11_100_100) */
    ldr     x0, =tntp_ntp_valid
    ldr     x1, =tntp_ntp_buf
    bl      tntp_copy48
    mov     w0, #0xE4               /* LI=3, VN=4, Mode=4 */
    ldr     x1, =tntp_ntp_buf
    strb    w0, [x1, #NTP_FLAGS]

    ldr     x0, =tntp_ntp_buf
    mov     w1, #NTP_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle
    cbnz    w0, .Lfail_nli3

    ldr     x0, =name_nli3
    bl      test_pass
    b       .Ldone_nli3
.Lfail_nli3:
    ldr     x0, =name_nli3
    bl      test_fail
.Ldone_nli3:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ntp_handle_bad_version — version=5 → rejected
 * ======================================================================== */
test_ntp_handle_bad_version:
    stp     x29, x30, [sp, #-16]!
    bl      tntp_reset_state

    /* flags = 0x2C: LI=0, VN=5(101), Mode=4(100) */
    ldr     x0, =tntp_ntp_valid
    ldr     x1, =tntp_ntp_buf
    bl      tntp_copy48
    mov     w0, #0x2C
    ldr     x1, =tntp_ntp_buf
    strb    w0, [x1, #NTP_FLAGS]

    ldr     x0, =tntp_ntp_buf
    mov     w1, #NTP_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle
    cbnz    w0, .Lfail_nbv

    ldr     x0, =name_nbv
    bl      test_pass
    b       .Ldone_nbv
.Lfail_nbv:
    ldr     x0, =name_nbv
    bl      test_fail
.Ldone_nbv:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ntp_handle_high_disp — root dispersion > 1s → rejected
 * ======================================================================== */
test_ntp_handle_high_disp:
    stp     x29, x30, [sp, #-16]!
    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_valid
    ldr     x1, =tntp_ntp_buf
    bl      tntp_copy48

    /* Set root dispersion at offset 8 to 2.0 (0x00020000 BE) */
    ldr     x1, =tntp_ntp_buf
    mov     w0, #0x00
    strb    w0, [x1, #8]
    mov     w0, #0x02
    strb    w0, [x1, #9]
    strb    wzr, [x1, #10]
    strb    wzr, [x1, #11]

    ldr     x0, =tntp_ntp_buf
    mov     w1, #NTP_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle
    cbnz    w0, .Lfail_nhd

    ldr     x0, =name_nhd
    bl      test_pass
    b       .Ldone_nhd
.Lfail_nhd:
    ldr     x0, =name_nhd
    bl      test_fail
.Ldone_nhd:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ntp_handle_zero_ts — TX timestamp = 0 → rejected
 * ======================================================================== */
test_ntp_handle_zero_ts:
    stp     x29, x30, [sp, #-16]!
    bl      tntp_reset_state

    ldr     x0, =tntp_ntp_valid
    ldr     x1, =tntp_ntp_buf
    bl      tntp_copy48

    /* Zero out TX timestamp at offset 40 */
    ldr     x1, =tntp_ntp_buf
    str     wzr, [x1, #NTP_TX_TS]

    ldr     x0, =tntp_ntp_buf
    mov     w1, #NTP_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle
    cbnz    w0, .Lfail_nzt

    ldr     x0, =name_nzt
    bl      test_pass
    b       .Ldone_nzt
.Lfail_nzt:
    ldr     x0, =name_nzt
    bl      test_fail
.Ldone_nzt:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ntp_handle_backward — new time < current sync → rejected
 * ======================================================================== */
test_ntp_handle_backward:
    stp     x29, x30, [sp, #-16]!

    /* First: sync with a high timestamp (Unix seconds = 1000000) */
    bl      tntp_reset_state
    ldr     x0, =tntp_ntp_valid
    mov     w1, #NTP_PKT_LEN
    mov     x2, #5000
    bl      ntp_handle
    cmp     w0, #1
    b.ne    .Lfail_nbk

    /* Now try to sync with an earlier timestamp.
     * Build a response with TX_TS = NTP_OFFSET + 500000 (< 1000000) */
    ldr     x0, =tntp_ntp_valid
    ldr     x1, =tntp_ntp_buf
    bl      tntp_copy48

    /* TX_TS for Unix=500000: 500000 + 0x83AA7E80 = 0x83B21700 (BE) */
    ldr     x1, =tntp_ntp_buf
    mov     w0, #0x83
    strb    w0, [x1, #40]
    mov     w0, #0xB2
    strb    w0, [x1, #41]
    mov     w0, #0x17
    strb    w0, [x1, #42]
    strb    wzr, [x1, #43]

    ldr     x0, =tntp_ntp_buf
    mov     w1, #NTP_PKT_LEN
    mov     x2, #6000
    bl      ntp_handle

    /* Should be rejected (backward jump) */
    cbnz    w0, .Lfail_nbk

    /* Verify sync_secs unchanged (still 1000000) */
    ldr     x0, =ntp_state
    ldr     x1, [x0, #NTPS_SYNC_SECS]
    ldr     x2, =1000000
    cmp     x1, x2
    b.ne    .Lfail_nbk

    ldr     x0, =name_nbk
    bl      test_pass
    b       .Ldone_nbk
.Lfail_nbk:
    ldr     x0, =name_nbk
    bl      test_fail
.Ldone_nbk:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ntp_time_stale — elapsed > 1800s → returns 0
 * ======================================================================== */
test_ntp_time_stale:
    stp     x29, x30, [sp, #-16]!

    /* Set up synced state with known values */
    ldr     x0, =ntp_state
    ldr     x1, =1000000
    str     x1, [x0, #NTPS_SYNC_SECS]
    mov     x1, #1000
    str     x1, [x0, #NTPS_SYNC_TICKS]
    mov     x1, #1                      /* 1 tick per second for easy math */
    str     x1, [x0, #NTPS_TIMER_FREQ]
    mov     w1, #1
    str     w1, [x0, #NTPS_SYNCED]

    /* Call ntp_time with current_ticks = 1000 + 1801 = 2801 */
    mov     x0, #2801
    bl      ntp_time

    /* Should return 0 (stale) */
    cbnz    x0, .Lfail_ntst

    ldr     x0, =name_ntst
    bl      test_pass
    b       .Ldone_ntst
.Lfail_ntst:
    ldr     x0, =name_ntst
    bl      test_fail
.Ldone_ntst:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_ntp_poll_backoff — poll_shift increments in timer_cb re-arm
 * ======================================================================== */
test_ntp_poll_backoff:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    /* Reset state: poll_shift = 0, freq = 1 */
    ldr     x0, =ntp_state
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    mov     x1, #1
    str     x1, [x0, #NTPS_TIMER_FREQ]

    /* Ensure gateway MAC is not valid (skip send path) */
    ldr     x0, =net_gw_mac_valid
    str     wzr, [x0]

    /* Set up send_ctx with NULL pool → skip timer_set */
    ldr     x19, =ntp_send_ctx
    str     xzr, [x19, #NTPC_DWC2_BASE]
    str     xzr, [x19, #NTPC_ECM_STATE]
    str     xzr, [x19, #NTPC_TX_BUF]
    str     xzr, [x19, #NTPC_TIMER_POOL]
    str     xzr, [x19, #NTPC_SEND_FN]

    /* Call timer_cb */
    ldr     x0, =ntp_send_ctx
    bl      ntp_timer_cb

    /* poll_shift should now be 1 (incremented from 0) */
    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_POLL_SHIFT]
    cmp     w1, #1
    b.ne    .Lfail_npb

    /* Call again — shift should be 2 */
    ldr     x0, =ntp_send_ctx
    bl      ntp_timer_cb

    ldr     x0, =ntp_state
    ldr     w1, [x0, #NTPS_POLL_SHIFT]
    cmp     w1, #2
    b.ne    .Lfail_npb

    ldr     x0, =name_npb
    bl      test_pass
    b       .Ldone_npb
.Lfail_npb:
    ldr     x0, =name_npb
    bl      test_fail
.Ldone_npb:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* === Helper: copy 48 bytes from x0 to x1 === */
tntp_copy48:
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]
    ldp     x2, x3, [x0, #32]
    stp     x2, x3, [x1, #32]
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

/* Gateway MAC for build_request test */
tntp_gw_mac:
    .byte   0x52, 0x55, 0x0A, 0x00, 0x02, 0x02

/*
 * Valid NTP server response (48 bytes)
 * Byte 0: flags = 0x24 (LI=0, VN=4, Mode=4=server)
 * Byte 1: stratum = 1
 * Byte 40-43: TX timestamp seconds (BE) = 0x83BDD100
 *   = 0x83AA7E80 + 1000000 = NTP_UNIX_OFFSET + 1000000
 *   → Unix seconds = 1000000
 */
.balign 4
tntp_ntp_valid:
    .byte   0x24                        /* flags: LI=0, VN=4, Mode=4 */
    .byte   0x01                        /* stratum: 1 */
    .byte   0x06                        /* poll */
    .byte   0xEC                        /* precision */
    .space  36                          /* root delay thru receive TS */
    .byte   0x83, 0xB9, 0xC0, 0xC0     /* TX timestamp seconds (BE) */
    .byte   0x00, 0x00, 0x00, 0x00     /* TX timestamp fraction */

/* NTP response with wrong mode (mode=3 = client) */
.balign 4
tntp_ntp_wrong_mode:
    .byte   0x23                        /* flags: LI=0, VN=4, Mode=3 */
    .byte   0x01                        /* stratum: 1 */
    .space  46                          /* rest doesn't matter */

/* NTP response with stratum=16 (invalid per RFC 5905) */
.balign 4
tntp_ntp_stratum16:
    .byte   0x24                        /* flags: LI=0, VN=4, Mode=4 */
    .byte   0x10                        /* stratum: 16 */
    .space  46

/* NTP response with stratum=0 (Kiss of Death) */
.balign 4
tntp_ntp_kod:
    .byte   0x24                        /* flags: LI=0, VN=4, Mode=4 */
    .byte   0x00                        /* stratum: 0 (KoD) */
    .space  46

/*
 * Full 90-byte UDP frame with NTP response on port 123
 *
 * ETH: dst=02:00:00:00:00:01 src=52:55:0A:00:02:02 type=0800
 * IP:  ver/ihl=45 dscp=00 totlen=004C id=0000 flags=0000
 *      ttl=40 proto=11(UDP) cksum=TBD src=D8EF2300 dst=0A00020F
 * UDP: sport=007B(123) dport=007B(123) len=0038(56) cksum=0000(skip)
 * NTP: flags=0x24(server) stratum=1 ... TX_TS_secs=0x83BDD100
 *
 * IP checksum computed over the header:
 *   4500 004C 0000 0000 4011 xxxx D8EF 2300 0A00 020F
 *   sum without cksum = 4500+004C+0000+0000+4011+0000+D8EF+2300+0A00+020F
 *   = 4500+004C+4011+D8EF+2300+0A00+020F
 *   = 4500+004C = 454C
 *   +4011 = 855D
 *   +D8EF = 15E4C → carry: 5E4D
 *   +2300 = 814D
 *   +0A00 = 8B4D
 *   +020F = 8D5C
 *   ~8D5C = 72A3
 */
.balign 4
tntp_udp_ntp_template:
    /* Ethernet header (14 bytes) */
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01     /* dst: our MAC */
    .byte   0x52, 0x55, 0x0A, 0x00, 0x02, 0x02     /* src */
    .byte   0x08, 0x00                               /* IPv4 */
    /* IP header (20 bytes) */
    .byte   0x45, 0x00                               /* ver/ihl, dscp */
    .byte   0x00, 0x4C                               /* totlen: 76 */
    .byte   0x00, 0x00                               /* id */
    .byte   0x00, 0x00                               /* flags/frag */
    .byte   0x40, 0x11                               /* ttl=64, proto=UDP */
    .byte   0x72, 0xA3                               /* IP checksum */
    .byte   0xD8, 0xEF, 0x23, 0x00                   /* src: 216.239.35.0 */
    .byte   0x0A, 0x00, 0x02, 0x0F                   /* dst: 10.0.2.15 */
    /* UDP header (8 bytes) */
    .byte   0x00, 0x7B                               /* sport: 123 */
    .byte   0x00, 0x7B                               /* dport: 123 */
    .byte   0x00, 0x38                               /* length: 56 */
    .byte   0x00, 0x00                               /* checksum: 0 (skip) */
    /* NTP payload (48 bytes) */
    .byte   0x24                                     /* flags: server mode */
    .byte   0x01                                     /* stratum: 1 */
    .byte   0x06                                     /* poll */
    .byte   0xEC                                     /* precision */
    .space  36                                       /* root delay thru recv TS */
    .byte   0x83, 0xB9, 0xC0, 0xC0                   /* TX timestamp secs (BE) */
    .byte   0x00, 0x00, 0x00, 0x00                   /* TX timestamp frac */

name_nbr:   .asciz "ntp_build_request"
name_nhv:   .asciz "ntp_handle_valid"
name_nhwm:  .asciz "ntp_handle_wrong_mode"
name_nhk:   .asciz "ntp_handle_kod"
name_nhs:   .asciz "ntp_handle_short"
name_nts:   .asciz "ntp_time_synced"
name_ntns:  .asciz "ntp_time_not_synced"
name_und:   .asciz "udp_ntp_dispatch"
name_ntcng: .asciz "ntp_timer_cb_no_gw"
name_ntcs:  .asciz "ntp_timer_cb_send"
name_nhs16: .asciz "ntp_handle_stratum16"
name_nli3:  .asciz "ntp_handle_li3"
name_nbv:   .asciz "ntp_handle_bad_version"
name_nhd:   .asciz "ntp_handle_high_disp"
name_nzt:   .asciz "ntp_handle_zero_ts"
name_nbk:   .asciz "ntp_handle_backward"
name_ntst:  .asciz "ntp_time_stale"
name_npb:   .asciz "ntp_poll_backoff"
name_nab:   .asciz "ntp_auth_build"
name_naa:   .asciz "ntp_auth_accept"
name_nar:   .asciz "ntp_auth_reject"
name_nas:   .asciz "ntp_auth_short"
name_nakm:  .asciz "ntp_auth_keyid_mismatch"
name_nadh:  .asciz "ntp_auth_digest_half"

/* Auth key for tests: 16 × 'A' (0x41) */
.balign 4
tntp_auth_key_data:
    .byte   0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41
    .byte   0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41

/* Expected MD5 digest for client request: MD5(key || 0x23,0x00×47) */
.balign 4
tntp_expected_client_digest:
    .byte   0xaa, 0x3c, 0x80, 0xed, 0x4c, 0x1c, 0xf6, 0x8a
    .byte   0xe9, 0xf5, 0xbf, 0x69, 0xb7, 0x2e, 0x97, 0x99

/*
 * Authenticated NTP server response (68 bytes):
 * valid_ntp(48) + key_id(4, BE) + MD5_digest(16)
 * MD5 = MD5(key(16×'A') || NTP(48)) = 09974e02449ecaaf963777e708a65dd8
 */
.balign 4
tntp_ntp_auth_valid:
    .byte   0x24                        /* flags: server mode */
    .byte   0x01                        /* stratum: 1 */
    .byte   0x06                        /* poll */
    .byte   0xEC                        /* precision */
    .space  36                          /* root delay thru receive TS */
    .byte   0x83, 0xB9, 0xC0, 0xC0     /* TX timestamp seconds (BE) */
    .byte   0x00, 0x00, 0x00, 0x00     /* TX timestamp fraction */
    .byte   0x00, 0x00, 0x00, 0x01     /* key_id (BE) = 1 */
    .byte   0x09, 0x97, 0x4e, 0x02, 0x44, 0x9e, 0xca, 0xaf
    .byte   0x96, 0x37, 0x77, 0xe7, 0x08, 0xa6, 0x5d, 0xd8

/* Same but with wrong key_id (2 instead of 1), correct digest */
.balign 4
tntp_ntp_auth_wrongkid:
    .byte   0x24, 0x01, 0x06, 0xEC
    .space  36
    .byte   0x83, 0xB9, 0xC0, 0xC0
    .byte   0x00, 0x00, 0x00, 0x00
    .byte   0x00, 0x00, 0x00, 0x02     /* key_id (BE) = 2 (mismatch) */
    .byte   0x09, 0x97, 0x4e, 0x02, 0x44, 0x9e, 0xca, 0xaf
    .byte   0x96, 0x37, 0x77, 0xe7, 0x08, 0xa6, 0x5d, 0xd8

/* First 8 bytes of digest correct, last 8 wrong (byte 15 flipped) */
.balign 4
tntp_ntp_auth_badhalf:
    .byte   0x24, 0x01, 0x06, 0xEC
    .space  36
    .byte   0x83, 0xB9, 0xC0, 0xC0
    .byte   0x00, 0x00, 0x00, 0x00
    .byte   0x00, 0x00, 0x00, 0x01     /* key_id (BE) = 1 (correct) */
    .byte   0x09, 0x97, 0x4e, 0x02, 0x44, 0x9e, 0xca, 0xaf
    .byte   0x96, 0x37, 0x77, 0xe7, 0x08, 0xa6, 0x5d, 0x27  /* byte 15: 0xd8→0x27 */

/* Same but with wrong digest (all zeros) */
.balign 4
tntp_ntp_auth_bad:
    .byte   0x24
    .byte   0x01
    .byte   0x06
    .byte   0xEC
    .space  36
    .byte   0x83, 0xB9, 0xC0, 0xC0
    .byte   0x00, 0x00, 0x00, 0x00
    .byte   0x00, 0x00, 0x00, 0x01     /* key_id (BE) = 1 */
    .space  16                          /* all zeros = bad digest */

.section .data
.balign 16
tntp_frame_buf:
    .space  90

.balign 4
tntp_ntp_buf:
    .space  48

.balign 4
tntp_udp_ntp_buf:
    .space  90

.balign 8
tntp_timer_pool:
    .space  TPOOL_DEFAULT_SIZE

.balign 4
tntp_send_count:
    .space  4

.balign 16
tntp_cb_tx_buf:
    .space  NTP_AUTH_FRAME_LEN

.balign 16
tntp_auth_frame_buf:
    .space  NTP_AUTH_FRAME_LEN
