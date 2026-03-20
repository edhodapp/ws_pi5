.include "dwc2.inc"
.include "usb.inc"
.include "usb_desc.inc"

.global usb_get_config_desc
.global usb_parse_bulk_eps
.global usb_cfg_total_len

.section .text

/*
 * usb_get_config_desc - Read a USB configuration descriptor
 *
 * Two-pass read: first 9 bytes to get wTotalLength, then full descriptor chain.
 *
 * x0: DWC2 base address
 * w1: device address (1-127)
 * w2: EP0 max packet size
 * x3: pointer to receive buffer
 * w4: buffer length (must be >= 9)
 *
 * Returns:
 *   w0: 0 on success, 1 on failure
 *   usb_cfg_total_len: actual wTotalLength from descriptor
 */
usb_get_config_desc:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    mov     x29, sp

    mov     x19, x0                 /* x19 = DWC2 base */
    mov     w20, w1                 /* w20 = dev_addr */
    mov     w21, w2                 /* w21 = MPS */
    mov     x22, x3                 /* x22 = buffer */
    mov     w23, w4                 /* w23 = buf_len */

    /* Copy template into writable scratch (8 bytes, wLength=9) */
    ldr     x0, =setup_get_cfg_tmpl
    ldr     x1, [x0]
    ldr     x0, =setup_scratch
    str     x1, [x0]

    /* --- Pass 1: read 9-byte config header --- */
    mov     x0, x19
    mov     w1, w20
    mov     w2, w21
    ldr     x3, =setup_scratch
    mov     x4, x22
    mov     w5, #USB_CFG_SIZE
    bl      usb_control_xfer
    cbnz    w0, .Lgcd_fail

    /* Extract wTotalLength (u16 LE at offset 2) */
    ldrh    w24, [x22, #USB_CFG_WTOTALLENGTH]

    /* Store for caller */
    ldr     x0, =usb_cfg_total_len
    strh    w24, [x0]

    /* Clamp to buf_len */
    cmp     w24, w23
    csel    w24, w24, w23, ls       /* w24 = min(wTotalLength, buf_len) */

    /* --- Pass 2: read full descriptor chain --- */
    /* Patch wLength in setup_scratch (offset 6, u16 LE) */
    ldr     x0, =setup_scratch
    strh    w24, [x0, #SETUP_WLENGTH]

    mov     x0, x19
    mov     w1, w20
    mov     w2, w21
    ldr     x3, =setup_scratch
    mov     x4, x22
    mov     w5, w24
    bl      usb_control_xfer
    cbnz    w0, .Lgcd_fail

    mov     w0, #0
    b       .Lgcd_done

.Lgcd_fail:
    mov     w0, #1

.Lgcd_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * usb_parse_bulk_eps - Parse bulk IN/OUT endpoints from a configuration descriptor chain
 *
 * Walks the descriptor chain looking for endpoint descriptors (bDescType==5)
 * with bulk transfer type (bmAttributes & 0x03 == 2).
 *
 * x0: pointer to descriptor buffer (starts with config descriptor)
 * w1: total length of descriptor chain
 * x2: pointer to BULKEP result struct (6 bytes)
 *
 * Returns:
 *   w0: 0 if both bulk IN and OUT found, 1 otherwise
 */
usb_parse_bulk_eps:
    /* No callee-saved registers needed — all work in x0-x15 */
    mov     x3, x0                  /* x3 = buf base */
    mov     w4, w1                  /* w4 = total_len */
    mov     x5, x2                  /* x5 = result ptr */
    mov     w6, #0                  /* w6 = offset */
    mov     w7, #0                  /* w7 = found_in */
    mov     w8, #0                  /* w8 = found_out */

.Lparse_loop:
    cmp     w6, w4
    b.ge    .Lparse_done

    /* bLength = buf[offset] */
    ldrb    w9, [x3, x6]
    cbz     w9, .Lparse_done        /* bLength==0 → malformed, stop */

    /* Check offset + bLength doesn't overrun */
    add     w10, w6, w9
    cmp     w10, w4
    b.gt    .Lparse_done

    /* bDescType = buf[offset + 1] */
    add     x11, x3, x6
    ldrb    w12, [x11, #1]
    cmp     w12, #USB_DESC_ENDPOINT
    b.ne    .Lparse_next

    /* Endpoint descriptor — check bmAttributes for bulk */
    ldrb    w12, [x11, #USB_EP_BMATTRIBUTES]
    and     w12, w12, #USB_EP_XFER_MASK
    cmp     w12, #USB_EP_XFER_BULK
    b.ne    .Lparse_next

    /* It's a bulk endpoint — read address and MPS */
    ldrb    w13, [x11, #USB_EP_BEPADDRESS]
    ldrh    w14, [x11, #USB_EP_WMAXPACKETSIZE]

    /* Check direction */
    tst     w13, #USB_EP_DIR_IN
    b.eq    .Lparse_out

    /* Bulk IN */
    strb    w13, [x5, #BULKEP_IN_ADDR]
    strh    w14, [x5, #BULKEP_IN_MPS]
    mov     w7, #1
    b       .Lparse_next

.Lparse_out:
    strb    w13, [x5, #BULKEP_OUT_ADDR]
    strh    w14, [x5, #BULKEP_OUT_MPS]
    mov     w8, #1

.Lparse_next:
    mov     w6, w10                 /* offset += bLength */
    b       .Lparse_loop

.Lparse_done:
    /* Return 0 if both found, 1 otherwise */
    and     w0, w7, w8
    eor     w0, w0, #1             /* invert: 1&1→0 (success), else 1 */
    ret

/* Setup packet template: GET_DESCRIPTOR(config, idx=0, wLength=9) */
.section .rodata
.balign 4
setup_get_cfg_tmpl:
    .byte   0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 0x09, 0x00

/* Writable copy for patching wLength */
.section .data
.balign 4
setup_scratch:
    .space 8

/* Actual wTotalLength from last usb_get_config_desc call */
.balign 2
usb_cfg_total_len:
    .hword 0
