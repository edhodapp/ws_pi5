/*
 * test_cdc_ecm - Tests for cdc_ecm_init (CDC-ECM bring-up)
 *
 * Tests:
 *   1. test_cdc_ecm_init — happy path: enumerate + config + parse + SET_CONFIGURATION
 *   2. test_cdc_ecm_enum_fail — enumeration failure → returns 1
 *   3. test_cdc_ecm_cfg_fail — GET_CONFIGURATION failure → returns 1
 *   4. test_cdc_ecm_no_bulk — no bulk endpoints in config → returns 1
 *   5. test_cdc_ecm_set_cfg_fail — SET_CONFIGURATION failure → returns 1
 *
 * Call sequence through usb_channel_xfer_fn (16 calls total):
 *   usb_enumerate (8 calls):
 *     1: SETUP GET_DEV(8)     2: DATA partial dev desc    3: STATUS
 *     4: SETUP SET_ADDR       5: STATUS
 *     6: SETUP GET_DEV(18)    7: DATA full dev desc       8: STATUS
 *   usb_get_config_desc (6 calls):
 *     9: SETUP GET_CFG(9)    10: DATA config header      11: STATUS
 *    12: SETUP GET_CFG(full) 13: DATA full config chain  14: STATUS
 *   SET_CONFIGURATION (2 calls):
 *    15: SETUP SET_CFG       16: STATUS
 */

.include "dwc2.inc"
.include "usb.inc"
.include "usb_desc.inc"

.global test_cdc_ecm_init
.global test_cdc_ecm_enum_fail
.global test_cdc_ecm_cfg_fail
.global test_cdc_ecm_no_bulk
.global test_cdc_ecm_set_cfg_fail

.section .text

/* ========================================================================
 * ecm_test_setup — install fake, reset counter, configure fail_at/cfg_src
 *
 * w0: fail_at value (0 = no failure)
 * x1: cfg_src pointer
 *
 * Outputs: x19 = &usb_channel_xfer_fn, x20 = original fn ptr
 *          (caller must save x19/x20 before calling)
 * ======================================================================== */
ecm_test_setup:
    ldr     x19, =usb_channel_xfer_fn
    ldr     x20, [x19]

    ldr     x9, =fake_ecm_xfer
    str     x9, [x19]

    ldr     x9, =ecm_fake_call_count
    str     wzr, [x9]

    ldr     x9, =ecm_fake_fail_at
    str     w0, [x9]

    ldr     x9, =ecm_fake_cfg_src
    str     x1, [x9]

    ret

/* ========================================================================
 * ecm_test_teardown — restore original fn ptr (does not clobber w0)
 * ======================================================================== */
ecm_test_teardown:
    str     x20, [x19]
    ret

/* ========================================================================
 * fake_ecm_xfer — counter-based fake dwc2_channel_xfer for cdc_ecm_init
 *
 * Writes device descriptor data on calls 2 and 7 (from fake_ecm_dev_desc).
 * Writes config data on calls 10 and 13 (from ecm_fake_cfg_src pointer).
 * Call 13 uses a byte-copy loop driven by wTotalLength.
 * Returns HCINT_CHHLTD (no XFERCOMP) when call_count == fail_at.
 * ======================================================================== */
fake_ecm_xfer:
    ldr     x9, =ecm_fake_call_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]

    /* Check for failure injection */
    ldr     x9, =ecm_fake_fail_at
    ldr     w11, [x9]
    cbz     w11, .Lecmf_dispatch
    cmp     w10, w11
    b.eq    .Lecmf_fail

.Lecmf_dispatch:
    cmp     w10, #2
    b.eq    .Lecmf_dev_partial
    cmp     w10, #7
    b.eq    .Lecmf_dev_full
    cmp     w10, #10
    b.eq    .Lecmf_cfg_hdr
    cmp     w10, #13
    b.eq    .Lecmf_cfg_full

    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lecmf_dev_partial:
    /* Call 2: write 8 bytes of device descriptor to x3 */
    ldr     x9, =fake_ecm_dev_desc
    ldr     x10, [x9]
    str     x10, [x3]
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lecmf_dev_full:
    /* Call 7: write 18 bytes of device descriptor to x3 */
    ldr     x9, =fake_ecm_dev_desc
    ldr     x10, [x9, #0]
    str     x10, [x3, #0]
    ldr     x10, [x9, #8]
    str     x10, [x3, #8]
    ldrh    w10, [x9, #16]
    strh    w10, [x3, #16]
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lecmf_cfg_hdr:
    /* Call 10: write 9-byte config header from cfg_src to x3 */
    ldr     x9, =ecm_fake_cfg_src
    ldr     x9, [x9]
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

.Lecmf_cfg_full:
    /* Call 13: byte-copy wTotalLength bytes from cfg_src to x3 */
    ldr     x9, =ecm_fake_cfg_src
    ldr     x9, [x9]
    ldrh    w11, [x9, #2]         /* wTotalLength at offset 2 */
    mov     w12, #0
.Lecmf_copy:
    cmp     w12, w11
    b.ge    .Lecmf_copy_done
    ldrb    w13, [x9, x12]
    strb    w13, [x3, x12]
    add     w12, w12, #1
    b       .Lecmf_copy
.Lecmf_copy_done:
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lecmf_fail:
    mov     w0, #HCINT_CHHLTD
    ret

/* ========================================================================
 * test_cdc_ecm_init — happy path
 * ======================================================================== */
test_cdc_ecm_init:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #0
    ldr     x1, =fake_ecm_cfg_desc
    bl      ecm_test_setup

    mov     x0, #0
    ldr     x1, =ecm_bulk_result
    bl      cdc_ecm_init

    bl      ecm_test_teardown

    /* Should return 0 */
    cbnz    w0, .Lfail_ecm_init

    /* Check bulk IN addr == 0x83 */
    ldr     x0, =ecm_bulk_result
    ldrb    w1, [x0, #BULKEP_IN_ADDR]
    cmp     w1, #0x83
    b.ne    .Lfail_ecm_init

    /* Check bulk OUT addr == 0x02 */
    ldrb    w1, [x0, #BULKEP_OUT_ADDR]
    cmp     w1, #0x02
    b.ne    .Lfail_ecm_init

    /* Check bulk IN MPS == 64 */
    ldrh    w1, [x0, #BULKEP_IN_MPS]
    cmp     w1, #64
    b.ne    .Lfail_ecm_init

    /* Check bulk OUT MPS == 64 */
    ldrh    w1, [x0, #BULKEP_OUT_MPS]
    cmp     w1, #64
    b.ne    .Lfail_ecm_init

    ldr     x0, =name_ecm_init
    bl      test_pass
    b       .Ldone_ecm_init

.Lfail_ecm_init:
    ldr     x0, =name_ecm_init
    bl      test_fail

.Ldone_ecm_init:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_cdc_ecm_enum_fail — fail at call 1 (SETUP of first GET_DEV)
 * ======================================================================== */
test_cdc_ecm_enum_fail:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #1
    ldr     x1, =fake_ecm_cfg_desc
    bl      ecm_test_setup

    mov     x0, #0
    ldr     x1, =ecm_bulk_result
    bl      cdc_ecm_init

    bl      ecm_test_teardown

    cmp     w0, #1
    b.ne    .Lfail_ecm_enum

    ldr     x0, =name_ecm_enum_fail
    bl      test_pass
    b       .Ldone_ecm_enum

.Lfail_ecm_enum:
    ldr     x0, =name_ecm_enum_fail
    bl      test_fail

.Ldone_ecm_enum:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_cdc_ecm_cfg_fail — fail at call 9 (SETUP of first GET_CFG)
 * ======================================================================== */
test_cdc_ecm_cfg_fail:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #9
    ldr     x1, =fake_ecm_cfg_desc
    bl      ecm_test_setup

    mov     x0, #0
    ldr     x1, =ecm_bulk_result
    bl      cdc_ecm_init

    bl      ecm_test_teardown

    cmp     w0, #1
    b.ne    .Lfail_ecm_cfg

    ldr     x0, =name_ecm_cfg_fail
    bl      test_pass
    b       .Ldone_ecm_cfg

.Lfail_ecm_cfg:
    ldr     x0, =name_ecm_cfg_fail
    bl      test_fail

.Ldone_ecm_cfg:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_cdc_ecm_no_bulk — config has no bulk endpoints → parse fails
 * ======================================================================== */
test_cdc_ecm_no_bulk:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #0
    ldr     x1, =fake_ecm_cfg_no_bulk
    bl      ecm_test_setup

    mov     x0, #0
    ldr     x1, =ecm_bulk_result
    bl      cdc_ecm_init

    bl      ecm_test_teardown

    cmp     w0, #1
    b.ne    .Lfail_ecm_no_bulk

    ldr     x0, =name_ecm_no_bulk
    bl      test_pass
    b       .Ldone_ecm_no_bulk

.Lfail_ecm_no_bulk:
    ldr     x0, =name_ecm_no_bulk
    bl      test_fail

.Ldone_ecm_no_bulk:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * test_cdc_ecm_set_cfg_fail — fail at call 15 (SETUP of SET_CONFIGURATION)
 * ======================================================================== */
test_cdc_ecm_set_cfg_fail:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     w0, #15
    ldr     x1, =fake_ecm_cfg_desc
    bl      ecm_test_setup

    mov     x0, #0
    ldr     x1, =ecm_bulk_result
    bl      cdc_ecm_init

    bl      ecm_test_teardown

    cmp     w0, #1
    b.ne    .Lfail_ecm_set_cfg

    ldr     x0, =name_ecm_set_cfg_fail
    bl      test_pass
    b       .Ldone_ecm_set_cfg

.Lfail_ecm_set_cfg:
    ldr     x0, =name_ecm_set_cfg_fail
    bl      test_fail

.Ldone_ecm_set_cfg:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * Test data
 * ======================================================================== */
.section .data

/* 18-byte device descriptor: bMaxPacketSize0=64 */
.balign 4
fake_ecm_dev_desc:
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
fake_ecm_cfg_desc:
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

/* 25-byte config chain: config(9) + interface(9) + EP IN interrupt(7) — no bulk */
.balign 4
fake_ecm_cfg_no_bulk:
    .byte   9, 2
    .hword  25                  /* wTotalLength LE */
    .byte   1, 1, 0, 0x80, 50
    .byte   9, 4, 0, 0, 1, 0x02, 0, 0, 0
    .byte   7, 5, 0x81, 0x03
    .hword  8                   /* wMaxPacketSize LE */
    .byte   255

/* Fake state */
.balign 4
ecm_fake_call_count:    .word 0
ecm_fake_fail_at:       .word 0

.balign 8
ecm_fake_cfg_src:       .quad 0

/* Result buffer */
.balign 4
ecm_bulk_result:
    .space  BULKEP_SIZE

.section .rodata
name_ecm_init:          .asciz "cdc_ecm_init"
name_ecm_enum_fail:     .asciz "cdc_ecm_enum_fail"
name_ecm_cfg_fail:      .asciz "cdc_ecm_cfg_fail"
name_ecm_no_bulk:       .asciz "cdc_ecm_no_bulk"
name_ecm_set_cfg_fail:  .asciz "cdc_ecm_set_cfg_fail"
