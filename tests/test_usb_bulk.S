/*
 * test_usb_bulk - Tests for usb_bulk_xfer
 *
 * Tests:
 *   1. test_bulk_xfer_out  — OUT, pktcnt=2 (even), PID stays DATA0
 *   2. test_bulk_xfer_in   — IN,  pktcnt=1 (odd),  PID toggles DATA1→DATA0
 *   3. test_bulk_xfer_fail — failure path, PID unchanged
 */

.include "dwc2.inc"

.global test_bulk_xfer_out
.global test_bulk_xfer_in
.global test_bulk_xfer_fail

.section .text

/* ========================================================================
 * fake_bulk_save_xfer — saves HCCHAR/HCTSIZ, returns success or fail
 *
 * Inputs: x0=chan_base, w1=HCCHAR, w2=HCTSIZ, x3=DMA addr
 * Returns: w0 = HCINT value
 * ======================================================================== */
fake_bulk_save_xfer:
    ldr     x9, =bulk_saved_hcchar
    str     w1, [x9]
    ldr     x9, =bulk_saved_hctsiz
    str     w2, [x9]

    /* Write HCTSIZ=0 to channel register so usb_bulk_xfer reads remaining=0 */
    str     wzr, [x0, #HC_TSIZ]

    ldr     x9, =bulk_fake_fail
    ldr     w9, [x9]
    cbnz    w9, .Lbfake_fail

    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lbfake_fail:
    mov     w0, #HCINT_CHHLTD
    ret

/* ========================================================================
 * bulk_test_setup — install fake, clear fail flag
 * Outputs: x19 = &usb_channel_xfer_fn, x20 = original fn ptr
 * ======================================================================== */
bulk_test_setup:
    ldr     x19, =usb_channel_xfer_fn
    ldr     x20, [x19]
    ldr     x9, =fake_bulk_save_xfer
    str     x9, [x19]
    ldr     x9, =bulk_fake_fail
    str     wzr, [x9]
    ret

/* ========================================================================
 * bulk_test_teardown — restore original fn ptr (preserves w0)
 * ======================================================================== */
bulk_test_teardown:
    str     x20, [x19]
    ret

/* ========================================================================
 * test_bulk_xfer_out — OUT ep 0x02, len=128, MPS=64, DATA0
 *
 * Expected HCCHAR: 0x80481040
 * Expected HCTSIZ: 0x00100080
 * pktcnt=2 (even) → PID stays DATA0
 * ======================================================================== */
test_bulk_xfer_out:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    bl      bulk_test_setup

    /* Set initial PID = DATA0 */
    ldr     x9, =bulk_test_pid
    str     wzr, [x9]

    /* usb_bulk_xfer(base=0, dev=1, ep=0x02, mps=64, buf, len=128, pid_ptr) */
    mov     x0, #0
    mov     w1, #1
    mov     w2, #0x02
    mov     w3, #64
    ldr     x4, =bulk_test_buf
    mov     w5, #128
    ldr     x6, =bulk_test_pid
    bl      usb_bulk_xfer

    mov     w10, w0
    bl      bulk_test_teardown

    /* return == 0 */
    cbnz    w10, .Lfail_bulk_out

    /* HCCHAR == 0x80481040 */
    ldr     x9, =bulk_saved_hcchar
    ldr     w9, [x9]
    ldr     w11, =0x80481040
    cmp     w9, w11
    b.ne    .Lfail_bulk_out

    /* HCTSIZ == 0x00100080 */
    ldr     x9, =bulk_saved_hctsiz
    ldr     w9, [x9]
    ldr     w11, =0x00100080
    cmp     w9, w11
    b.ne    .Lfail_bulk_out

    /* PID unchanged (DATA0 = 0) */
    ldr     x9, =bulk_test_pid
    ldr     w9, [x9]
    cbnz    w9, .Lfail_bulk_out

    ldr     x0, =name_bulk_out
    bl      test_pass
    b       .Ldone_bulk_out

.Lfail_bulk_out:
    ldr     x0, =name_bulk_out
    bl      test_fail

.Ldone_bulk_out:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_bulk_xfer_in — IN ep 0x83, len=64, MPS=64, DATA1
 *
 * Expected HCCHAR: 0x80489840
 * Expected HCTSIZ: 0x40080040
 * pktcnt=1 (odd) → PID toggles DATA1→DATA0
 * ======================================================================== */
test_bulk_xfer_in:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    bl      bulk_test_setup

    /* Set initial PID = DATA1 */
    ldr     x9, =bulk_test_pid
    ldr     w10, =HCTSIZ_PID_DATA1
    str     w10, [x9]

    /* usb_bulk_xfer(base=0, dev=1, ep=0x83, mps=64, buf, len=64, pid_ptr) */
    mov     x0, #0
    mov     w1, #1
    mov     w2, #0x83
    mov     w3, #64
    ldr     x4, =bulk_test_buf
    mov     w5, #64
    ldr     x6, =bulk_test_pid
    bl      usb_bulk_xfer

    mov     w10, w0
    bl      bulk_test_teardown

    /* return == 0 */
    cbnz    w10, .Lfail_bulk_in

    /* HCCHAR == 0x80489840 */
    ldr     x9, =bulk_saved_hcchar
    ldr     w9, [x9]
    ldr     w11, =0x80489840
    cmp     w9, w11
    b.ne    .Lfail_bulk_in

    /* HCTSIZ == 0x40080040 */
    ldr     x9, =bulk_saved_hctsiz
    ldr     w9, [x9]
    ldr     w11, =0x40080040
    cmp     w9, w11
    b.ne    .Lfail_bulk_in

    /* PID toggled to DATA0 = 0 */
    ldr     x9, =bulk_test_pid
    ldr     w9, [x9]
    cbnz    w9, .Lfail_bulk_in

    ldr     x0, =name_bulk_in
    bl      test_pass
    b       .Ldone_bulk_in

.Lfail_bulk_in:
    ldr     x0, =name_bulk_in
    bl      test_fail

.Ldone_bulk_in:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_bulk_xfer_fail — failure path, PID unchanged
 * ======================================================================== */
test_bulk_xfer_fail:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    bl      bulk_test_setup

    /* Set fail flag */
    ldr     x9, =bulk_fake_fail
    mov     w10, #1
    str     w10, [x9]

    /* Set initial PID = DATA0 */
    ldr     x9, =bulk_test_pid
    str     wzr, [x9]

    /* usb_bulk_xfer(base=0, dev=1, ep=0x02, mps=64, buf, len=64, pid_ptr) */
    mov     x0, #0
    mov     w1, #1
    mov     w2, #0x02
    mov     w3, #64
    ldr     x4, =bulk_test_buf
    mov     w5, #64
    ldr     x6, =bulk_test_pid
    bl      usb_bulk_xfer

    mov     w10, w0
    bl      bulk_test_teardown

    /* return == 1 */
    cmp     w10, #1
    b.ne    .Lfail_bulk_fail

    /* PID unchanged (DATA0 = 0) */
    ldr     x9, =bulk_test_pid
    ldr     w9, [x9]
    cbnz    w9, .Lfail_bulk_fail

    ldr     x0, =name_bulk_fail
    bl      test_pass
    b       .Ldone_bulk_fail

.Lfail_bulk_fail:
    ldr     x0, =name_bulk_fail
    bl      test_fail

.Ldone_bulk_fail:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .data
.balign 4
bulk_saved_hcchar:      .word 0
bulk_saved_hctsiz:      .word 0
bulk_fake_fail:         .word 0
bulk_test_pid:          .word 0

.balign 4
bulk_test_buf:
    .space 128

.section .rodata
name_bulk_out:          .asciz "bulk_xfer_out"
name_bulk_in:           .asciz "bulk_xfer_in"
name_bulk_fail:         .asciz "bulk_xfer_fail"
