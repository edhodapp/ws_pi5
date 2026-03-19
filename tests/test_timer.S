/*
 * test_timer — Tests for timer infrastructure
 */

.include "timer.inc"

.global test_timer

.section .text

test_timer:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      test_timer_now
    bl      test_timer_freq
    bl      test_pool_init
    bl      test_set
    bl      test_set_full
    bl      test_cancel
    bl      test_check_fires
    bl      test_check_not_yet
    bl      test_check_clears
    bl      test_check_multiple

    ldp     x29, x30, [sp], #16
    ret

/* ---- Callback stub: increments word at [x0] ---- */
ttimer_cb_inc:
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]
    ret

/* ---- Helper: init pool with default capacity and zero counter ---- */
ttimer_setup:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =ttimer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init

    ldr     x0, =ttimer_counter
    str     wzr, [x0]

    ldp     x29, x30, [sp], #16
    ret

/* ---- test_timer_now: counter is monotonic ---- */
test_timer_now:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      timer_now
    mov     x19, x0             /* first reading */
    bl      timer_now           /* second reading */

    cmp     x0, x19
    b.lo    .Lfail_tnow        /* second < first = not monotonic */

    ldr     x0, =name_tnow
    bl      test_pass
    b       .Ldone_tnow
.Lfail_tnow:
    ldr     x0, =name_tnow
    bl      test_fail
.Ldone_tnow:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_timer_freq: frequency > 0 ---- */
test_timer_freq:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      timer_freq
    cbz     x0, .Lfail_tfreq

    ldr     x0, =name_tfreq
    bl      test_pass
    b       .Ldone_tfreq
.Lfail_tfreq:
    ldr     x0, =name_tfreq
    bl      test_fail
.Ldone_tfreq:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_pool_init: capacity stored, all callbacks zero ---- */
test_pool_init:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      ttimer_setup

    /* Check capacity */
    ldr     x0, =ttimer_pool
    ldr     w1, [x0, #TPOOL_CAP]
    cmp     w1, #TPOOL_DEFAULT_CAP
    b.ne    .Lfail_pinit

    /* Check all callbacks are zero */
    add     x2, x0, #TPOOL_SLOTS
    mov     w3, #TPOOL_DEFAULT_CAP
.Lpi_check:
    cbz     w3, .Lpi_ok
    ldr     x4, [x2, #SLOT_CALLBACK]
    cbnz    x4, .Lfail_pinit
    add     x2, x2, #SLOT_SIZE
    sub     w3, w3, #1
    b       .Lpi_check
.Lpi_ok:
    ldr     x0, =name_pinit
    bl      test_pass
    b       .Ldone_pinit
.Lfail_pinit:
    ldr     x0, =name_pinit
    bl      test_fail
.Ldone_pinit:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_set: set one timer, verify slot filled, returns 0 ---- */
test_set:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      ttimer_setup

    ldr     x0, =ttimer_pool
    mov     x1, #1000              /* expiry */
    ldr     x2, =ttimer_cb_inc     /* callback */
    ldr     x3, =ttimer_counter    /* context */
    bl      timer_set

    /* Should return index 0 */
    cbnz    w0, .Lfail_tset

    /* Verify slot 0 has correct expiry */
    ldr     x1, =ttimer_pool
    add     x1, x1, #TPOOL_SLOTS
    ldr     x2, [x1, #SLOT_EXPIRY]
    cmp     x2, #1000
    b.ne    .Lfail_tset

    /* Verify callback is non-zero */
    ldr     x2, [x1, #SLOT_CALLBACK]
    cbz     x2, .Lfail_tset

    ldr     x0, =name_tset
    bl      test_pass
    b       .Ldone_tset
.Lfail_tset:
    ldr     x0, =name_tset
    bl      test_fail
.Ldone_tset:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_set_full: fill all slots, next returns -1 ---- */
test_set_full:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      ttimer_setup

    /* Fill all 16 slots */
    mov     w19, #TPOOL_DEFAULT_CAP
.Ltsf_fill:
    cbz     w19, .Ltsf_try_extra
    ldr     x0, =ttimer_pool
    mov     x1, #5000
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set
    sub     w19, w19, #1
    b       .Ltsf_fill

.Ltsf_try_extra:
    /* One more should fail with -1 */
    ldr     x0, =ttimer_pool
    mov     x1, #9999
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set
    cmn     w0, #1
    b.ne    .Lfail_tsf

    ldr     x0, =name_tsf
    bl      test_pass
    b       .Ldone_tsf
.Lfail_tsf:
    ldr     x0, =name_tsf
    bl      test_fail
.Ldone_tsf:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_cancel: set then cancel, verify callback is 0 ---- */
test_cancel:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      ttimer_setup

    /* Set a timer */
    ldr     x0, =ttimer_pool
    mov     x1, #2000
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set
    mov     w19, w0             /* save slot index */

    /* Cancel it */
    ldr     x0, =ttimer_pool
    mov     w1, w19
    bl      timer_cancel

    /* Verify callback is 0 */
    ldr     x0, =ttimer_pool
    add     x0, x0, #TPOOL_SLOTS
    /* index 0, so no offset needed */
    ldr     x1, [x0, #SLOT_CALLBACK]
    cbnz    x1, .Lfail_tcan

    ldr     x0, =name_tcan
    bl      test_pass
    b       .Ldone_tcan
.Lfail_tcan:
    ldr     x0, =name_tcan
    bl      test_fail
.Ldone_tcan:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_check_fires: timer with past expiry fires ---- */
test_check_fires:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      ttimer_setup

    /* Set timer expiring at tick 100 */
    ldr     x0, =ttimer_pool
    mov     x1, #100
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set

    /* Check with current_tick = 200 (past expiry) */
    ldr     x0, =ttimer_pool
    mov     x1, #200
    bl      timer_check

    /* Should have fired 1 timer */
    cmp     w0, #1
    b.ne    .Lfail_tcf

    /* Counter should be 1 */
    ldr     x0, =ttimer_counter
    ldr     w1, [x0]
    cmp     w1, #1
    b.ne    .Lfail_tcf

    ldr     x0, =name_tcf
    bl      test_pass
    b       .Ldone_tcf
.Lfail_tcf:
    ldr     x0, =name_tcf
    bl      test_fail
.Ldone_tcf:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_check_not_yet: future timer does not fire ---- */
test_check_not_yet:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      ttimer_setup

    /* Set timer expiring at tick 500 */
    ldr     x0, =ttimer_pool
    mov     x1, #500
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set

    /* Check with current_tick = 100 (before expiry) */
    ldr     x0, =ttimer_pool
    mov     x1, #100
    bl      timer_check

    /* Should have fired 0 timers */
    cbnz    w0, .Lfail_tcny

    /* Counter should still be 0 */
    ldr     x0, =ttimer_counter
    ldr     w1, [x0]
    cbnz    w1, .Lfail_tcny

    ldr     x0, =name_tcny
    bl      test_pass
    b       .Ldone_tcny
.Lfail_tcny:
    ldr     x0, =name_tcny
    bl      test_fail
.Ldone_tcny:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_check_clears: after firing, slot is inactive ---- */
test_check_clears:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      ttimer_setup

    /* Set timer expiring at tick 50 */
    ldr     x0, =ttimer_pool
    mov     x1, #50
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set

    /* Fire it */
    ldr     x0, =ttimer_pool
    mov     x1, #100
    bl      timer_check

    /* Verify slot 0 callback is now 0 (single-shot) */
    ldr     x0, =ttimer_pool
    add     x0, x0, #TPOOL_SLOTS
    ldr     x1, [x0, #SLOT_CALLBACK]
    cbnz    x1, .Lfail_tccl

    /* Fire again — counter should NOT increment */
    ldr     x0, =ttimer_pool
    mov     x1, #200
    bl      timer_check

    ldr     x0, =ttimer_counter
    ldr     w1, [x0]
    cmp     w1, #1              /* should still be 1 from first fire */
    b.ne    .Lfail_tccl

    ldr     x0, =name_tccl
    bl      test_pass
    b       .Ldone_tccl
.Lfail_tccl:
    ldr     x0, =name_tccl
    bl      test_fail
.Ldone_tccl:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_check_multiple: 3 timers, 2 expired, 1 not ---- */
test_check_multiple:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      ttimer_setup

    /* Timer A: expiry=100 (should fire) */
    ldr     x0, =ttimer_pool
    mov     x1, #100
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set

    /* Timer B: expiry=200 (should fire) */
    ldr     x0, =ttimer_pool
    mov     x1, #200
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set

    /* Timer C: expiry=900 (should NOT fire) */
    ldr     x0, =ttimer_pool
    mov     x1, #900
    ldr     x2, =ttimer_cb_inc
    ldr     x3, =ttimer_counter
    bl      timer_set

    /* Check with current_tick = 500 */
    ldr     x0, =ttimer_pool
    mov     x1, #500
    bl      timer_check

    /* Should return count = 2 */
    cmp     w0, #2
    b.ne    .Lfail_tcm

    /* Counter should be 2 */
    ldr     x0, =ttimer_counter
    ldr     w1, [x0]
    cmp     w1, #2
    b.ne    .Lfail_tcm

    ldr     x0, =name_tcm
    bl      test_pass
    b       .Ldone_tcm
.Lfail_tcm:
    ldr     x0, =name_tcm
    bl      test_fail
.Ldone_tcm:
    ldp     x29, x30, [sp], #16
    ret

/* ---- BSS ---- */
.section .bss
.balign 16
ttimer_pool:    .skip TPOOL_DEFAULT_SIZE
ttimer_counter: .skip 4

/* ---- Test name strings ---- */
.section .rodata
name_tnow:     .asciz "timer_now"
name_tfreq:    .asciz "timer_freq"
name_pinit:    .asciz "timer_pool_init"
name_tset:     .asciz "timer_set"
name_tsf:      .asciz "timer_set_full"
name_tcan:     .asciz "timer_cancel"
name_tcf:      .asciz "timer_check_fires"
name_tcny:     .asciz "timer_check_not_yet"
name_tccl:     .asciz "timer_check_clears"
name_tcm:      .asciz "timer_check_multiple"
