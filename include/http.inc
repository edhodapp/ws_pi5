/* HTTP server constants and connection state struct */

/* HTTP connection states */
.equ HTTPS_IDLE,        0       /* no active HTTP transaction */
.equ HTTPS_RECV_HDR,    1       /* accumulating request headers */
.equ HTTPS_SENDING,     2       /* sending response (headers + body) */
.equ HTTPS_DONE,        3       /* response complete, close pending */

/* HTTP response status codes (stored in HCONN_STATUS) */
.equ HSTATUS_200,       0       /* 200 OK */
.equ HSTATUS_400,       1       /* 400 Bad Request */
.equ HSTATUS_404,       2       /* 404 Not Found */
.equ HSTATUS_405,       3       /* 405 Method Not Allowed */
.equ HSTATUS_411,       4       /* 411 Length Required */
.equ HSTATUS_413,       5       /* 413 Payload Too Large */
.equ HSTATUS_414,       6       /* 414 URI Too Long */
.equ HSTATUS_431,       7       /* 431 Request Header Fields Too Large */

/* HTTP connection flags (stored in HCONN_FLAGS) */
.equ HFLAG_HTTP11,      0x01    /* bit 0: HTTP/1.1 (vs 1.0) */
.equ HFLAG_HEAD,        0x02    /* bit 1: HEAD method (suppress body) */
.equ HFLAG_CLOSE,       0x04    /* bit 2: send Connection: close (close after response) */
.equ HFLAG_POST,        0x08    /* bit 3: POST method (for 411 check) */
.equ HFLAG_CL_SEEN,     0x10    /* bit 4: Content-Length header present (distinguishes absent from "CL: 0") */

/* HTTP connection struct (64 bytes per slot)
 *
 * Bytes 0-31: shared between parser (RECV_HDR) and sender (SENDING).
 * Bytes 32-63: parser state (only used during RECV_HDR).
 * This is NOT a union — the parser fields persist until the
 * transition to SENDING reads them to set up the response. */
.equ HCONN_STATE,       0       /* u8  — HTTPS_* state */
.equ HCONN_STATUS,      1       /* u8  — HSTATUS_* response code */
.equ HCONN_FLAGS,       2       /* u8  — HFLAG_* request flags */
.equ HCONN_PAD1,        3       /* u8  — reserved */
.equ HCONN_RESP_PTR,    4       /* u32 — current offset into response */
.equ HCONN_RESP_LEN,    8       /* u32 — total response length (hdr+body) */
.equ HCONN_HDR_LEN,     12      /* u32 — response header length */
.equ HCONN_BODY_PTR,    16      /* u64 — pointer to body in .rodata */
.equ HCONN_BODY_LEN,    24      /* u32 — body length */
.equ HCONN_RECV_TICK,   28      /* u32 — timer tick when RECV_HDR started */

/* Slowloris timeout: close connections in RECV_HDR for > 30 seconds */
.equ HTTP_RECV_TIMEOUT_SECS, 30

/* Parser fields (bytes 32-63, used during RECV_HDR) */
.equ HCONN_PARSE_STATE, 32      /* u8  — FSA state (S_METHOD..S_ERROR) */
.equ HCONN_METHOD_ID,   33      /* u8  — 0=unknown, 1=GET, 2=HEAD */
.equ HCONN_PARSE_OFF,   34      /* u16 — current parse offset in rx buffer */
.equ HCONN_URI_START,   36      /* u16 — byte offset of URI start */
.equ HCONN_URI_LEN,     38      /* u16 — URI length */
.equ HCONN_VER_MINOR,   40      /* u8  — version minor digit ('0' or '1') */
.equ HCONN_HOST_FOUND,  41      /* u8  — 1 if Host: header seen */
.equ HCONN_CLOSE_FOUND, 42     /* u8  — 1 if Connection: close seen */
.equ HCONN_METHOD_LEN,  42      /* u16 — method string length */
.equ HCONN_REQ_LEN,     44      /* u32 — total request length (for pipelining) */
.equ HCONN_HDR_NM_START, 48     /* u16 — header name start (temp for Host check) */
/* Reused after parse completes (SENDING state): */
.equ HCONN_HDR_SRC_PTR, 48     /* u64 — response header source pointer */
.equ HCONN_HDR_SRC_LEN, 56     /* u32 — response header source length */
.equ HCONN_CONTENT_LEN, 60     /* u32 — parsed Content-Length header (0 if absent) */

.equ HCONN_SIZE,        64
.equ HCONN_SHIFT,       6       /* log2(64) */

/* Invariant lock: .Lhp_dynamic uses `lsr #HCONN_SHIFT` to derive the
 * HCONN index from a byte offset into http_conn_table. If HCONN_SIZE
 * ever drifts from (1 << HCONN_SHIFT), that addressing silently yields
 * wrong buffer offsets. Catch it at assembly time. */
.if HCONN_SIZE != (1 << HCONN_SHIFT)
.error "HCONN_SIZE must equal (1 << HCONN_SHIFT)"
.endif

.equ HTTP_MAX_CONNS,    128
.equ HTTP_CONN_TABLE_SIZE, 8192 /* 128 * 64 */

/* FSA parser states */
.equ S_METHOD,    0     /* reading method characters */
.equ S_M_SP,      1     /* space after method → URI start */
.equ S_URI,       2     /* reading URI */
.equ S_U_SP,      3     /* space after URI → version start */
.equ S_VH,        4     /* saw 'H', expect 'T' */
.equ S_VT1,       5     /* expect second 'T' */
.equ S_VT2,       6     /* expect 'P' */
.equ S_VP,        7     /* expect '/' */
.equ S_VSLASH,    8     /* expect major digit */
.equ S_VMAJ,      9     /* expect '.' */
.equ S_VDOT,     10     /* expect minor digit */
.equ S_VMIN,     11     /* expect CR */
.equ S_RL_CR,    12     /* expect LF (end request-line) */
.equ S_HDR_ST,   13     /* header start: CR→end, ALPHA→name */
.equ S_HDR_NM,   14     /* header field name (until colon) */
.equ S_HDR_VL,   15     /* header value (until CR) */
.equ S_HDR_CR,   16     /* expect LF after header value */
.equ S_END_CR,   17     /* final LF → DONE */
.equ S_DONE,     18     /* request fully parsed */
.equ S_ERROR,    19     /* malformed request */
.equ S_COUNT,    20

/* Character classes for FSA lookup table */
.equ CC_ALPHA,    0
.equ CC_DIGIT,    1
.equ CC_SP,       2
.equ CC_CR,       3
.equ CC_LF,       4
.equ CC_COLON,    5
.equ CC_SLASH,    6
.equ CC_DOT,      7
.equ CC_OTHER,    8
.equ CC_COUNT,    9

/* Method IDs */
.equ METHOD_UNKNOWN,  0
.equ METHOD_GET,      1
.equ METHOD_HEAD,     2

/* Route table entry layout (48 bytes, 8-byte aligned)
 *
 * Static routes: ROUTE_HANDLER = 0, body from ROUTE_BODY_PTR.
 * Dynamic routes: ROUTE_HANDLER = function pointer. The handler
 * is called to generate the body into a buffer. Handler signature:
 *   x0: output buffer, w1: max buffer size
 *   Returns: w0 = bytes written to buffer (body content)
 */
.equ ROUTE_PATH_LEN,    0      /* u32 — path string length */
.equ ROUTE_BODY_LEN,    4      /* u32 — body length (0 for dynamic) */
.equ ROUTE_PATH_PTR,    8      /* u64 — pointer to path string */
.equ ROUTE_BODY_PTR,   16      /* u64 — pointer to body (static) */
.equ ROUTE_HDR_PTR,    24      /* u64 — pointer to header template */
.equ ROUTE_HDR_LEN,    32      /* u32 — header template length */
.equ ROUTE_FLAGS,      36      /* u32 — 0=static, 1=dynamic (chunked) */
.equ ROUTE_HANDLER,    40      /* u64 — handler fn ptr (unused for static) */
.equ ROUTE_SIZE,       48

/* HTTP send context (same layout as TSCTX) */
.equ HSCTX_DWC2_BASE,  0
.equ HSCTX_ECM_STATE,  8
.equ HSCTX_TX_BUF,     16
.equ HSCTX_SEND_FN,    24
.equ HSCTX_SIZE,        32

/* Request parsing */
.equ HTTP_END_MARKER,   0x0A0D0A0D  /* \r\n\r\n in LE word */
.equ HTTP_GET_MARKER,   0x20544547  /* "GET " in LE word */
.equ HTTP_HEAD_MARK_LO, 0x44414548  /* "HEAD" in LE word */
.equ HTTP_POST_MARKER,  0x54534F50  /* "POST" in LE word */
.equ HTTP_HEAD_SPACE,   0x20        /* " " after 4-letter method */

/* Request limits */
.equ HTTP_MAX_REQUEST_LINE, 8192    /* max request-line length → 414 */
.equ HTTP_MAX_HEADERS,      8192    /* max total header size → 431 */

/* Peek buffer for request parsing */
.equ HTTP_PEEK_BUF_SIZE, 512

/* Per-HCONN dynamic response scratch sizes.
 * Body buf holds raw handler output; chunk buf holds chunk-encoded output
 * plus the 5-byte "0\r\n\r\n" terminator.
 * Body size must be a power of 2 so the per-HCONN offset can use a shift. */
.equ HTTP_DYN_BODY_SIZE,  1024
.equ HTTP_DYN_BODY_SHIFT, 10
.equ HTTP_DYN_CHUNK_SIZE, 1088

/* Per-HCONN request body scratch. Used for POST / PUT-style bodies that
 * arrive with a Content-Length. Single-shot only: the whole body must
 * already be in the rx buffer when the parser reaches S_DONE. Multi-
 * packet accumulation will need its own state. Size must be a power of
 * 2 for shift-indexing. */
.equ HTTP_MAX_RECV_BODY,  1024
.equ HTTP_MAX_RECV_BODY_SHIFT, 10
