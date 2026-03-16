/*
 * test_usb_fail - USB failure path tests
 *
 * Uses a counter-based fake dwc2_channel_xfer to inject failures at
 * specific call numbers within usb_enumerate, exercising error branches
 * in usb_control_xfer and usb_enumerate.
 */

.include "dwc2.inc"
.include "usb.inc"

.global test_usb_xfer_setup_fail
.global test_usb_xfer_data_fail
.global test_usb_xfer_status_fail
.global test_usb_enum_set_addr_fail
.global test_usb_enum_get_full_fail

.section .text

/*
 * fake_xfer_counted - Counter-based fake dwc2_channel_xfer
 *
 * Increments xfer_call_count. If count == xfer_fail_at, returns
 * HCINT_CHHLTD (halted, no transfer complete). Otherwise returns
 * HCINT_XFERCOMP | HCINT_CHHLTD (success).
 */
fake_xfer_counted:
    ldr     x1, =xfer_call_count
    ldr     w2, [x1]
    add     w2, w2, #1
    str     w2, [x1]

    ldr     x1, =xfer_fail_at
    ldr     w3, [x1]
    cmp     w2, w3
    b.eq    .Lfake_fail

    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lfake_fail:
    mov     w0, #HCINT_CHHLTD
    ret

/*
 * usb_enum_expect_fail - Helper: run usb_enumerate with xfer failing at call N
 *
 * w0: call number to fail at (1-based)
 *
 * Returns:
 *   w0: 0 if usb_enumerate returned 1 (expected failure), 1 otherwise
 */
usb_enum_expect_fail:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x29, sp

    /* Save fail_at value */
    mov     w19, w0

    /* Save original function pointer */
    ldr     x20, =usb_channel_xfer_fn
    ldr     x21, [x20]

    /* Set fail_at */
    ldr     x0, =xfer_fail_at
    str     w19, [x0]

    /* Reset call counter */
    ldr     x0, =xfer_call_count
    str     wzr, [x0]

    /* Install fake */
    ldr     x0, =fake_xfer_counted
    str     x0, [x20]

    /* Pre-fill descriptor buffer: bMaxPacketSize0=8 at offset 7 */
    ldr     x0, =fail_desc_buf
    mov     w1, #8
    strb    w1, [x0, #USBDEV_BMAXPACKETSIZE0]

    /* Call usb_enumerate(DWC2_BASE=0, desc_buf) */
    mov     x0, #0
    ldr     x1, =fail_desc_buf
    bl      usb_enumerate

    /* Restore original pointer */
    str     x21, [x20]

    /* Check: usb_enumerate should have returned 1 */
    cmp     w0, #1
    b.ne    .Lhelper_bad
    mov     w0, #0
    b       .Lhelper_done

.Lhelper_bad:
    mov     w0, #1

.Lhelper_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* === Individual tests === */

test_usb_xfer_setup_fail:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     w0, #1
    bl      usb_enum_expect_fail
    cbnz    w0, 1f
    ldr     x0, =name_xfer_setup_fail
    bl      test_pass
    b       2f
1:  ldr     x0, =name_xfer_setup_fail
    bl      test_fail
2:  ldp     x29, x30, [sp], #16
    ret

test_usb_xfer_data_fail:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     w0, #2
    bl      usb_enum_expect_fail
    cbnz    w0, 1f
    ldr     x0, =name_xfer_data_fail
    bl      test_pass
    b       2f
1:  ldr     x0, =name_xfer_data_fail
    bl      test_fail
2:  ldp     x29, x30, [sp], #16
    ret

test_usb_xfer_status_fail:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     w0, #3
    bl      usb_enum_expect_fail
    cbnz    w0, 1f
    ldr     x0, =name_xfer_status_fail
    bl      test_pass
    b       2f
1:  ldr     x0, =name_xfer_status_fail
    bl      test_fail
2:  ldp     x29, x30, [sp], #16
    ret

test_usb_enum_set_addr_fail:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     w0, #4
    bl      usb_enum_expect_fail
    cbnz    w0, 1f
    ldr     x0, =name_set_addr_fail
    bl      test_pass
    b       2f
1:  ldr     x0, =name_set_addr_fail
    bl      test_fail
2:  ldp     x29, x30, [sp], #16
    ret

test_usb_enum_get_full_fail:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     w0, #6
    bl      usb_enum_expect_fail
    cbnz    w0, 1f
    ldr     x0, =name_get_full_fail
    bl      test_pass
    b       2f
1:  ldr     x0, =name_get_full_fail
    bl      test_fail
2:  ldp     x29, x30, [sp], #16
    ret

/* Data */
.section .data
.balign 4
xfer_call_count: .word 0
xfer_fail_at:    .word 0

.balign 4
fail_desc_buf:
    .space USBDEV_SIZE

.section .rodata
name_xfer_setup_fail:  .asciz "usb_xfer_setup_fail"
name_xfer_data_fail:   .asciz "usb_xfer_data_fail"
name_xfer_status_fail: .asciz "usb_xfer_status_fail"
name_set_addr_fail:    .asciz "usb_enum_set_addr_fail"
name_get_full_fail:    .asciz "usb_enum_get_full_fail"
