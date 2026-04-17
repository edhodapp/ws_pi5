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
 * Clobbers: x0-x6, x19-x24, x30
 */
http_poll:
    stp     x29, x30, [sp, #-80]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    /* sp+64..79: scratch space for request parsing */

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
    /* Fall through to try_parse — data may already be in rx buffer */

.Lhp_try_parse:
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

    /* Set flags from parsed fields */
    mov     w0, #0
    strb    w0, [x20, #HCONN_FLAGS]

    /* HTTP/1.1 if VER_MINOR == '1' */
    ldrb    w0, [x20, #HCONN_VER_MINOR]
    cmp     w0, #'1'
    b.ne    .Lhp_ver_done
    ldrb    w0, [x20, #HCONN_FLAGS]
    orr     w0, w0, #HFLAG_HTTP11
    strb    w0, [x20, #HCONN_FLAGS]
.Lhp_ver_done:

    /* Identify method: "GET " or "HEAD " */
    ldr     w0, [x22]
    ldr     w1, =HTTP_GET_MARKER
    cmp     w0, w1
    b.eq    .Lhp_method_get

    ldr     w1, =HTTP_HEAD_MARK_LO
    cmp     w0, w1
    b.ne    .Lhp_bad_method
    ldrb    w1, [x22, #4]
    cmp     w1, #HTTP_HEAD_SPACE
    b.ne    .Lhp_bad_method

    /* HEAD method */
    ldrb    w0, [x20, #HCONN_FLAGS]
    orr     w0, w0, #HFLAG_HEAD
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
    /* Match URI from parser fields */
    ldrh    w24, [x20, #HCONN_URI_START]
    ldrh    w1, [x20, #HCONN_URI_LEN]
    add     x0, x22, x24, uxtw
    bl      http_match_uri

    cbnz    w0, .Lhp_resp_404
    mov     w0, #HSTATUS_200
    strb    w0, [x20, #HCONN_STATUS]
    ldr     x1, =http_200_body
    ldr     w2, =http_200_body_len
    ldr     w3, =http_200_hdr_len
    b       .Lhp_setup_resp

.Lhp_resp_404:
    mov     w0, #HSTATUS_404
    strb    w0, [x20, #HCONN_STATUS]
    ldr     x1, =http_404_body
    ldr     w2, =http_404_body_len
    ldr     w3, =http_404_hdr_len
    b       .Lhp_setup_resp

.Lhp_bad_method:
    mov     w0, #HSTATUS_405
    strb    w0, [x20, #HCONN_STATUS]
    ldr     x1, =http_405_body
    ldr     w2, =http_405_body_len
    ldr     w3, =http_405_hdr_len
    b       .Lhp_setup_resp

.Lhp_bad_request:
    mov     w0, #HSTATUS_400
    strb    w0, [x20, #HCONN_STATUS]
    ldr     x1, =http_400_body
    ldr     w2, =http_400_body_len
    ldr     w3, =http_400_hdr_len
    b       .Lhp_setup_resp

.Lhp_setup_resp:
    str     x1, [x20, #HCONN_BODY_PTR]
    str     w2, [x20, #HCONN_BODY_LEN]
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

    /* Select header source based on status */
    ldrb    w0, [x20, #HCONN_STATUS]
    cbz     w0, .Lhp_hdr_200
    cmp     w0, #HSTATUS_400
    b.eq    .Lhp_hdr_400
    cmp     w0, #HSTATUS_404
    b.eq    .Lhp_hdr_404
    cmp     w0, #HSTATUS_405
    b.eq    .Lhp_hdr_405
    b       .Lhp_hdr_400              /* fallback for unknown status */

.Lhp_hdr_200:
    ldr     x2, =http_200_hdr
    add     x2, x2, x22
    b       .Lhp_do_send

.Lhp_hdr_400:
    ldr     x2, =http_400_hdr
    add     x2, x2, x22
    b       .Lhp_do_send

.Lhp_hdr_404:
    ldr     x2, =http_404_hdr
    add     x2, x2, x22
    b       .Lhp_do_send

.Lhp_hdr_405:
    ldr     x2, =http_405_hdr
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
    /* Response complete — close connection */
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
    b       .Lhp_next

.Lhp_next:
    add     x19, x19, #TCONN_SIZE
    add     x20, x20, #HCONN_SIZE
    b       .Lhp_loop

.Lhp_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
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
 * http_match_uri — Match URI against known routes
 *
 * x0: URI pointer, w1: URI length
 * Returns: w0 = 0 (200 OK), 1 (404 Not Found)
 * Clobbers: x0-x2
 */
http_match_uri:
    /* Match "/" exactly */
    cmp     w1, #1
    b.ne    .Lmu_404
    ldrb    w2, [x0]
    cmp     w2, #0x2F              /* '/' */
    b.ne    .Lmu_404
    mov     w0, #0
    ret
.Lmu_404:
    mov     w0, #1
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
 * Response data
 * =================================================================== */
.section .rodata

.global http_200_hdr
.global http_200_body
.global http_404_hdr
.global http_404_body

http_200_hdr:
    .ascii  "HTTP/1.1 200 OK\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 158\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
http_200_hdr_end:
.equ http_200_hdr_len, http_200_hdr_end - http_200_hdr

http_200_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>ws_pi5</title></head>\n"
    .ascii  "<body><h1>Hello from bare-metal Pi 4!</h1>\n"
    .ascii  "<p>No OS. No C. Just AArch64 assembly.</p>\n"
    .ascii  "</body></html>\n"
http_200_body_end:
.equ http_200_body_len, http_200_body_end - http_200_body

http_404_hdr:
    .ascii  "HTTP/1.1 404 Not Found\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 97\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
http_404_hdr_end:
.equ http_404_hdr_len, http_404_hdr_end - http_404_hdr

http_404_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>404</title></head>\n"
    .ascii  "<body><h1>404 Not Found</h1></body></html>\n"
http_404_body_end:
.equ http_404_body_len, http_404_body_end - http_404_body

http_400_hdr:
    .ascii  "HTTP/1.1 400 Bad Request\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 99\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
http_400_hdr_end:
.equ http_400_hdr_len, http_400_hdr_end - http_400_hdr

http_400_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>400</title></head>\n"
    .ascii  "<body><h1>400 Bad Request</h1></body></html>\n"
http_400_body_end:
.equ http_400_body_len, http_400_body_end - http_400_body

http_405_hdr:
    .ascii  "HTTP/1.1 405 Method Not Allowed\r\n"
    .ascii  "Server: ws_pi5\r\n"
    .ascii  "Allow: GET, HEAD\r\n"
    .ascii  "Content-Type: text/html; charset=utf-8\r\n"
    .ascii  "Content-Length: 106\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
http_405_hdr_end:
.equ http_405_hdr_len, http_405_hdr_end - http_405_hdr

http_405_body:
    .ascii  "<!DOCTYPE html>\n"
    .ascii  "<html><head><title>405</title></head>\n"
    .ascii  "<body><h1>405 Method Not Allowed</h1></body></html>\n"
http_405_body_end:
.equ http_405_body_len, http_405_body_end - http_405_body

/* ===================================================================
 * BSS
 * =================================================================== */
.section .bss
.balign 8
http_conn_table:
    .space  HTTP_CONN_TABLE_SIZE

.section .data
.balign 8
http_send_ctx:
    .space  HSCTX_SIZE
