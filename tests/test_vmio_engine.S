/*
 * test_vmio_engine — Tests for VMIO FSA engine
 */

.include "vmio.inc"

.global test_vmio_engine

.section .text

test_vmio_engine:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      test_engine_init
    bl      test_engine_step_idle
    bl      test_engine_step_no_trans
    bl      test_engine_step_oob
    bl      test_engine_step_one
    bl      test_engine_multi_step

    ldp     x29, x30, [sp], #16
    ret

/* ---- Handler stubs ---- */

/*
 * teng_handler_set_flag — stores 1 at [x2]
 * x0=event_ptr, x1=engine_ptr, x2=ctx_ptr
 */
teng_handler_set_flag:
    mov     w3, #1
    str     w3, [x2]
    ret

/*
 * teng_handler_inc — increments word at [x2]
 * x0=event_ptr, x1=engine_ptr, x2=ctx_ptr
 */
teng_handler_inc:
    ldr     w3, [x2]
    add     w3, w3, #1
    str     w3, [x2]
    ret

/* ---- Helper: init both queues + zero table ---- */
teng_setup:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =teng_hi_queue
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init
    ldr     x0, =teng_lo_queue
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    /* Zero the transition table (96 bytes = 12 x 8) */
    ldr     x0, =teng_table
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]
    stp     xzr, xzr, [x0, #48]
    stp     xzr, xzr, [x0, #64]
    stp     xzr, xzr, [x0, #80]

    /* Zero the flag */
    ldr     x0, =teng_flag
    str     wzr, [x0]

    ldp     x29, x30, [sp], #16
    ret

/* ---- Helper: enqueue event with given code to lo queue ---- */
/* w0 = evt_code. Clobbers x0-x7, sp adjusted temporarily. */
teng_enqueue_lo:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    sub     sp, sp, #EVT_SIZE
    stp     xzr, xzr, [sp]
    stp     xzr, xzr, [sp, #16]
    strh    w0, [sp, #EVT_CODE]

    ldr     x0, =teng_lo_queue
    mov     x1, sp
    bl      vmio_queue_enqueue

    add     sp, sp, #EVT_SIZE
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_engine_init ---- */
test_engine_init:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      teng_setup

    /* Call vmio_engine_init */
    ldr     x0, =teng_engine
    mov     w1, #0              /* initial state */
    mov     w2, #3              /* n_states */
    mov     w3, #2              /* n_events */
    ldr     x4, =teng_table
    ldr     x5, =teng_hi_queue
    ldr     x6, =teng_lo_queue
    ldr     x7, =teng_flag
    bl      vmio_engine_init

    /* Verify all fields */
    ldr     x0, =teng_engine
    ldr     w1, [x0, #ENG_STATE]
    cbnz    w1, .Lfail_einit
    ldr     w1, [x0, #ENG_NSTATES]
    cmp     w1, #3
    b.ne    .Lfail_einit
    ldr     w1, [x0, #ENG_NEVENTS]
    cmp     w1, #2
    b.ne    .Lfail_einit
    ldr     x1, [x0, #ENG_TABLE]
    ldr     x2, =teng_table
    cmp     x1, x2
    b.ne    .Lfail_einit
    ldr     x1, [x0, #ENG_HI_Q]
    ldr     x2, =teng_hi_queue
    cmp     x1, x2
    b.ne    .Lfail_einit
    ldr     x1, [x0, #ENG_LO_Q]
    ldr     x2, =teng_lo_queue
    cmp     x1, x2
    b.ne    .Lfail_einit
    ldr     x1, [x0, #ENG_CTX]
    ldr     x2, =teng_flag
    cmp     x1, x2
    b.ne    .Lfail_einit

    ldr     x0, =name_einit
    bl      test_pass
    b       .Ldone_einit
.Lfail_einit:
    ldr     x0, =name_einit
    bl      test_fail
.Ldone_einit:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_engine_step_idle ---- */
test_engine_step_idle:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      teng_setup

    /* Init engine with empty queues */
    ldr     x0, =teng_engine
    mov     w1, #0
    mov     w2, #3
    mov     w3, #2
    ldr     x4, =teng_table
    ldr     x5, =teng_hi_queue
    ldr     x6, =teng_lo_queue
    ldr     x7, =teng_flag
    bl      vmio_engine_init

    /* Step — should return STEP_IDLE (1) */
    ldr     x0, =teng_engine
    bl      vmio_engine_step
    cmp     w0, #STEP_IDLE
    b.ne    .Lfail_esidle

    ldr     x0, =name_esidle
    bl      test_pass
    b       .Ldone_esidle
.Lfail_esidle:
    ldr     x0, =name_esidle
    bl      test_fail
.Ldone_esidle:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_engine_step_no_trans ---- */
test_engine_step_no_trans:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      teng_setup

    /* Init engine (table is all zeros = no transitions) */
    ldr     x0, =teng_engine
    mov     w1, #0
    mov     w2, #3
    mov     w3, #2
    ldr     x4, =teng_table
    ldr     x5, =teng_hi_queue
    ldr     x6, =teng_lo_queue
    ldr     x7, =teng_flag
    bl      vmio_engine_init

    /* Enqueue one event (code=0) */
    mov     w0, #0
    bl      teng_enqueue_lo

    /* Step — should return STEP_NO_TRANS (-1) */
    ldr     x0, =teng_engine
    bl      vmio_engine_step
    cmn     w0, #1
    b.ne    .Lfail_esnt

    /* Verify state unchanged (still 0) */
    ldr     x0, =teng_engine
    ldr     w1, [x0, #ENG_STATE]
    cbnz    w1, .Lfail_esnt

    ldr     x0, =name_esnt
    bl      test_pass
    b       .Ldone_esnt
.Lfail_esnt:
    ldr     x0, =name_esnt
    bl      test_fail
.Ldone_esnt:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_engine_step_oob ---- */
test_engine_step_oob:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      teng_setup

    /* Init engine: n_events=2 */
    ldr     x0, =teng_engine
    mov     w1, #0
    mov     w2, #3
    mov     w3, #2
    ldr     x4, =teng_table
    ldr     x5, =teng_hi_queue
    ldr     x6, =teng_lo_queue
    ldr     x7, =teng_flag
    bl      vmio_engine_init

    /* Enqueue event with code=2 (out of bounds for n_events=2) */
    mov     w0, #2
    bl      teng_enqueue_lo

    /* Step — should return STEP_NO_TRANS via b.hs */
    ldr     x0, =teng_engine
    bl      vmio_engine_step
    cmn     w0, #1
    b.ne    .Lfail_esoob

    ldr     x0, =name_esoob
    bl      test_pass
    b       .Ldone_esoob
.Lfail_esoob:
    ldr     x0, =name_esoob
    bl      test_fail
.Ldone_esoob:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_engine_step_one ---- */
test_engine_step_one:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      teng_setup

    /* Set table entry (state=0, code=0) → next_state=1, handler=set_flag */
    /* Index = 0*2 + 0 = 0, offset = 0*16 = 0 */
    ldr     x0, =teng_table
    mov     w1, #1
    str     w1, [x0, #TRANS_NEXT]           /* next_state = 1 */
    ldr     x1, =teng_handler_set_flag
    str     x1, [x0, #TRANS_HANDLER]        /* handler */

    /* Init engine: state=0, ctx=&teng_flag */
    ldr     x0, =teng_engine
    mov     w1, #0
    mov     w2, #3
    mov     w3, #2
    ldr     x4, =teng_table
    ldr     x5, =teng_hi_queue
    ldr     x6, =teng_lo_queue
    ldr     x7, =teng_flag
    bl      vmio_engine_init

    /* Enqueue event code=0 */
    mov     w0, #0
    bl      teng_enqueue_lo

    /* Step */
    ldr     x0, =teng_engine
    bl      vmio_engine_step
    cbnz    w0, .Lfail_es1          /* expect STEP_OK (0) */

    /* Verify state == 1 */
    ldr     x0, =teng_engine
    ldr     w1, [x0, #ENG_STATE]
    cmp     w1, #1
    b.ne    .Lfail_es1

    /* Verify flag == 1 */
    ldr     x0, =teng_flag
    ldr     w1, [x0]
    cmp     w1, #1
    b.ne    .Lfail_es1

    ldr     x0, =name_es1
    bl      test_pass
    b       .Ldone_es1
.Lfail_es1:
    ldr     x0, =name_es1
    bl      test_fail
.Ldone_es1:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_engine_multi_step ---- */
test_engine_multi_step:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      teng_setup

    /*
     * 3 states (A=0, B=1, C=2), 2 event codes (GO=0, X=1)
     * Table layout: 3*2 = 6 entries, each 16 bytes
     * Entry (state=0, code=0): next=1, handler=inc   offset=0
     * Entry (state=1, code=0): next=2, handler=inc   offset=32 (index 2)
     */
    ldr     x0, =teng_table

    /* (A=0, GO=0) -> B=1 */
    mov     w1, #1
    str     w1, [x0, #TRANS_NEXT]
    ldr     x1, =teng_handler_inc
    str     x1, [x0, #TRANS_HANDLER]

    /* (B=1, GO=0) -> C=2: index=1*2+0=2, offset=32 */
    mov     w1, #2
    str     w1, [x0, #32 + TRANS_NEXT]
    ldr     x1, =teng_handler_inc
    str     x1, [x0, #32 + TRANS_HANDLER]

    /* Init engine: state=0, ctx=&teng_flag (flag=0, used as counter) */
    ldr     x0, =teng_engine
    mov     w1, #0
    mov     w2, #3
    mov     w3, #2
    ldr     x4, =teng_table
    ldr     x5, =teng_hi_queue
    ldr     x6, =teng_lo_queue
    ldr     x7, =teng_flag
    bl      vmio_engine_init

    /* Enqueue two GO events (code=0) */
    mov     w0, #0
    bl      teng_enqueue_lo
    mov     w0, #0
    bl      teng_enqueue_lo

    /* Step 1: A->B */
    ldr     x0, =teng_engine
    bl      vmio_engine_step
    cbnz    w0, .Lfail_esm

    /* Step 2: B->C */
    ldr     x0, =teng_engine
    bl      vmio_engine_step
    cbnz    w0, .Lfail_esm

    /* Verify state == 2 (C) */
    ldr     x0, =teng_engine
    ldr     w1, [x0, #ENG_STATE]
    cmp     w1, #2
    b.ne    .Lfail_esm

    /* Verify counter == 2 */
    ldr     x0, =teng_flag
    ldr     w1, [x0]
    cmp     w1, #2
    b.ne    .Lfail_esm

    ldr     x0, =name_esm
    bl      test_pass
    b       .Ldone_esm
.Lfail_esm:
    ldr     x0, =name_esm
    bl      test_fail
.Ldone_esm:
    ldp     x29, x30, [sp], #16
    ret

/* ---- BSS ---- */
.section .bss
.balign 16
teng_engine:    .skip ENG_SIZE
teng_hi_queue:  .skip Q_DEFAULT_SIZE
teng_lo_queue:  .skip Q_DEFAULT_SIZE
teng_table:     .skip 96            /* 3 states * 2 events * 16 bytes */
teng_flag:      .skip 4

/* ---- Test name strings ---- */
.section .rodata
name_einit:     .asciz "engine_init"
name_esidle:    .asciz "engine_step_idle"
name_esnt:      .asciz "engine_step_no_trans"
name_esoob:     .asciz "engine_step_oob"
name_es1:       .asciz "engine_step_one"
name_esm:       .asciz "engine_multi_step"
