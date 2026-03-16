/*
 * test_usb_desc - Tests for USB descriptor parsing
 *
 * Tests:
 *   1. test_parse_bulk_eps — parse bulk IN+OUT from hand-crafted descriptor chain
 *   2. test_parse_no_bulk — descriptor chain with only interrupt endpoints → returns 1
 *   3. test_parse_zero_blength — bLength=0 terminates without hanging → returns 1
 *   4. test_get_config_desc — two-pass GET_DESCRIPTOR via counter-based fake xfer
 */

.include "dwc2.inc"
.include "usb.inc"
.include "usb_desc.inc"

.global test_parse_bulk_eps
.global test_parse_no_bulk
.global test_parse_zero_blength
.global test_get_config_desc

.section .text

/* ========================================================================
 * test_parse_bulk_eps
 * ======================================================================== */
test_parse_bulk_eps:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =fake_cfg_desc
    mov     w1, #32
    ldr     x2, =bulk_result
    bl      usb_parse_bulk_eps

    /* Should return 0 */
    cbnz    w0, .Lfail_parse_bulk

    /* Check bulk_in_addr == 0x83 */
    ldr     x0, =bulk_result
    ldrb    w1, [x0, #BULKEP_IN_ADDR]
    cmp     w1, #0x83
    b.ne    .Lfail_parse_bulk

    /* Check bulk_out_addr == 0x02 */
    ldrb    w1, [x0, #BULKEP_OUT_ADDR]
    cmp     w1, #0x02
    b.ne    .Lfail_parse_bulk

    /* Check bulk_in_mps == 64 */
    ldrh    w1, [x0, #BULKEP_IN_MPS]
    cmp     w1, #64
    b.ne    .Lfail_parse_bulk

    /* Check bulk_out_mps == 64 */
    ldrh    w1, [x0, #BULKEP_OUT_MPS]
    cmp     w1, #64
    b.ne    .Lfail_parse_bulk

    ldr     x0, =name_parse_bulk
    bl      test_pass
    b       .Ldone_parse_bulk

.Lfail_parse_bulk:
    ldr     x0, =name_parse_bulk
    bl      test_fail

.Ldone_parse_bulk:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_parse_no_bulk — only interrupt endpoints, should return 1
 * ======================================================================== */
test_parse_no_bulk:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =fake_cfg_intr_only
    mov     w1, #25
    ldr     x2, =bulk_result
    bl      usb_parse_bulk_eps

    /* Should return 1 (no bulk endpoints found) */
    cmp     w0, #1
    b.ne    .Lfail_no_bulk

    ldr     x0, =name_no_bulk
    bl      test_pass
    b       .Ldone_no_bulk

.Lfail_no_bulk:
    ldr     x0, =name_no_bulk
    bl      test_fail

.Ldone_no_bulk:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_parse_zero_blength — bLength=0 after config header, should not hang
 * ======================================================================== */
test_parse_zero_blength:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    ldr     x0, =fake_cfg_zero_blen
    mov     w1, #12
    ldr     x2, =bulk_result
    bl      usb_parse_bulk_eps

    /* Should return 1 (no endpoints found before bLength=0 terminated) */
    cmp     w0, #1
    b.ne    .Lfail_zero_blen

    ldr     x0, =name_zero_blen
    bl      test_pass
    b       .Ldone_zero_blen

.Lfail_zero_blen:
    ldr     x0, =name_zero_blen
    bl      test_fail

.Ldone_zero_blen:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_get_config_desc — two-pass GET_DESCRIPTOR via counter-based fake
 * ======================================================================== */
test_get_config_desc:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    /* Save original xfer function pointer */
    ldr     x19, =usb_channel_xfer_fn
    ldr     x20, [x19]

    /* Reset call counter */
    ldr     x0, =gcd_xfer_call_count
    str     wzr, [x0]

    /* Install our fake */
    ldr     x0, =fake_gcd_xfer
    str     x0, [x19]

    /* Clear the receive buffer */
    ldr     x0, =gcd_recv_buf
    mov     w1, #64
1:  strb    wzr, [x0], #1
    subs    w1, w1, #1
    b.ne    1b

    /* Call usb_get_config_desc(base=0, dev_addr=1, mps=64, buf, buf_len=64) */
    mov     x0, #0
    mov     w1, #1
    mov     w2, #64
    ldr     x3, =gcd_recv_buf
    mov     w4, #64
    bl      usb_get_config_desc

    /* Restore original pointer */
    str     x20, [x19]

    /* Should return 0 */
    cbnz    w0, .Lfail_gcd

    /* Check buffer starts with config descriptor: bLength=9, bDescType=2 */
    ldr     x0, =gcd_recv_buf
    ldrb    w1, [x0, #USB_CFG_BLENGTH]
    cmp     w1, #9
    b.ne    .Lfail_gcd

    ldrb    w1, [x0, #USB_CFG_BDESCTYPE]
    cmp     w1, #USB_DESC_CONFIGURATION
    b.ne    .Lfail_gcd

    /* Check wTotalLength was stored correctly */
    ldr     x0, =usb_cfg_total_len
    ldrh    w1, [x0]
    cmp     w1, #32
    b.ne    .Lfail_gcd

    /* Check byte at offset 9 (first byte of interface desc) is 9 (bLength) */
    ldr     x0, =gcd_recv_buf
    ldrb    w1, [x0, #9]
    cmp     w1, #9
    b.ne    .Lfail_gcd

    ldr     x0, =name_gcd
    bl      test_pass
    b       .Ldone_gcd

.Lfail_gcd:
    ldr     x0, =name_gcd
    bl      test_fail

.Ldone_gcd:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ========================================================================
 * fake_gcd_xfer - Counter-based fake for test_get_config_desc
 *
 * usb_control_xfer makes 3 calls per transfer (SETUP, DATA, STATUS).
 * usb_get_config_desc does 2 transfers = 6 calls total.
 *
 * Call 2 (DATA of first GET_DESC): write 9-byte config header with wTotalLength=32
 * Call 5 (DATA of second GET_DESC): write 32-byte full descriptor chain
 * All others: return XFERCOMP|CHHLTD
 * ======================================================================== */
fake_gcd_xfer:
    /* Increment call counter */
    ldr     x9, =gcd_xfer_call_count
    ldr     w10, [x9]
    add     w10, w10, #1
    str     w10, [x9]

    cmp     w10, #2
    b.eq    .Lfake_gcd_hdr

    cmp     w10, #5
    b.eq    .Lfake_gcd_full

    /* Default: success */
    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret

.Lfake_gcd_hdr:
    /* Call 2: write 9-byte config header into DMA buffer (x3) */
    ldr     x9, =fake_cfg_desc
    /* Copy 9 bytes */
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

.Lfake_gcd_full:
    /* Call 5: write full 32-byte descriptor chain into DMA buffer (x3) */
    ldr     x9, =fake_cfg_desc
    /* Copy 32 bytes (4 x ldr/str of 8 bytes) */
    ldr     x10, [x9, #0]
    str     x10, [x3, #0]
    ldr     x10, [x9, #8]
    str     x10, [x3, #8]
    ldr     x10, [x9, #16]
    str     x10, [x3, #16]
    ldr     x10, [x9, #24]
    str     x10, [x3, #24]

    mov     w0, #(HCINT_XFERCOMP | HCINT_CHHLTD)
    ret


/* ========================================================================
 * Test data
 * ======================================================================== */
.section .data

/*
 * Hand-crafted USB configuration descriptor chain (32 bytes total):
 *   Config desc (9) + Interface desc (9) + Endpoint OUT bulk (7) + Endpoint IN bulk (7)
 */
.balign 4
fake_cfg_desc:
    /* Config descriptor: bLen=9, bDescType=2, wTotalLen=32, bNumIntf=1, bCfgVal=1, iCfg=0, bmAttr=0x80, bMaxPwr=50 */
    .byte   9, 2
    .hword  32                  /* wTotalLength LE */
    .byte   1, 1, 0, 0x80, 50
    /* Interface descriptor: bLen=9, bDescType=4, bIntfNum=0, bAltSet=0, bNumEP=2, bClass=0x0A, bSubClass=0, bProtocol=0, iIntf=0 */
    .byte   9, 4, 0, 0, 2, 0x0A, 0, 0, 0
    /* Endpoint descriptor: bLen=7, bDescType=5, bEpAddr=0x02 (OUT), bmAttr=0x02 (bulk), wMPS=64, bInterval=0 */
    .byte   7, 5, 0x02, 0x02
    .hword  64                  /* wMaxPacketSize LE */
    .byte   0
    /* Endpoint descriptor: bLen=7, bDescType=5, bEpAddr=0x83 (IN), bmAttr=0x02 (bulk), wMPS=64, bInterval=0 */
    .byte   7, 5, 0x83, 0x02
    .hword  64                  /* wMaxPacketSize LE */
    .byte   0

/*
 * Descriptor chain with only interrupt endpoints (25 bytes):
 *   Config desc (9) + Interface desc (9) + Endpoint IN interrupt (7)
 */
.balign 4
fake_cfg_intr_only:
    .byte   9, 2
    .hword  25
    .byte   1, 1, 0, 0x80, 50
    .byte   9, 4, 0, 0, 1, 0x02, 0, 0, 0
    /* Endpoint: bLen=7, bDescType=5, bEpAddr=0x81 (IN), bmAttr=0x03 (interrupt), wMPS=8, bInterval=255 */
    .byte   7, 5, 0x81, 0x03
    .hword  8
    .byte   255

/*
 * Descriptor chain with bLength=0 after config header (12 bytes declared, stops at offset 9):
 */
.balign 4
fake_cfg_zero_blen:
    .byte   9, 2
    .hword  12
    .byte   1, 1, 0, 0x80, 50
    /* Next descriptor has bLength=0 — parser must stop */
    .byte   0, 0, 0

/* Result struct */
.balign 4
bulk_result:
    .space  BULKEP_SIZE

/* Counter for fake_gcd_xfer */
.balign 4
gcd_xfer_call_count:
    .word   0

/* Receive buffer for test_get_config_desc */
.balign 4
gcd_recv_buf:
    .space  64

.section .rodata
name_parse_bulk:    .asciz "parse_bulk_eps"
name_no_bulk:       .asciz "parse_no_bulk"
name_zero_blen:     .asciz "parse_zero_blength"
name_gcd:           .asciz "get_config_desc"
