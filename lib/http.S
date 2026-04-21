/*
 * http.S — HTTP/1.1 server for bare-metal web serving
 *
 * Cooperative poll-based architecture: http_poll scans connections,
 * parses requests from TCP rx buffers, and sends responses one chunk
 * at a time via tcp_send.
 */

.include "net.inc"
.include "tcp.inc"
.include "http.inc"

.global http_init
.global http_set_send_ctx
.global http_poll
.global http_conn_table
.global http_send_ctx
.global http_find_end_of_headers
.global http_find_uri_end
.global http_match_uri
.global http_find_host_header
.global http_update_date
.global http_test_dispatch_handler
.global http_test_echo_handler
.global http_body_recv_bufs

.section .text

/*
 * http_init — Zero the HTTP connection table
 * Clobbers: x0-x1
 */
http_init:
    ldr     x0, =http_conn_table
    mov     w1, #(HTTP_CONN_TABLE_SIZE / 8)
.Lhi_zero:
    str     xzr, [x0], #8
    subs    w1, w1, #1
    b.ne    .Lhi_zero
    ret

/*
 * http_set_send_ctx — Store I/O context for response sending
 *
 * x0: DWC2 base, x1: ecm_state, x2: tx_buf, x3: send_fn
 * Clobbers: x4
 */
http_set_send_ctx:
    ldr     x4, =http_send_ctx
    str     x0, [x4, #HSCTX_DWC2_BASE]
    str     x1, [x4, #HSCTX_ECM_STATE]
    str     x2, [x4, #HSCTX_TX_BUF]
    str     x3, [x4, #HSCTX_SEND_FN]
    ret

/*
 * http_poll — Scan connections: parse requests, send responses
 *
 * Called from net_loop on every iteration.
 * Clobbers: x0-x9, x19-x24, x30 (x7-x9 scratch for dynamic dispatch)
 */
http_poll:
    stp     x29, x30, [sp, #-96]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    /* sp+64..95: scratch space for request parsing */

    ldr     x19, =tcp_conn_table
    ldr     x20, =http_conn_table
    mov     w21, #HTTP_MAX_CONNS

.Lhp_loop:
    cbz     w21, .Lhp_done
    sub     w21, w21, #1

    /* Check TCP state */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lhp_not_estab

    /* Check HTTP state */
    ldrb    w0, [x20, #HCONN_STATE]

    /* IDLE + ESTABLISHED → start receiving headers */
    cbz     w0, .Lhp_start_recv

    /* RECV_HDR → try to parse */
    cmp     w0, #HTTPS_RECV_HDR
    b.eq    .Lhp_try_parse

    /* SENDING → send next chunk */
    cmp     w0, #HTTPS_SENDING
    b.eq    .Lhp_send_chunk

    /* RECV_BODY → resume body accumulation */
    cmp     w0, #HTTPS_RECV_BODY
    b.eq    .Lhp_resume_body

    b       .Lhp_next

.Lhp_not_estab:
    /* Connection not ESTABLISHED — if HCONN not IDLE, reset it */
    ldrb    w0, [x20, #HCONN_STATE]
    cbz     w0, .Lhp_next
    strb    wzr, [x20, #HCONN_STATE]    /* reset to IDLE */
    b       .Lhp_next

.Lhp_start_recv:
    mov     w0, #HTTPS_RECV_HDR
    strb    w0, [x20, #HCONN_STATE]
    /* Record start time for Slowloris timeout */
    bl      timer_now
    str     w0, [x20, #HCONN_RECV_TICK]
    /* Fall through to try_parse — data may already be in rx buffer */

.Lhp_try_parse:
    /* Slowloris check: close RECV_HDR connections older than 30s.
     * elapsed = timer_now() - RECV_TICK
     * threshold = timer_freq() * HTTP_RECV_TIMEOUT_SECS */
    bl      timer_now
    ldr     w1, [x20, #HCONN_RECV_TICK]
    sub     w24, w0, w1             /* w24 = elapsed ticks */
    bl      timer_freq
    mov     w1, #HTTP_RECV_TIMEOUT_SECS
    mul     w0, w0, w1              /* w0 = threshold ticks */
    cmp     w24, w0
    b.hs    .Lhp_slowloris_close

    /* Check if there's data in the rx buffer */
    ldrh    w0, [x19, #TCONN_RXLEN]
    cbz     w0, .Lhp_next

    /* Peek rx buffer */
    mov     x0, x19
    bl      tcp_rx_peek
    mov     x22, x0                     /* x22 = buf ptr */
    mov     w23, w1                     /* w23 = data len */

    /* Run the FSA parser (state persists in HCONN across calls) */
    mov     x0, x20                     /* HCONN */
    mov     x1, x22                     /* buf */
    mov     w2, w23                     /* len */
    bl      http_parse_request

    /* Check parser result */
    cmp     w0, #S_DONE
    b.eq    .Lhp_fsa_done
    cmp     w0, #S_ERROR
    b.eq    .Lhp_bad_request
    b       .Lhp_next                   /* need more data */

.Lhp_resume_body:
    /* Slowloris also applies to RECV_BODY: a client that trickles the
     * body across packets must still complete within the total recv
     * window (measured from when RECV_HDR started). Same timer, same
     * threshold. */
    bl      timer_now
    ldr     w1, [x20, #HCONN_RECV_TICK]
    sub     w24, w0, w1
    bl      timer_freq
    mov     w1, #HTTP_RECV_TIMEOUT_SECS
    mul     w0, w0, w1
    cmp     w24, w0
    b.hs    .Lhp_slowloris_close

    /* If no new data, stay in RECV_BODY */
    ldrh    w0, [x19, #TCONN_RXLEN]
    cbz     w0, .Lhp_next
    mov     x0, x19
    bl      tcp_rx_peek
    mov     x22, x0
    mov     w23, w1
    /* Re-enter the body-check block; header fields on HCONN are
     * unchanged since the first time we reached S_DONE. */
    b       .Lhp_body_check

.Lhp_fsa_done:
    /* --- FSA completed: extract fields and set up response ---
     *
     * HCONN parser fields: URI_START, URI_LEN, VER_MINOR,
     * HOST_FOUND. Method identified by comparing raw bytes.
     *
     * The FSA validates structure but not the specific "HTTP/"
     * prefix characters (it accepts any ALPHA in those positions).
     * Validate the prefix here. Version starts at:
     * URI_START + URI_LEN + 1 (space after URI). */
    ldrh    w0, [x20, #HCONN_URI_START]
    ldrh    w1, [x20, #HCONN_URI_LEN]
    add     w0, w0, w1
    add     w0, w0, #1                  /* offset of 'H' in "HTTP/" */
    ldrb    w1, [x22, w0, uxtw]
    cmp     w1, #'H'
    b.ne    .Lhp_bad_request
    add     w0, w0, #1
    ldrb    w1, [x22, w0, uxtw]
    cmp     w1, #'T'
    b.ne    .Lhp_bad_request
    add     w0, w0, #1
    ldrb    w1, [x22, w0, uxtw]
    cmp     w1, #'T'
    b.ne    .Lhp_bad_request
    add     w0, w0, #1
    ldrb    w1, [x22, w0, uxtw]
    cmp     w1, #'P'
    b.ne    .Lhp_bad_request

    /* HCONN_FLAGS is cleared at request-start boundaries
     * (.Lhp_close keep-alive and .Lhp_reset_hconn), and the parser
     * may have set HFLAG_CL_SEEN during header processing. Preserve
     * what's there; OR in the bits the dispatcher owns below. */

    /* HTTP/1.1 if VER_MINOR == '1' */
    ldrb    w0, [x20, #HCONN_VER_MINOR]
    cmp     w0, #'1'
    b.ne    .Lhp_ver_done
    ldrb    w0, [x20, #HCONN_FLAGS]
    orr     w0, w0, #HFLAG_HTTP11
    strb    w0, [x20, #HCONN_FLAGS]
.Lhp_ver_done:

    /* Identify method: "GET ", "HEAD ", or "POST " */
    ldr     w0, [x22]
    ldr     w1, =HTTP_GET_MARKER
    cmp     w0, w1
    b.eq    .Lhp_method_get

    ldr     w1, =HTTP_HEAD_MARK_LO
    cmp     w0, w1
    b.ne    .Lhp_check_post
    ldrb    w1, [x22, #4]
    cmp     w1, #HTTP_HEAD_SPACE
    b.ne    .Lhp_bad_method

    /* HEAD method */
    ldrb    w0, [x20, #HCONN_FLAGS]
    orr     w0, w0, #HFLAG_HEAD
    strb    w0, [x20, #HCONN_FLAGS]
    b       .Lhp_method_done

.Lhp_check_post:
    ldr     w1, =HTTP_POST_MARKER
    cmp     w0, w1
    b.ne    .Lhp_bad_method
    ldrb    w1, [x22, #4]
    cmp     w1, #HTTP_HEAD_SPACE
    b.ne    .Lhp_bad_method
    /* POST method — mark so the 411 check downstream can distinguish
     * from GET/HEAD (which don't require Content-Length). */
    ldrb    w0, [x20, #HCONN_FLAGS]
    orr     w0, w0, #HFLAG_POST
    strb    w0, [x20, #HCONN_FLAGS]
    b       .Lhp_method_done

.Lhp_method_get:
.Lhp_method_done:

    /* Host header check (HTTP/1.1 only) */
    ldrb    w0, [x20, #HCONN_FLAGS]
    tst     w0, #HFLAG_HTTP11
    b.eq    .Lhp_host_ok
    ldrb    w0, [x20, #HCONN_HOST_FOUND]
    cbz     w0, .Lhp_bad_request

.Lhp_host_ok:
    /* Determine Connection behavior:
     * - If client sent "Connection: close", set HFLAG_CLOSE
     * - If HTTP/1.0 (no HFLAG_HTTP11), set HFLAG_CLOSE
     * - Otherwise: persistent (HTTP/1.1 default) */
    ldrb    w0, [x20, #HCONN_CLOSE_FOUND]
    cbnz    w0, .Lhp_set_close

    ldrb    w0, [x20, #HCONN_FLAGS]
    tst     w0, #HFLAG_HTTP11
    b.ne    .Lhp_conn_done          /* HTTP/1.1 → persistent */

.Lhp_set_close:
    ldrb    w0, [x20, #HCONN_FLAGS]
    orr     w0, w0, #HFLAG_CLOSE
    strb    w0, [x20, #HCONN_FLAGS]
.Lhp_conn_done:

    /* POST requires Content-Length per RFC 7230 §3.3.3. If HFLAG_POST
     * is set but HFLAG_CL_SEEN is not, reject with 411 before any
     * body handling. */
    ldrb    w0, [x20, #HCONN_FLAGS]
    and     w1, w0, #(HFLAG_POST | HFLAG_CL_SEEN)
    cmp     w1, #HFLAG_POST
    b.eq    .Lhp_resp_411

    /* Body check. Reachable from fresh-dispatch (fall-through from the
     * 411 check above) and from .Lhp_resume_body when a HTTPS_RECV_BODY
     * connection sees new rx data. Bounds:
     *   - CL must fit the per-slot buffer (HTTP_MAX_RECV_BODY)
     *   - REQ_LEN + CL must fit the rx peek (w23); otherwise wait for
     *     more data via HTTPS_RECV_BODY. */
.Lhp_body_check:
    ldr     w0, [x20, #HCONN_CONTENT_LEN]
    cbz     w0, .Lhp_body_done
    cmp     w0, #HTTP_MAX_RECV_BODY
    b.hi    .Lhp_resp_413           /* oversize → reject */
    ldr     w1, [x20, #HCONN_REQ_LEN]
    add     w2, w1, w0
    cmp     w2, w23
    b.hi    .Lhp_wait_body          /* partial → wait for more rx */

    /* source = rx buffer + REQ_LEN */
    add     x2, x22, x1, uxtw

    /* dest = http_body_recv_bufs + (hconn_index << HTTP_MAX_RECV_BODY_SHIFT) */
    ldr     x3, =http_conn_table
    sub     x3, x20, x3
    lsr     x3, x3, #HCONN_SHIFT
    ldr     x4, =http_body_recv_bufs
    add     x3, x4, x3, lsl #HTTP_MAX_RECV_BODY_SHIFT

    /* Counter in w6 (not w4) to keep the base pointer in x4 live and
     * unambiguous above. */
    mov     w6, w0
.Lhp_body_cp:
    cbz     w6, .Lhp_body_done
    ldrb    w5, [x2], #1
    strb    w5, [x3], #1
    sub     w6, w6, #1
    b       .Lhp_body_cp

.Lhp_body_done:

    /* Increment request counter */
    ldr     x0, =http_request_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    /* Match URI against route table */
    ldrh    w24, [x20, #HCONN_URI_START]
    ldrh    w1, [x20, #HCONN_URI_LEN]
    add     x0, x22, x24, uxtw
    bl      http_match_uri
    /* x0 = route entry pointer, or 0 for 404 */

    cbz     x0, .Lhp_resp_404

    /* Route matched. Check if dynamic or static. */
    mov     w1, #HSTATUS_200
    strb    w1, [x20, #HCONN_STATUS]
    ldr     w1, [x0, #ROUTE_FLAGS]
    cbnz    w1, .Lhp_dynamic

    /* Static route: load body/header from route entry */
    ldr     x1, [x0, #ROUTE_BODY_PTR]
    ldr     w2, [x0, #ROUTE_BODY_LEN]
    ldr     x24, [x0, #ROUTE_HDR_PTR]
    ldr     w3, [x0, #ROUTE_HDR_LEN]
    b       .Lhp_setup_resp

.Lhp_dynamic:
    /* Dynamic route: generate body, chunk-encode, send as one response.
     * Each HCONN owns its own body/chunk scratch, so two concurrent
     * dynamic responses cannot stomp each other's bytes.
     *
     * 1. Compute this HCONN's per-way body_buf and chunk_buf addresses
     * 2. Generate body into per-way body_buf
     * 3. Chunk-encode into per-way chunk_buf
     * 4. Append terminator "0\r\n\r\n"
     * 5. Point HCONN body at the per-way chunk_buf */

    /* Compute hconn index = (x20 - http_conn_table) >> HCONN_SHIFT.
     * Invariant: x20 walks http_conn_table in HCONN_SIZE strides driven
     * by the poll loop at .Lhp_next, so x5 is always in [0, HTTP_MAX_CONNS). */
    ldr     x5, =http_conn_table
    sub     x5, x20, x5
    lsr     x5, x5, #HCONN_SHIFT    /* x5 = hconn_index */

    /* body_buf = http_dyn_body_bufs + (index * HTTP_DYN_BODY_SIZE) */
    ldr     x6, =http_dyn_body_bufs
    add     x6, x6, x5, lsl #HTTP_DYN_BODY_SHIFT

    /* chunk_buf = http_dyn_chunk_bufs + (index * HTTP_DYN_CHUNK_SIZE) */
    mov     w7, #HTTP_DYN_CHUNK_SIZE
    umull   x7, w5, w7
    ldr     x8, =http_dyn_chunk_bufs
    add     x7, x8, x7              /* x7 = per-way chunk_buf */

    /* Load the route's handler before saving x0, so the handler load
     * doesn't depend on the stp ordering. */
    ldr     x9, [x0, #ROUTE_HANDLER]

    /* Save route ptr, rx buf, body_buf, chunk_buf across function calls */
    stp     x0, x22, [sp, #64]
    stp     x6, x7, [sp, #80]

    /* Invoke handler(body_buf, max_len, hconn) → bytes written.
     * Handlers may read the POST body from http_body_recv_bufs at the
     * index derived from HCONN. Handlers that don't need HCONN simply
     * ignore x2 per AAPCS64. */
    mov     x0, x6                  /* body_buf */
    mov     w1, #HTTP_DYN_BODY_SIZE
    mov     x2, x20                 /* hconn */
    blr     x9                      /* w0 = body bytes */
    mov     w23, w0                 /* w23 = body_len */

    /* Chunk-encode body into per-way chunk_buf */
    ldr     x0, [sp, #88]           /* chunk_buf */
    ldr     x1, [sp, #80]           /* body_buf */
    mov     w2, w23
    bl      http_chunk_encode       /* w0 = chunk bytes */
    mov     w23, w0                 /* w23 = encoded chunk size */

    /* Append terminator */
    ldr     x0, [sp, #88]           /* chunk_buf */
    add     x0, x0, x23             /* after chunk data */
    bl      http_chunk_terminate    /* w0 = 5 */
    add     w23, w23, w0            /* total = chunk + terminator */

    /* Set up response from per-way chunk_buf */
    ldp     x0, x22, [sp, #64]      /* restore route ptr + rx buf */
    ldr     x1, [sp, #88]           /* body_ptr = per-way chunk_buf */
    mov     w2, w23
    ldr     x24, [x0, #ROUTE_HDR_PTR]
    ldr     w3, [x0, #ROUTE_HDR_LEN]
    b       .Lhp_setup_resp

.Lhp_resp_404:
    mov     w0, #HSTATUS_404
    strb    w0, [x20, #HCONN_STATUS]
    ldr     x1, =http_404_body
    ldr     w2, =http_404_body_len
    ldr     x24, =http_404_hdr
    ldr     w3, =http_404_hdr_len
    b       .Lhp_setup_resp

.Lhp_bad_method:
    mov     w0, #HSTATUS_405
    strb    w0, [x20, #HCONN_STATUS]
    ldr     x1, =http_405_body
    ldr     w2, =http_405_body_len
    ldr     x24, =http_405_hdr
    ldr     w3, =http_405_hdr_len
    b       .Lhp_setup_resp

.Lhp_bad_request:
    mov     w0, #HSTATUS_400
    strb    w0, [x20, #HCONN_STATUS]
    ldr     x1, =http_400_body
    ldr     w2, =http_400_body_len
    ldr     x24, =http_400_hdr
    ldr     w3, =http_400_hdr_len
    b       .Lhp_setup_resp

.Lhp_resp_411:
    /* POST without Content-Length. Force close — we don't know how
     * many body bytes (if any) the client is sending, so keep-alive
     * can't safely resume on this connection. */
    mov     w0, #HSTATUS_411
    strb    w0, [x20, #HCONN_STATUS]
    ldrb    w1, [x20, #HCONN_FLAGS]
    orr     w1, w1, #HFLAG_CLOSE
    strb    w1, [x20, #HCONN_FLAGS]
    ldr     x1, =http_411_body
    ldr     w2, =http_411_body_len
    ldr     x24, =http_411_hdr
    ldr     w3, =http_411_hdr_len
    b       .Lhp_setup_resp

.Lhp_resp_413:
    /* Oversize request body. Reject before body copy / dispatch.
     * Force connection close: the request body protocol is compromised
     * on this connection, so keep-alive would let a malicious client
     * keep sending more oversize POSTs. Matches the "Connection: close"
     * line baked into the 413 response header. */
    mov     w0, #HSTATUS_413
    strb    w0, [x20, #HCONN_STATUS]
    ldrb    w1, [x20, #HCONN_FLAGS]
    orr     w1, w1, #HFLAG_CLOSE
    strb    w1, [x20, #HCONN_FLAGS]
    ldr     x1, =http_413_body
    ldr     w2, =http_413_body_len
    ldr     x24, =http_413_hdr
    ldr     w3, =http_413_hdr_len
    b       .Lhp_setup_resp

.Lhp_setup_resp:
    str     x1, [x20, #HCONN_BODY_PTR]
    str     w2, [x20, #HCONN_BODY_LEN]
    str     x24, [x20, #HCONN_HDR_SRC_PTR]
    str     w3, [x20, #HCONN_HDR_SRC_LEN]
    /* HEAD: send headers only (Content-Length stays in header for RFC compliance).
     * GET/errors: send headers + body. */
    add     w4, w2, w3                  /* hdr + body */
    ldrb    w5, [x20, #HCONN_FLAGS]
    tst     w5, #HFLAG_HEAD
    csel    w4, w3, w4, ne              /* HEAD → hdr only; else hdr+body */
    str     w4, [x20, #HCONN_RESP_LEN]
    str     w3, [x20, #HCONN_HDR_LEN]
    str     wzr, [x20, #HCONN_RESP_PTR]
    mov     w0, #HTTPS_SENDING
    strb    w0, [x20, #HCONN_STATE]

    /* Flush rx buffer */
    mov     x0, x19
    bl      tcp_rx_flush

    b       .Lhp_next

/* (parse_incomplete removed — now branches directly to .Lhp_next) */

.Lhp_send_chunk:
    /* Check if connection is still ESTABLISHED */
    ldrb    w0, [x19, #TCONN_STATE]
    cmp     w0, #TCPS_ESTABLISHED
    b.ne    .Lhp_reset_hconn

    /* Check remaining */
    ldr     w22, [x20, #HCONN_RESP_PTR]
    ldr     w23, [x20, #HCONN_RESP_LEN]
    subs    w24, w23, w22               /* remaining */
    cbz     w24, .Lhp_close

    /* Check send window */
    mov     x0, x19
    bl      tcp_send_ready
    cbz     w0, .Lhp_next              /* window closed */

    /* chunk = min(ready, remaining) */
    cmp     w0, w24
    csel    w24, w0, w24, lo

    /* Determine source: header or body region */
    ldr     w1, [x20, #HCONN_HDR_LEN]
    cmp     w22, w1
    b.hs    .Lhp_from_body

    /* From header: truncate chunk at header boundary */
    sub     w2, w1, w22                 /* hdr_remaining */
    cmp     w24, w2
    csel    w24, w24, w2, lo

    /* Read header source from stored pointer */
    ldr     x2, [x20, #HCONN_HDR_SRC_PTR]
    add     x2, x2, x22
    b       .Lhp_do_send

.Lhp_from_body:
    ldr     x2, [x20, #HCONN_BODY_PTR]
    ldr     w1, [x20, #HCONN_HDR_LEN]
    sub     w3, w22, w1                 /* body offset */
    add     x2, x2, x3

.Lhp_do_send:
    /* tcp_send(conn, tx_buf, payload, len) */
    ldr     x23, =http_send_ctx
    mov     x0, x19
    ldr     x1, [x23, #HSCTX_TX_BUF]
    /* x2 = payload source (set above) */
    mov     w3, w24
    bl      tcp_send
    cbz     w0, .Lhp_next              /* send failed */
    mov     w22, w0                     /* frame_len */

    /* Transmit frame */
    ldr     x0, [x23, #HSCTX_DWC2_BASE]
    ldr     x1, [x23, #HSCTX_ECM_STATE]
    ldr     x2, [x23, #HSCTX_TX_BUF]
    mov     w3, w22
    ldr     x4, [x23, #HSCTX_SEND_FN]
    blr     x4

    /* Advance pointer */
    ldr     w0, [x20, #HCONN_RESP_PTR]
    add     w0, w0, w24
    str     w0, [x20, #HCONN_RESP_PTR]

    b       .Lhp_next

.Lhp_close:
    /* Response complete. Keep-alive or close?
     * Close if: HFLAG_CLOSE set, or HTTP/1.0 without explicit keep-alive.
     * For now: HTTP/1.1 default = persistent, HTTP/1.0 = close.
     * Connection: close from client overrides. */
    ldrb    w0, [x20, #HCONN_FLAGS]
    tst     w0, #HFLAG_CLOSE
    b.ne    .Lhp_do_close

    tst     w0, #HFLAG_HTTP11
    b.eq    .Lhp_do_close           /* HTTP/1.0 → close */

    /* Keep-alive: reset HCONN to RECV_HDR for next request.
     * Reset parser state so the FSA starts from S_METHOD. */
    mov     w0, #HTTPS_RECV_HDR
    strb    w0, [x20, #HCONN_STATE]
    strb    wzr, [x20, #HCONN_PARSE_STATE]
    strh    wzr, [x20, #HCONN_PARSE_OFF]
    strb    wzr, [x20, #HCONN_HOST_FOUND]
    strb    wzr, [x20, #HCONN_CLOSE_FOUND]
    strb    wzr, [x20, #HCONN_VER_MINOR]
    strb    wzr, [x20, #HCONN_FLAGS]
    str     wzr, [x20, #HCONN_CONTENT_LEN]

    /* Partial rx flush: consume only REQ_LEN bytes, preserving
     * any pipelined data after the current request.
     * TODO: implement partial flush in tcp layer. For now, full flush. */
    mov     x0, x19
    bl      tcp_rx_flush

    b       .Lhp_next

.Lhp_slowloris_close:
    /* Slowloris timeout — close without sending a response */
.Lhp_do_close:
    ldr     x23, =http_send_ctx
    mov     x0, x19
    ldr     x1, [x23, #HSCTX_TX_BUF]
    bl      tcp_close
    cbz     w0, .Lhp_reset_hconn

    /* Send FIN frame */
    mov     w22, w0
    ldr     x0, [x23, #HSCTX_DWC2_BASE]
    ldr     x1, [x23, #HSCTX_ECM_STATE]
    ldr     x2, [x23, #HSCTX_TX_BUF]
    mov     w3, w22
    ldr     x4, [x23, #HSCTX_SEND_FN]
    blr     x4

.Lhp_reset_hconn:
    strb    wzr, [x20, #HCONN_STATE]
    strb    wzr, [x20, #HCONN_FLAGS]
    str     wzr, [x20, #HCONN_CONTENT_LEN]
    b       .Lhp_next

.Lhp_wait_body:
    /* Body incomplete — park in HTTPS_RECV_BODY and let the next poll
     * iteration resume via .Lhp_resume_body when more rx arrives. */
    mov     w0, #HTTPS_RECV_BODY
    strb    w0, [x20, #HCONN_STATE]
    b       .Lhp_next

.Lhp_next:
    add     x19, x19, #TCONN_SIZE
    add     x20, x20, #HCONN_SIZE
    b       .Lhp_loop

.Lhp_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #96
    ret

/*
 * http_find_end_of_headers — Scan for \r\n\r\n in buffer
 *
 * x0: buffer, w1: length
 * Returns: w0 = offset of first byte PAST the \r\n\r\n, or -1 if not found
 * Clobbers: x0-x3
 */
http_find_end_of_headers:
    cmp     w1, #4
    b.lt    .Lfeh_not_found

    sub     w1, w1, #3              /* last valid start position */
    mov     w2, #0                  /* offset */

.Lfeh_scan:
    cmp     w2, w1
    b.hs    .Lfeh_not_found

    ldrb    w3, [x0, x2]
    cmp     w3, #0x0D              /* \r */
    b.ne    .Lfeh_next
    add     w3, w2, #1
    ldrb    w3, [x0, x3]
    cmp     w3, #0x0A              /* \n */
    b.ne    .Lfeh_next
    add     w3, w2, #2
    ldrb    w3, [x0, x3]
    cmp     w3, #0x0D              /* \r */
    b.ne    .Lfeh_next
    add     w3, w2, #3
    ldrb    w3, [x0, x3]
    cmp     w3, #0x0A              /* \n */
    b.ne    .Lfeh_next

    /* Found: return offset + 4 */
    add     w0, w2, #4
    ret

.Lfeh_next:
    add     w2, w2, #1
    b       .Lfeh_scan

.Lfeh_not_found:
    mov     w0, #-1
    ret

/*
 * http_find_uri_end — Find end of URI (next space after start)
 *
 * x0: URI start pointer, w1: max length
 * Returns: w0 = URI length (up to first space)
 * Clobbers: x0-x2
 */
http_find_uri_end:
    mov     w2, #0
.Lfue_scan:
    cmp     w2, w1
    b.hs    .Lfue_done
    ldrb    w3, [x0, x2]
    cmp     w3, #0x20              /* space */
    b.eq    .Lfue_done
    add     w2, w2, #1
    b       .Lfue_scan
.Lfue_done:
    mov     w0, w2
    ret

/*
 * http_match_uri — Match URI against route table
 *
 * x0: URI pointer, w1: URI length
 * Returns: x0 = route entry pointer, or 0 if no match (404)
 * Clobbers: x0-x8, x30
 */
http_match_uri:
    /* Scan route table for matching path.
     * x0: URI pointer, w1: URI length
     * Returns: x0 = route entry pointer (or 0 if no match)
     * Clobbers: x0-x5 */
    stp     x29, x30, [sp, #-16]!
    mov     x2, x0                 /* x2 = URI ptr */
    mov     w3, w1                 /* w3 = URI len */

    ldr     x4, =http_route_table
    ldr     w5, =http_route_count

.Lmu_scan:
    cbz     w5, .Lmu_404
    sub     w5, w5, #1

    /* Compare path_len */
    ldr     w0, [x4, #ROUTE_PATH_LEN]
    cmp     w0, w3
    b.ne    .Lmu_next

    /* Length matches — compare bytes */
    ldr     x1, [x4, #ROUTE_PATH_PTR]
    mov     w6, #0
.Lmu_cmp:
    cmp     w6, w0
    b.hs    .Lmu_found
    ldrb    w7, [x2, x6]
    ldrb    w8, [x1, x6]
    cmp     w7, w8
    b.ne    .Lmu_next
    add     w6, w6, #1
    b       .Lmu_cmp

.Lmu_found:
    mov     x0, x4                 /* return route pointer */
    ldp     x29, x30, [sp], #16
    ret

.Lmu_next:
    add     x4, x4, #ROUTE_SIZE
    b       .Lmu_scan

.Lmu_404:
    mov     x0, #0                 /* no match */
    ldp     x29, x30, [sp], #16
    ret

/*
 * http_find_host_header — Scan headers for "Host:" field
 *
 * x0: buffer start (beginning of request)
 * w2: header section length (up to \r\n\r\n)
 * Returns: w0 = 1 if Host: found, 0 if not
 * Clobbers: x0-x4
 *
 * Scans for "\r\nHost:" (case-sensitive) after the request-line.
 * The first \r\n in the buffer ends the request-line; Host: must
 * appear after that as a header field.
 */
http_find_host_header:
    cmp     w2, #10                 /* minimum: "X\r\nHost:Y" */
    b.lt    .Lfhh_no

    /* Scan for "\r\nHost:" (6 bytes) */
    mov     w3, #0
.Lfhh_scan:
    sub     w4, w2, #6
    cmp     w3, w4
    b.hs    .Lfhh_no

    ldrb    w4, [x0, x3]
    cmp     w4, #0x0D               /* \r */
    b.ne    .Lfhh_next

    add     w4, w3, #1
    ldrb    w4, [x0, x4]
    cmp     w4, #0x0A               /* \n */
    b.ne    .Lfhh_next

    /* Check "Host:" at offset +2 (case-insensitive per RFC 9110 §5.1:
     * header field names are case-insensitive). OR with 0x20 folds
     * uppercase ASCII to lowercase before comparison. */
    add     w4, w3, #2
    ldrb    w1, [x0, x4]
    orr     w1, w1, #0x20           /* fold to lowercase */
    cmp     w1, #'h'
    b.ne    .Lfhh_next
    add     w4, w4, #1
    ldrb    w1, [x0, x4]
    orr     w1, w1, #0x20
    cmp     w1, #'o'
    b.ne    .Lfhh_next
    add     w4, w4, #1
    ldrb    w1, [x0, x4]
    orr     w1, w1, #0x20
    cmp     w1, #'s'
    b.ne    .Lfhh_next
    add     w4, w4, #1
    ldrb    w1, [x0, x4]
    orr     w1, w1, #0x20
    cmp     w1, #'t'
    b.ne    .Lfhh_next
    add     w4, w4, #1
    ldrb    w1, [x0, x4]
    cmp     w1, #':'                /* colon is not alpha — exact match */
    b.ne    .Lfhh_next

    /* Found "\r\nHost:" */
    mov     w0, #1
    ret

.Lfhh_next:
    add     w3, w3, #1
    b       .Lfhh_scan

.Lfhh_no:
    mov     w0, #0
    ret

/* ===================================================================
/*
 * http_update_date — Update Date header in all response templates
 *
 * Called from the idle loop. Gets current time via timer_now + ntp_time.
 * If NTP not synced, leaves the default epoch date.
 *
 * Clobbers: x0-x7, x19-x24, x30 (via http_format_date)
 */
http_update_date:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    bl      timer_now
    bl      ntp_time
    cbz     x0, .Lud_done           /* not synced → keep existing */

    /* Format into each template's Date field */
    mov     x19, x0                 /* save timestamp */

    mov     x0, x19
    ldr     x1, =http_200_date
    bl      http_format_date

    mov     x0, x19
    ldr     x1, =http_404_date
    bl      http_format_date

    mov     x0, x19
    ldr     x1, =http_400_date
    bl      http_format_date

    mov     x0, x19
    ldr     x1, =http_405_date
    bl      http_format_date

    mov     x0, x19
    ldr     x1, =http_411_date
    bl      http_format_date

    mov     x0, x19
    ldr     x1, =http_413_date
    bl      http_format_date

    mov     x0, x19
    ldr     x1, =http_about_date
    bl      http_format_date

    mov     x0, x19
    ldr     x1, =http_status_date
    bl      http_format_date

    mov     x0, x19
    ldr     x1, =http_test_css_date
    bl      http_format_date

.Lud_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * http_test_echo_handler — Copies the request body from this HCONN's
 * slot of http_body_recv_bufs into the output buffer. Demonstrates
 * the handler ABI's HCONN access for POST body processing.
 *
 * x0: output buffer, w1: max buffer size, x2: HCONN pointer
 * Returns: w0 = bytes written (= HCONN_CONTENT_LEN, clamped to max)
 * Inputs x0, w1, x2 are used then overwritten; scratch is x3-x7.
 * Precondition: x2 is a valid pointer inside http_conn_table.
 */
http_test_echo_handler:
    /* body_src = http_body_recv_bufs + (hconn_index << SHIFT) */
    ldr     x3, =http_conn_table
    sub     x3, x2, x3
    lsr     x3, x3, #HCONN_SHIFT
    ldr     x4, =http_body_recv_bufs
    add     x3, x4, x3, lsl #HTTP_MAX_RECV_BODY_SHIFT

    ldr     w5, [x2, #HCONN_CONTENT_LEN]

    /* Clamp body length to max output buffer */
    cmp     w5, w1
    csel    w5, w5, w1, ls

    mov     w6, w5
.Lteh_cp:
    cbz     w6, .Lteh_done
    ldrb    w7, [x3], #1
    strb    w7, [x0], #1
    sub     w6, w6, #1
    b       .Lteh_cp
.Lteh_done:
    mov     w0, w5
    ret

/*
 * http_test_dispatch_handler — Emits the sentinel "DISPATCH_OK\n"
 * for the /_test_dispatch route. Used by
 * test_http_route_handler_dispatch to verify the dispatch path loads
 * handlers from ROUTE_HANDLER rather than hardcoding one function.
 *
 * x0: output buffer, w1: max buffer size, x2: HCONN (unused)
 * Returns: w0 = 12 on success, 0 if buffer is too small
 * Scratch: x2-x4 (x0 is consumed by the copy; x2 is an unused input).
 */
http_test_dispatch_handler:
    cmp     w1, #12
    b.lo    .Lhtd_short
    ldr     x2, =http_test_dispatch_sentinel
    mov     w3, #12
.Lhtd_cp:
    ldrb    w4, [x2], #1
    strb    w4, [x0], #1
    subs    w3, w3, #1
    b.ne    .Lhtd_cp
    mov     w0, #12
    ret
.Lhtd_short:
    mov     w0, #0
    ret

/* ===================================================================
 * Route table
 * =================================================================== */
.section .rodata
.balign 8
.global http_route_table
.global http_route_count

http_route_table:
    /* Route 0: "/" (static) */
    .word   1                       /* path_len */
    .word   http_200_body_len       /* body_len */
    .xword  http_path_root          /* path_ptr */
    .xword  http_200_body           /* body_ptr */
    .xword  http_200_hdr            /* hdr_ptr */
    .word   http_200_hdr_len        /* hdr_len */
    .word   0                       /* flags=0 (static) */
    .xword  0                       /* ROUTE_HANDLER unused */

    /* Route 1: "/about" (static) */
    .word   6                       /* path_len */
    .word   http_about_body_len     /* body_len */
    .xword  http_path_about         /* path_ptr */
    .xword  http_about_body         /* body_ptr */
    .xword  http_about_hdr          /* hdr_ptr */
    .word   http_about_hdr_len      /* hdr_len */
    .word   0                       /* flags=0 (static) */
    .xword  0                       /* ROUTE_HANDLER unused */

    /* Route 2: "/status" (dynamic — chunked encoding) */
    .word   7                       /* path_len */
    .word   0                       /* body_len = 0 (dynamic) */
    .xword  http_path_status        /* path_ptr */
    .xword  0                       /* body_ptr = unused */
    .xword  http_status_hdr         /* hdr_ptr */
    .word   http_status_hdr_len     /* hdr_len */
    .word   1                       /* flags=1 (dynamic) */
    .xword  http_status_generate    /* ROUTE_HANDLER */

    /* Route 3: "/_test_dispatch" (dynamic, test-only sentinel).
     * Baked into production because exercising route dispatch from
     * tests requires a second handler; impact is 48 B of rodata plus
     * a short handler. Not exposed via the packager. */
    .word   15                      /* path_len = len("/_test_dispatch") */
    .word   0                       /* body_len = 0 (dynamic) */
    .xword  http_path_test_dispatch /* path_ptr */
    .xword  0                       /* body_ptr = unused */
    .xword  http_status_hdr         /* hdr_ptr — reuse chunked header */
    .word   http_status_hdr_len     /* hdr_len */
    .word   1                       /* flags=1 (dynamic) */
    .xword  http_test_dispatch_handler /* ROUTE_HANDLER */

    /* Route 4: "/_test_echo" (dynamic, test-only). Echoes POST body
     * back. Like /_test_dispatch, test scaffolding compiled into
     * production; overwritten by the appliance packager. */
    .word   11                      /* path_len = len("/_test_echo") */
    .word   0
    .xword  http_path_test_echo
    .xword  0
    .xword  http_status_hdr
    .word   http_status_hdr_len
    .word   1
    .xword  http_test_echo_handler

    /* Route 5: "/_test_css" (static, test-only). Proves the runtime
     * supports Content-Type other than text/html — the packager will
     * rely on this for .css / .png / image/* assets. */
    .word   10                      /* path_len = len("/_test_css") */
    .word   http_test_css_body_len
    .xword  http_path_test_css
    .xword  http_test_css_body
    .xword  http_test_css_hdr
    .word   http_test_css_hdr_len
    .word   0
    .xword  0

    /* Route 6: "/counter" (dynamic). Real handler — increments a
     * store on each GET and emits the running count. First real
     * appliance feature that uses the store API. */
    .word   8                       /* path_len = len("/counter") */
    .word   0
    .xword  http_path_counter
    .xword  0
    .xword  http_status_hdr         /* reuse chunked header template */
    .word   http_status_hdr_len
    .word   1                       /* dynamic */
    .xword  http_counter_handler

http_route_table_end:
.equ http_route_count, (http_route_table_end - http_route_table) / ROUTE_SIZE

http_path_root:
    .ascii  "/"

http_path_about:
    .ascii  "/about"

http_path_status:
    .ascii  "/status"

http_path_test_dispatch:
    .ascii  "/_test_dispatch"

http_path_test_echo:
    .ascii  "/_test_echo"

http_path_test_css:
    .ascii  "/_test_css"

http_path_counter:
    .ascii  "/counter"

http_test_dispatch_sentinel:
    .ascii  "DISPATCH_OK\n"

/* ===================================================================
 * Response data
 *
 * Headers are in .data (writable) because the Date field is filled
 * at runtime by http_update_date. The "Date: " prefix and \r\n are
 * static; the 29-byte date value is overwritten each second.
 *
 * Bodies remain in .rodata (immutable).
 * =================================================================== */
.section .data
.balign 4

.global http_200_hdr
.global http_200_body
.global http_404_hdr
.global http_404_body

http_200_hdr:
    .ascii  "HTTP/1.1 200 OK\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_200_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 158\r\n"
    .ascii  "\r\n"
http_200_hdr_end:
.equ http_200_hdr_len, http_200_hdr_end - http_200_hdr

.section .rodata
http_200_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>ws_pi5</title></head>\n"
    .ascii  "<body><h1>Hello from bare-metal Pi 4!</h1>\n"
    .ascii  "<p>No OS. No C. Just AArch64 assembly.</p>\n"
    .ascii  "</body></html>\n"
http_200_body_end:
.equ http_200_body_len, http_200_body_end - http_200_body

.section .data
.balign 4
http_404_hdr:
    .ascii  "HTTP/1.1 404 Not Found\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_404_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 97\r\n"
    .ascii  "\r\n"
http_404_hdr_end:
.equ http_404_hdr_len, http_404_hdr_end - http_404_hdr

.section .rodata
http_404_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>404</title></head>\n"
    .ascii  "<body><h1>404 Not Found</h1></body></html>\n"
http_404_body_end:
.equ http_404_body_len, http_404_body_end - http_404_body

.section .data
.balign 4
http_400_hdr:
    .ascii  "HTTP/1.1 400 Bad Request\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_400_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 99\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
http_400_hdr_end:
.equ http_400_hdr_len, http_400_hdr_end - http_400_hdr

.section .rodata
http_400_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>400</title></head>\n"
    .ascii  "<body><h1>400 Bad Request</h1></body></html>\n"
http_400_body_end:
.equ http_400_body_len, http_400_body_end - http_400_body

.section .data
.balign 4
http_405_hdr:
    .ascii  "HTTP/1.1 405 Method Not Allowed\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_405_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Allow: GET, HEAD, POST\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 106\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
http_405_hdr_end:
.equ http_405_hdr_len, http_405_hdr_end - http_405_hdr

.section .rodata
http_405_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>405</title></head>\n"
    .ascii  "<body><h1>405 Method Not Allowed</h1></body></html>\n"
http_405_body_end:
.equ http_405_body_len, http_405_body_end - http_405_body

.section .data
.balign 4
http_test_css_hdr:
    .ascii  "HTTP/1.1 200 OK\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_test_css_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Content-Type: text/css\r\n"
    .ascii  "Content-Length: 18\r\n"
    .ascii  "\r\n"
http_test_css_hdr_end:
.equ http_test_css_hdr_len, http_test_css_hdr_end - http_test_css_hdr

.section .rodata
http_test_css_body:
    .ascii  "body{color:#333;}\n"
http_test_css_body_end:
.equ http_test_css_body_len, http_test_css_body_end - http_test_css_body

.if http_test_css_body_len != 18
.error "http_test_css_body_len drifted from the 18 hardcoded in http_test_css_hdr"
.endif

.section .data
.balign 4
http_411_hdr:
    .ascii  "HTTP/1.1 411 Length Required\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_411_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 103\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
http_411_hdr_end:
.equ http_411_hdr_len, http_411_hdr_end - http_411_hdr

.section .rodata
http_411_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>411</title></head>\n"
    .ascii  "<body><h1>411 Length Required</h1></body></html>\n"
http_411_body_end:
.equ http_411_body_len, http_411_body_end - http_411_body

.if http_411_body_len != 103
.error "http_411_body_len drifted from the 103 hardcoded in http_411_hdr"
.endif

.section .data
.balign 4
http_413_hdr:
    .ascii  "HTTP/1.1 413 Payload Too Large\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_413_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 105\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
http_413_hdr_end:
.equ http_413_hdr_len, http_413_hdr_end - http_413_hdr

.section .rodata
http_413_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>413</title></head>\n"
    .ascii  "<body><h1>413 Payload Too Large</h1></body></html>\n"
http_413_body_end:
.equ http_413_body_len, http_413_body_end - http_413_body

/* Lock the Content-Length string in http_413_hdr to the actual body
 * size at assembly time. If the body changes, the .equ computes a new
 * length and this .if fires before the binary is built. */
.if http_413_body_len != 105
.error "http_413_body_len drifted from the 105 hardcoded in http_413_hdr"
.endif

.section .data
.balign 4
http_about_hdr:
    .ascii  "HTTP/1.1 200 OK\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_about_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 372\r\n"
    .ascii  "\r\n"
http_about_hdr_end:
.equ http_about_hdr_len, http_about_hdr_end - http_about_hdr

.section .rodata
http_about_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>About ws_pi5</title></head>\n"
    .ascii  "<body>\n"
    .ascii  "<h1>About</h1>\n"
    .ascii  "<p>Bare-metal AArch64 web server on Raspberry Pi 4.</p>\n"
    .ascii  "<p>No OS. No C runtime. Just assembly.</p>\n"
    .ascii  "<ul>\n"
    .ascii  "<li>TCP: 128 connections, WSCALE, SACK, timestamps</li>\n"
    .ascii  "<li>HTTP/1.1: keep-alive, FSA parser, HEAD, Date</li>\n"
    .ascii  "<li>GENET Gigabit Ethernet with HW TX checksum</li>\n"
    .ascii  "</ul>\n"
    .ascii  "</body></html>\n"
http_about_body_end:
.equ http_about_body_len, http_about_body_end - http_about_body

.section .data
.balign 4
http_status_hdr:
    .ascii  "HTTP/1.1 200 OK\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Date: "
http_status_date:
    .ascii  "Thu, 01 Jan 1970 00:00:00 GMT"
    .ascii  "\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Transfer-Encoding: chunked\r\n"
    .ascii  "\r\n"
http_status_hdr_end:
.equ http_status_hdr_len, http_status_hdr_end - http_status_hdr

/* ===================================================================
 * BSS
 * =================================================================== */
.section .bss
.balign 8
http_conn_table:
    .space  HTTP_CONN_TABLE_SIZE

/* Per-HCONN dynamic response buffers — each way owns its own scratch
 * so concurrent dynamic responses cannot corrupt each other. */
.balign 8
http_dyn_body_bufs:
    .space  HTTP_MAX_CONNS * HTTP_DYN_BODY_SIZE
http_dyn_chunk_bufs:
    .space  HTTP_MAX_CONNS * HTTP_DYN_CHUNK_SIZE

/* Per-HCONN request body receive buffers. Populated by http_poll when
 * a POST/PUT request has Content-Length > 0 and the whole body is
 * already in the TCP rx buffer. Handlers that consume bodies will read
 * from their own slot here. */
.balign 8
http_body_recv_bufs:
    .space  HTTP_MAX_CONNS * HTTP_MAX_RECV_BODY

.section .data
.balign 8
http_send_ctx:
    .space  HSCTX_SIZE
