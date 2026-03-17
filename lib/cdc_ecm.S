.include "dwc2.inc"
.include "usb.inc"
.include "usb_desc.inc"

.global cdc_ecm_init

.section .text

/*
 * cdc_ecm_init - Bring up a CDC-ECM USB device
 *
 * Performs full USB bring-up: enumerate → read config descriptor →
 * parse bulk endpoints → SET_CONFIGURATION.
 *
 * x0: DWC2 base address
 * x1: pointer to BULKEP result struct (6 bytes, filled on success)
 *
 * Returns:
 *   w0: 0 on success, 1 on failure
 */
cdc_ecm_init:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x29, sp

    mov     x19, x0                 /* x19 = dwc2_base */
    mov     x20, x1                 /* x20 = bulkep_result */

    /* Step 1: usb_enumerate(dwc2_base, &ecm_dev_desc) */
    mov     x0, x19
    ldr     x1, =ecm_dev_desc
    bl      usb_enumerate
    cbnz    w0, .Lecm_init_fail

    /* Step 2: Extract bMaxPacketSize0 */
    ldr     x0, =ecm_dev_desc
    ldrb    w21, [x0, #USBDEV_BMAXPACKETSIZE0]

    /* Step 3: usb_get_config_desc(dwc2_base, 1, MPS, &ecm_cfg_desc, 256) */
    mov     x0, x19
    mov     w1, #1
    mov     w2, w21
    ldr     x3, =ecm_cfg_desc
    mov     w4, #256
    bl      usb_get_config_desc
    cbnz    w0, .Lecm_init_fail

    /* Step 4: usb_parse_bulk_eps(&ecm_cfg_desc, usb_cfg_total_len, bulkep_result) */
    ldr     x0, =ecm_cfg_desc
    ldr     x1, =usb_cfg_total_len
    ldrh    w1, [x1]
    mov     x2, x20
    bl      usb_parse_bulk_eps
    cbnz    w0, .Lecm_init_fail

    /* Step 5: Build SET_CONFIGURATION setup packet */
    ldr     x0, =setup_set_cfg_tmpl
    ldr     x1, [x0]
    ldr     x0, =ecm_setup_set_cfg
    str     x1, [x0]
    /* Patch wValue low byte with bConfigurationValue */
    ldr     x1, =ecm_cfg_desc
    ldrb    w1, [x1, #USB_CFG_BCFGVALUE]
    strb    w1, [x0, #2]

    /* Step 6: usb_control_xfer(dwc2_base, 1, MPS, &ecm_setup_set_cfg, NULL, 0) */
    mov     x0, x19
    mov     w1, #1
    mov     w2, w21
    ldr     x3, =ecm_setup_set_cfg
    mov     x4, #0
    mov     w5, #0
    bl      usb_control_xfer
    cbnz    w0, .Lecm_init_fail

    mov     w0, #0
    b       .Lecm_init_done

.Lecm_init_fail:
    mov     w0, #1

.Lecm_init_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* SET_CONFIGURATION template: bmReqType=0, bReq=9, wValue/wIndex/wLength=0 */
.section .rodata
.balign 4
setup_set_cfg_tmpl:
    .byte   0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00

/* Internal buffers */
.section .data
.balign 4
ecm_dev_desc:
    .space  18

.balign 4
ecm_cfg_desc:
    .space  256

.balign 4
ecm_setup_set_cfg:
    .space  8
