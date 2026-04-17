/*
 * test_http.S — Tests for HTTP server
 *
 * Tests:
 *   1. test_http_init           — http_init zeros connection table
 *   2. test_http_parse_get      — complete GET / request → parsed OK
 *   3. test_http_parse_incomplete — partial headers → not parsed
 *   4. test_http_parse_404      — GET /notfound → 404
 *   5. test_http_parse_bad_method — POST → treated as 404
 *   6. test_http_find_eoh       — \r\n\r\n detection
 *   7. test_http_uri_match      — "/" matches, "/foo" doesn't
 */

.include "net.inc"
.include "tcp.inc"
.include "http.inc"

.global test_http

.section .text

test_http:
    stp     x29, x30, [sp, #-16]!
    bl      test_http_init
    bl      test_http_find_eoh
    bl      test_http_find_eoh_missing
    bl      test_http_uri_match_root
    bl      test_http_uri_match_404
    bl      test_http_parse_get
    bl      test_http_parse_incomplete
    bl      test_http_parse_404
    bl      test_http_parse_bad_method
    bl      test_http_parse_head
    bl      test_http_version_10
    bl      test_http_version_11
    bl      test_http_method_not_allowed
    bl      test_http_missing_host_11
    bl      test_http_no_host_10_ok
    bl      test_http_head_no_body
    bl      test_http_host_lowercase
    bl      test_http_bad_version
    bl      test_http_fsa_get_11
    bl      test_http_fsa_head_10
    bl      test_http_fsa_incomplete
    bl      test_http_fsa_bad_method
    bl      test_http_date_epoch
    bl      test_http_date_2026
    bl      test_http_leap_2000
    bl      test_http_noleap_2100
    bl      test_http_send_chunk
    bl      test_http_send_close
    bl      test_http_reset_during_send
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_init — http_init zeros all HCONN slots
 * ======================================================================== */
test_http_init:
    stp     x29, x30, [sp, #-16]!

    /* Dirty the table first */
    ldr     x0, =http_conn_table
    mov     w1, #0xFF
    strb    w1, [x0]

    bl      http_init

    /* First byte should be 0 */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0]
    cbnz    w0, .Lfail_hi

    /* Last slot should also be 0 */
    ldr     x0, =http_conn_table
    ldr     w1, =(HTTP_CONN_TABLE_SIZE - HCONN_SIZE)
    add     x0, x0, x1
    ldrb    w0, [x0]
    cbnz    w0, .Lfail_hi

    ldr     x0, =name_hi
    bl      test_pass
    b       .Ldone_hi
.Lfail_hi:
    ldr     x0, =name_hi
    bl      test_fail
.Ldone_hi:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_find_eoh — detect \r\n\r\n at correct offset
 * ======================================================================== */
test_http_find_eoh:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =thttp_get_request
    ldr     w1, =thttp_get_request_len
    bl      http_find_end_of_headers

    /* Should return offset past \r\n\r\n */
    cmp     w0, #-1
    b.eq    .Lfail_feoh

    /* Offset should be > 0 and <= request length */
    cbz     w0, .Lfail_feoh

    ldr     x0, =name_feoh
    bl      test_pass
    b       .Ldone_feoh
.Lfail_feoh:
    ldr     x0, =name_feoh
    bl      test_fail
.Ldone_feoh:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_find_eoh_missing — no \r\n\r\n → returns -1
 * ======================================================================== */
test_http_find_eoh_missing:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =thttp_partial_request
    ldr     w1, =thttp_partial_request_len
    bl      http_find_end_of_headers

    cmn     w0, #1
    b.ne    .Lfail_feohm

    ldr     x0, =name_feohm
    bl      test_pass
    b       .Ldone_feohm
.Lfail_feohm:
    ldr     x0, =name_feohm
    bl      test_fail
.Ldone_feohm:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_uri_match_root — "/" → 200
 * ======================================================================== */
test_http_uri_match_root:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =thttp_uri_root
    mov     w1, #1
    bl      http_match_uri

    cbnz    w0, .Lfail_umr

    ldr     x0, =name_umr
    bl      test_pass
    b       .Ldone_umr
.Lfail_umr:
    ldr     x0, =name_umr
    bl      test_fail
.Ldone_umr:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_uri_match_404 — "/foo" → 404
 * ======================================================================== */
test_http_uri_match_404:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =thttp_uri_foo
    mov     w1, #4
    bl      http_match_uri

    cmp     w0, #1
    b.ne    .Lfail_um4

    ldr     x0, =name_um4
    bl      test_pass
    b       .Ldone_um4
.Lfail_um4:
    ldr     x0, =name_um4
    bl      test_fail
.Ldone_um4:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_parse_get — complete GET / → parse succeeds, state = SENDING
 *
 * Uses ttcp_do_handshake to create an ESTABLISHED connection, then
 * manually writes the request into the rx buffer and calls http_poll.
 * ======================================================================== */
test_http_parse_get:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* Pre-seed slot 0 as ESTABLISHED with request in rx buffer */
    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000             /* lport = 80 NBO */
    strh    w0, [x19, #TCONN_LPORT]

    /* Copy request to rx buffer */
    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_get_request
    ldr     w2, =thttp_get_request_len
.Lhpg_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpg_cp

    /* Set RXLEN */
    ldr     w0, =thttp_get_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    /* Set up HTTP send context (mock — won't actually send) */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    /* Verify rx data is in the buffer before calling http_poll */
    mov     x0, x19
    bl      tcp_rx_peek
    /* x0 = buf ptr, w1 = len */
    cbz     w1, .Lfail_hpg          /* no data → peek failed */

    /* Verify first 4 bytes = "GET " */
    ldr     w2, [x0]
    ldr     w3, =0x20544547          /* "GET " LE */
    cmp     w2, w3
    b.ne    .Lfail_hpg

    /* Call http_poll */
    bl      http_poll

    /* Check what HCONN state is after poll */
    ldr     x0, =http_conn_table
    ldrb    w1, [x0, #HCONN_STATE]

    /* IDLE=0, RECV_HDR=1, SENDING=2, DONE=3 */
    /* We expect SENDING (2) */
    cmp     w1, #HTTPS_SENDING
    b.ne    .Lfail_hpg

    ldr     x0, =name_hpg
    bl      test_pass
    b       .Ldone_hpg
.Lfail_hpg:
    ldr     x0, =name_hpg
    bl      test_fail
.Ldone_hpg:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_parse_incomplete — partial headers → stays in RECV_HDR
 * ======================================================================== */
test_http_parse_incomplete:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    /* Copy partial request (no \r\n\r\n) */
    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_partial_request
    ldr     w2, =thttp_partial_request_len
.Lhpi_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpi_cp

    ldr     w0, =thttp_partial_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    bl      http_poll

    /* HCONN should be in RECV_HDR (not SENDING) */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATE]
    cmp     w0, #HTTPS_RECV_HDR
    b.ne    .Lfail_hpi

    ldr     x0, =name_hpi
    bl      test_pass
    b       .Ldone_hpi
.Lfail_hpi:
    ldr     x0, =name_hpi
    bl      test_fail
.Ldone_hpi:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_parse_404 — GET /notfound → status = 404
 * ======================================================================== */
test_http_parse_404:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_404_request
    ldr     w2, =thttp_404_request_len
.Lhp4_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhp4_cp

    ldr     w0, =thttp_404_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Status should be HSTATUS_404 */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATUS]
    cmp     w0, #HSTATUS_404
    b.ne    .Lfail_hp4

    ldr     x0, =name_hp4
    bl      test_pass
    b       .Ldone_hp4
.Lfail_hp4:
    ldr     x0, =name_hp4
    bl      test_fail
.Ldone_hp4:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_parse_bad_method — POST → 404
 * ======================================================================== */
test_http_parse_bad_method:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_post_request
    ldr     w2, =thttp_post_request_len
.Lhpbm_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpbm_cp

    ldr     w0, =thttp_post_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Status should be HSTATUS_405 (method not allowed) */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATUS]
    cmp     w0, #HSTATUS_405
    b.ne    .Lfail_hpbm

    ldr     x0, =name_hpbm
    bl      test_pass
    b       .Ldone_hpbm
.Lfail_hpbm:
    ldr     x0, =name_hpbm
    bl      test_fail
.Ldone_hpbm:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_parse_head — HEAD / → SENDING + HFLAG_HEAD set
 * ======================================================================== */
test_http_parse_head:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_head_request
    ldr     w2, =thttp_head_request_len
.Lhph_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhph_cp

    ldr     w0, =thttp_head_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* State should be SENDING */
    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hph

    /* HFLAG_HEAD should be set */
    ldrb    w0, [x20, #HCONN_FLAGS]
    tst     w0, #HFLAG_HEAD
    b.eq    .Lfail_hph

    ldr     x0, =name_hph
    bl      test_pass
    b       .Ldone_hph
.Lfail_hph:
    ldr     x0, =name_hph
    bl      test_fail
.Ldone_hph:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_version_10 — HTTP/1.0 → HFLAG_HTTP11 NOT set
 * ======================================================================== */
test_http_version_10:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_get_10_request
    ldr     w2, =thttp_get_10_request_len
.Lhv10_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhv10_cp

    ldr     w0, =thttp_get_10_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* State should be SENDING */
    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hv10

    /* HFLAG_HTTP11 should NOT be set */
    ldrb    w0, [x20, #HCONN_FLAGS]
    tst     w0, #HFLAG_HTTP11
    b.ne    .Lfail_hv10

    ldr     x0, =name_hv10
    bl      test_pass
    b       .Ldone_hv10
.Lfail_hv10:
    ldr     x0, =name_hv10
    bl      test_fail
.Ldone_hv10:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_version_11 — HTTP/1.1 → HFLAG_HTTP11 set
 * ======================================================================== */
test_http_version_11:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_get_request
    ldr     w2, =thttp_get_request_len
.Lhv11_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhv11_cp

    ldr     w0, =thttp_get_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hv11

    /* HFLAG_HTTP11 SHOULD be set */
    ldrb    w0, [x20, #HCONN_FLAGS]
    tst     w0, #HFLAG_HTTP11
    b.eq    .Lfail_hv11

    ldr     x0, =name_hv11
    bl      test_pass
    b       .Ldone_hv11
.Lfail_hv11:
    ldr     x0, =name_hv11
    bl      test_fail
.Ldone_hv11:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_method_not_allowed — POST → status 405 (not 404)
 * ======================================================================== */
test_http_method_not_allowed:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_post_request
    ldr     w2, =thttp_post_request_len
.Lhmna_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhmna_cp

    ldr     w0, =thttp_post_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Status should be HSTATUS_405 */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATUS]
    cmp     w0, #HSTATUS_405
    b.ne    .Lfail_hmna

    ldr     x0, =name_hmna
    bl      test_pass
    b       .Ldone_hmna
.Lfail_hmna:
    ldr     x0, =name_hmna
    bl      test_fail
.Ldone_hmna:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_missing_host_11 — HTTP/1.1 without Host: → status 400
 * ======================================================================== */
test_http_missing_host_11:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_nohost_11_request
    ldr     w2, =thttp_nohost_11_request_len
.Lhmh_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhmh_cp

    ldr     w0, =thttp_nohost_11_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Status should be HSTATUS_400 */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATUS]
    cmp     w0, #HSTATUS_400
    b.ne    .Lfail_hmh

    ldr     x0, =name_hmh
    bl      test_pass
    b       .Ldone_hmh
.Lfail_hmh:
    ldr     x0, =name_hmh
    bl      test_fail
.Ldone_hmh:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_no_host_10_ok — HTTP/1.0 without Host: → accepted (200)
 * ======================================================================== */
test_http_no_host_10_ok:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_nohost_10_request
    ldr     w2, =thttp_nohost_10_request_len
.Lhnh10_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhnh10_cp

    ldr     w0, =thttp_nohost_10_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Status should be HSTATUS_200 (accepted without Host) */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATUS]
    cmp     w0, #HSTATUS_200
    b.ne    .Lfail_hnh10

    ldr     x0, =name_hnh10
    bl      test_pass
    b       .Ldone_hnh10
.Lfail_hnh10:
    ldr     x0, =name_hnh10
    bl      test_fail
.Ldone_hnh10:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_head_no_body — HEAD response: RESP_LEN == HDR_LEN (no body)
 * ======================================================================== */
test_http_head_no_body:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_head_request
    ldr     w2, =thttp_head_request_len
.Lhhnb_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhhnb_cp

    ldr     w0, =thttp_head_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* RESP_LEN must equal HDR_LEN (no body for HEAD) */
    ldr     x20, =http_conn_table
    ldr     w0, [x20, #HCONN_RESP_LEN]
    ldr     w1, [x20, #HCONN_HDR_LEN]
    cmp     w0, w1
    b.ne    .Lfail_hhnb

    /* HDR_LEN must be non-zero (we sent real headers) */
    cbz     w1, .Lfail_hhnb

    ldr     x0, =name_hhnb
    bl      test_pass
    b       .Ldone_hhnb
.Lfail_hhnb:
    ldr     x0, =name_hhnb
    bl      test_fail
.Ldone_hhnb:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_host_lowercase — "host:" (lowercase) accepted for HTTP/1.1
 * ======================================================================== */
test_http_host_lowercase:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_host_lower_request
    ldr     w2, =thttp_host_lower_request_len
.Lhhl_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhhl_cp

    ldr     w0, =thttp_host_lower_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Should be SENDING with status 200 (not 400 from missing Host) */
    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hhl

    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_200
    b.ne    .Lfail_hhl

    ldr     x0, =name_hhl
    bl      test_pass
    b       .Ldone_hhl
.Lfail_hhl:
    ldr     x0, =name_hhl
    bl      test_fail
.Ldone_hhl:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_bad_version — garbage version string → 400 Bad Request
 * ======================================================================== */
test_http_bad_version:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_bad_version_request
    ldr     w2, =thttp_bad_version_request_len
.Lhbv_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhbv_cp

    ldr     w0, =thttp_bad_version_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Status should be HSTATUS_400 */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATUS]
    cmp     w0, #HSTATUS_400
    b.ne    .Lfail_hbv

    ldr     x0, =name_hbv
    bl      test_pass
    b       .Ldone_hbv
.Lfail_hbv:
    ldr     x0, =name_hbv
    bl      test_fail
.Ldone_hbv:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_fsa_get_11 — FSA parser: "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
 * → S_DONE, URI="/", version=1, Host found
 * ======================================================================== */
test_http_fsa_get_11:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    /* Zero an HCONN on the stack for the parser */
    ldr     x19, =http_conn_table      /* reuse slot 0 */
    mov     w0, #HCONN_SIZE / 8
    mov     x1, x19
.Lfg11_z:
    str     xzr, [x1], #8
    subs    w0, w0, #1
    b.ne    .Lfg11_z

    /* Call parser with GET /1.1 + Host request */
    mov     x0, x19
    ldr     x1, =thttp_get_request
    ldr     w2, =thttp_get_request_len
    bl      http_parse_request

    /* Should return S_DONE */
    cmp     w0, #S_DONE
    b.ne    .Lfail_fg11

    /* URI_START should be 4 ("GET " is 4 bytes) */
    ldrh    w0, [x19, #HCONN_URI_START]
    cmp     w0, #4
    b.ne    .Lfail_fg11

    /* URI_LEN should be 1 ("/") */
    ldrh    w0, [x19, #HCONN_URI_LEN]
    cmp     w0, #1
    b.ne    .Lfail_fg11

    /* VER_MINOR should be '1' (HTTP/1.1) */
    ldrb    w0, [x19, #HCONN_VER_MINOR]
    cmp     w0, #'1'
    b.ne    .Lfail_fg11

    /* HOST_FOUND should be 1 */
    ldrb    w0, [x19, #HCONN_HOST_FOUND]
    cmp     w0, #1
    b.ne    .Lfail_fg11

    /* REQ_LEN should equal request length */
    ldr     w0, [x19, #HCONN_REQ_LEN]
    ldr     w1, =thttp_get_request_len
    cmp     w0, w1
    b.ne    .Lfail_fg11

    ldr     x0, =name_fg11
    bl      test_pass
    b       .Ldone_fg11
.Lfail_fg11:
    ldr     x0, =name_fg11
    bl      test_fail
.Ldone_fg11:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_fsa_head_10 — FSA parser: "HEAD / HTTP/1.0\r\n\r\n"
 * → S_DONE, URI="/", version=0, no Host required
 * ======================================================================== */
test_http_fsa_head_10:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    ldr     x19, =http_conn_table
    mov     w0, #HCONN_SIZE / 8
    mov     x1, x19
.Lfh10_z:
    str     xzr, [x1], #8
    subs    w0, w0, #1
    b.ne    .Lfh10_z

    mov     x0, x19
    ldr     x1, =thttp_head_10_request
    ldr     w2, =thttp_head_10_request_len
    bl      http_parse_request

    cmp     w0, #S_DONE
    b.ne    .Lfail_fh10

    /* URI_START should be 5 ("HEAD " is 5 bytes) */
    ldrh    w0, [x19, #HCONN_URI_START]
    cmp     w0, #5
    b.ne    .Lfail_fh10

    /* URI_LEN should be 1 */
    ldrh    w0, [x19, #HCONN_URI_LEN]
    cmp     w0, #1
    b.ne    .Lfail_fh10

    /* VER_MINOR should be '0' (HTTP/1.0) */
    ldrb    w0, [x19, #HCONN_VER_MINOR]
    cmp     w0, #'0'
    b.ne    .Lfail_fh10

    /* HOST_FOUND should be 0 (no Host header in this request) */
    ldrb    w0, [x19, #HCONN_HOST_FOUND]
    cbnz    w0, .Lfail_fh10

    ldr     x0, =name_fh10
    bl      test_pass
    b       .Ldone_fh10
.Lfail_fh10:
    ldr     x0, =name_fh10
    bl      test_fail
.Ldone_fh10:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_fsa_incomplete — partial request → parser returns non-terminal
 * ======================================================================== */
test_http_fsa_incomplete:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    ldr     x19, =http_conn_table
    mov     w0, #HCONN_SIZE / 8
    mov     x1, x19
.Lffi_z:
    str     xzr, [x1], #8
    subs    w0, w0, #1
    b.ne    .Lffi_z

    mov     x0, x19
    ldr     x1, =thttp_partial_request
    ldr     w2, =thttp_partial_request_len
    bl      http_parse_request

    /* Should NOT be DONE or ERROR — still parsing */
    cmp     w0, #S_DONE
    b.eq    .Lfail_ffi
    cmp     w0, #S_ERROR
    b.eq    .Lfail_ffi

    ldr     x0, =name_ffi
    bl      test_pass
    b       .Ldone_ffi
.Lfail_ffi:
    ldr     x0, =name_ffi
    bl      test_fail
.Ldone_ffi:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_fsa_bad_method — garbage request → S_ERROR
 * ======================================================================== */
test_http_fsa_bad_method:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    ldr     x19, =http_conn_table
    mov     w0, #HCONN_SIZE / 8
    mov     x1, x19
.Lffbm_z:
    str     xzr, [x1], #8
    subs    w0, w0, #1
    b.ne    .Lffbm_z

    mov     x0, x19
    ldr     x1, =thttp_garbage_request
    ldr     w2, =thttp_garbage_request_len
    bl      http_parse_request

    cmp     w0, #S_ERROR
    b.ne    .Lfail_ffbm

    ldr     x0, =name_ffbm
    bl      test_pass
    b       .Ldone_ffbm
.Lfail_ffbm:
    ldr     x0, =name_ffbm
    bl      test_fail
.Ldone_ffbm:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * Helper: thttp_check_date — compare formatted date output to expected
 *
 * x0: expected string, x1: actual buffer, w2: length
 * Returns: w0 = 1 if match, 0 if mismatch
 * ======================================================================== */
thttp_check_date:
    mov     w3, #0
.Ltcd_loop:
    cmp     w3, w2
    b.hs    .Ltcd_match
    ldrb    w4, [x0, x3]
    ldrb    w5, [x1, x3]
    cmp     w4, w5
    b.ne    .Ltcd_fail
    add     w3, w3, #1
    b       .Ltcd_loop
.Ltcd_match:
    mov     w0, #1
    ret
.Ltcd_fail:
    mov     w0, #0
    ret

/* ========================================================================
 * test_http_date_epoch — Unix 0 → "Thu, 01 Jan 1970 00:00:00 GMT"
 * ======================================================================== */
test_http_date_epoch:
    stp     x29, x30, [sp, #-16]!

    mov     x0, #0
    ldr     x1, =thttp_date_buf
    bl      http_format_date

    cmp     w0, #29
    b.ne    .Lfail_hde

    ldr     x0, =thttp_date_epoch_expected
    ldr     x1, =thttp_date_buf
    mov     w2, #29
    bl      thttp_check_date
    cbz     w0, .Lfail_hde

    ldr     x0, =name_hde
    bl      test_pass
    b       .Ldone_hde
.Lfail_hde:
    ldr     x0, =name_hde
    bl      test_fail
.Ldone_hde:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_date_2026 — 2026-04-16 19:45:00 → "Thu, 16 Apr 2026 19:45:00 GMT"
 * Timestamp: 1776368700
 * ======================================================================== */
test_http_date_2026:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =1776368700
    ldr     x1, =thttp_date_buf
    bl      http_format_date

    cmp     w0, #29
    b.ne    .Lfail_hd26

    ldr     x0, =thttp_date_2026_expected
    ldr     x1, =thttp_date_buf
    mov     w2, #29
    bl      thttp_check_date
    cbz     w0, .Lfail_hd26

    ldr     x0, =name_hd26
    bl      test_pass
    b       .Ldone_hd26
.Lfail_hd26:
    ldr     x0, =name_hd26
    bl      test_fail
.Ldone_hd26:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_leap_2000 — 2000-02-29 00:00:00 → "Tue, 29 Feb 2000 00:00:00 GMT"
 * Timestamp: 951782400 (leap year divisible by 400)
 * ======================================================================== */
test_http_leap_2000:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =951782400
    ldr     x1, =thttp_date_buf
    bl      http_format_date

    cmp     w0, #29
    b.ne    .Lfail_hl20

    ldr     x0, =thttp_date_leap2000_expected
    ldr     x1, =thttp_date_buf
    mov     w2, #29
    bl      thttp_check_date
    cbz     w0, .Lfail_hl20

    ldr     x0, =name_hl20
    bl      test_pass
    b       .Ldone_hl20
.Lfail_hl20:
    ldr     x0, =name_hl20
    bl      test_fail
.Ldone_hl20:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_noleap_2100 — 2100-02-28 12:00:00 → NOT Feb 29
 * Timestamp: 4107499200 (century not divisible by 400 → no leap)
 * ======================================================================== */
test_http_noleap_2100:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =4107499200
    ldr     x1, =thttp_date_buf
    bl      http_format_date

    cmp     w0, #29
    b.ne    .Lfail_hn21

    ldr     x0, =thttp_date_noleap2100_expected
    ldr     x1, =thttp_date_buf
    mov     w2, #29
    bl      thttp_check_date
    cbz     w0, .Lfail_hn21

    ldr     x0, =name_hn21
    bl      test_pass
    b       .Ldone_hn21
.Lfail_hn21:
    ldr     x0, =name_hn21
    bl      test_fail
.Ldone_hn21:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_send_chunk — SENDING state sends one chunk and advances ptr
 * ======================================================================== */
test_http_send_chunk:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* Pre-seed ESTABLISHED connection with large SND_WND */
    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]
    mov     w0, #2000
    str     w0, [x19, #TCONN_SND_WND]
    /* Need SND_NXT = SND_UNA (no data in flight) for tcp_send to work */
    mov     w0, #100
    str     w0, [x19, #TCONN_SND_UNA]
    str     w0, [x19, #TCONN_SND_NXT]
    /* Need PEER_MSS */
    mov     w0, #TCP_OUR_MSS
    strh    w0, [x19, #TCONN_PEER_MSS]
    /* Need CWND */
    mov     w0, #0x40000
    str     w0, [x19, #TCONN_CWND]
    /* Need RMAC */
    ldr     x0, =net_our_mac
    ldr     w1, [x0]
    str     w1, [x19, #TCONN_RMAC]
    ldrh    w1, [x0, #4]
    strh    w1, [x19, #(TCONN_RMAC + 4)]
    /* Need RIP */
    ldr     x0, =net_our_ip
    ldr     w0, [x0]
    str     w0, [x19, #TCONN_RIP]
    /* Need RCV_NXT for ACK field */
    mov     w0, #1
    str     w0, [x19, #TCONN_RCV_NXT]

    /* Pre-set HCONN to SENDING with 200 response */
    ldr     x20, =http_conn_table
    mov     w0, #HTTPS_SENDING
    strb    w0, [x20, #HCONN_STATE]
    strb    wzr, [x20, #HCONN_STATUS]
    str     wzr, [x20, #HCONN_RESP_PTR]
    ldr     x0, =http_200_body
    str     x0, [x20, #HCONN_BODY_PTR]
    mov     w0, #158                    /* http_200_body_len */
    str     w0, [x20, #HCONN_BODY_LEN]
    mov     w1, #133                    /* http_200_hdr_len (no Connection: close) */
    str     w1, [x20, #HCONN_HDR_LEN]
    add     w2, w0, w1
    str     w2, [x20, #HCONN_RESP_LEN]

    /* Install mock send */
    ldr     x0, =thttp_send_count
    str     wzr, [x0]
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_counting_send
    bl      http_set_send_ctx

    /* Call http_poll — should send one chunk */
    bl      http_poll

    /* Send should have been called */
    ldr     x0, =thttp_send_count
    ldr     w0, [x0]
    cbz     w0, .Lfail_hsc

    /* RESP_PTR should have advanced (> 0) */
    ldr     w0, [x20, #HCONN_RESP_PTR]
    cbz     w0, .Lfail_hsc

    ldr     x0, =name_hsc
    bl      test_pass
    b       .Ldone_hsc
.Lfail_hsc:
    ldr     x0, =name_hsc
    bl      test_fail
.Ldone_hsc:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_send_close — response complete → tcp_close + IDLE
 * ======================================================================== */
test_http_send_close:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* Pre-seed ESTABLISHED connection */
    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]
    mov     w0, #100
    str     w0, [x19, #TCONN_SND_UNA]
    str     w0, [x19, #TCONN_SND_NXT]
    mov     w0, #TCP_OUR_MSS
    strh    w0, [x19, #TCONN_PEER_MSS]
    mov     w0, #0x40000
    str     w0, [x19, #TCONN_CWND]
    ldr     x0, =net_our_mac
    ldr     w1, [x0]
    str     w1, [x19, #TCONN_RMAC]
    ldr     x0, =net_our_ip
    ldr     w0, [x0]
    str     w0, [x19, #TCONN_RIP]
    mov     w0, #1
    str     w0, [x19, #TCONN_RCV_NXT]
    mov     w0, #-1
    str     w0, [x19, #TCONN_TIMER_SLOT]

    /* HCONN: SENDING, RESP_PTR == RESP_LEN (all sent) */
    ldr     x20, =http_conn_table
    mov     w0, #HTTPS_SENDING
    strb    w0, [x20, #HCONN_STATE]
    mov     w0, #100
    str     w0, [x20, #HCONN_RESP_PTR]
    str     w0, [x20, #HCONN_RESP_LEN]     /* ptr == len → done */

    /* Install mock send for tcp_close FIN */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_counting_send
    bl      http_set_send_ctx

    bl      http_poll

    /* HCONN should be back to IDLE */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATE]
    cbnz    w0, .Lfail_hscl

    ldr     x0, =name_hscl
    bl      test_pass
    b       .Ldone_hscl
.Lfail_hscl:
    ldr     x0, =name_hscl
    bl      test_fail
.Ldone_hscl:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_reset_during_send — TCP RST while SENDING → reset to IDLE
 * ======================================================================== */
test_http_reset_during_send:
    stp     x29, x30, [sp, #-16]!

    bl      tcp_init
    bl      http_init

    /* TCONN slot 0: state = CLOSED (simulates RST) */
    ldr     x0, =tcp_conn_table
    strb    wzr, [x0, #TCONN_STATE]

    /* HCONN slot 0: SENDING (stale — TCP connection gone) */
    ldr     x0, =http_conn_table
    mov     w1, #HTTPS_SENDING
    strb    w1, [x0, #HCONN_STATE]

    bl      http_poll

    /* HCONN should be reset to IDLE */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATE]
    cbnz    w0, .Lfail_hrds

    ldr     x0, =name_hrds
    bl      test_pass
    b       .Ldone_hrds
.Lfail_hrds:
    ldr     x0, =name_hrds
    bl      test_fail
.Ldone_hrds:
    ldp     x29, x30, [sp], #16
    ret

/* Counting send function for send-path tests */
thttp_counting_send:
    ldr     x9, =thttp_send_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]
    mov     w0, #0
    ret

/* Mock send function */
thttp_mock_send:
    mov     w0, #0
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .rodata

thttp_get_request:
    .ascii  "GET / HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_get_request_end:
.equ thttp_get_request_len, thttp_get_request_end - thttp_get_request

thttp_partial_request:
    .ascii  "GET / HTTP/1.1\r\nHost: 10.0.2.15\r\n"
thttp_partial_request_end:
.equ thttp_partial_request_len, thttp_partial_request_end - thttp_partial_request

thttp_404_request:
    .ascii  "GET /notfound HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_404_request_end:
.equ thttp_404_request_len, thttp_404_request_end - thttp_404_request

thttp_post_request:
    .ascii  "POST / HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_post_request_end:
.equ thttp_post_request_len, thttp_post_request_end - thttp_post_request

thttp_head_request:
    .ascii  "HEAD / HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_head_request_end:
.equ thttp_head_request_len, thttp_head_request_end - thttp_head_request

thttp_get_10_request:
    .ascii  "GET / HTTP/1.0\r\n\r\n"
thttp_get_10_request_end:
.equ thttp_get_10_request_len, thttp_get_10_request_end - thttp_get_10_request

thttp_nohost_11_request:
    .ascii  "GET / HTTP/1.1\r\n\r\n"
thttp_nohost_11_request_end:
.equ thttp_nohost_11_request_len, thttp_nohost_11_request_end - thttp_nohost_11_request

thttp_nohost_10_request:
    .ascii  "GET / HTTP/1.0\r\n\r\n"
thttp_nohost_10_request_end:
.equ thttp_nohost_10_request_len, thttp_nohost_10_request_end - thttp_nohost_10_request

thttp_head_10_request:
    .ascii  "HEAD / HTTP/1.0\r\n\r\n"
thttp_head_10_request_end:
.equ thttp_head_10_request_len, thttp_head_10_request_end - thttp_head_10_request

thttp_garbage_request:
    .ascii  "123 / HTTP/1.1\r\nHost: x\r\n\r\n"
thttp_garbage_request_end:
.equ thttp_garbage_request_len, thttp_garbage_request_end - thttp_garbage_request

thttp_bad_version_request:
    .ascii  "GET / JUNK/9.9\r\nHost: test\r\n\r\n"
thttp_bad_version_request_end:
.equ thttp_bad_version_request_len, thttp_bad_version_request_end - thttp_bad_version_request

thttp_host_lower_request:
    .ascii  "GET / HTTP/1.1\r\nhost: 10.0.2.15\r\n\r\n"
thttp_host_lower_request_end:
.equ thttp_host_lower_request_len, thttp_host_lower_request_end - thttp_host_lower_request

thttp_uri_root:
    .ascii  "/"

thttp_uri_foo:
    .ascii  "/foo"

name_hi:    .asciz "http_init"
name_feoh:  .asciz "http_find_eoh"
name_feohm: .asciz "http_find_eoh_missing"
name_umr:   .asciz "http_uri_match_root"
name_um4:   .asciz "http_uri_match_404"
name_hpg:   .asciz "http_parse_get"
name_hpi:   .asciz "http_parse_incomplete"
name_hp4:   .asciz "http_parse_404"
name_hpbm:  .asciz "http_parse_bad_method"
name_hph:   .asciz "http_parse_head"
name_hv10:  .asciz "http_version_10"
name_hv11:  .asciz "http_version_11"
name_hmna:  .asciz "http_method_not_allowed"
name_hmh:   .asciz "http_missing_host_11"
name_hnh10: .asciz "http_no_host_10_ok"
name_hhnb:  .asciz "http_head_no_body"
name_hhl:   .asciz "http_host_lowercase"
name_hbv:   .asciz "http_bad_version"
name_fg11:  .asciz "http_fsa_get_11"
name_fh10:  .asciz "http_fsa_head_10"
name_ffi:   .asciz "http_fsa_incomplete"
name_ffbm:  .asciz "http_fsa_bad_method"
name_hde:   .asciz "http_date_epoch"
name_hd26:  .asciz "http_date_2026"
name_hl20:  .asciz "http_leap_2000"
name_hn21:  .asciz "http_noleap_2100"
name_hsc:   .asciz "http_send_chunk"

thttp_date_epoch_expected:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"

thttp_date_2026_expected:
    .ascii  "Thu, 16 Apr 2026 19:45:00 GMT"

thttp_date_leap2000_expected:
    .ascii  "Tue, 29 Feb 2000 00:00:00 GMT"

thttp_date_noleap2100_expected:
    .ascii  "Sun, 28 Feb 2100 12:00:00 GMT"
name_hscl:  .asciz "http_send_close"
name_hrds:  .asciz "http_reset_during_send"

.section .data
.balign 16
thttp_tx_buf:
    .space  ETH_FRAME_MAX

.balign 4
thttp_send_count:
    .word   0

.balign 4
thttp_date_buf:
    .space  32
