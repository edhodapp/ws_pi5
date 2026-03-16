/*
 * vmio_queue — VMIO event queue operations (circular buffer)
 */

.include "vmio.inc"

.global vmio_queue_init
.global vmio_queue_enqueue
.global vmio_queue_dequeue
.global vmio_dequeue_priority

.section .text

/*
 * vmio_queue_init — Initialize an event queue
 * x0: pointer to queue struct
 * w1: capacity (must be power of 2)
 * Clobbers: w2
 */
vmio_queue_init:
    str     wzr, [x0, #Q_HEAD]
    str     wzr, [x0, #Q_TAIL]
    sub     w2, w1, #1
    str     w2, [x0, #Q_MASK]
    ret

/*
 * vmio_queue_enqueue — Add an event to the queue
 * x0: pointer to queue struct
 * x1: pointer to event (32 bytes) to copy in
 * Returns: w0 = 0 on success, -1 if full
 * Clobbers: x2-x7
 */
vmio_queue_enqueue:
    ldr     w2, [x0, #Q_TAIL]
    ldr     w3, [x0, #Q_MASK]
    add     w4, w2, #1
    and     w4, w4, w3          /* next_tail = (tail+1) & mask */
    ldr     w5, [x0, #Q_HEAD]
    cmp     w4, w5
    b.eq    .Lenq_full

    /* Compute slot address: &q_slots[tail * EVT_SIZE] */
    add     x5, x0, #Q_SLOTS
    lsl     w6, w2, #5          /* tail * 32 */
    add     x5, x5, x6

    /* Copy 32 bytes: 2x ldp/stp */
    ldp     x6, x7, [x1]
    stp     x6, x7, [x5]
    ldp     x6, x7, [x1, #16]
    stp     x6, x7, [x5, #16]

    /* Advance tail */
    str     w4, [x0, #Q_TAIL]
    mov     w0, #0
    ret

.Lenq_full:
    mov     w0, #-1
    ret

/*
 * vmio_queue_dequeue — Remove an event from the queue
 * x0: pointer to queue struct
 * x1: pointer to destination buffer (32 bytes)
 * Returns: w0 = 0 on success, -1 if empty
 * Clobbers: x2-x7
 */
vmio_queue_dequeue:
    ldr     w2, [x0, #Q_HEAD]
    ldr     w3, [x0, #Q_TAIL]
    cmp     w2, w3
    b.eq    .Ldeq_empty

    /* Compute slot address: &q_slots[head * EVT_SIZE] */
    ldr     w3, [x0, #Q_MASK]
    add     x4, x0, #Q_SLOTS
    lsl     w5, w2, #5          /* head * 32 */
    add     x4, x4, x5

    /* Copy 32 bytes out */
    ldp     x5, x6, [x4]
    stp     x5, x6, [x1]
    ldp     x5, x6, [x4, #16]
    stp     x5, x6, [x1, #16]

    /* Advance head */
    add     w2, w2, #1
    and     w2, w2, w3
    str     w2, [x0, #Q_HEAD]
    mov     w0, #0
    ret

.Ldeq_empty:
    mov     w0, #-1
    ret

/*
 * vmio_dequeue_priority — Dequeue from hi queue first, then lo queue
 * x0: pointer to hi-priority queue
 * x1: pointer to lo-priority queue
 * x2: pointer to destination buffer (32 bytes)
 * Returns: w0 = 0 on success, -1 if both empty
 * Clobbers: x3-x7
 */
vmio_dequeue_priority:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x1             /* save lo queue ptr */

    /* Try hi queue first */
    mov     x1, x2
    bl      vmio_queue_dequeue
    cbz     w0, .Lprio_done

    /* Hi was empty — try lo queue */
    mov     x0, x19
    bl      vmio_queue_dequeue

.Lprio_done:
    ldp     x19, x30, [sp], #16
    ret
