/*
 * test_cdc_ecm_data - Tests for cdc_ecm_activate, cdc_ecm_send, cdc_ecm_recv
 *
 * Tests:
 *   1. test_ecm_activate      — SET_INTERFACE succeeds, PIDs reset to 0
 *   2. test_ecm_activate_fail — SET_INTERFACE fails → returns 1
 *   3. test_ecm_send          — bulk OUT with correct HCCHAR/HCTSIZ
 *   4. test_ecm_recv          — bulk IN with correct HCCHAR/HCTSIZ
 */

.include "dwc2.inc"
.include "cdc_ecm.inc"

.global test_ecm_activate
.global test_ecm_activate_fail
.global test_ecm_send
.global test_ecm_recv

.section .text

/* ========================================================================
 * fake_ecmd_xfer — saves HCCHAR/HCTSIZ, increments call_count, fail support
 *
 * Inputs: x0=chan_base, w1=HCCHAR, w2=HCTSIZ, x3=DMA addr
 * Returns: w0 = HCINT value
 * ======================================================================== */
fake_ecmd_xfer:
    ldr     x9, =ecmd_saved_hcchar
    str     w1, [x9]
    ldr     x9, =ecmd_saved_hctsiz
    str     w2, [x9]

    /* Write HCTSIZ=0 to channel register so usb_bulk_xfer reads remaining=0 */
    str     wzr, [x0, #HC_TSIZ]

    ldr     x9, =ecmd_call_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]

    ldr     x9, =ecmd_fail_at
    ldr     w11, [x9]
    cbz     w11, .Lecmd_ok
    cmp     w10, w11
    b.eq    .Lecmd_fail

.Lecmd_ok:
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lecmd_fail:
    mov     w0, #HCINT_CHHLTD
    ret

/* ========================================================================
 * ecmd_test_setup — install fake, clear counter
 *
 * w0: fail_at value (0 = no failure)
 * Outputs: x19 = &usb_channel_xfer_fn, x20 = original fn ptr
 * ======================================================================== */
ecmd_test_setup:
    ldr     x19, =usb_channel_xfer_fn
    ldr     x20, [x19]
    ldr     x9, =fake_ecmd_xfer
    str     x9, [x19]

    ldr     x9, =ecmd_call_count
    str     wzr, [x9]

    ldr     x9, =ecmd_fail_at
    str     w0, [x9]

    ret

/* ========================================================================
 * ecmd_test_teardown — restore original fn ptr (preserves w0)
 * ======================================================================== */
ecmd_test_teardown:
    str     x20, [x19]
    ret

/* ========================================================================
 * test_ecm_activate — SET_INTERFACE succeeds, PIDs reset
 *
 * Pre-fill PID fields with 0xDEADBEEF sentinel.
 * After success: ret==0, IN_PID==0, OUT_PID==0, call_count==2
 * ======================================================================== */
test_ecm_activate:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #0
    bl      ecmd_test_setup

    /* Pre-fill PID fields with sentinel */
    ldr     x9, =ecmd_ecm_state
    ldr     w10, =0xDEADBEEF
    str     w10, [x9, #ECM_IN_PID]
    str     w10, [x9, #ECM_OUT_PID]

    /* cdc_ecm_activate(dwc2_base=0, ecm_state) */
    mov     x0, #0
    ldr     x1, =ecmd_ecm_state
    bl      cdc_ecm_activate

    mov     w10, w0
    bl      ecmd_test_teardown

    /* ret == 0 */
    cbnz    w10, .Lfail_ecm_act

    /* IN_PID == 0 */
    ldr     x9, =ecmd_ecm_state
    ldr     w11, [x9, #ECM_IN_PID]
    cbnz    w11, .Lfail_ecm_act

    /* OUT_PID == 0 */
    ldr     w11, [x9, #ECM_OUT_PID]
    cbnz    w11, .Lfail_ecm_act

    /* call_count == 2 */
    ldr     x9, =ecmd_call_count
    ldr     w11, [x9]
    cmp     w11, #2
    b.ne    .Lfail_ecm_act

    ldr     x0, =name_ecm_activate
    bl      test_pass
    b       .Ldone_ecm_act

.Lfail_ecm_act:
    ldr     x0, =name_ecm_activate
    bl      test_fail

.Ldone_ecm_act:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_ecm_activate_fail — fail_at=1 → ret==1
 * ======================================================================== */
test_ecm_activate_fail:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #1
    bl      ecmd_test_setup

    mov     x0, #0
    ldr     x1, =ecmd_ecm_state
    bl      cdc_ecm_activate

    mov     w10, w0
    bl      ecmd_test_teardown

    /* ret == 1 */
    cmp     w10, #1
    b.ne    .Lfail_ecm_act_f

    ldr     x0, =name_ecm_activate_fail
    bl      test_pass
    b       .Ldone_ecm_act_f

.Lfail_ecm_act_f:
    ldr     x0, =name_ecm_activate_fail
    bl      test_fail

.Ldone_ecm_act_f:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_ecm_send — bulk OUT ep 0x02, MPS=64, len=64, PID=DATA0
 *
 * Expected HCCHAR: 0x80481040
 * Expected HCTSIZ: 0x00080040
 * ======================================================================== */
test_ecm_send:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #0
    bl      ecmd_test_setup

    /* Fill ecm_state for OUT endpoint */
    ldr     x9, =ecmd_ecm_state
    mov     w10, #0x02
    strb    w10, [x9, #ECM_OUT_ADDR]
    mov     w10, #64
    strh    w10, [x9, #ECM_OUT_MPS]
    str     wzr, [x9, #ECM_OUT_PID]

    /* cdc_ecm_send(dwc2_base=0, ecm_state, buf, len=64) */
    mov     x0, #0
    ldr     x1, =ecmd_ecm_state
    ldr     x2, =ecmd_test_buf
    mov     w3, #64
    bl      cdc_ecm_send

    mov     w10, w0
    bl      ecmd_test_teardown

    /* ret == 0 */
    cbnz    w10, .Lfail_ecm_send

    /* HCCHAR == 0x80481040 */
    ldr     x9, =ecmd_saved_hcchar
    ldr     w9, [x9]
    ldr     w11, =0x80481040
    cmp     w9, w11
    b.ne    .Lfail_ecm_send

    /* HCTSIZ == 0x00080040 */
    ldr     x9, =ecmd_saved_hctsiz
    ldr     w9, [x9]
    ldr     w11, =0x00080040
    cmp     w9, w11
    b.ne    .Lfail_ecm_send

    ldr     x0, =name_ecm_send
    bl      test_pass
    b       .Ldone_ecm_send

.Lfail_ecm_send:
    ldr     x0, =name_ecm_send
    bl      test_fail

.Ldone_ecm_send:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_ecm_recv — bulk IN ep 0x83, MPS=64, len=64, PID=DATA0
 *
 * Expected HCCHAR: 0x80489840
 * Expected HCTSIZ: 0x00080040
 * ======================================================================== */
test_ecm_recv:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #0
    bl      ecmd_test_setup

    /* Fill ecm_state for IN endpoint */
    ldr     x9, =ecmd_ecm_state
    mov     w10, #0x83
    strb    w10, [x9, #ECM_IN_ADDR]
    mov     w10, #64
    strh    w10, [x9, #ECM_IN_MPS]
    str     wzr, [x9, #ECM_IN_PID]

    /* cdc_ecm_recv(dwc2_base=0, ecm_state, buf, len=64) */
    mov     x0, #0
    ldr     x1, =ecmd_ecm_state
    ldr     x2, =ecmd_test_buf
    mov     w3, #64
    bl      cdc_ecm_recv

    mov     w10, w0
    bl      ecmd_test_teardown

    /* ret == 0 */
    cbnz    w10, .Lfail_ecm_recv

    /* HCCHAR == 0x80489840 */
    ldr     x9, =ecmd_saved_hcchar
    ldr     w9, [x9]
    ldr     w11, =0x80489840
    cmp     w9, w11
    b.ne    .Lfail_ecm_recv

    /* HCTSIZ == 0x00080040 */
    ldr     x9, =ecmd_saved_hctsiz
    ldr     w9, [x9]
    ldr     w11, =0x00080040
    cmp     w9, w11
    b.ne    .Lfail_ecm_recv

    ldr     x0, =name_ecm_recv
    bl      test_pass
    b       .Ldone_ecm_recv

.Lfail_ecm_recv:
    ldr     x0, =name_ecm_recv
    bl      test_fail

.Ldone_ecm_recv:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .data
.balign 4
ecmd_saved_hcchar:      .word 0
ecmd_saved_hctsiz:      .word 0
ecmd_call_count:        .word 0
ecmd_fail_at:           .word 0

.balign 16
ecmd_ecm_state:
    .space  ECM_SIZE

.balign 4
ecmd_test_buf:
    .space  64

.section .rodata
name_ecm_activate:      .asciz "ecm_activate"
name_ecm_activate_fail: .asciz "ecm_activate_fail"
name_ecm_send:          .asciz "ecm_send"
name_ecm_recv:          .asciz "ecm_recv"
