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
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* save out */
    mov     w20, w1                 /* save max_len */
    mov     x21, x2                 /* save HCONN */

    /* GET vs POST: HFLAG_POST set iff method was POST */
    ldrb    w0, [x21, #HCONN_FLAGS]
    tst     w0, #HFLAG_POST
    b.eq    .Lhgh_emit

    /* --- POST path: copy body into guestbook_slot_buf (zero-padded),
     * then store_append. The slot buffer is static BSS shared across
     * all handler invocations — safe because http_poll runs handlers
     * serially within a single poll tick, and the slot buffer is no
     * longer needed after store_append returns. */
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

    /* Copy min(CL, GUESTBOOK_REC_BYTES) bytes */
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

.Lhgh_emit:
    /* Minimal response: "OK" (2 bytes). Phase B will render entries. */
    mov     w0, #'O'
    strb    w0, [x19]
    mov     w0, #'K'
    strb    w0, [x19, #1]
    mov     w0, #2

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
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

/*
 * guestbook_slot_buf — scratch used by the guestbook handler to zero-
 * pad a request body before store_append. Shared across handler
 * invocations (serialized by the single-threaded poll loop).
 */
.section .bss
.balign 16
guestbook_slot_buf:
    .space  GUESTBOOK_REC_BYTES
