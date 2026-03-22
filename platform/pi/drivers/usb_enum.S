.include "dwc2.inc"
.include "usb.inc"

.global usb_control_xfer
.global usb_enumerate

.section .text

/*
 * usb_control_xfer - Execute a USB control transfer (SETUP + optional DATA + STATUS)
 *
 * x0: DWC2 base address
 * w1: device address (0-127)
 * w2: EP0 max packet size
 * x3: pointer to 8-byte setup packet
 * x4: pointer to data buffer (ignored if w5 == 0)
 * w5: data length (0 for no-data control transfers)
 *
 * Returns:
 *   w0: 0 on success, 1 on failure
 *
 * Uses channel 0 for all phases. Direction extracted from setup packet byte 0 bit 7.
 */
usb_control_xfer:
    stp     x29, x30, [sp, #-80]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    mov     x29, sp

    /* Save arguments in callee-saved registers */
    add     x20, x0, #DWC2_HC_BASE /* x20 = channel 0 register base */
    mov     w21, w1                 /* w21 = device address */
    mov     w22, w2                 /* w22 = EP0 MPS */
    mov     x23, x3                 /* x23 = setup packet */
    mov     x24, x4                 /* x24 = data buffer */
    mov     w25, w5                 /* w25 = data length */

    /* Extract direction from bmRequestType bit 7 */
    ldrb    w26, [x23]
    lsr     w26, w26, #7            /* w26 = 1 if IN, 0 if OUT */

    /* === SETUP phase: OUT, PID=SETUP, 8 bytes === */

    /* HCCHAR: MPS | (dev_addr << 22) | CHEN — direction=OUT(0), type=control(0) */
    mov     w1, w22
    orr     w1, w1, w21, lsl #22
    orr     w1, w1, #HCCHAR_CHEN

    /* HCTSIZ: PID=SETUP | PKTCNT=1 | SIZE=8 */
    mov     w2, #SETUP_SIZE
    orr     w2, w2, #HCTSIZ_PKTCNT_1
    orr     w2, w2, #HCTSIZ_PID_SETUP

    mov     x0, x20
    mov     x3, x23                 /* DMA addr = setup packet */
    ldr     x5, =usb_channel_xfer_fn
    ldr     x5, [x5]
    blr     x5

    tst     w0, #HCINT_XFERCOMP
    b.eq    .Lctl_fail

    /* === DATA phase (skip if data_len == 0) === */
    cbz     w25, .Lctl_status

    /* HCCHAR: MPS | (dev_addr << 22) | direction | CHEN */
    mov     w1, w22
    orr     w1, w1, w21, lsl #22
    cbz     w26, 1f
    orr     w1, w1, #HCCHAR_EPDIR_IN
1:  orr     w1, w1, #HCCHAR_CHEN

    /* HCTSIZ: PID=DATA1 | PKTCNT | SIZE */
    mov     w2, w25                 /* transfer size */
    /* pkt_count = ceil(data_len / mps) */
    add     w3, w25, w22
    sub     w3, w3, #1
    udiv    w3, w3, w22
    orr     w2, w2, w3, lsl #19
    orr     w2, w2, #HCTSIZ_PID_DATA1

    mov     x0, x20
    mov     x3, x24                 /* DMA addr = data buffer */
    ldr     x5, =usb_channel_xfer_fn
    ldr     x5, [x5]
    blr     x5

    tst     w0, #HCINT_XFERCOMP
    b.eq    .Lctl_fail

    /* === STATUS phase: opposite direction, zero-length, PID=DATA1 === */
.Lctl_status:
    /* Status is IN unless data phase was IN (then OUT) */
    mov     w1, w22
    orr     w1, w1, w21, lsl #22

    /* Determine status direction */
    cbnz    w25, .Lctl_status_has_data
    /* No data phase → status is IN */
    orr     w1, w1, #HCCHAR_EPDIR_IN
    b       .Lctl_status_go
.Lctl_status_has_data:
    cbz     w26, .Lctl_status_in    /* data was OUT → status IN */
    b       .Lctl_status_go         /* data was IN → status OUT */
.Lctl_status_in:
    orr     w1, w1, #HCCHAR_EPDIR_IN
.Lctl_status_go:
    orr     w1, w1, #HCCHAR_CHEN

    /* HCTSIZ: PID=DATA1 | PKTCNT=1 | SIZE=0 */
    mov     w2, #0
    orr     w2, w2, #HCTSIZ_PKTCNT_1
    orr     w2, w2, #HCTSIZ_PID_DATA1

    mov     x0, x20
    ldr     x3, =usb_status_buf    /* DMA needs a valid address */
    ldr     x5, =usb_channel_xfer_fn
    ldr     x5, [x5]
    blr     x5

    tst     w0, #HCINT_XFERCOMP
    b.eq    .Lctl_fail

    mov     w0, #0
    b       .Lctl_done

.Lctl_fail:
    mov     w0, #1

.Lctl_done:
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret

/*
 * usb_enumerate - Enumerate a USB device on the DWC2 root port
 *
 * Performs:
 *   1. GET_DESCRIPTOR(device, 8) at address 0 → extract bMaxPacketSize0
 *   2. SET_ADDRESS(1)
 *   3. GET_DESCRIPTOR(device, 18) at address 1 → full device descriptor
 *
 * x0: DWC2 base address (after dwc2_init)
 * x1: pointer to 18-byte buffer to receive the device descriptor
 *
 * Returns:
 *   w0: 0 on success, 1 on failure
 */
usb_enumerate:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x29, sp

    mov     x19, x0                 /* x19 = DWC2 base */
    mov     x20, x1                 /* x20 = descriptor buffer */

    /* --- Step 1: GET_DESCRIPTOR(device, 8 bytes) at address 0, MPS=8 --- */
    mov     x0, x19
    mov     w1, #0                  /* dev addr = 0 */
    mov     w2, #8                  /* initial MPS = 8 */
    ldr     x3, =setup_get_dev8
    mov     x4, x20                 /* receive into desc buffer */
    mov     w5, #8
    bl      usb_control_xfer
    cbnz    w0, .Lenum_fail

    /* Extract bMaxPacketSize0 */
    ldrb    w22, [x20, #USBDEV_BMAXPACKETSIZE0]

    /* --- Step 2: SET_ADDRESS(1) --- */
    mov     x0, x19
    mov     w1, #0                  /* still at address 0 */
    mov     w2, w22                 /* use learned MPS */
    ldr     x3, =setup_set_addr1
    mov     x4, #0                  /* no data */
    mov     w5, #0
    bl      usb_control_xfer
    cbnz    w0, .Lenum_fail

    /* Post-address-change settle delay */
    mov     w0, #50000
.Laddr_delay:
    subs    w0, w0, #1
    b.ne    .Laddr_delay

    /* --- Step 3: GET_DESCRIPTOR(device, 18 bytes) at address 1 --- */
    mov     x0, x19
    mov     w1, #1                  /* dev addr = 1 */
    mov     w2, w22                 /* learned MPS */
    ldr     x3, =setup_get_dev18
    mov     x4, x20                 /* receive into desc buffer */
    mov     w5, #USBDEV_SIZE        /* 18 bytes */
    bl      usb_control_xfer
    cbnz    w0, .Lenum_fail

    mov     w0, #0
    b       .Lenum_done

.Lenum_fail:
    mov     w0, #1

.Lenum_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* Pre-built setup packets in .rodata (read by DMA for SETUP OUT) */
.section .rodata
.balign 4
setup_get_dev8:
    /* GET_DESCRIPTOR, device, 8 bytes */
    .byte   0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x08, 0x00

.balign 4
setup_set_addr1:
    /* SET_ADDRESS, address=1 */
    .byte   0x00, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00

.balign 4
setup_get_dev18:
    /* GET_DESCRIPTOR, device, 18 bytes */
    .byte   0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00

/* Function pointer for dwc2_channel_xfer — overridable for testing */
.section .data
.balign 8
.global usb_channel_xfer_fn
usb_channel_xfer_fn: .quad dwc2_channel_xfer

/* Writable buffer for STATUS phase DMA (zero-length transfers) */
.balign 4
usb_status_buf:
    .space 8
