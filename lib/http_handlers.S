/*
 * http_handlers.S — Dynamic route handlers for the appliance.
 *
 * Each handler uses the handler ABI:
 *   x0: output buffer, w1: max buffer size, x2: HCONN pointer
 *   Returns: w0 = bytes written
 *
 * Counter: increments a 1-slot store on each invocation, emits the
 * decimal count. Uses records_written as the "count" — no payload
 * bytes to copy per append, just the metadata bump.
 */

.include "store.inc"
.include "http.inc"

.global http_counter_handler
.global counter_store
.global http_guestbook_handler
.global guestbook_store
.global http_form_log_handler
.global form_log_store

.section .text

/*
 * fmt_u32_decimal — Format unsigned 32-bit value as decimal ASCII.
 * x0: output buffer, w1: value
 * Returns: w0 = bytes written (1..10)
 * Clobbers: x0-x6; uses 16 bytes of stack scratch.
 */
fmt_u32_decimal:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    sub     sp, sp, #16

    cbz     w1, .Lfd_zero

    mov     w2, w1                  /* work value */
    mov     w3, #0                  /* digit count */
.Lfd_loop:
    mov     w4, #10
    udiv    w5, w2, w4              /* quotient */
    msub    w6, w5, w4, w2          /* remainder = value - quot*10 */
    add     w6, w6, #'0'
    strb    w6, [sp, w3, uxtw]
    add     w3, w3, #1
    mov     w2, w5
    cbnz    w5, .Lfd_loop

    /* Emit digits in reverse order (stack had them low-to-high) */
    mov     w4, w3
    mov     w5, #0
.Lfd_copy:
    cbz     w4, .Lfd_done
    sub     w4, w4, #1
    ldrb    w6, [sp, w4, uxtw]
    strb    w6, [x0, w5, uxtw]
    add     w5, w5, #1
    b       .Lfd_copy

.Lfd_done:
    mov     w0, w3
    add     sp, sp, #16
    ldp     x29, x30, [sp], #32
    ret

.Lfd_zero:
    mov     w6, #'0'
    strb    w6, [x0]
    mov     w0, #1
    add     sp, sp, #16
    ldp     x29, x30, [sp], #32
    ret

/*
 * http_counter_handler — increments counter_store and writes the
 * running count (decimal) into the output buffer.
 *
 * x0: output, w1: max_len, x2: HCONN (unused)
 * Returns: w0 = bytes written
 */
http_counter_handler:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]

    mov     x19, x0                 /* save out_buf */
    mov     w20, w1                 /* save max_len (unused for now) */

    /* Append a dummy record to bump records_written; the store is
     * configured with record_bytes=0, so no bytes actually get copied. */
    ldr     x0, =counter_store
    ldr     x1, =counter_store      /* any non-null pointer */
    bl      store_append

    /* Format records_written into the output buffer */
    ldr     x0, =counter_store
    ldr     w1, [x0, #STORE_WRITTEN]
    mov     x0, x19
    bl      fmt_u32_decimal
    /* w0 = bytes written, propagates as our return value */

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * http_guestbook_handler — POST: append request body to guestbook_store
 * (zero-padded to GUESTBOOK_REC_BYTES). GET: emit minimal "OK" for now
 * (Phase A); a later step renders stored entries as an HTML list.
 *
 * x0: output, w1: max_len, x2: HCONN
 * Returns: w0 = bytes written
 */
.equ GUESTBOOK_REC_BYTES, 128
.equ GUESTBOOK_CAP,       16

http_guestbook_handler:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* save out base */
    mov     w20, w1                 /* save max_len */
    mov     x21, x2                 /* save HCONN */

    /* GET vs POST: HFLAG_POST set iff method was POST */
    ldrb    w0, [x21, #HCONN_FLAGS]
    tst     w0, #HFLAG_POST
    b.eq    .Lhgh_get

    /* --- POST path: copy body into guestbook_slot_buf (zero-padded),
     * then store_append. Serialized use of the shared slot buffer is
     * safe under the single-threaded poll loop. */
    ldr     x22, =guestbook_slot_buf
    mov     x0, x22
    mov     w3, #GUESTBOOK_REC_BYTES / 8
.Lhgh_zero:
    str     xzr, [x0], #8
    sub     w3, w3, #1
    cbnz    w3, .Lhgh_zero

    /* body source = http_body_recv_bufs + (hconn_index << SHIFT) */
    ldr     x0, =http_conn_table
    sub     x0, x21, x0
    lsr     x0, x0, #HCONN_SHIFT
    ldr     x1, =http_body_recv_bufs
    add     x0, x1, x0, lsl #HTTP_MAX_RECV_BODY_SHIFT

    ldr     w3, [x21, #HCONN_CONTENT_LEN]
    mov     w4, #GUESTBOOK_REC_BYTES
    cmp     w3, w4
    csel    w3, w3, w4, ls

    mov     x4, x22
.Lhgh_cp:
    cbz     w3, .Lhgh_store
    ldrb    w5, [x0], #1
    strb    w5, [x4], #1
    sub     w3, w3, #1
    b       .Lhgh_cp

.Lhgh_store:
    ldr     x0, =guestbook_store
    mov     x1, x22
    bl      store_append

    /* POST response: "OK" */
    mov     w0, #'O'
    strb    w0, [x19]
    mov     w0, #'K'
    strb    w0, [x19, #1]
    mov     w0, #2
    b       .Lhgh_ret

.Lhgh_get:
    /* --- GET path: render "<ul>\n<li>ENTRY</li>\n...</ul>\n".
     * x22 = output cursor (advances through the out buffer).
     * x23 = count; x24 = current entry index.
     * The handler keeps a running count of remaining max_len via w20
     * and truncates if it would overflow. */

    mov     x22, x19                /* cursor = out base */

    ldr     x0, =http_gb_ul_open
    mov     w1, #5                  /* "<ul>\n" */
    bl      gb_emit_literal

    ldr     x0, =guestbook_store
    bl      store_count
    mov     w23, w0
    mov     w24, #0

.Lhgh_entry_loop:
    cmp     w24, w23
    b.hs    .Lhgh_close

    /* "<li>" (4 bytes) */
    ldr     x0, =http_gb_li_open
    mov     w1, #4
    bl      gb_emit_literal

    /* Read entry index=w24 into guestbook_slot_buf */
    ldr     x0, =guestbook_store
    mov     w1, w24
    ldr     x2, =guestbook_slot_buf
    bl      store_read
    /* w0 = bytes copied (= GUESTBOOK_REC_BYTES for a valid entry) */

    /* Emit bytes from slot until NUL or GUESTBOOK_REC_BYTES */
    ldr     x0, =guestbook_slot_buf
    mov     w1, #0                  /* byte index */
.Lhgh_entry_bytes:
    cmp     w1, #GUESTBOOK_REC_BYTES
    b.hs    .Lhgh_entry_done
    ldrb    w2, [x0, w1, uxtw]
    cbz     w2, .Lhgh_entry_done
    /* Skip if we'd exceed max_len */
    cbz     w20, .Lhgh_close
    strb    w2, [x22], #1
    sub     w20, w20, #1
    add     w1, w1, #1
    b       .Lhgh_entry_bytes

.Lhgh_entry_done:
    /* "</li>\n" (6 bytes) */
    ldr     x0, =http_gb_li_close
    mov     w1, #6
    bl      gb_emit_literal

    add     w24, w24, #1
    b       .Lhgh_entry_loop

.Lhgh_close:
    /* "</ul>\n" (6 bytes) */
    ldr     x0, =http_gb_ul_close
    mov     w1, #6
    bl      gb_emit_literal

    /* Return bytes written = cursor - base */
    sub     x0, x22, x19

.Lhgh_ret:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * gb_emit_literal — copy w1 bytes from x0 into the output cursor x22,
 * advancing x22 and decrementing w20 (remaining capacity). Truncates
 * silently if w20 reaches 0.
 *
 * Private helper for http_guestbook_handler; reads/writes x22 and w20.
 * Clobbers x0, w1, w2.
 */
gb_emit_literal:
.Lgbe_loop:
    cbz     w1, .Lgbe_done
    cbz     w20, .Lgbe_done
    ldrb    w2, [x0], #1
    strb    w2, [x22], #1
    sub     w1, w1, #1
    sub     w20, w20, #1
    b       .Lgbe_loop
.Lgbe_done:
    ret

/*
 * counter_store — 1-slot, 0-byte record ring. records_written is the
 * counter value; there is no payload data. Static init: written = 0,
 * rec_bytes = 0, cap = 1.
 */
.section .data
.balign 16
counter_store:
    .word   0                       /* records_written */
    .word   0                       /* record_bytes */
    .word   1                       /* capacity (power of 2) */
    .word   0                       /* pad */
    /* No data region: record_bytes = 0, so no slots need space. */

/*
 * guestbook_store — 16-slot ring of 128-byte entries. Each entry is a
 * zero-padded byte string (effective length bounded by first NUL or
 * GUESTBOOK_REC_BYTES).
 */
.balign 16
guestbook_store:
    .word   0                       /* records_written */
    .word   GUESTBOOK_REC_BYTES     /* record_bytes = 128 */
    .word   GUESTBOOK_CAP           /* capacity = 16 */
    .word   0                       /* pad */
    .space  GUESTBOOK_CAP * GUESTBOOK_REC_BYTES

.balign 16
form_log_store:
    .word   0
    .word   FORM_LOG_REC_BYTES      /* record_bytes = 256 */
    .word   FORM_LOG_CAP            /* capacity = 8 */
    .word   0
    .space  FORM_LOG_CAP * FORM_LOG_REC_BYTES

/*
 * http_form_log_handler — POST: append body to form_log_store, emit
 * "OK". GET: emit the current log count as decimal.
 *
 * x0: output, w1: max_len, x2: HCONN
 * Returns: w0 = bytes written
 *
 * form_log_store uses 256-byte records to fit typical form bodies.
 * POST body is zero-padded via a shared scratch (form_log_slot_buf),
 * analogous to the guestbook handler.
 */
.equ FORM_LOG_REC_BYTES, 256
.equ FORM_LOG_CAP,       8

http_form_log_handler:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* save out */
    mov     w20, w1                 /* save max_len */
    mov     x21, x2                 /* save HCONN */

    ldrb    w0, [x21, #HCONN_FLAGS]
    tst     w0, #HFLAG_POST
    b.eq    .Lhfh_get

    /* POST: zero-pad body into form_log_slot_buf, then store_append */
    ldr     x22, =form_log_slot_buf
    mov     x0, x22
    mov     w3, #FORM_LOG_REC_BYTES / 8
.Lhfh_zero:
    str     xzr, [x0], #8
    sub     w3, w3, #1
    cbnz    w3, .Lhfh_zero

    ldr     x0, =http_conn_table
    sub     x0, x21, x0
    lsr     x0, x0, #HCONN_SHIFT
    ldr     x1, =http_body_recv_bufs
    add     x0, x1, x0, lsl #HTTP_MAX_RECV_BODY_SHIFT

    ldr     w3, [x21, #HCONN_CONTENT_LEN]
    mov     w4, #FORM_LOG_REC_BYTES
    cmp     w3, w4
    csel    w3, w3, w4, ls

    mov     x4, x22
.Lhfh_cp:
    cbz     w3, .Lhfh_store
    ldrb    w5, [x0], #1
    strb    w5, [x4], #1
    sub     w3, w3, #1
    b       .Lhfh_cp

.Lhfh_store:
    ldr     x0, =form_log_store
    mov     x1, x22
    bl      store_append

    /* Emit "OK" */
    mov     w0, #'O'
    strb    w0, [x19]
    mov     w0, #'K'
    strb    w0, [x19, #1]
    mov     w0, #2
    b       .Lhfh_ret

.Lhfh_get:
    /* GET: emit the store's current count as decimal ASCII. */
    ldr     x0, =form_log_store
    bl      store_count
    mov     w1, w0
    mov     x0, x19
    bl      fmt_u32_decimal
    /* w0 = bytes written, propagates */

.Lhfh_ret:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/*
 * HTML fragments for guestbook rendering. Kept as plain ASCII in
 * .rodata; the handler copies them through the per-HCONN output
 * buffer via gb_emit_literal.
 */
.section .rodata
http_gb_ul_open:
    .ascii  "<ul>\n"
http_gb_ul_close:
    .ascii  "</ul>\n"
http_gb_li_open:
    .ascii  "<li>"
http_gb_li_close:
    .ascii  "</li>\n"

/*
 * guestbook_slot_buf — scratch used by the guestbook handler to zero-
 * pad a request body before store_append (POST), and to read entries
 * into during rendering (GET). Shared across handler invocations
 * (serialized by the single-threaded poll loop).
 */
.section .bss
.balign 16
guestbook_slot_buf:
    .space  GUESTBOOK_REC_BYTES

.balign 16
form_log_slot_buf:
    .space  FORM_LOG_REC_BYTES
