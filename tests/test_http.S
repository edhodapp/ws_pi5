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
    add     x0, x0, #(HTTP_CONN_TABLE_SIZE - HCONN_SIZE)
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

    /* Status should be 1 (404) */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATUS]
    cmp     w0, #1
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

    /* Status should be 1 (404 — bad method) */
    ldr     x0, =http_conn_table
    ldrb    w0, [x0, #HCONN_STATUS]
    cmp     w0, #1
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

.section .data
.balign 16
thttp_tx_buf:
    .space  ETH_FRAME_MAX
