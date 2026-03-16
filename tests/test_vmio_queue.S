/*
 * test_vmio_queue — Tests for VMIO event queue operations
 */

.include "vmio.inc"

.global test_vmio_queue

.section .text

test_vmio_queue:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      test_qi_init
    bl      test_qi_enqueue_one
    bl      test_qi_enqueue_full
    bl      test_qi_dequeue_one
    bl      test_qi_dequeue_empty
    bl      test_qi_wrap
    bl      test_qi_priority
    bl      test_qi_priority_empty

    ldp     x29, x30, [sp], #16
    ret

/* ---- test_qi_init ---- */
test_qi_init:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =test_queue_0
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    ldr     x0, =test_queue_0
    ldr     w1, [x0, #Q_HEAD]
    cbnz    w1, .Lfail_init
    ldr     w1, [x0, #Q_TAIL]
    cbnz    w1, .Lfail_init
    ldr     w1, [x0, #Q_MASK]
    cmp     w1, #Q_DEFAULT_MASK
    b.ne    .Lfail_init

    ldr     x0, =name_init
    bl      test_pass
    b       .Ldone_init
.Lfail_init:
    ldr     x0, =name_init
    bl      test_fail
.Ldone_init:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_qi_enqueue_one ---- */
test_qi_enqueue_one:
    stp     x29, x30, [sp, #-16]!

    /* Init queue */
    ldr     x0, =test_queue_0
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    /* Build a known event on stack */
    sub     sp, sp, #EVT_SIZE
    mov     x0, sp
    mov     w1, #0x0001         /* auto */
    strh    w1, [x0, #EVT_AUTO]
    mov     w1, #0x0002         /* way */
    strh    w1, [x0, #EVT_WAY]
    mov     w1, #0x0003         /* code */
    strh    w1, [x0, #EVT_CODE]
    strh    wzr, [x0, #EVT_FLAGS]
    mov     x1, #0xAAAA
    str     x1, [x0, #EVT_DST]
    mov     x1, #0xBBBB
    str     x1, [x0, #EVT_SRC]
    mov     x1, #0xCCCC
    str     x1, [x0, #EVT_DATA]

    /* Enqueue */
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_enqueue
    cbnz    w0, .Lfail_enq1

    /* Check tail == 1 */
    ldr     x0, =test_queue_0
    ldr     w1, [x0, #Q_TAIL]
    cmp     w1, #1
    b.ne    .Lfail_enq1

    /* Check slot[0].evt_auto == 0x0001 */
    ldrh    w1, [x0, #Q_SLOTS + EVT_AUTO]
    cmp     w1, #0x0001
    b.ne    .Lfail_enq1

    /* Check slot[0].evt_data == 0xCCCC */
    ldr     x1, [x0, #Q_SLOTS + EVT_DATA]
    mov     x2, #0xCCCC
    cmp     x1, x2
    b.ne    .Lfail_enq1

    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_enq1
    bl      test_pass
    b       .Ldone_enq1
.Lfail_enq1:
    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_enq1
    bl      test_fail
.Ldone_enq1:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_qi_enqueue_full ---- */
test_qi_enqueue_full:
    stp     x19, x30, [sp, #-16]!

    /* Init queue */
    ldr     x0, =test_queue_0
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    /* Build a dummy event on stack */
    sub     sp, sp, #EVT_SIZE
    mov     x0, sp
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]

    /* Fill queue to capacity (mask+1 - 1 = 15 entries = full) */
    mov     w19, #0
.Lfill_loop:
    cmp     w19, #Q_DEFAULT_MASK   /* enqueue 15 times (capacity-1 = full) */
    b.ge    .Lfill_done
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_enqueue
    cbnz    w0, .Lfail_enq_full   /* should succeed */
    add     w19, w19, #1
    b       .Lfill_loop
.Lfill_done:

    /* Next enqueue should fail */
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_enqueue
    cmn     w0, #1                /* expect -1 */
    b.ne    .Lfail_enq_full

    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_enq_full
    bl      test_pass
    b       .Ldone_enq_full
.Lfail_enq_full:
    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_enq_full
    bl      test_fail
.Ldone_enq_full:
    ldp     x19, x30, [sp], #16
    ret

/* ---- test_qi_dequeue_one ---- */
test_qi_dequeue_one:
    stp     x29, x30, [sp, #-16]!

    /* Init queue */
    ldr     x0, =test_queue_0
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    /* Build event on stack: evt_code=0x42 */
    sub     sp, sp, #EVT_SIZE
    mov     x0, sp
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    mov     w1, #0x42
    strh    w1, [x0, #EVT_CODE]
    mov     x1, #0xDEAD
    str     x1, [x0, #EVT_DATA]

    /* Enqueue */
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_enqueue
    cbnz    w0, .Lfail_deq1

    /* Zero the stack event to prove dequeue writes fresh data */
    mov     x0, sp
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]

    /* Dequeue into same stack slot */
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_dequeue
    cbnz    w0, .Lfail_deq1

    /* Check head advanced */
    ldr     x0, =test_queue_0
    ldr     w1, [x0, #Q_HEAD]
    cmp     w1, #1
    b.ne    .Lfail_deq1

    /* Check dequeued evt_code == 0x42 */
    ldrh    w1, [sp, #EVT_CODE]
    cmp     w1, #0x42
    b.ne    .Lfail_deq1

    /* Check dequeued evt_data == 0xDEAD */
    ldr     x1, [sp, #EVT_DATA]
    mov     x2, #0xDEAD
    cmp     x1, x2
    b.ne    .Lfail_deq1

    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_deq1
    bl      test_pass
    b       .Ldone_deq1
.Lfail_deq1:
    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_deq1
    bl      test_fail
.Ldone_deq1:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_qi_dequeue_empty ---- */
test_qi_dequeue_empty:
    stp     x29, x30, [sp, #-16]!

    /* Init queue (empty) */
    ldr     x0, =test_queue_0
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    /* Try dequeue — should return -1 */
    sub     sp, sp, #EVT_SIZE
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_dequeue
    cmn     w0, #1
    b.ne    .Lfail_deq_empty

    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_deq_empty
    bl      test_pass
    b       .Ldone_deq_empty
.Lfail_deq_empty:
    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_deq_empty
    bl      test_fail
.Ldone_deq_empty:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_qi_wrap ---- */
test_qi_wrap:
    stp     x19, x30, [sp, #-16]!
    stp     x20, x21, [sp, #-16]!

    /* Init queue */
    ldr     x0, =test_queue_0
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    /* Allocate stack space for one event */
    sub     sp, sp, #EVT_SIZE

    /*
     * Enqueue then dequeue 20 times — forces wrap past capacity.
     * Each event has evt_code = iteration number.
     */
    mov     w19, #0             /* iteration counter */
    mov     w20, #20            /* total iterations */
.Lwrap_loop:
    cmp     w19, w20
    b.ge    .Lwrap_pass

    /* Build event: evt_code = w19 */
    mov     x0, sp
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    strh    w19, [x0, #EVT_CODE]

    /* Enqueue */
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_enqueue
    cbnz    w0, .Lfail_wrap

    /* Clear stack event */
    mov     x0, sp
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]

    /* Dequeue */
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_dequeue
    cbnz    w0, .Lfail_wrap

    /* Check evt_code == w19 */
    ldrh    w21, [sp, #EVT_CODE]
    cmp     w21, w19
    b.ne    .Lfail_wrap

    add     w19, w19, #1
    b       .Lwrap_loop

.Lwrap_pass:
    /* Verify queue is empty (head == tail) */
    ldr     x0, =test_queue_0
    ldr     w1, [x0, #Q_HEAD]
    ldr     w2, [x0, #Q_TAIL]
    cmp     w1, w2
    b.ne    .Lfail_wrap

    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_wrap
    bl      test_pass
    b       .Ldone_wrap
.Lfail_wrap:
    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_wrap
    bl      test_fail
.Ldone_wrap:
    ldp     x20, x21, [sp], #16
    ldp     x19, x30, [sp], #16
    ret

/* ---- test_qi_priority ---- */
test_qi_priority:
    stp     x29, x30, [sp, #-16]!

    /* Init both queues */
    ldr     x0, =test_queue_0
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init
    ldr     x0, =test_queue_1
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    /* Allocate stack event */
    sub     sp, sp, #EVT_SIZE

    /* Event A (code=0xAA) -> queue_0 (low priority) */
    mov     x0, sp
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    mov     w1, #0xAA
    strh    w1, [x0, #EVT_CODE]
    ldr     x0, =test_queue_0
    mov     x1, sp
    bl      vmio_queue_enqueue
    cbnz    w0, .Lfail_prio

    /* Event B (code=0xBB) -> queue_1 (high priority) */
    mov     x0, sp
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    mov     w1, #0xBB
    strh    w1, [x0, #EVT_CODE]
    ldr     x0, =test_queue_1
    mov     x1, sp
    bl      vmio_queue_enqueue
    cbnz    w0, .Lfail_prio

    /* Dequeue priority: should get B (0xBB) first from hi queue */
    ldr     x0, =test_queue_1
    ldr     x1, =test_queue_0
    mov     x2, sp
    bl      vmio_dequeue_priority
    cbnz    w0, .Lfail_prio
    ldrh    w1, [sp, #EVT_CODE]
    cmp     w1, #0xBB
    b.ne    .Lfail_prio

    /* Dequeue priority: should get A (0xAA) from lo queue */
    ldr     x0, =test_queue_1
    ldr     x1, =test_queue_0
    mov     x2, sp
    bl      vmio_dequeue_priority
    cbnz    w0, .Lfail_prio
    ldrh    w1, [sp, #EVT_CODE]
    cmp     w1, #0xAA
    b.ne    .Lfail_prio

    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_prio
    bl      test_pass
    b       .Ldone_prio
.Lfail_prio:
    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_prio
    bl      test_fail
.Ldone_prio:
    ldp     x29, x30, [sp], #16
    ret

/* ---- test_qi_priority_empty ---- */
test_qi_priority_empty:
    stp     x29, x30, [sp, #-16]!

    /* Init both queues (empty) */
    ldr     x0, =test_queue_0
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init
    ldr     x0, =test_queue_1
    mov     w1, #Q_DEFAULT_CAP
    bl      vmio_queue_init

    /* Dequeue priority from both empty — should return -1 */
    sub     sp, sp, #EVT_SIZE
    ldr     x0, =test_queue_1
    ldr     x1, =test_queue_0
    mov     x2, sp
    bl      vmio_dequeue_priority
    cmn     w0, #1
    b.ne    .Lfail_prio_empty

    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_prio_empty
    bl      test_pass
    b       .Ldone_prio_empty
.Lfail_prio_empty:
    add     sp, sp, #EVT_SIZE
    ldr     x0, =name_prio_empty
    bl      test_fail
.Ldone_prio_empty:
    ldp     x29, x30, [sp], #16
    ret

/* ---- BSS: test queues ---- */
.section .bss
.balign 16
test_queue_0:   .skip Q_DEFAULT_SIZE
test_queue_1:   .skip Q_DEFAULT_SIZE

/* ---- Test name strings ---- */
.section .rodata
name_init:       .asciz "queue_init"
name_enq1:       .asciz "enqueue_one"
name_enq_full:   .asciz "enqueue_full"
name_deq1:       .asciz "dequeue_one"
name_deq_empty:  .asciz "dequeue_empty"
name_wrap:       .asciz "queue_wrap"
name_prio:       .asciz "dequeue_priority"
name_prio_empty: .asciz "priority_empty"
