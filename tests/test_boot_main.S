/*
 * test_boot_main - Integration tests for main() in src/main.S
 *
 * Tests all 6 branch edges (3 cbnz × taken/not-taken) by calling main
 * with injectable fakes for dwc2_mbox_call_fn and usb_channel_xfer_fn.
 *
 * Call sequence through usb_channel_xfer_fn (18 calls total):
 *   cdc_ecm_init → usb_enumerate (8 calls):
 *     1: SETUP GET_DEV(8)     2: DATA partial dev desc    3: STATUS
 *     4: SETUP SET_ADDR       5: STATUS
 *     6: SETUP GET_DEV(18)    7: DATA full dev desc       8: STATUS
 *   cdc_ecm_init → usb_get_config_desc (6 calls):
 *     9: SETUP GET_CFG(9)    10: DATA config header      11: STATUS
 *    12: SETUP GET_CFG(full) 13: DATA full config chain  14: STATUS
 *   cdc_ecm_init → SET_CONFIGURATION (2 calls):
 *    15: SETUP SET_CFG       16: STATUS
 *   cdc_ecm_activate → SET_INTERFACE (2 calls):
 *    17: SETUP SET_IFACE     18: STATUS
 *
 * Tests:
 *   1. test_main_success           — all 18 calls succeed → w0 == 0
 *   2. test_main_dwc2_fail         — mbox_call fails → w0 == 1
 *   3. test_main_ecm_init_fail     — xfer call 1 fails → w0 == 1
 *   4. test_main_ecm_activate_fail — xfer call 17 fails → w0 == 1
 */

.include "dwc2.inc"
.include "usb.inc"
.include "usb_desc.inc"
.include "cdc_ecm.inc"

.global test_main_success
.global test_main_dwc2_fail
.global test_main_ecm_init_fail
.global test_main_ecm_activate_fail

.section .text

/* ========================================================================
 * fake_main_xfer — counter-based fake for integration tests
 *
 * Writes device descriptor on calls 2/7, config descriptor on calls 10/13.
 * Returns success for all other calls (including 17-18 for activate).
 * Returns HCINT_CHHLTD (no XFERCOMP) when call_count == fail_at.
 * ======================================================================== */
fake_main_xfer:
    ldr     x9, =main_fake_call_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]

    /* Check for failure injection */
    ldr     x9, =main_fake_fail_at
    ldr     w11, [x9]
    cbz     w11, .Lmfx_dispatch
    cmp     w10, w11
    b.eq    .Lmfx_fail

.Lmfx_dispatch:
    cmp     w10, #2
    b.eq    .Lmfx_dev_partial
    cmp     w10, #7
    b.eq    .Lmfx_dev_full
    cmp     w10, #10
    b.eq    .Lmfx_cfg_hdr
    cmp     w10, #13
    b.eq    .Lmfx_cfg_full

    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lmfx_dev_partial:
    /* Call 2: write 8 bytes of device descriptor to x3 */
    ldr     x9, =fake_main_dev_desc
    ldr     x10, [x9]
    str     x10, [x3]
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lmfx_dev_full:
    /* Call 7: write 18 bytes of device descriptor to x3 */
    ldr     x9, =fake_main_dev_desc
    ldr     x10, [x9, #0]
    str     x10, [x3, #0]
    ldr     x10, [x9, #8]
    str     x10, [x3, #8]
    ldrh    w10, [x9, #16]
    strh    w10, [x3, #16]
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lmfx_cfg_hdr:
    /* Call 10: write 9-byte config header to x3 */
    ldr     x9, =fake_main_cfg_desc
    ldrb    w10, [x9, #0]
    strb    w10, [x3, #0]
    ldrb    w10, [x9, #1]
    strb    w10, [x3, #1]
    ldrh    w10, [x9, #2]
    strh    w10, [x3, #2]
    ldrb    w10, [x9, #4]
    strb    w10, [x3, #4]
    ldrb    w10, [x9, #5]
    strb    w10, [x3, #5]
    ldrb    w10, [x9, #6]
    strb    w10, [x3, #6]
    ldrb    w10, [x9, #7]
    strb    w10, [x3, #7]
    ldrb    w10, [x9, #8]
    strb    w10, [x3, #8]
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lmfx_cfg_full:
    /* Call 13: byte-copy wTotalLength bytes from cfg_desc to x3 */
    ldr     x9, =fake_main_cfg_desc
    ldrh    w11, [x9, #2]         /* wTotalLength at offset 2 */
    mov     w12, #0
.Lmfx_copy:
    cmp     w12, w11
    b.ge    .Lmfx_copy_done
    ldrb    w13, [x9, x12]
    strb    w13, [x3, x12]
    add     w12, w12, #1
    b       .Lmfx_copy
.Lmfx_copy_done:
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lmfx_fail:
    mov     w0, #HCINT_CHHLTD
    ret

/* ========================================================================
 * fake_mbox_fail_main — always returns 1
 * ======================================================================== */
fake_mbox_fail_main:
    mov     w0, #1
    ret

/* ========================================================================
 * main_test_setup — install xfer fake, reset counter, configure fail_at
 *
 * w0: fail_at value (0 = no failure)
 *
 * Saves: x19 = &usb_channel_xfer_fn, x20 = original xfer fn
 *        x21 = &dwc2_mbox_call_fn,   x22 = original mbox fn
 * ======================================================================== */
main_test_setup:
    ldr     x19, =usb_channel_xfer_fn
    ldr     x20, [x19]
    ldr     x21, =dwc2_mbox_call_fn
    ldr     x22, [x21]

    ldr     x9, =fake_main_xfer
    str     x9, [x19]

    ldr     x9, =main_fake_call_count
    str     wzr, [x9]

    ldr     x9, =main_fake_fail_at
    str     w0, [x9]

    ret

/* ========================================================================
 * main_test_teardown — restore both fn ptrs (preserves w0)
 * ======================================================================== */
main_test_teardown:
    str     x20, [x19]
    str     x22, [x21]
    ret

/* ========================================================================
 * test_main_success — all paths succeed, w0 == 0
 * ======================================================================== */
test_main_success:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x29, sp

    mov     w0, #0              /* fail_at = 0 (no failure) */
    bl      main_test_setup

    bl      main

    mov     w10, w0
    bl      main_test_teardown

    cbnz    w10, .Lfail_main_success

    ldr     x0, =name_main_success
    bl      test_pass
    b       .Ldone_main_success

.Lfail_main_success:
    ldr     x0, =name_main_success
    bl      test_fail

.Ldone_main_success:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_main_dwc2_fail — mbox_call fails → main returns 1
 * ======================================================================== */
test_main_dwc2_fail:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x29, sp

    mov     w0, #0              /* fail_at = 0 (xfer won't be reached) */
    bl      main_test_setup

    /* Override mbox fn to fail */
    ldr     x9, =fake_mbox_fail_main
    str     x9, [x21]

    bl      main

    mov     w10, w0
    bl      main_test_teardown

    cmp     w10, #1
    b.ne    .Lfail_main_dwc2

    ldr     x0, =name_main_dwc2_fail
    bl      test_pass
    b       .Ldone_main_dwc2

.Lfail_main_dwc2:
    ldr     x0, =name_main_dwc2_fail
    bl      test_fail

.Ldone_main_dwc2:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_main_ecm_init_fail — xfer call 1 fails → main returns 1
 * ======================================================================== */
test_main_ecm_init_fail:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x29, sp

    mov     w0, #1              /* fail_at = 1 */
    bl      main_test_setup

    bl      main

    mov     w10, w0
    bl      main_test_teardown

    cmp     w10, #1
    b.ne    .Lfail_main_ecm_init

    ldr     x0, =name_main_ecm_init_fail
    bl      test_pass
    b       .Ldone_main_ecm_init

.Lfail_main_ecm_init:
    ldr     x0, =name_main_ecm_init_fail
    bl      test_fail

.Ldone_main_ecm_init:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * test_main_ecm_activate_fail — xfer call 17 fails → main returns 1
 * ======================================================================== */
test_main_ecm_activate_fail:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x29, sp

    mov     w0, #17             /* fail_at = 17 */
    bl      main_test_setup

    bl      main

    mov     w10, w0
    bl      main_test_teardown

    cmp     w10, #1
    b.ne    .Lfail_main_ecm_act

    ldr     x0, =name_main_ecm_act_fail
    bl      test_pass
    b       .Ldone_main_ecm_act

.Lfail_main_ecm_act:
    ldr     x0, =name_main_ecm_act_fail
    bl      test_fail

.Ldone_main_ecm_act:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .data

/* 18-byte device descriptor: bMaxPacketSize0=64 */
.balign 4
fake_main_dev_desc:
    .byte   18, 1               /* bLength=18, bDescType=1 (DEVICE) */
    .hword  0x0200              /* bcdUSB 2.0 */
    .byte   0x02, 0, 0          /* bDevClass=CDC, subclass=0, protocol=0 */
    .byte   64                  /* bMaxPacketSize0=64 */
    .hword  0x1234              /* idVendor */
    .hword  0x5678              /* idProduct */
    .hword  0x0100              /* bcdDevice 1.0 */
    .byte   0, 0, 0             /* iManufacturer, iProduct, iSerialNumber */
    .byte   1                   /* bNumConfigurations */

/* 32-byte config chain: config(9) + interface(9) + EP OUT bulk 0x02(7) + EP IN bulk 0x83(7) */
.balign 4
fake_main_cfg_desc:
    .byte   9, 2
    .hword  32                  /* wTotalLength LE */
    .byte   1, 1, 0, 0x80, 50
    .byte   9, 4, 0, 0, 2, 0x0A, 0, 0, 0
    .byte   7, 5, 0x02, 0x02
    .hword  64                  /* wMaxPacketSize LE */
    .byte   0
    .byte   7, 5, 0x83, 0x02
    .hword  64                  /* wMaxPacketSize LE */
    .byte   0

.balign 4
main_fake_call_count:   .word 0
main_fake_fail_at:      .word 0

.section .rodata
name_main_success:          .asciz "main_success"
name_main_dwc2_fail:        .asciz "main_dwc2_fail"
name_main_ecm_init_fail:    .asciz "main_ecm_init_fail"
name_main_ecm_act_fail:     .asciz "main_ecm_activate_fail"
