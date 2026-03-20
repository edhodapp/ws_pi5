.include "timer.inc"

.global timer_pool_init
.global timer_set
.global timer_cancel
.global timer_check

.section .text

/*
 * timer_pool_init - Initialize a timer pool
 * x0: pool pointer
 * w1: capacity (number of slots)
 * Clobbers: x0-x3
 */
timer_pool_init:
    str     w1, [x0, #TPOOL_CAP]
    str     wzr, [x0, #TPOOL_PAD]

    /* Zero all slots: cap * 32 bytes */
    add     x2, x0, #TPOOL_SLOTS       /* x2 = start of slots */
    mov     w3, w1                      /* w3 = remaining count */
.Lpi_loop:
    cbz     w3, .Lpi_done
    stp     xzr, xzr, [x2]             /* expiry + callback */
    stp     xzr, xzr, [x2, #16]        /* context + pad */
    add     x2, x2, #SLOT_SIZE
    sub     w3, w3, #1
    b       .Lpi_loop
.Lpi_done:
    ret

/*
 * timer_set - Arm a timer in the first free slot
 * x0: pool pointer
 * x1: expiry tick
 * x2: callback function pointer
 * x3: context (passed as x0 to callback)
 * Returns: w0 = slot index (0..cap-1), or -1 if full
 * Clobbers: x0-x6
 */
timer_set:
    ldr     w4, [x0, #TPOOL_CAP]       /* w4 = capacity */
    add     x5, x0, #TPOOL_SLOTS       /* x5 = current slot ptr */
    mov     w6, #0                      /* w6 = index */
.Lts_scan:
    cmp     w6, w4
    b.ge    .Lts_full
    ldr     x0, [x5, #SLOT_CALLBACK]
    cbnz    x0, .Lts_next               /* slot active, skip */

    /* Found free slot — fill it */
    str     x1, [x5, #SLOT_EXPIRY]
    str     x2, [x5, #SLOT_CALLBACK]
    str     x3, [x5, #SLOT_CONTEXT]
    mov     w0, w6
    ret
.Lts_next:
    add     x5, x5, #SLOT_SIZE
    add     w6, w6, #1
    b       .Lts_scan
.Lts_full:
    mov     w0, #-1
    ret

/*
 * timer_cancel - Cancel a timer by slot index
 * x0: pool pointer
 * w1: slot index
 * Clobbers: x0-x2
 */
timer_cancel:
    /* slot_ptr = pool + TPOOL_SLOTS + index * SLOT_SIZE */
    mov     w2, #SLOT_SIZE
    umull   x2, w1, w2
    add     x0, x0, #TPOOL_SLOTS
    add     x0, x0, x2
    str     xzr, [x0, #SLOT_CALLBACK]  /* mark inactive */
    ret

/*
 * timer_check - Fire expired timers
 * x0: pool pointer
 * x1: current_tick
 * Returns: w0 = count of fired timers
 * Clobbers: x0-x7, x19-x23, x30
 */
timer_check:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                     /* x19 = pool ptr */
    mov     x20, x1                     /* x20 = current_tick */
    ldr     w21, [x19, #TPOOL_CAP]      /* w21 = capacity */
    add     x22, x19, #TPOOL_SLOTS      /* x22 = current slot ptr */
    mov     w23, #0                     /* w23 = fired count */

.Ltc_loop:
    cbz     w21, .Ltc_done

    /* Check if slot is active */
    ldr     x0, [x22, #SLOT_CALLBACK]
    cbz     x0, .Ltc_skip              /* inactive, skip */

    /* Check if expired: expiry <= current_tick */
    ldr     x1, [x22, #SLOT_EXPIRY]
    cmp     x1, x20
    b.hi    .Ltc_skip                  /* expiry > current_tick, not yet */

    /* Fire: clear callback BEFORE calling (safe against re-arm) */
    mov     x2, x0                      /* x2 = callback */
    str     xzr, [x22, #SLOT_CALLBACK]  /* mark inactive */
    ldr     x0, [x22, #SLOT_CONTEXT]    /* x0 = context for callback */
    blr     x2                          /* call callback(context) */
    add     w23, w23, #1

.Ltc_skip:
    add     x22, x22, #SLOT_SIZE
    sub     w21, w21, #1
    b       .Ltc_loop

.Ltc_done:
    mov     w0, w23                     /* return fired count */
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #48
    ret
