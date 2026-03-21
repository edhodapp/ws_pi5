.include "dwc2.inc"

.global usb_bulk_xfer

.section .text

/*
 * usb_bulk_xfer - Execute a USB bulk transfer with DATA toggle tracking
 *
 * x0: DWC2 base address
 * w1: device address (0-127)
 * w2: endpoint address (bit 7 = direction: 1=IN, 0=OUT; bits 3:0 = EP number)
 * w3: max packet size
 * x4: pointer to data buffer
 * w5: data length
 * x6: pointer to PID state word (HCTSIZ_PID_DATA0 or HCTSIZ_PID_DATA1;
 *     caller initializes before first call, updated on success)
 *
 * Returns:
 *   w0: 0 on success, 1 on failure
 *   w1: actual bytes transferred (valid only on success)
 */
usb_bulk_xfer:
    stp     x29, x30, [sp, #-80]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    mov     x29, sp

    /* Save arguments in callee-saved registers */
    add     x19, x0, #DWC2_HC_BASE /* x19 = channel 0 register base */
    mov     w20, w1                 /* w20 = device address */
    mov     w21, w2                 /* w21 = ep_addr */
    mov     w22, w3                 /* w22 = mps */
    mov     x23, x4                 /* x23 = data buffer */
    mov     w24, w5                 /* w24 = data length */
    mov     x25, x6                 /* x25 = pid_ptr */

    /* pktcnt = ceil(len / mps) = (len + mps - 1) / mps */
    add     w9, w24, w22
    sub     w9, w9, #1
    udiv    w26, w9, w22            /* w26 = pktcnt */

    /* Build HCCHAR in w1:
     *   MPS | (epnum << 11) | [EPDIR_IN] | EPTYPE_BULK | (devaddr << 22) | CHEN */
    mov     w1, w22
    and     w9, w21, #0x0F
    orr     w1, w1, w9, lsl #HCCHAR_EPNUM_SHIFT
    tst     w21, #0x80
    b.eq    1f
    orr     w1, w1, #HCCHAR_EPDIR_IN
1:  orr     w1, w1, #HCCHAR_EPTYPE_BULK
    orr     w1, w1, w20, lsl #22
    orr     w1, w1, #HCCHAR_CHEN

    /* Build HCTSIZ in w2: len | (pktcnt << 19) | *pid_ptr */
    mov     w2, w24
    orr     w2, w2, w26, lsl #19
    ldr     w9, [x25]
    orr     w2, w2, w9

    /* Dispatch via injectable function pointer */
    mov     x0, x19
    mov     x3, x23
    ldr     x5, =usb_channel_xfer_fn
    ldr     x5, [x5]
    blr     x5

    tst     w0, #HCINT_XFERCOMP
    b.eq    .Lbulk_fail

    /* Success — toggle PID if pktcnt is odd */
    tbz     w26, #0, .Lbulk_ok
    ldr     w9, [x25]
    eor     w9, w9, #0x40000000
    str     w9, [x25]
.Lbulk_ok:
    /* Compute actual bytes transferred: original_len - HCTSIZ remaining */
    ldr     w1, [x19, #HC_TSIZ]
    and     w1, w1, #0x7FFFF       /* bits [18:0] = remaining byte count */
    sub     w1, w24, w1             /* w1 = actual bytes transferred */
    mov     w0, #0
    b       .Lbulk_done

.Lbulk_fail:
    mov     w0, #1

.Lbulk_done:
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret
