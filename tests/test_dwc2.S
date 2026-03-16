/*
 * test_dwc2 - Test DWC2 USB host controller initialization
 *
 * Verifies:
 *   1. dwc2_init returns 0 (success)
 *   2. HPRT PrtConnSts (bit 0) is set — QEMU's usb-net device is connected
 */

.include "dwc2.inc"

.global test_dwc2

.section .text

test_dwc2:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      dwc2_init
    cbnz    w0, .Lfail_init

    /* Verify HPRT shows device connected */
    ldr     x0, =DWC2_BASE
    ldr     w0, [x0, #DWC2_HPRT]
    tbz     w0, #0, .Lfail_connect

    ldr     x0, =name_dwc2_init
    bl      test_pass
    b       .Ldone

.Lfail_init:
    ldr     x0, =name_dwc2_init_fail
    bl      test_fail
    b       .Ldone

.Lfail_connect:
    ldr     x0, =name_dwc2_no_connect
    bl      test_fail

.Ldone:
    ldp     x29, x30, [sp], #16
    ret

.section .rodata
name_dwc2_init:        .asciz "dwc2_init"
name_dwc2_init_fail:   .asciz "dwc2_init_returned_error"
name_dwc2_no_connect:  .asciz "dwc2_hprt_no_connect"
