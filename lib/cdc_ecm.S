.include "dwc2.inc"
.include "usb.inc"
.include "usb_desc.inc"
.include "cdc_ecm.inc"

.global cdc_ecm_init
.global cdc_ecm_activate
.global cdc_ecm_send
.global cdc_ecm_recv

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

/*
 * cdc_ecm_activate - Activate the CDC-ECM data interface
 *
 * Sends SET_INTERFACE(alt=1, iface=1) and resets PID toggles.
 *
 * x0: DWC2 base address
 * x1: pointer to ECM state struct (ECM_SIZE bytes)
 *
 * Returns:
 *   w0: 0 on success, 1 on failure
 */
cdc_ecm_activate:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     x19, x0                 /* x19 = dwc2_base */
    mov     x20, x1                 /* x20 = ecm_state */

    /* usb_control_xfer(dwc2_base, dev_addr=1, mps=64, &setup_set_iface, NULL, 0) */
    mov     x0, x19
    mov     w1, #1
    mov     w2, #64
    ldr     x3, =setup_set_iface
    mov     x4, #0
    mov     w5, #0
    bl      usb_control_xfer
    cbnz    w0, .Lactivate_fail

    /* Reset PID toggles */
    str     wzr, [x20, #ECM_IN_PID]
    str     wzr, [x20, #ECM_OUT_PID]

    mov     w0, #0
    b       .Lactivate_done

.Lactivate_fail:
    mov     w0, #1

.Lactivate_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * cdc_ecm_send - Send an Ethernet frame via bulk OUT
 *
 * x0: DWC2 base address
 * x1: pointer to ECM state struct
 * x2: pointer to frame buffer
 * w3: frame length
 *
 * Returns:
 *   w0: 0 on success, 1 on failure
 */
cdc_ecm_send:
    mov     x9, x1                  /* save ecm_state */
    mov     x4, x2                  /* buf */
    mov     w5, w3                  /* len */
    ldrb    w2, [x9, #ECM_OUT_ADDR] /* ep_addr */
    ldrh    w3, [x9, #ECM_OUT_MPS]  /* mps */
    add     x6, x9, #ECM_OUT_PID    /* pid_ptr */
    mov     w1, #1                   /* dev_addr */
    b       usb_bulk_xfer

/*
 * cdc_ecm_recv - Receive an Ethernet frame via bulk IN
 *
 * x0: DWC2 base address
 * x1: pointer to ECM state struct
 * x2: pointer to receive buffer
 * w3: buffer length
 *
 * Returns:
 *   w0: 0 on success, 1 on failure
 */
cdc_ecm_recv:
    mov     x9, x1                  /* save ecm_state */
    mov     x4, x2                  /* buf */
    mov     w5, w3                  /* len */
    ldrb    w2, [x9, #ECM_IN_ADDR]  /* ep_addr */
    ldrh    w3, [x9, #ECM_IN_MPS]   /* mps */
    add     x6, x9, #ECM_IN_PID     /* pid_ptr */
    mov     w1, #1                   /* dev_addr */
    b       usb_bulk_xfer

/* SET_CONFIGURATION template: bmReqType=0, bReq=9, wValue/wIndex/wLength=0 */
.section .rodata
.balign 4
setup_set_cfg_tmpl:
    .byte   0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00

/* SET_INTERFACE: bmReqType=0x01, bReq=0x0B, wValue=1(alt), wIndex=1(iface), wLength=0 */
.balign 4
setup_set_iface:
    .byte   0x01, 0x0B, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00

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
