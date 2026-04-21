/* Tests for the in-RAM store API (lib/store.S). */

.include "store.inc"

.global test_store

.section .text

test_store:
    stp     x29, x30, [sp, #-16]!
    bl      test_store_init_append_count
    bl      test_store_append_read_roundtrip
    bl      test_store_wrap_around
    bl      test_store_read_oob_returns_zero
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_store_init_append_count — init a 4-slot 8-byte store, append
 * one record, verify count == 1.
 * ======================================================================== */
test_store_init_append_count:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =tstore
    mov     w1, #8                  /* record_bytes */
    mov     w2, #4                  /* capacity */
    bl      store_init

    ldr     x0, =tstore
    ldr     x1, =tstore_rec0
    bl      store_append

    ldr     x0, =tstore
    bl      store_count
    cmp     w0, #1
    b.ne    .Ltsiac_fail

    ldr     x0, =name_tsiac
    bl      test_pass
    b       .Ltsiac_done
.Ltsiac_fail:
    ldr     x0, =name_tsiac
    bl      test_fail
.Ltsiac_done:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_store_append_read_roundtrip — a record written via store_append
 * comes back exactly via store_read at index 0.
 * ======================================================================== */
test_store_append_read_roundtrip:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =tstore
    mov     w1, #8
    mov     w2, #4
    bl      store_init

    ldr     x0, =tstore
    ldr     x1, =tstore_rec0
    bl      store_append

    /* Read back into tstore_out */
    ldr     x0, =tstore
    mov     w1, #0
    ldr     x2, =tstore_out
    bl      store_read
    cmp     w0, #8
    b.ne    .Ltsarr_fail

    /* Compare tstore_out with tstore_rec0 byte-by-byte */
    ldr     x0, =tstore_out
    ldr     x1, =tstore_rec0
    mov     w2, #8
.Ltsarr_cmp:
    cbz     w2, .Ltsarr_ok
    ldrb    w3, [x0], #1
    ldrb    w4, [x1], #1
    cmp     w3, w4
    b.ne    .Ltsarr_fail
    sub     w2, w2, #1
    b       .Ltsarr_cmp

.Ltsarr_ok:
    ldr     x0, =name_tsarr
    bl      test_pass
    b       .Ltsarr_done
.Ltsarr_fail:
    ldr     x0, =name_tsarr
    bl      test_fail
.Ltsarr_done:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_store_wrap_around — appending more than capacity keeps count at
 * capacity and advances the "oldest" pointer; index 0 returns the entry
 * that was written (cap entries ago).
 * ======================================================================== */
test_store_wrap_around:
    stp     x29, x30, [sp, #-16]!

    /* 2-slot store, 1-byte records */
    ldr     x0, =tstore
    mov     w1, #1
    mov     w2, #2
    bl      store_init

    /* Append 'A', 'B', 'C' — after three writes, oldest is 'B' */
    ldr     x0, =tstore
    ldr     x1, =tstore_char_a
    bl      store_append
    ldr     x0, =tstore
    ldr     x1, =tstore_char_b
    bl      store_append
    ldr     x0, =tstore
    ldr     x1, =tstore_char_c
    bl      store_append

    /* Count should be capped at 2 */
    ldr     x0, =tstore
    bl      store_count
    cmp     w0, #2
    b.ne    .Ltswa_fail

    /* index 0 (oldest) = 'B' */
    ldr     x0, =tstore
    mov     w1, #0
    ldr     x2, =tstore_out
    bl      store_read
    ldr     x0, =tstore_out
    ldrb    w0, [x0]
    cmp     w0, #'B'
    b.ne    .Ltswa_fail

    /* index 1 (newest) = 'C' */
    ldr     x0, =tstore
    mov     w1, #1
    ldr     x2, =tstore_out
    bl      store_read
    ldr     x0, =tstore_out
    ldrb    w0, [x0]
    cmp     w0, #'C'
    b.ne    .Ltswa_fail

    ldr     x0, =name_tswa
    bl      test_pass
    b       .Ltswa_done
.Ltswa_fail:
    ldr     x0, =name_tswa
    bl      test_fail
.Ltswa_done:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_store_read_oob_returns_zero — reading at index >= count returns 0
 * bytes (and should not touch out_ptr beyond the caller's expectation).
 * ======================================================================== */
test_store_read_oob_returns_zero:
    stp     x29, x30, [sp, #-16]!

    /* Empty store: count = 0, any index is out of range */
    ldr     x0, =tstore
    mov     w1, #8
    mov     w2, #4
    bl      store_init

    ldr     x0, =tstore
    mov     w1, #0
    ldr     x2, =tstore_out
    bl      store_read
    cbnz    w0, .Ltsoob_fail

    /* After one append, count = 1; index 1 is out of range */
    ldr     x0, =tstore
    ldr     x1, =tstore_rec0
    bl      store_append

    ldr     x0, =tstore
    mov     w1, #1
    ldr     x2, =tstore_out
    bl      store_read
    cbnz    w0, .Ltsoob_fail

    ldr     x0, =name_tsoob
    bl      test_pass
    b       .Ltsoob_done
.Ltsoob_fail:
    ldr     x0, =name_tsoob
    bl      test_fail
.Ltsoob_done:
    ldp     x29, x30, [sp], #16
    ret

.section .rodata
tstore_rec0:
    .ascii  "REC00001"

tstore_char_a: .byte 'A'
tstore_char_b: .byte 'B'
tstore_char_c: .byte 'C'

name_tsiac: .asciz "store_init_append_count"
name_tsarr: .asciz "store_append_read_roundtrip"
name_tswa:  .asciz "store_wrap_around"
name_tsoob: .asciz "store_read_oob_returns_zero"

.section .bss
.balign 16
tstore:
    .space  STORE_DATA + 4 * 8      /* header + capacity * record_bytes */
tstore_out:
    .space  16                      /* scratch for store_read */
