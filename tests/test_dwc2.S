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
.global test_dwc2_mbox_fail
.global test_dwc2_xfer_timeout

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

/*
 * test_dwc2_mbox_fail - Verify dwc2_init fails when mbox_call fails
 *
 * Overrides dwc2_mbox_call_fn with a fake that returns 1.
 * Calls dwc2_init(x0=0). Verifies it returns 1.
 * Restores the original pointer afterward.
 */
test_dwc2_mbox_fail:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    /* Save original function pointer */
    ldr     x19, =dwc2_mbox_call_fn
    ldr     x20, [x19]

    /* Install fake */
    ldr     x0, =fake_mbox_fail
    str     x0, [x19]

    /* Call dwc2_init with base=0 (never reaches MMIO) */
    mov     x0, #0
    bl      dwc2_init

    /* Restore original pointer */
    str     x20, [x19]

    /* Expect w0 == 1 */
    cmp     w0, #1
    b.ne    .Lfail_mbox

    ldr     x0, =name_dwc2_mbox_fail
    bl      test_pass
    b       .Ldone_mbox

.Lfail_mbox:
    ldr     x0, =name_dwc2_mbox_fail_bad
    bl      test_fail

.Ldone_mbox:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

fake_mbox_fail:
    mov     w0, #1
    ret

/*
 * test_dwc2_xfer_timeout - Verify dwc2_channel_poll returns 0 on timeout
 *
 * Calls dwc2_channel_poll with a zeroed channel register block.
 * HC_INT at offset 0x08 is zero, so the poll loop exhausts its
 * counter and returns 0 (timeout).
 */
test_dwc2_xfer_timeout:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =fake_chan_regs
    bl      dwc2_channel_poll

    /* Expect w0 == 0 (timeout) */
    cbnz    w0, .Lfail_xfer_timeout

    ldr     x0, =name_dwc2_xfer_timeout
    bl      test_pass
    b       .Ldone_xfer_timeout

.Lfail_xfer_timeout:
    ldr     x0, =name_dwc2_xfer_timeout
    bl      test_fail

.Ldone_xfer_timeout:
    ldp     x29, x30, [sp], #16
    ret

/* Fake DWC2 register block — zeroed by BSS init, large enough for HPRT at 0x440 */
.section .bss
.balign 8
fake_dwc2_regs:
    .space  0x448

/* Fake channel register block — zeroed by BSS init, HC_INT at +0x08 is 0 */
.balign 8
fake_chan_regs:
    .space  0x20

.section .rodata
name_dwc2_init:          .asciz "dwc2_init"
name_dwc2_init_fail:     .asciz "dwc2_init_returned_error"
name_dwc2_no_connect:    .asciz "dwc2_hprt_no_connect"
name_dwc2_timeout:       .asciz "dwc2_port_init_timeout"
name_dwc2_timeout_fail:  .asciz "dwc2_port_init_timeout_expected_failure"
name_dwc2_mbox_fail:     .asciz "dwc2_mbox_call_fail"
name_dwc2_mbox_fail_bad: .asciz "dwc2_mbox_fail_expected_error"
name_dwc2_xfer_timeout:  .asciz "dwc2_channel_poll_timeout"
