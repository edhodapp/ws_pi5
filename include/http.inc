/* HTTP server constants and connection state struct */

/* HTTP connection states */
.equ HTTPS_IDLE,        0       /* no active HTTP transaction */
.equ HTTPS_RECV_HDR,    1       /* accumulating request headers */
.equ HTTPS_SENDING,     2       /* sending response (headers + body) */
.equ HTTPS_DONE,        3       /* response complete, close pending */
.equ HTTPS_RECV_BODY,   4       /* parsed headers, waiting for rest of body */

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
.equ HCONN_QUERY_START, 50      /* u16 — offset in rx buffer where query string starts (0 = absent) */
.equ HCONN_QUERY_LEN,   52      /* u16 — query string length (0 = absent) */
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
.equ ROUTE_FLAGS,      36      /* u8  — 0=static, 1=dynamic (chunked) */
.equ ROUTE_METHODS,    37      /* u8  — bitmask of HM_* methods this route accepts */
/* bytes 38-39: pad */
.equ ROUTE_HANDLER,    40      /* u64 — handler fn ptr (unused for static) */
.equ ROUTE_SIZE,       48

/* Route method bitmask values. Stored in ROUTE_METHODS; the dispatcher
 * rejects mismatched methods with 405 before invoking the handler. */
.equ HM_GET,            0x01
.equ HM_HEAD,           0x02
.equ HM_POST,           0x04

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

/* =====================================================================
 * Appliance packaging slab — binary contract
 *
 * The kernel reserves a fixed-size region in .data that the appliance
 * packager (mk_appliance.py) overwrites to inject a user-provided
 * route table and content bundle. The packager locates the slab by
 * searching the kernel image for APPLIANCE_MAGIC_NONE (the "unused"
 * marker written at link time) and rewrites the magic, routes, and
 * content in place. Nothing in the slab is accessed by the running
 * kernel until a later commit wires boot-time initialization; today
 * this commit just reserves the bytes and locks down the layout.
 *
 * Layout (fixed offsets within the slab):
 *   0   APPLIANCE_HDR_MAGIC     8 B  — one of APPLIANCE_MAGIC_*
 *   8   APPLIANCE_HDR_VERSION   4 B  — u32, currently 1
 *   12  APPLIANCE_HDR_RCOUNT    4 B  — u32, number of active routes
 *   16  APPLIANCE_HDR_CLEN      4 B  — u32, bytes used in content region
 *   20  APPLIANCE_HDR_KSIZE     4 B  — u32, kernel-side APPLIANCE_SLAB_SIZE
 *                                     baked in at build time. The packager
 *                                     reads this and refuses to run if its
 *                                     own APPLIANCE_SLAB_SIZE differs;
 *                                     writing a mismatched slab would
 *                                     either over-write adjacent kernel
 *                                     code or leave the tail of the
 *                                     placeholder unwritten.
 *   24  APPLIANCE_ROUTES        variable — APPLIANCE_MAX_ROUTES × 48 B
 *   ...within each route entry, pointer fields hold BYTE OFFSETS into
 *      APPLIANCE_CONTENT rather than absolute pointers. Boot-time
 *      init converts them to absolute pointers.
 *   24 + N*48 APPLIANCE_CONTENT  variable — APPLIANCE_CONTENT_MAX bytes
 *
 * Magic values are raw 8-byte ASCII, stored little-endian-word so
 * `.quad` of the two halves reads back as the string in memory.
 * ===================================================================== */

.equ APPLIANCE_HDR_MAGIC,       0
.equ APPLIANCE_HDR_VERSION,     8
.equ APPLIANCE_HDR_RCOUNT,      12
.equ APPLIANCE_HDR_CLEN,        16
.equ APPLIANCE_HDR_KSIZE,       20
.equ APPLIANCE_HDR_SIZE,        24

/* APPLIANCE_MAX_ROUTES — overridable via `make MAX_ROUTES=<n>` so
 * route-heavy builds can raise the cap without editing this file. */
.ifdef MAX_ROUTES_OVERRIDE
.equ APPLIANCE_MAX_ROUTES,      MAX_ROUTES_OVERRIDE
.else
.equ APPLIANCE_MAX_ROUTES,      512
.endif
.equ APPLIANCE_ROUTES_OFF,      24
.equ APPLIANCE_ROUTES_SIZE,     (APPLIANCE_MAX_ROUTES * ROUTE_SIZE)

.equ APPLIANCE_CONTENT_OFF,     (APPLIANCE_ROUTES_OFF + APPLIANCE_ROUTES_SIZE)
/* APPLIANCE_CONTENT_MAX — overridable via `make CONTENT_MAX=<bytes>` so
 * kernel8.img can be sized to fit a user's actual site rather than
 * burning the full default slab regardless.
 *
 * Default sizes the SLAB SECTION (header + routes + content) to
 * exactly 255 MiB. On SIZE_LOCKED builds the linker places the slab
 * at LINK_ADDR + 1 MiB so total image = 256 MiB exactly (power of 2).
 * Since the slab also carries APPLIANCE_CONTENT_OFF bytes of header
 * + route table in front of the actual content, content max =
 * 255 MiB - APPLIANCE_CONTENT_OFF (= 24 B header + 512 * 48 routes
 * = 24,600 B by default). User-visible "max site size" is therefore
 * 255 MiB - 24,600 B ≈ 254.98 MiB. The 1 MiB pre-slab reserve carries
 * .text + .rodata + non-slab .data globals (currently ~100 KiB
 * combined, so ~10× growth headroom). Changing 255 MiB here without
 * also adjusting the linker reserve trips the SIZE_LOCKED ASSERTs. */
.ifdef CONTENT_MAX_OVERRIDE
.equ APPLIANCE_CONTENT_MAX,     CONTENT_MAX_OVERRIDE
.else
.equ APPLIANCE_CONTENT_MAX,     ((255 * 1024 * 1024) - APPLIANCE_CONTENT_OFF)
.endif
.equ APPLIANCE_SLAB_SIZE,       (APPLIANCE_CONTENT_OFF + APPLIANCE_CONTENT_MAX)

.equ APPLIANCE_VERSION,         1

/* The "unused" magic lands at link time. The packager rewrites it to
 * APPLIANCE_MAGIC_V1 as part of producing an appliance image. */
.equ APPLIANCE_MAGIC_NONE_LO,   0x4950534E57      /* "NSPIW" — high half lies in the .lo field */
.equ APPLIANCE_MAGIC_NONE_HI,   0x454E4F4E        /* "NONE"  */
/* Combined: bytes 0..7 = "WSPINONE" (LE word layout via .ascii) */

.equ APPLIANCE_MAGIC_V1_LO,     0x4950535700      /* placeholder — see .ascii */
/* Packager writes literal 8-byte string "WSPIAPLI" — no .equ math needed. */

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

/* ========================================================================
 * Output FSA. Send-side states and events used by lib/http_output_fsa.S.
 * Kept here so tests and any future tcp.S hook (option-b migration) can
 * reference the same canonical numbers.
 * ======================================================================== */

/* States (O_*) — per-HCONN entry in http_fsa_ostate. */
.equ O_IDLE,        0    /* no response queued */
.equ O_SETUP,       1    /* hdr+body installed, waiting for first tx window */
.equ O_TX,          2    /* emitting chunks */
.equ O_DRAINING,    3    /* all bytes handed to tcp, waiting for sndbuf drain */
.equ FSA_NSTATES,   4

/* Events (E_*) — evt_code in the EVT struct, also the bit index in
 * http_fsa_evt_pending so gating can check/set with `1 << evt_code`. */
.equ E_RESP_READY,      0    /* hi — route produced hdr+body */
.equ E_WIN_OPEN,        1    /* lo — tcp_send_ready transitioned 0 → non-0 */
.equ E_CHUNK_SENT,      2    /* lo — handler wrote one frame; loop */
.equ E_ALL_QUEUED,      3    /* lo — last byte handed to tcp */
.equ E_ALL_DRAINED,     4    /* lo — sndbuf_unacked reached 0 */
.equ E_TCP_CLOSED,      5    /* hi — conn left ESTABLISHED */
.equ E_DO_CLOSE,        6    /* hi — h_decide → route to close */
.equ E_DO_KEEPALIVE,    7    /* hi — h_decide → route to keepalive */
.equ FSA_NEVENTS,       8

/* Queue sizing: per-(way, event_code) gating in http_fsa_evt_pending
 * bounds the live event count at HTTP_MAX_CONNS per queue. Power-of-2
 * required by Q_MASK. */
.equ HTTP_FSA_Q_CAP,    128
.equ HTTP_FSA_Q_MASK,   127
