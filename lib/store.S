/*
 * store.S — In-RAM ring-buffer store.
 *
 * Layout per `include/store.inc`:
 *   words 0..3 header, then capacity * record_bytes.
 *
 * Capacity must be a power of 2 so wrap-around is a mask AND.
 * Records are byte-copied, so any alignment works for the payload.
 */

.include "store.inc"

.global store_init
.global store_append
.global store_count
.global store_read

.section .text

/*
 * store_init(x0: store, w1: record_bytes, w2: capacity)
 * Zeros records_written; stores the shape fields.
 * Leaf; clobbers: nothing beyond x0-x2.
 */
store_init:
    str     wzr, [x0, #STORE_WRITTEN]
    str     w1, [x0, #STORE_REC_BYTES]
    str     w2, [x0, #STORE_CAP]
    ret

/*
 * store_append(x0: store, x1: data_ptr)
 * Copies record_bytes from data_ptr into slot = written & (cap-1).
 * Records_written is incremented after the copy completes.
 * Leaf; clobbers: x0-x6.
 */
store_append:
    ldr     w2, [x0, #STORE_WRITTEN]
    ldr     w3, [x0, #STORE_CAP]
    sub     w4, w3, #1              /* mask = cap - 1 */
    and     w4, w2, w4              /* slot = written & mask */
    ldr     w3, [x0, #STORE_REC_BYTES]
    mul     w4, w4, w3              /* offset = slot * rec_bytes */
    add     x5, x0, #STORE_DATA
    add     x5, x5, w4, uxtw        /* dest = data_base + offset */

    /* Copy rec_bytes from x1 into x5 */
    mov     w4, w3
.Lsa_cp:
    cbz     w4, .Lsa_done
    ldrb    w6, [x1], #1
    strb    w6, [x5], #1
    sub     w4, w4, #1
    b       .Lsa_cp

.Lsa_done:
    add     w2, w2, #1
    str     w2, [x0, #STORE_WRITTEN]
    ret

/*
 * store_count(x0: store) -> w0 = min(records_written, capacity)
 * Leaf; clobbers: x0-x2.
 */
store_count:
    ldr     w1, [x0, #STORE_WRITTEN]
    ldr     w2, [x0, #STORE_CAP]
    cmp     w1, w2
    csel    w0, w1, w2, ls
    ret

/*
 * store_read(x0: store, w1: index, x2: out_ptr) -> w0 = bytes copied
 * index 0 = oldest, count-1 = newest. Returns 0 if index >= count.
 * Leaf; clobbers: x0-x7.
 */
store_read:
    ldr     w5, [x0, #STORE_WRITTEN]
    ldr     w6, [x0, #STORE_CAP]
    cmp     w5, w6
    csel    w3, w5, w6, ls          /* w3 = count */
    cmp     w1, w3
    b.hs    .Lsr_oob

    /* slot = (written - count + index) & (cap - 1) */
    sub     w5, w5, w3
    add     w5, w5, w1
    sub     w4, w6, #1              /* mask = cap - 1 */
    and     w5, w5, w4

    ldr     w6, [x0, #STORE_REC_BYTES]
    mul     w5, w5, w6              /* offset */
    add     x3, x0, #STORE_DATA
    add     x3, x3, w5, uxtw        /* source */

    mov     w5, w6
.Lsr_cp:
    cbz     w5, .Lsr_done
    ldrb    w7, [x3], #1
    strb    w7, [x2], #1
    sub     w5, w5, #1
    b       .Lsr_cp

.Lsr_done:
    mov     w0, w6
    ret

.Lsr_oob:
    mov     w0, #0
    ret
