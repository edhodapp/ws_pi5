.include "mailbox.inc"
.include "dwc2.inc"

.global dwc2_init
.global dwc2_port_init
.global dwc2_channel_xfer

.section .text

/*
 * dwc2_init - Initialize the DWC2 USB host controller
 *
 * x0: DWC2 base address
 *
 * Sequence:
 *   1. Power on USB via VideoCore mailbox
 *   2. Core soft reset
 *   3. Force host mode
 *   4. Configure host clock, FIFO sizes
 *   5. Flush FIFOs
 *   6. Power the root port
 *   7. Wait for device connection
 *   8. Port reset
 *
 * Returns:
 *   w0: 0 on success (port connected after reset)
 *   w0: 1 on failure (mailbox error or connect timeout)
 *
 * Clobbers: x0-x5 (via mbox_call), x19-x20 saved/restored
 */
dwc2_init:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     x19, x0                 /* x19 = DWC2 base address */

    /* --- Step 1: Power on USB via mailbox --- */
    ldr     x0, =dwc2_mbox_buf

    /* Build SET_POWER_STATE tag buffer */
    mov     w1, #32
    str     w1, [x0]                /* buffer size */
    str     wzr, [x0, #4]           /* request code */
    ldr     w1, =TAG_SET_POWER
    str     w1, [x0, #8]            /* tag id */
    mov     w1, #8
    str     w1, [x0, #12]           /* value buffer size */
    str     wzr, [x0, #16]          /* request indicator */
    mov     w1, #MBOX_USB_DEVICE_ID
    str     w1, [x0, #20]           /* device id = 3 (USB HCD) */
    mov     w1, #3
    str     w1, [x0, #24]           /* state = on + wait */
    str     wzr, [x0, #28]          /* end tag */

    mov     w1, #MBOX_CH_PROP
    ldr     x2, =MBOX_BASE
    ldr     x5, =dwc2_mbox_call_fn
    ldr     x5, [x5]
    blr     x5
    cbnz    w0, .Linit_fail

    /* --- Step 2: Core soft reset --- */

    /* Wait for AHB idle before reset */
.Lwait_ahb1:
    ldr     w0, [x19, #DWC2_GRSTCTL]
    tbz     w0, #GRSTCTL_AHBIDLE_BIT, .Lwait_ahb1

    /* Assert soft reset */
    mov     w0, #GRSTCTL_CSFTRST
    str     w0, [x19, #DWC2_GRSTCTL]

    /* Wait for reset to complete (bit 0 auto-clears) */
.Lwait_reset:
    ldr     w0, [x19, #DWC2_GRSTCTL]
    tbnz    w0, #0, .Lwait_reset

    /* Wait for AHB idle after reset */
.Lwait_ahb2:
    ldr     w0, [x19, #DWC2_GRSTCTL]
    tbz     w0, #GRSTCTL_AHBIDLE_BIT, .Lwait_ahb2

    /* Disable power/clock gating */
    str     wzr, [x19, #DWC2_PCGCCTL]

    /* Enable DMA */
    ldr     w0, [x19, #DWC2_GAHBCFG]
    orr     w0, w0, #GAHBCFG_DMAEN
    str     w0, [x19, #DWC2_GAHBCFG]

    /* --- Step 3: Force host mode --- */
    ldr     w0, [x19, #DWC2_GUSBCFG]
    orr     w0, w0, #GUSBCFG_FHMOD
    str     w0, [x19, #DWC2_GUSBCFG]

    /* Delay for mode switch (~25ms at real speed, trivial on QEMU) */
    mov     w0, #10000
.Lmode_delay:
    subs    w0, w0, #1
    b.ne    .Lmode_delay

    /* Wait until host mode is active */
.Lwait_host:
    ldr     w0, [x19, #DWC2_GINTSTS]
    tbz     w0, #GINTSTS_CURMOD_BIT, .Lwait_host

    /* --- Step 4: Configure host clock and FIFOs --- */

    /* HCFG: FS/LS PHY clock = 48 MHz */
    ldr     w0, [x19, #DWC2_HCFG]
    bic     w0, w0, #3
    orr     w0, w0, #1
    str     w0, [x19, #DWC2_HCFG]

    /* RX FIFO size */
    mov     w0, #DWC2_RXFSIZ
    str     w0, [x19, #DWC2_GRXFSIZ]

    /* Non-periodic TX FIFO: depth=256, start=256 */
    ldr     w0, =DWC2_NPTXFSIZ
    str     w0, [x19, #DWC2_GNPTXFSIZ]

    /* Periodic TX FIFO: depth=256, start=512 */
    ldr     w0, =DWC2_PTXFSIZ
    str     w0, [x19, #DWC2_HPTXFSIZ]

    /* --- Step 5: Flush all FIFOs --- */

    /* Flush all TX FIFOs */
    mov     w0, #GRSTCTL_TXFFLSH_ALL
    str     w0, [x19, #DWC2_GRSTCTL]
.Lwait_txflush:
    ldr     w0, [x19, #DWC2_GRSTCTL]
    tbnz    w0, #5, .Lwait_txflush

    /* Flush RX FIFO */
    mov     w0, #GRSTCTL_RXFFLSH
    str     w0, [x19, #DWC2_GRSTCTL]
.Lwait_rxflush:
    ldr     w0, [x19, #DWC2_GRSTCTL]
    tbnz    w0, #4, .Lwait_rxflush

    /* Fall through to port init */
    b       .Lport_init_entry

/*
 * dwc2_port_init - Port power, connect wait, and reset (steps 6-8)
 *
 * x0: DWC2 base address
 *
 * Callable independently for testing with fake register blocks.
 * Expects caller to set up x29/x30/x19/x20 frame if called directly,
 * or use the standalone entry point below.
 *
 * Returns:
 *   w0: 0 on success (port connected after reset)
 *   w0: 1 on failure (connect timeout)
 *
 * Clobbers: x0-x1, x19-x20 saved/restored
 */
dwc2_port_init:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp
    mov     x19, x0

.Lport_init_entry:
    /* --- Step 6: Power the root port --- */
    ldr     w0, [x19, #DWC2_HPRT]
    mov     w1, #HPRT_W1C_MASK
    bic     w0, w0, w1              /* Clear W1C bits */
    orr     w0, w0, #HPRT_PRTPWR
    str     w0, [x19, #DWC2_HPRT]

    /* --- Step 7: Wait for device connection --- */
    mov     w20, #60000
.Lwait_connect:
    ldr     w0, [x19, #DWC2_HPRT]
    tbnz    w0, #0, .Lconnected
    subs    w20, w20, #1
    b.ne    .Lwait_connect
    b       .Linit_fail             /* Timeout — no device */

.Lconnected:
    /* Clear connect-detect W1C bit */
    ldr     w0, [x19, #DWC2_HPRT]
    mov     w1, #HPRT_W1C_MASK
    bic     w0, w0, w1
    orr     w0, w0, #HPRT_PRTCONNDET
    str     w0, [x19, #DWC2_HPRT]

    /* --- Step 8: Port reset --- */

    /* Assert reset */
    ldr     w0, [x19, #DWC2_HPRT]
    mov     w1, #HPRT_W1C_MASK
    bic     w0, w0, w1
    orr     w0, w0, #HPRT_PRTRST
    str     w0, [x19, #DWC2_HPRT]

    /* Hold reset (~50ms real, short loop for QEMU) */
    mov     w0, #50000
.Lreset_delay:
    subs    w0, w0, #1
    b.ne    .Lreset_delay

    /* Deassert reset */
    ldr     w0, [x19, #DWC2_HPRT]
    mov     w1, #HPRT_W1C_MASK
    bic     w0, w0, w1
    bic     w0, w0, #HPRT_PRTRST
    str     w0, [x19, #DWC2_HPRT]

    /* Brief settle delay */
    mov     w0, #50000
.Lpost_reset_delay:
    subs    w0, w0, #1
    b.ne    .Lpost_reset_delay

    /* Success */
    mov     w0, #0
    b       .Linit_done

.Linit_fail:
    mov     w0, #1

.Linit_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * dwc2_channel_xfer - Execute a single transfer on a DWC2 host channel
 *
 * x0: channel register base (dwc2_base + DWC2_HC_BASE + ch * DWC2_HC_STRIDE)
 * w1: HCCHAR value (with HCCHAR_CHEN set)
 * w2: HCTSIZ value (PID, packet count, transfer size)
 * x3: DMA buffer physical address
 *
 * Returns:
 *   w0: HCINT value on completion (test HCINT_XFERCOMP for success)
 *       0 on timeout
 *
 * Leaf function — clobbers: w1-w5
 */
dwc2_channel_xfer:
    /* Clear any pending interrupts */
    mov     w4, #0xFFFF
    str     w4, [x0, #HC_INT]

    /* Enable all channel interrupt sources */
    mov     w4, #0x7FF
    str     w4, [x0, #HC_INTMSK]

    /* Clear split control (no hub) */
    str     wzr, [x0, #HC_SPLT]

    /* Set transfer size and PID */
    str     w2, [x0, #HC_TSIZ]

    /* Set DMA address */
    str     w3, [x0, #HC_DMA]

    /* Start the transfer */
    str     w1, [x0, #HC_CHAR]

    /* Poll for any interrupt (transfer complete, error, NAK, etc.) */
    mov     w5, #60000
.Lcxfer_poll:
    ldr     w4, [x0, #HC_INT]
    cbnz    w4, .Lcxfer_done
    subs    w5, w5, #1
    b.ne    .Lcxfer_poll
    mov     w0, #0
    ret

.Lcxfer_done:
    /* Clear the interrupt bits */
    str     w4, [x0, #HC_INT]
    mov     w0, w4
    ret

/* Function pointer for mbox_call — overridable for testing */
.section .data
.balign 8
.global dwc2_mbox_call_fn
dwc2_mbox_call_fn: .quad mbox_call

/* 16-byte aligned mailbox buffer for USB power-on */
.balign 16
dwc2_mbox_buf:
    .space 32
