/*
 * vmio_engine — VMIO FSA engine: init + single-step
 */

.include "vmio.inc"

.global vmio_engine_init
.global vmio_engine_step

.section .text

/*
 * vmio_engine_init — Initialize engine struct
 * x0: engine_ptr
 * w1: initial_state
 * w2: n_states
 * w3: n_events
 * x4: table_ptr
 * x5: hi_queue_ptr
 * x6: lo_queue_ptr
 * x7: ctx_ptr
 * Leaf function, no return value.
 */
vmio_engine_init:
    str     w1, [x0, #ENG_STATE]
    str     w2, [x0, #ENG_NSTATES]
    str     w3, [x0, #ENG_NEVENTS]
    str     wzr, [x0, #ENG_PAD]
    str     x4, [x0, #ENG_TABLE]
    str     x5, [x0, #ENG_HI_Q]
    str     x6, [x0, #ENG_LO_Q]
    str     x7, [x0, #ENG_CTX]
    ret

/*
 * vmio_engine_step — Dequeue one event and execute transition
 * x0: engine_ptr
 * Returns: w0 = STEP_OK (0), STEP_IDLE (1), or STEP_NO_TRANS (-1)
 * Callee-saves: x19-x22, x29, x30
 */
vmio_engine_step:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* x19 = engine_ptr */

    /* Allocate stack scratch for dequeued event */
    sub     sp, sp, #EVT_SIZE

    /* Dequeue priority: hi queue first, then lo */
    ldr     x0, [x19, #ENG_HI_Q]
    ldr     x1, [x19, #ENG_LO_Q]
    mov     x2, sp
    bl      vmio_dequeue_priority
    cbnz    w0, .Lstep_idle

    /* Event dequeued at sp. Extract evt_code (u16). */
    ldrh    w20, [sp, #EVT_CODE]    /* w20 = evt_code */

    /* Bounds-check evt_code against n_events */
    ldr     w21, [x19, #ENG_NEVENTS]
    cmp     w20, w21
    b.hs    .Lstep_no_trans

    /* Compute table index: state * n_events + evt_code */
    ldr     w22, [x19, #ENG_STATE]
    mul     w22, w22, w21           /* state * n_events */
    add     w22, w22, w20           /* + evt_code */

    /* Load entry at table + index * 16 */
    ldr     x21, [x19, #ENG_TABLE]
    lsl     w20, w22, #4            /* index * 16 */
    add     x21, x21, x20           /* entry_ptr */

    /* Check handler != 0 */
    ldr     x22, [x21, #TRANS_HANDLER]
    cbz     x22, .Lstep_no_trans

    /* Store next_state before calling handler */
    ldr     w20, [x21, #TRANS_NEXT]
    str     w20, [x19, #ENG_STATE]

    /* Call handler(x0=event_ptr, x1=engine_ptr, x2=ctx_ptr) */
    mov     x0, sp                  /* event on stack */
    mov     x1, x19
    ldr     x2, [x19, #ENG_CTX]
    blr     x22

    mov     w0, #STEP_OK
    b       .Lstep_done

.Lstep_idle:
    mov     w0, #STEP_IDLE
    b       .Lstep_done

.Lstep_no_trans:
    mov     w0, #STEP_NO_TRANS

.Lstep_done:
    add     sp, sp, #EVT_SIZE
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #48
    ret
