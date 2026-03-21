/* HTTP server constants and connection state struct */

/* HTTP connection states */
.equ HTTPS_IDLE,        0       /* no active HTTP transaction */
.equ HTTPS_RECV_HDR,    1       /* accumulating request headers */
.equ HTTPS_SENDING,     2       /* sending response (headers + body) */
.equ HTTPS_DONE,        3       /* response complete, close pending */

/* HTTP connection struct (32 bytes per slot) */
.equ HCONN_STATE,       0       /* u8  — HTTPS_* state */
.equ HCONN_STATUS,      1       /* u8  — 0=200, 1=404 */
.equ HCONN_PAD1,        2       /* u16 — reserved */
.equ HCONN_RESP_PTR,    4       /* u32 — current offset into response */
.equ HCONN_RESP_LEN,    8       /* u32 — total response length (hdr+body) */
.equ HCONN_HDR_LEN,     12      /* u32 — response header length */
.equ HCONN_BODY_PTR,    16      /* u64 — pointer to body in .rodata */
.equ HCONN_BODY_LEN,    24      /* u32 — body length */
.equ HCONN_PAD2,        28      /* u32 — reserved */

.equ HCONN_SIZE,        32
.equ HCONN_SHIFT,       5       /* log2(32) */
.equ HTTP_MAX_CONNS,    128
.equ HTTP_CONN_TABLE_SIZE, 4096 /* 128 * 32 */

/* HTTP send context (same layout as TSCTX) */
.equ HSCTX_DWC2_BASE,  0
.equ HSCTX_ECM_STATE,  8
.equ HSCTX_TX_BUF,     16
.equ HSCTX_SEND_FN,    24
.equ HSCTX_SIZE,        32

/* Request parsing */
.equ HTTP_END_MARKER,   0x0A0D0A0D  /* \r\n\r\n in LE word */
.equ HTTP_GET_MARKER,   0x20544547  /* "GET " in LE word */

/* Peek buffer for request parsing */
.equ HTTP_PEEK_BUF_SIZE, 512
