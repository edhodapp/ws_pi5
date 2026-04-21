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

.global http_counter_handler
.global counter_store

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
