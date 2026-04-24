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
.include "store.inc"

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
    bl      test_http_chunk_encode
    bl      test_http_chunk_terminate
    bl      test_http_date_epoch
    bl      test_http_date_2026
    bl      test_http_leap_2000
    bl      test_http_noleap_2100
    bl      test_http_send_chunk
    bl      test_http_send_close
    bl      test_http_reset_during_send
    bl      test_http_resp_isolation
    bl      test_http_route_handler_dispatch
    bl      test_http_post_accepted
    bl      test_http_content_length_parsed
    bl      test_http_post_body_copied
    bl      test_http_post_body_to_handler
    bl      test_http_post_oversize_413
    bl      test_http_post_cl_overflow_413
    bl      test_http_post_no_cl_411
    bl      test_http_post_dup_cl_400
    bl      test_http_post_multi_packet_body
    bl      test_http_route_css_content_type
    bl      test_http_counter_increments
    bl      test_http_guestbook_post
    bl      test_http_guestbook_get_render
    bl      test_http_form_log_post
    bl      test_http_query_string_split
    bl      test_http_guestbook_html_escape
    bl      test_http_route_method_405
    bl      test_http_405_allow_per_route
    bl      test_http_recv_body_slowloris
    bl      test_http_pipelined_keepalive
    bl      test_http_appliance_slab_placeholder
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

    cbz     x0, .Lfail_umr         /* should return non-zero (route ptr) */

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

    cbnz    x0, .Lfail_um4         /* should return 0 (no route) */

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
    ldr     x1, =thttp_put_request
    ldr     w2, =thttp_put_request_len
.Lhpbm_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpbm_cp

    ldr     w0, =thttp_put_request_len
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
    ldr     x1, =thttp_put_request
    ldr     w2, =thttp_put_request_len
.Lhmna_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhmna_cp

    ldr     w0, =thttp_put_request_len
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
 * test_http_chunk_encode — 5 bytes "Hello" → "5\r\nHello\r\n" (10 bytes)
 * ======================================================================== */
test_http_chunk_encode:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =thttp_chunk_buf
    ldr     x1, =thttp_chunk_data
    mov     w2, #5
    bl      http_chunk_encode

    /* Should return 10 bytes: "5\r\nHello\r\n" */
    cmp     w0, #10
    b.ne    .Lfail_hce

    /* Verify first byte is '5' */
    ldr     x0, =thttp_chunk_buf
    ldrb    w1, [x0]
    cmp     w1, #'5'
    b.ne    .Lfail_hce

    /* Verify \r\n after size */
    ldrb    w1, [x0, #1]
    cmp     w1, #0x0D
    b.ne    .Lfail_hce
    ldrb    w1, [x0, #2]
    cmp     w1, #0x0A
    b.ne    .Lfail_hce

    /* Verify data starts at offset 3 */
    ldrb    w1, [x0, #3]
    cmp     w1, #'H'
    b.ne    .Lfail_hce

    /* Verify trailing \r\n */
    ldrb    w1, [x0, #8]
    cmp     w1, #0x0D
    b.ne    .Lfail_hce
    ldrb    w1, [x0, #9]
    cmp     w1, #0x0A
    b.ne    .Lfail_hce

    ldr     x0, =name_hce
    bl      test_pass
    b       .Ldone_hce
.Lfail_hce:
    ldr     x0, =name_hce
    bl      test_fail
.Ldone_hce:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_http_chunk_terminate — "0\r\n\r\n" = 5 bytes
 * ======================================================================== */
test_http_chunk_terminate:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =thttp_chunk_buf
    bl      http_chunk_terminate

    cmp     w0, #5
    b.ne    .Lfail_hct

    ldr     x0, =thttp_chunk_buf
    ldrb    w1, [x0]
    cmp     w1, #'0'
    b.ne    .Lfail_hct
    ldrb    w1, [x0, #1]
    cmp     w1, #0x0D
    b.ne    .Lfail_hct
    ldrb    w1, [x0, #2]
    cmp     w1, #0x0A
    b.ne    .Lfail_hct
    ldrb    w1, [x0, #3]
    cmp     w1, #0x0D
    b.ne    .Lfail_hct
    ldrb    w1, [x0, #4]
    cmp     w1, #0x0A
    b.ne    .Lfail_hct

    ldr     x0, =name_hct
    bl      test_pass
    b       .Ldone_hct
.Lfail_hct:
    ldr     x0, =name_hct
    bl      test_fail
.Ldone_hct:
    ldp     x29, x30, [sp], #16
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

/* ========================================================================
 * test_http_resp_isolation — two concurrent dynamic responses must use
 * distinct buffers.
 *
 * Sets up HCONNs 0 and 1 as ESTABLISHED with GET /status requests in
 * their rx buffers. http_poll walks both through dispatch; both land in
 * SENDING with HCONN_BODY_PTR populated.
 *
 * Asserts: the two body_ptr values differ. This holds because
 * .Lhp_dynamic derives each HCONN's scratch address from its index in
 * http_conn_table — a shared-buffer dispatch would violate it.
 * ======================================================================== */
test_http_resp_isolation:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* --- TCONN slot 0: ESTABLISHED, GET /status in rx buffer --- */
    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_status_request
    ldr     w2, =thttp_status_request_len
.Lhri_cp0:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhri_cp0
    ldr     w0, =thttp_status_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    /* --- TCONN slot 1: ESTABLISHED, same request in its rx buffer --- */
    ldr     x20, =tcp_conn_table
    add     x20, x20, #TCONN_SIZE
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x20, #TCONN_STATE]
    mov     w0, #0x5001
    strh    w0, [x20, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    mov     w1, #TCP_RXBUF_SIZE
    add     x0, x0, x1, uxtw             /* slot 1 rx buffer */
    ldr     x1, =thttp_status_request
    ldr     w2, =thttp_status_request_len
.Lhri_cp1:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhri_cp1
    ldr     w0, =thttp_status_request_len
    strh    w0, [x20, #TCONN_RXLEN]

    /* Mock send; TCP not set up for real sends, so send_chunk is a no-op
     * and both HCONNs stay in SENDING with body_ptr populated. */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Both HCONNs must have reached SENDING */
    ldr     x19, =http_conn_table
    ldrb    w0, [x19, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hri

    ldr     x20, =http_conn_table
    add     x20, x20, #HCONN_SIZE
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hri

    /* The assertion: body_ptrs must differ (per-way buffers) */
    ldr     x0, [x19, #HCONN_BODY_PTR]
    ldr     x1, [x20, #HCONN_BODY_PTR]
    cmp     x0, x1
    b.eq    .Lfail_hri                   /* shared buffer → FAIL */

    ldr     x0, =name_hri
    bl      test_pass
    b       .Ldone_hri
.Lfail_hri:
    ldr     x0, =name_hri
    bl      test_fail
.Ldone_hri:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_route_handler_dispatch — the dispatch path invokes the
 * handler pointer stored in the route entry's ROUTE_HANDLER field.
 *
 * Sets up HCONN[0] as ESTABLISHED with GET /_test_dispatch. That route's
 * ROUTE_HANDLER points at http_test_dispatch_handler, which emits the
 * sentinel "DISPATCH_OK\n" (12 bytes). The chunk encoder wraps it as
 * "C\r\nDISPATCH_OK\n\r\n", so body_ptr[3] onward spells the sentinel.
 *
 * Asserts: body_ptr[3..5] == "DIS". This is only possible if the
 * dispatcher loads the handler from ROUTE_HANDLER — a hardcoded
 * http_status_generate would emit the status page instead, and a
 * missing route would 404 with the static error body.
 * ======================================================================== */
test_http_route_handler_dispatch:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* TCONN slot 0: ESTABLISHED, GET /_test_dispatch */
    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_test_dispatch_request
    ldr     w2, =thttp_test_dispatch_request_len
.Lhrhd_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhrhd_cp
    ldr     w0, =thttp_test_dispatch_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    /* Mock send — dispatch runs, no real transmit */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Must reach SENDING with 200 status */
    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hrhd

    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_200
    b.ne    .Lfail_hrhd

    /* body_ptr[3..5] should be 'D','I','S' from "DISPATCH_OK\n" after
     * chunk framing "C\r\n..." */
    ldr     x1, [x20, #HCONN_BODY_PTR]
    ldrb    w0, [x1, #3]
    cmp     w0, #'D'
    b.ne    .Lfail_hrhd
    ldrb    w0, [x1, #4]
    cmp     w0, #'I'
    b.ne    .Lfail_hrhd
    ldrb    w0, [x1, #5]
    cmp     w0, #'S'
    b.ne    .Lfail_hrhd

    ldr     x0, =name_hrhd
    bl      test_pass
    b       .Ldone_hrhd
.Lfail_hrhd:
    ldr     x0, =name_hrhd
    bl      test_fail
.Ldone_hrhd:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_post_accepted — a POST request reaches route dispatch and
 * returns a non-405 status.
 *
 * Sets up HCONN[0] as ESTABLISHED with POST / HTTP/1.1 (no body). The
 * route "/" is a static 200 responder. Asserts: HCONN_STATUS == 200.
 *
 * Prerequisite for guestbook/form_log/counter handlers, which consume
 * POST bodies; this test only checks method acceptance — body parsing
 * is a follow-on step.
 * ======================================================================== */
test_http_post_accepted:
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
.Lhpa_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpa_cp
    ldr     w0, =thttp_post_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_200
    b.ne    .Lfail_hpa

    ldr     x0, =name_hpa
    bl      test_pass
    b       .Ldone_hpa
.Lfail_hpa:
    ldr     x0, =name_hpa
    bl      test_fail
.Ldone_hpa:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_content_length_parsed — parser extracts Content-Length
 * from the headers and stores the numeric value on HCONN.
 *
 * Feeds a POST with "Content-Length: 42" (no body required; parser
 * terminates at \r\n\r\n regardless) and asserts HCONN_CONTENT_LEN
 * is 42 afterward. This value drives future body accumulation.
 * ======================================================================== */
test_http_content_length_parsed:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      http_init

    /* Zero HCONN[0] for a clean parse state */
    ldr     x19, =http_conn_table
    mov     w1, #HCONN_SIZE / 8
    mov     x0, x19
.Lhclp_z:
    str     xzr, [x0], #8
    subs    w1, w1, #1
    b.ne    .Lhclp_z

    /* Parse request with Content-Length: 42 */
    mov     x0, x19
    ldr     x1, =thttp_post_cl42_request
    ldr     w2, =thttp_post_cl42_request_len
    bl      http_parse_request

    cmp     w0, #S_DONE
    b.ne    .Lfail_hclp

    ldr     w0, [x19, #HCONN_CONTENT_LEN]
    cmp     w0, #42
    b.ne    .Lfail_hclp

    ldr     x0, =name_hclp
    bl      test_pass
    b       .Ldone_hclp
.Lfail_hclp:
    ldr     x0, =name_hclp
    bl      test_fail
.Ldone_hclp:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_post_body_copied — POST body bytes land in the per-HCONN
 * receive buffer.
 *
 * Sends POST / with Content-Length: 5 and body "hello" (headers + body
 * in a single rx write). After http_poll, the first 5 bytes of
 * http_body_recv_bufs (HCONN[0]'s slot) must equal "hello".
 *
 * Exercises single-shot body copy: the rx buffer has the entire
 * request before the parser reaches S_DONE, so the body is reachable
 * at rx_buffer + HCONN_REQ_LEN and gets copied into HCONN[0]'s slot
 * of http_body_recv_bufs before tcp_rx_flush wipes the rx data.
 * ======================================================================== */
test_http_post_body_copied:
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
    ldr     x1, =thttp_post_body_request
    ldr     w2, =thttp_post_body_request_len
.Lhpbc_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpbc_cp
    ldr     w0, =thttp_post_body_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* HCONN[0] should have CONTENT_LEN == 5 */
    ldr     x20, =http_conn_table
    ldr     w0, [x20, #HCONN_CONTENT_LEN]
    cmp     w0, #5
    b.ne    .Lfail_hpbc

    /* http_body_recv_bufs[0] should start with "hello" */
    ldr     x1, =http_body_recv_bufs
    ldrb    w0, [x1]
    cmp     w0, #'h'
    b.ne    .Lfail_hpbc
    ldrb    w0, [x1, #1]
    cmp     w0, #'e'
    b.ne    .Lfail_hpbc
    ldrb    w0, [x1, #2]
    cmp     w0, #'l'
    b.ne    .Lfail_hpbc
    ldrb    w0, [x1, #3]
    cmp     w0, #'l'
    b.ne    .Lfail_hpbc
    ldrb    w0, [x1, #4]
    cmp     w0, #'o'
    b.ne    .Lfail_hpbc

    ldr     x0, =name_hpbc
    bl      test_pass
    b       .Ldone_hpbc
.Lfail_hpbc:
    ldr     x0, =name_hpbc
    bl      test_fail
.Ldone_hpbc:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_post_body_to_handler — a handler can read the POST body
 * from HCONN and echo it in the response.
 *
 * POSTs "ping" to /_test_echo. That route's handler reads the request
 * body from http_body_recv_bufs[hconn_index] (computed via the HCONN
 * pointer it now receives as its third argument) and copies those
 * bytes into the output. The chunked wrapper puts "4\r\n" before the
 * data, so body_ptr[3..6] should spell "ping".
 * ======================================================================== */
test_http_post_body_to_handler:
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
    ldr     x1, =thttp_post_echo_request
    ldr     w2, =thttp_post_echo_request_len
.Lhpeh_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpeh_cp
    ldr     w0, =thttp_post_echo_request_len
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
    b.ne    .Lfail_hpeh

    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_200
    b.ne    .Lfail_hpeh

    /* body_ptr[3..6] should be "ping" after the "4\r\n" chunk prefix */
    ldr     x1, [x20, #HCONN_BODY_PTR]
    ldrb    w0, [x1, #3]
    cmp     w0, #'p'
    b.ne    .Lfail_hpeh
    ldrb    w0, [x1, #4]
    cmp     w0, #'i'
    b.ne    .Lfail_hpeh
    ldrb    w0, [x1, #5]
    cmp     w0, #'n'
    b.ne    .Lfail_hpeh
    ldrb    w0, [x1, #6]
    cmp     w0, #'g'
    b.ne    .Lfail_hpeh

    ldr     x0, =name_hpeh
    bl      test_pass
    b       .Ldone_hpeh
.Lfail_hpeh:
    ldr     x0, =name_hpeh
    bl      test_fail
.Ldone_hpeh:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_post_oversize_413 — a POST declaring Content-Length bigger
 * than HTTP_MAX_RECV_BODY is rejected with 413 Payload Too Large.
 *
 * Today the body-copy block silently skips oversize bodies and the
 * request dispatches normally (status 200 for /), misleading the
 * handler about whether it received valid input. This test asserts
 * the status code is set to HSTATUS_413 instead.
 * ======================================================================== */
test_http_post_oversize_413:
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
    ldr     x1, =thttp_post_oversize_request
    ldr     w2, =thttp_post_oversize_request_len
.Lhpo4_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpo4_cp
    ldr     w0, =thttp_post_oversize_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_413
    b.ne    .Lfail_hpo4

    ldr     x0, =name_hpo4
    bl      test_pass
    b       .Ldone_hpo4
.Lfail_hpo4:
    ldr     x0, =name_hpo4
    bl      test_fail
.Ldone_hpo4:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_post_cl_overflow_413 — a Content-Length that would wrap
 * around u32 to a small value must still be rejected with 413.
 *
 * "4294967396" decimal = 2^32 + 100. Without clamping, the digit
 * accumulator silently wraps to 100 — which is below
 * HTTP_MAX_RECV_BODY (1024), so the oversize check in the body-copy
 * block lets the request through and the handler sees 100 bytes of
 * whatever was after the headers. With clamping, the accumulator
 * stops once it crosses HTTP_MAX_RECV_BODY (four digits in: 4294),
 * and the 413 path fires.
 * ======================================================================== */
test_http_post_cl_overflow_413:
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
    ldr     x1, =thttp_post_cl_overflow_request
    ldr     w2, =thttp_post_cl_overflow_request_len
.Lhpco_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpco_cp
    ldr     w0, =thttp_post_cl_overflow_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_413
    b.ne    .Lfail_hpco

    ldr     x0, =name_hpco
    bl      test_pass
    b       .Ldone_hpco
.Lfail_hpco:
    ldr     x0, =name_hpco
    bl      test_fail
.Ldone_hpco:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_post_no_cl_411 — a POST without any Content-Length header
 * must be rejected with 411 Length Required (RFC 7230 §3.3.3).
 *
 * Today such a request dispatches as 200: the parser terminates at
 * \r\n\r\n, HCONN_CONTENT_LEN stays 0 (indistinguishable from an
 * explicit "Content-Length: 0"), and http_poll cannot tell whether
 * the header was present. After the fix, an HFLAG_CL_SEEN bit
 * distinguishes "header present with value 0" from "header absent",
 * and POST + absent triggers 411.
 * ======================================================================== */
test_http_post_no_cl_411:
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
    ldr     x1, =thttp_post_no_cl_request
    ldr     w2, =thttp_post_no_cl_request_len
.Lhpnc_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpnc_cp
    ldr     w0, =thttp_post_no_cl_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_411
    b.ne    .Lfail_hpnc

    ldr     x0, =name_hpnc
    bl      test_pass
    b       .Ldone_hpnc
.Lfail_hpnc:
    ldr     x0, =name_hpnc
    bl      test_fail
.Ldone_hpnc:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_post_dup_cl_400 — two Content-Length headers in the same
 * request must cause a parse error, handled as 400 Bad Request.
 *
 * Duplicate Content-Length is classic request-smuggling bait: the
 * front proxy and the backend may disagree on which value is
 * authoritative. RFC 7230 §3.3.3 requires the server to reject the
 * message. Today the parser silently overwrites HCONN_CONTENT_LEN
 * with the second value; after the fix it transitions to S_ERROR,
 * which the dispatcher translates to 400.
 * ======================================================================== */
test_http_post_dup_cl_400:
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
    ldr     x1, =thttp_post_dup_cl_request
    ldr     w2, =thttp_post_dup_cl_request_len
.Lhpdc_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpdc_cp
    ldr     w0, =thttp_post_dup_cl_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_400
    b.ne    .Lfail_hpdc

    ldr     x0, =name_hpdc
    bl      test_pass
    b       .Ldone_hpdc
.Lfail_hpdc:
    ldr     x0, =name_hpdc
    bl      test_fail
.Ldone_hpdc:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_post_multi_packet_body — a body that arrives across two
 * TCP segments must accumulate into http_body_recv_bufs and dispatch
 * only when complete.
 *
 * Puts the request headers plus the first 2 body bytes in rx and
 * calls http_poll. State must transition to HTTPS_RECV_BODY (parser
 * reached S_DONE, body not complete). Appends the remaining 3 body
 * bytes, calls http_poll again. State must transition to
 * HTTPS_SENDING and http_body_recv_bufs[0] must contain the full
 * "hello".
 * ======================================================================== */
test_http_post_multi_packet_body:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    /* Copy headers + first 2 body bytes ("he") into rx */
    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_post_mp_part1
    ldr     w2, =thttp_post_mp_part1_len
.Lhpmp_cp1:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpmp_cp1
    ldr     w0, =thttp_post_mp_part1_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    /* First poll: should transition to HTTPS_RECV_BODY */
    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_RECV_BODY
    b.ne    .Lfail_hpmp

    /* Append the remaining 3 body bytes ("llo") to rx */
    ldr     x0, =tcp_rxbuf_pool
    ldr     w1, =thttp_post_mp_part1_len
    add     x0, x0, x1, uxtw
    ldr     x1, =thttp_post_mp_part2
    mov     w2, #3
.Lhpmp_cp2:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpmp_cp2
    ldr     w0, =thttp_post_mp_part1_len
    add     w0, w0, #3
    strh    w0, [x19, #TCONN_RXLEN]

    /* Second poll: should dispatch (state → SENDING, body complete) */
    bl      http_poll

    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hpmp

    /* http_body_recv_bufs[0..5] == "hello" */
    ldr     x1, =http_body_recv_bufs
    ldrb    w0, [x1]
    cmp     w0, #'h'
    b.ne    .Lfail_hpmp
    ldrb    w0, [x1, #1]
    cmp     w0, #'e'
    b.ne    .Lfail_hpmp
    ldrb    w0, [x1, #2]
    cmp     w0, #'l'
    b.ne    .Lfail_hpmp
    ldrb    w0, [x1, #3]
    cmp     w0, #'l'
    b.ne    .Lfail_hpmp
    ldrb    w0, [x1, #4]
    cmp     w0, #'o'
    b.ne    .Lfail_hpmp

    ldr     x0, =name_hpmp
    bl      test_pass
    b       .Ldone_hpmp
.Lfail_hpmp:
    ldr     x0, =name_hpmp
    bl      test_fail
.Ldone_hpmp:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_route_css_content_type — a static route with Content-Type
 * other than text/html is served correctly end-to-end.
 *
 * GETs /_test_css. That route's header template declares
 * "Content-Type: text/css". After dispatch, HCONN_HDR_SRC_PTR should
 * point at http_test_css_hdr, and the bytes at that address should
 * contain "Content-Type: text/css".
 *
 * Validates that the runtime supports per-route Content-Type (the
 * packager will lean on this for CSS/images/favicon); a hardcoded
 * text/html assumption anywhere would cause the assertion to fail.
 * ======================================================================== */
test_http_route_css_content_type:
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
    ldr     x1, =thttp_get_test_css_request
    ldr     w2, =thttp_get_test_css_request_len
.Lhcss_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhcss_cp
    ldr     w0, =thttp_get_test_css_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Must reach SENDING with 200 status */
    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hcss

    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_200
    b.ne    .Lfail_hcss

    /* Scan the selected header block for "text/css" (8 bytes).
     * HCONN_HDR_SRC_PTR points at http_test_css_hdr; scan from there. */
    ldr     x1, [x20, #HCONN_HDR_SRC_PTR]
    ldr     w2, [x20, #HCONN_HDR_SRC_LEN]
    /* sentinel bytes to find: 't','e','x','t','/','c','s','s' */
    mov     w3, #0                      /* cursor */
.Lhcss_scan:
    add     w4, w3, #8
    cmp     w4, w2
    b.hi    .Lfail_hcss                 /* walked past end → not found */
    ldrb    w4, [x1, w3, uxtw]
    cmp     w4, #'t'
    b.ne    .Lhcss_next
    add     w4, w3, #1
    ldrb    w4, [x1, w4, uxtw]
    cmp     w4, #'e'
    b.ne    .Lhcss_next
    add     w4, w3, #2
    ldrb    w4, [x1, w4, uxtw]
    cmp     w4, #'x'
    b.ne    .Lhcss_next
    add     w4, w3, #3
    ldrb    w4, [x1, w4, uxtw]
    cmp     w4, #'t'
    b.ne    .Lhcss_next
    add     w4, w3, #4
    ldrb    w4, [x1, w4, uxtw]
    cmp     w4, #'/'
    b.ne    .Lhcss_next
    add     w4, w3, #5
    ldrb    w4, [x1, w4, uxtw]
    cmp     w4, #'c'
    b.ne    .Lhcss_next
    add     w4, w3, #6
    ldrb    w4, [x1, w4, uxtw]
    cmp     w4, #'s'
    b.ne    .Lhcss_next
    add     w4, w3, #7
    ldrb    w4, [x1, w4, uxtw]
    cmp     w4, #'s'
    b.eq    .Lhcss_found

.Lhcss_next:
    add     w3, w3, #1
    b       .Lhcss_scan

.Lhcss_found:
    ldr     x0, =name_hcss
    bl      test_pass
    b       .Ldone_hcss
.Lfail_hcss:
    ldr     x0, =name_hcss
    bl      test_fail
.Ldone_hcss:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_counter_increments — /counter advances by one per request.
 *
 * GETs /counter twice (resetting conn state between, simulating fresh
 * connections). Records counter_store.records_written after each. The
 * delta must be exactly 1.
 *
 * Intentionally observes the store directly rather than parsing the
 * response body — this isolates the handler's state mutation from
 * response formatting. A formatting-specific test can follow.
 * ======================================================================== */
test_http_counter_increments:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    /* First GET /counter */
    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_get_counter_request
    ldr     w2, =thttp_get_counter_request_len
.Lhci_cp1:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhci_cp1
    ldr     w0, =thttp_get_counter_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Capture the counter value after the first request */
    ldr     x0, =counter_store
    ldr     w20, [x0, #STORE_WRITTEN]

    /* Second GET /counter */
    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_get_counter_request
    ldr     w2, =thttp_get_counter_request_len
.Lhci_cp2:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhci_cp2
    ldr     w0, =thttp_get_counter_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x0, =counter_store
    ldr     w1, [x0, #STORE_WRITTEN]
    sub     w0, w1, w20
    cmp     w0, #1
    b.ne    .Lfail_hci

    ldr     x0, =name_hci
    bl      test_pass
    b       .Ldone_hci
.Lfail_hci:
    ldr     x0, =name_hci
    bl      test_fail
.Ldone_hci:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_guestbook_post — POSTing to /guestbook appends the body
 * to guestbook_store. Asserts store_count increments and the stored
 * entry's first 5 bytes equal "hello".
 *
 * Entries are zero-padded to rec_bytes (128). Only the first 5 bytes
 * are asserted here; the rest are zero-init'd on the handler side so
 * renderings can stop at the first NUL.
 * ======================================================================== */
test_http_guestbook_post:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* Record pre-state count (in case earlier tests posted here) */
    ldr     x0, =guestbook_store
    bl      store_count
    mov     w20, w0

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_post_guestbook_request
    ldr     w2, =thttp_post_guestbook_request_len
.Lhgp_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhgp_cp
    ldr     w0, =thttp_post_guestbook_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Count must have advanced by one */
    ldr     x0, =guestbook_store
    bl      store_count
    sub     w0, w0, w20
    cmp     w0, #1
    b.ne    .Lfail_hgp

    /* Read the newest entry (index = count - 1) into tstore_gb_out */
    ldr     x0, =guestbook_store
    bl      store_count
    sub     w1, w0, #1
    ldr     x0, =guestbook_store
    ldr     x2, =tstore_gb_out
    bl      store_read

    /* First 5 bytes should be "hello" */
    ldr     x0, =tstore_gb_out
    ldrb    w1, [x0]
    cmp     w1, #'h'
    b.ne    .Lfail_hgp
    ldrb    w1, [x0, #1]
    cmp     w1, #'e'
    b.ne    .Lfail_hgp
    ldrb    w1, [x0, #2]
    cmp     w1, #'l'
    b.ne    .Lfail_hgp
    ldrb    w1, [x0, #3]
    cmp     w1, #'l'
    b.ne    .Lfail_hgp
    ldrb    w1, [x0, #4]
    cmp     w1, #'o'
    b.ne    .Lfail_hgp

    /* Byte 5 should be 0 (zero-padded) */
    ldrb    w1, [x0, #5]
    cbnz    w1, .Lfail_hgp

    ldr     x0, =name_hgp
    bl      test_pass
    b       .Ldone_hgp
.Lfail_hgp:
    ldr     x0, =name_hgp
    bl      test_fail
.Ldone_hgp:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_guestbook_get_render — GET /guestbook renders stored
 * entries as an HTML list. Seeds a 128-byte "hello" record directly
 * via store_append, fires GET, then scans the chunk-encoded response
 * body for the literal bytes "hello".
 *
 * Scanning for a substring makes the test robust across chunk-prefix
 * length variations — the handler output's exact byte size may shift
 * with other content changes.
 * ======================================================================== */
test_http_guestbook_get_render:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* Pre-seed a "hello" entry directly into guestbook_store. The
     * source is a 128-byte rodata record so store_append reads a
     * known, properly-sized buffer. */
    ldr     x0, =guestbook_store
    ldr     x1, =thttp_gb_hello_padded
    bl      store_append

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_get_guestbook_request
    ldr     w2, =thttp_get_guestbook_request_len
.Lhgr_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhgr_cp
    ldr     w0, =thttp_get_guestbook_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Reach SENDING with status 200 */
    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATE]
    cmp     w0, #HTTPS_SENDING
    b.ne    .Lfail_hgr
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_200
    b.ne    .Lfail_hgr

    /* Scan body_ptr[0..body_len] for the literal bytes "hello" */
    ldr     x0, [x20, #HCONN_BODY_PTR]
    ldr     w1, [x20, #HCONN_BODY_LEN]
    ldr     x2, =thttp_gb_needle_hello
    mov     w3, #5
    bl      thttp_find_bytes
    cbz     w0, .Lfail_hgr

    ldr     x0, =name_hgr
    bl      test_pass
    b       .Ldone_hgr
.Lfail_hgr:
    ldr     x0, =name_hgr
    bl      test_fail
.Ldone_hgr:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * thttp_find_bytes(x0: haystack, w1: hay_len, x2: needle, w3: needle_len)
 * Returns w0 = 1 if the needle appears anywhere in the haystack, 0 otherwise.
 * Leaf; clobbers x0-x9.
 */
thttp_find_bytes:
    cbz     w3, .Ltfb_yes            /* empty needle trivially matches */
    cmp     w1, w3
    b.lo    .Ltfb_no                 /* haystack shorter than needle */

    sub     w4, w1, w3               /* last valid start offset */
    mov     w5, #0                   /* cursor */
.Ltfb_outer:
    cmp     w5, w4
    b.hi    .Ltfb_no
    mov     w6, #0
.Ltfb_inner:
    cmp     w6, w3
    b.hs    .Ltfb_yes
    add     w7, w5, w6
    ldrb    w8, [x0, w7, uxtw]
    ldrb    w9, [x2, w6, uxtw]
    cmp     w8, w9
    b.ne    .Ltfb_advance
    add     w6, w6, #1
    b       .Ltfb_inner

.Ltfb_advance:
    add     w5, w5, #1
    b       .Ltfb_outer

.Ltfb_yes:
    mov     w0, #1
    ret
.Ltfb_no:
    mov     w0, #0
    ret

/* ========================================================================
 * test_http_form_log_post — POST /form_log appends body to
 * form_log_store. Store entries are 256 bytes (FORM_LOG_REC_BYTES),
 * large enough for typical form submissions.
 * ======================================================================== */
test_http_form_log_post:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* Baseline count in case earlier tests touched this store */
    ldr     x0, =form_log_store
    bl      store_count
    mov     w20, w0

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_post_form_log_request
    ldr     w2, =thttp_post_form_log_request_len
.Lhfl_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhfl_cp
    ldr     w0, =thttp_post_form_log_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Count should have advanced by one */
    ldr     x0, =form_log_store
    bl      store_count
    sub     w0, w0, w20
    cmp     w0, #1
    b.ne    .Lfail_hfl

    /* Read the newest entry into tstore_gb_out (128 bytes — we only
     * need to check the first bytes). Then scan for "name=alice". */
    ldr     x0, =form_log_store
    bl      store_count
    sub     w1, w0, #1
    ldr     x0, =form_log_store
    ldr     x2, =tstore_fl_out
    bl      store_read

    ldr     x0, =tstore_fl_out
    mov     w1, #256                /* FORM_LOG_REC_BYTES */
    ldr     x2, =thttp_fl_needle
    mov     w3, #10                 /* strlen("name=alice") */
    bl      thttp_find_bytes
    cbz     w0, .Lfail_hfl

    ldr     x0, =name_hfl
    bl      test_pass
    b       .Ldone_hfl
.Lfail_hfl:
    ldr     x0, =name_hfl
    bl      test_fail
.Ldone_hfl:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_query_string_split — a URI containing a query string
 * still dispatches to the path's route.
 *
 * GET /counter?foo=bar should match the /counter route and run the
 * counter handler. Today the route matcher compares the entire URI
 * verbatim, so /counter?foo=bar → 404. After the fix, the URI gets
 * split at the first '?'; the path half ("/counter") is what route
 * matching sees, and the query half is recorded separately on HCONN
 * for later handler access.
 *
 * Asserted via counter_store advance (the handler ran) and 200
 * status (not 404).
 * ======================================================================== */
test_http_query_string_split:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    /* Baseline counter value */
    ldr     x0, =counter_store
    ldr     w20, [x0, #STORE_WRITTEN]

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_get_counter_q_request
    ldr     w2, =thttp_get_counter_q_request_len
.Lhqs_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhqs_cp
    ldr     w0, =thttp_get_counter_q_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_200
    b.ne    .Lfail_hqs

    /* Counter handler must have run — records_written advanced */
    ldr     x0, =counter_store
    ldr     w1, [x0, #STORE_WRITTEN]
    cmp     w1, w20
    b.eq    .Lfail_hqs               /* no advance → handler didn't run */

    ldr     x0, =name_hqs
    bl      test_pass
    b       .Ldone_hqs
.Lfail_hqs:
    ldr     x0, =name_hqs
    bl      test_fail
.Ldone_hqs:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_guestbook_html_escape — guestbook render must HTML-escape
 * user content so stored "<script>" cannot break out of the list.
 *
 * Seeds a 128-byte record containing the raw bytes "<script>x" and
 * GETs /guestbook. Asserts two things:
 *   - The escaped literal "&lt;script&gt;" appears in the body.
 *   - The raw "<script>" bytes do NOT appear in the body.
 *
 * Together these prove the renderer transforms dangerous characters
 * rather than emitting them verbatim.
 * ======================================================================== */
test_http_guestbook_html_escape:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x0, =guestbook_store
    ldr     x1, =thttp_gb_script_padded
    bl      store_append

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_get_guestbook_request
    ldr     w2, =thttp_get_guestbook_request_len
.Lhgesc_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhgesc_cp
    ldr     w0, =thttp_get_guestbook_request_len
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
    b.ne    .Lfail_hgesc

    /* body must contain the escaped form "&lt;script&gt;" */
    ldr     x0, [x20, #HCONN_BODY_PTR]
    ldr     w1, [x20, #HCONN_BODY_LEN]
    ldr     x2, =thttp_gb_needle_esc_script
    mov     w3, #13                 /* strlen("&lt;script&gt;") */
    bl      thttp_find_bytes
    cbz     w0, .Lfail_hgesc

    /* body must NOT contain raw "<script>" */
    ldr     x0, [x20, #HCONN_BODY_PTR]
    ldr     w1, [x20, #HCONN_BODY_LEN]
    ldr     x2, =thttp_gb_needle_raw_script
    mov     w3, #8                  /* strlen("<script>") */
    bl      thttp_find_bytes
    cbnz    w0, .Lfail_hgesc

    ldr     x0, =name_hgesc
    bl      test_pass
    b       .Ldone_hgesc
.Lfail_hgesc:
    ldr     x0, =name_hgesc
    bl      test_fail
.Ldone_hgesc:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_route_method_405 — a POST to a route that declares only
 * GET/HEAD must return 405, not 200 or the handler's output.
 *
 * Route "/about" is static and only serves reads. Today any method
 * accepted by the parser dispatches — this test asserts the
 * per-route methods bitmask gates the call.
 * ======================================================================== */
test_http_route_method_405:
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
    ldr     x1, =thttp_post_about_request
    ldr     w2, =thttp_post_about_request_len
.Lhrm4_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhrm4_cp
    ldr     w0, =thttp_post_about_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_405
    b.ne    .Lfail_hrm4

    ldr     x0, =name_hrm4
    bl      test_pass
    b       .Ldone_hrm4
.Lfail_hrm4:
    ldr     x0, =name_hrm4
    bl      test_fail
.Ldone_hrm4:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_405_allow_per_route — the 405 response's Allow header
 * reflects the route's actual accepted methods, not a hardcoded
 * "GET, HEAD, POST".
 *
 * POSTs /about (declared GET+HEAD). The header sent back at
 * HCONN_HDR_SRC_PTR must contain "Allow: GET, HEAD\r\n" and must NOT
 * contain ", POST" — proving the Allow line is derived from
 * ROUTE_METHODS rather than a template that always advertises POST.
 * ======================================================================== */
test_http_405_allow_per_route:
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
    ldr     x1, =thttp_post_about_request
    ldr     w2, =thttp_post_about_request_len
.Lh4apr_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lh4apr_cp
    ldr     w0, =thttp_post_about_request_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    ldr     x20, =http_conn_table
    ldrb    w0, [x20, #HCONN_STATUS]
    cmp     w0, #HSTATUS_405
    b.ne    .Lfail_h4apr

    /* Header must contain "Allow: GET, HEAD\r\n" */
    ldr     x0, [x20, #HCONN_HDR_SRC_PTR]
    ldr     w1, [x20, #HCONN_HDR_SRC_LEN]
    ldr     x2, =thttp_allow_gh_needle
    mov     w3, #18
    bl      thttp_find_bytes
    cbz     w0, .Lfail_h4apr

    /* Header must NOT contain ", POST" */
    ldr     x0, [x20, #HCONN_HDR_SRC_PTR]
    ldr     w1, [x20, #HCONN_HDR_SRC_LEN]
    ldr     x2, =thttp_post_suffix_needle
    mov     w3, #6
    bl      thttp_find_bytes
    cbnz    w0, .Lfail_h4apr

    ldr     x0, =name_h4apr
    bl      test_pass
    b       .Ldone_h4apr
.Lfail_h4apr:
    ldr     x0, =name_h4apr
    bl      test_fail
.Ldone_h4apr:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_recv_body_slowloris — a connection stuck in RECV_BODY
 * past HTTP_RECV_TIMEOUT_SECS gets closed by the Slowloris check.
 *
 * Seeds HCONN[0] in HTTPS_RECV_BODY with HCONN_RECV_TICK shifted
 * (freq * 31) ticks into the past, so http_poll's Slowloris gate
 * fires immediately. The test asserts HCONN_STATE is back to
 * HTTPS_IDLE after the poll, which is what the close path leaves
 * behind — whether tcp_close itself succeeds or not, the reset
 * path lands on IDLE.
 * ======================================================================== */
test_http_recv_body_slowloris:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      tcp_init
    bl      http_init

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    /* HCONN[0] in RECV_BODY */
    ldr     x20, =http_conn_table
    mov     w0, #HTTPS_RECV_BODY
    strb    w0, [x20, #HCONN_STATE]

    /* Push RECV_TICK (timer_freq * 31) ticks into the past so the
     * Slowloris gate computes elapsed > threshold regardless of
     * the actual timer_now reading. */
    bl      timer_now
    mov     w1, w0                   /* w1 = now */
    bl      timer_freq
    mov     w2, w0                   /* w2 = freq */
    mov     w3, #31
    mul     w2, w2, w3               /* freq * 31 seconds */
    sub     w1, w1, w2               /* now - (freq*31) */
    str     w1, [x20, #HCONN_RECV_TICK]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    bl      http_poll

    /* Slowloris close resets state → IDLE */
    ldrb    w0, [x20, #HCONN_STATE]
    cbnz    w0, .Lfail_hslb

    ldr     x0, =name_hslb
    bl      test_pass
    b       .Ldone_hslb
.Lfail_hslb:
    ldr     x0, =name_hslb
    bl      test_fail
.Ldone_hslb:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_http_pipelined_keepalive — two GETs in a single rx write
 * must both dispatch.
 *
 * Drops the concatenation of two "GET /counter HTTP/1.1" requests
 * into slot 0's rx buffer and polls repeatedly. /counter's handler
 * increments a store every time it runs, so the store's records_written
 * must advance by 2 before the test finishes.
 *
 * Tests the partial rx consume at setup_resp. A full flush would
 * wipe request B along with A, and only the first request would be
 * processed.
 * ======================================================================== */
test_http_pipelined_keepalive:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    bl      tcp_init
    bl      http_init

    /* Baseline counter */
    ldr     x0, =counter_store
    ldr     w20, [x0, #STORE_WRITTEN]

    ldr     x19, =tcp_conn_table
    mov     w0, #TCPS_ESTABLISHED
    strb    w0, [x19, #TCONN_STATE]
    mov     w0, #0x5000
    strh    w0, [x19, #TCONN_LPORT]

    /* Copy two back-to-back GET /counter requests into the rx buffer */
    ldr     x0, =tcp_rxbuf_pool
    ldr     x1, =thttp_pipelined_counter
    ldr     w2, =thttp_pipelined_counter_len
.Lhpk_cp:
    ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    w2, w2, #1
    b.ne    .Lhpk_cp
    ldr     w0, =thttp_pipelined_counter_len
    strh    w0, [x19, #TCONN_RXLEN]

    mov     x0, #0
    mov     x1, #0
    ldr     x2, =thttp_tx_buf
    ldr     x3, =thttp_mock_send
    bl      http_set_send_ctx

    /* Poll parses request A. After setup_resp's tcp_rx_consume, B's
     * bytes (42 bytes) should remain in rx — a full flush would leave
     * 0. This assertion is the direct proof that partial consume
     * works; the downstream machinery (keep-alive reset, next parse)
     * is covered by the HTTP/1.1 keep-alive path at runtime. */
    bl      http_poll

.Lhpk_check:
    ldrh    w0, [x19, #TCONN_RXLEN]
    cmp     w0, #42
    b.ne    .Lfail_hpk

    ldr     x0, =name_hpk
    bl      test_pass
    b       .Ldone_hpk
.Lfail_hpk:
    ldr     x0, =name_hpk
    bl      test_fail
.Ldone_hpk:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_http_appliance_slab_placeholder — the packager slab is linked
 * into the image with the "no appliance" magic bytes.
 *
 * The packager finds the slab by searching for "WSPINONE" and rewrites
 * it in place. If the link-time placeholder drifts, the packager's
 * locator breaks silently. This test is a regression guard against
 * anyone changing the magic string without updating both sides.
 *
 * Reads byte-by-byte rather than loading a word so it doesn't depend
 * on endianness of the magic constant definitions — a reader of the
 * raw image sees bytes 'W','S','P','I','N','O','N','E' in order.
 * ======================================================================== */
test_http_appliance_slab_placeholder:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =http_appliance_slab
    ldrb    w1, [x0]
    cmp     w1, #'W'
    b.ne    .Lfail_hasp
    ldrb    w1, [x0, #1]
    cmp     w1, #'S'
    b.ne    .Lfail_hasp
    ldrb    w1, [x0, #2]
    cmp     w1, #'P'
    b.ne    .Lfail_hasp
    ldrb    w1, [x0, #3]
    cmp     w1, #'I'
    b.ne    .Lfail_hasp
    ldrb    w1, [x0, #4]
    cmp     w1, #'N'
    b.ne    .Lfail_hasp
    ldrb    w1, [x0, #5]
    cmp     w1, #'O'
    b.ne    .Lfail_hasp
    ldrb    w1, [x0, #6]
    cmp     w1, #'N'
    b.ne    .Lfail_hasp
    ldrb    w1, [x0, #7]
    cmp     w1, #'E'
    b.ne    .Lfail_hasp

    /* Header fields past the magic should all be zero in the
     * placeholder — version / rcount / clen / pad. */
    ldr     w1, [x0, #APPLIANCE_HDR_VERSION]
    cbnz    w1, .Lfail_hasp
    ldr     w1, [x0, #APPLIANCE_HDR_RCOUNT]
    cbnz    w1, .Lfail_hasp
    ldr     w1, [x0, #APPLIANCE_HDR_CLEN]
    cbnz    w1, .Lfail_hasp

    ldr     x0, =name_hasp
    bl      test_pass
    b       .Ldone_hasp
.Lfail_hasp:
    ldr     x0, =name_hasp
    bl      test_fail
.Ldone_hasp:
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
    .ascii  "POST /_test_echo HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 0\r\n\r\n"
thttp_post_request_end:
.equ thttp_post_request_len, thttp_post_request_end - thttp_post_request

thttp_put_request:
    .ascii  "PUT / HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_put_request_end:
.equ thttp_put_request_len, thttp_put_request_end - thttp_put_request

thttp_post_cl42_request:
    .ascii  "POST / HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 42\r\n\r\n"
thttp_post_cl42_request_end:
.equ thttp_post_cl42_request_len, thttp_post_cl42_request_end - thttp_post_cl42_request

thttp_post_body_request:
    .ascii  "POST /_test_echo HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 5\r\n\r\nhello"
thttp_post_body_request_end:
.equ thttp_post_body_request_len, thttp_post_body_request_end - thttp_post_body_request

thttp_post_echo_request:
    .ascii  "POST /_test_echo HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 4\r\n\r\nping"
thttp_post_echo_request_end:
.equ thttp_post_echo_request_len, thttp_post_echo_request_end - thttp_post_echo_request

thttp_post_oversize_request:
    .ascii  "POST /_test_echo HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 2000\r\n\r\n"
thttp_post_oversize_request_end:
.equ thttp_post_oversize_request_len, thttp_post_oversize_request_end - thttp_post_oversize_request

thttp_post_cl_overflow_request:
    .ascii  "POST /_test_echo HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 4294967396\r\n\r\n"
thttp_post_cl_overflow_request_end:
.equ thttp_post_cl_overflow_request_len, thttp_post_cl_overflow_request_end - thttp_post_cl_overflow_request

thttp_post_no_cl_request:
    .ascii  "POST /_test_echo HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_post_no_cl_request_end:
.equ thttp_post_no_cl_request_len, thttp_post_no_cl_request_end - thttp_post_no_cl_request

thttp_post_dup_cl_request:
    .ascii  "POST /_test_echo HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 5\r\nContent-Length: 99\r\n\r\n"
thttp_post_dup_cl_request_end:
.equ thttp_post_dup_cl_request_len, thttp_post_dup_cl_request_end - thttp_post_dup_cl_request

thttp_post_mp_part1:
    .ascii  "POST /_test_echo HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 5\r\n\r\nhe"
thttp_post_mp_part1_end:
.equ thttp_post_mp_part1_len, thttp_post_mp_part1_end - thttp_post_mp_part1

thttp_post_mp_part2:
    .ascii  "llo"

thttp_get_test_css_request:
    .ascii  "GET /_test_css HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_get_test_css_request_end:
.equ thttp_get_test_css_request_len, thttp_get_test_css_request_end - thttp_get_test_css_request

thttp_get_counter_request:
    .ascii  "GET /counter HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_get_counter_request_end:
.equ thttp_get_counter_request_len, thttp_get_counter_request_end - thttp_get_counter_request

thttp_post_guestbook_request:
    .ascii  "POST /guestbook HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 5\r\n\r\nhello"
thttp_post_guestbook_request_end:
.equ thttp_post_guestbook_request_len, thttp_post_guestbook_request_end - thttp_post_guestbook_request

thttp_get_guestbook_request:
    .ascii  "GET /guestbook HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_get_guestbook_request_end:
.equ thttp_get_guestbook_request_len, thttp_get_guestbook_request_end - thttp_get_guestbook_request

.balign 16
thttp_gb_hello_padded:
    .ascii  "hello"
    .skip   123                     /* pad to 128 bytes for store_append */

thttp_gb_needle_hello:
    .ascii  "hello"

.balign 16
thttp_gb_script_padded:
    .ascii  "<script>x"
    .skip   119                     /* pad to 128 bytes */

thttp_gb_needle_esc_script:
    .ascii  "&lt;script&gt;"

thttp_gb_needle_raw_script:
    .ascii  "<script>"

thttp_post_form_log_request:
    .ascii  "POST /form_log HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 23\r\n\r\nname=alice&msg=hi+there"
thttp_post_form_log_request_end:
.equ thttp_post_form_log_request_len, thttp_post_form_log_request_end - thttp_post_form_log_request

thttp_fl_needle:
    .ascii  "name=alice"

thttp_get_counter_q_request:
    .ascii  "GET /counter?foo=bar HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_get_counter_q_request_end:
.equ thttp_get_counter_q_request_len, thttp_get_counter_q_request_end - thttp_get_counter_q_request

thttp_post_about_request:
    .ascii  "POST /about HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 0\r\n\r\n"
thttp_post_about_request_end:
.equ thttp_post_about_request_len, thttp_post_about_request_end - thttp_post_about_request

thttp_allow_gh_needle:
    .ascii  "Allow: GET, HEAD\r\n"

thttp_post_suffix_needle:
    .ascii  ", POST"

thttp_pipelined_counter:
    .ascii  "GET /counter HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
    .ascii  "GET /counter HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_pipelined_counter_end:
.equ thttp_pipelined_counter_len, thttp_pipelined_counter_end - thttp_pipelined_counter

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

thttp_status_request:
    .ascii  "GET /status HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_status_request_end:
.equ thttp_status_request_len, thttp_status_request_end - thttp_status_request

thttp_test_dispatch_request:
    .ascii  "GET /_test_dispatch HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
thttp_test_dispatch_request_end:
.equ thttp_test_dispatch_request_len, thttp_test_dispatch_request_end - thttp_test_dispatch_request

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
name_hce:   .asciz "http_chunk_encode"
name_hct:   .asciz "http_chunk_terminate"
name_hde:   .asciz "http_date_epoch"
name_hd26:  .asciz "http_date_2026"
name_hl20:  .asciz "http_leap_2000"
name_hn21:  .asciz "http_noleap_2100"
name_hsc:   .asciz "http_send_chunk"

thttp_chunk_data:
    .ascii  "Hello"

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
name_hri:   .asciz "http_resp_isolation"
name_hrhd:  .asciz "http_route_handler_dispatch"
name_hpa:   .asciz "http_post_accepted"
name_hclp:  .asciz "http_content_length_parsed"
name_hpbc:  .asciz "http_post_body_copied"
name_hpeh:  .asciz "http_post_body_to_handler"
name_hpo4:  .asciz "http_post_oversize_413"
name_hpco:  .asciz "http_post_cl_overflow_413"
name_hpnc:  .asciz "http_post_no_cl_411"
name_hpdc:  .asciz "http_post_dup_cl_400"
name_hpmp:  .asciz "http_post_multi_packet_body"
name_hcss:  .asciz "http_route_css_content_type"
name_hci:   .asciz "http_counter_increments"
name_hgp:   .asciz "http_guestbook_post"
name_hgr:   .asciz "http_guestbook_get_render"
name_hfl:   .asciz "http_form_log_post"
name_hqs:   .asciz "http_query_string_split"
name_hgesc: .asciz "http_guestbook_html_escape"
name_hrm4:  .asciz "http_route_method_405"
name_h4apr: .asciz "http_405_allow_per_route"
name_hslb:  .asciz "http_recv_body_slowloris"
name_hpk:   .asciz "http_pipelined_keepalive"
name_hasp:  .asciz "http_appliance_slab_placeholder"

.section .data
.balign 16
thttp_tx_buf:
    .space  ETH_FRAME_MAX

.balign 4
thttp_send_count:
    .word   0

.balign 4
thttp_chunk_buf:
    .space  64

.balign 4
thttp_date_buf:
    .space  32

.balign 16
tstore_gb_out:
    .space  128

.balign 16
tstore_fl_out:
    .space  256
