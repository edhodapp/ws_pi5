/*
 * test_dwc2 - Test DWC2 USB host controller initialization
 *
 * Verifies:
 *   1. dwc2_init returns 0 (success)
 *   2. HPRT PrtConnSts (bit 0) is set — QEMU's usb-net device is connected
 *
 * test_dwc2_timeout - Test dwc2_port_init connect-timeout path
 *
 * Verifies:
 *   dwc2_port_init returns 1 (failure) when HPRT never shows device connected
 *   Uses a zeroed RAM buffer as fake DWC2 register block.
 */

.include "dwc2.inc"

.global test_dwc2
.global test_dwc2_timeout

.section .text

test_dwc2:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =DWC2_BASE
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

/*
 * test_dwc2_timeout - Verify connect-timeout failure path
 *
 * Calls dwc2_port_init with a fake register block (zeroed RAM).
 * The port power write stores HPRT_PRTPWR into the buffer, but bit 0
 * (connect status) is never set, so the connect poll times out.
 * Expects dwc2_port_init to return 1 (failure).
 */
test_dwc2_timeout:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =fake_dwc2_regs
    bl      dwc2_port_init

    /* Expect w0 == 1 (timeout failure) */
    cmp     w0, #1
    b.ne    .Lfail_timeout

    ldr     x0, =name_dwc2_timeout
    bl      test_pass
    b       .Ldone_timeout

.Lfail_timeout:
    ldr     x0, =name_dwc2_timeout_fail
    bl      test_fail

.Ldone_timeout:
    ldp     x29, x30, [sp], #16
    ret

/* Fake DWC2 register block — zeroed by BSS init, large enough for HPRT at 0x440 */
.section .bss
.balign 8
fake_dwc2_regs:
    .space  0x448

.section .rodata
name_dwc2_init:          .asciz "dwc2_init"
name_dwc2_init_fail:     .asciz "dwc2_init_returned_error"
name_dwc2_no_connect:    .asciz "dwc2_hprt_no_connect"
name_dwc2_timeout:       .asciz "dwc2_port_init_timeout"
name_dwc2_timeout_fail:  .asciz "dwc2_port_init_timeout_expected_failure"
