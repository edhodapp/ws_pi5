.include "mailbox.inc"

.global mbox_call

.section .text

/*
 * mbox_call - Send a property tag buffer to the VideoCore mailbox
 *
 * x0: physical address of 16-byte-aligned tag buffer
 * w1: channel number (typically MBOX_CH_PROP = 8)
 *
 * Returns:
 *   w0: 0 on success (buffer code has response-ok bit set)
 *   w0: 1 on failure
 *
 * The buffer must be 16-byte aligned (low 4 bits available for channel).
 * Caller must construct a valid property tag buffer before calling.
 *
 * Clobbers: x0-x5
 */
mbox_call:
    /* Combine buffer address with channel in low 4 bits */
    and     w2, w1, #0xF
    orr     x2, x0, x2             /* x2 = buffer | channel */

    ldr     x3, =MBOX_BASE

    /* Poll until mailbox is not full */
.Lmbox_write_wait:
    ldr     w4, [x3, #MBOX_STATUS]
    tbnz    w4, #31, .Lmbox_write_wait   /* bit 31 = FULL */

    /* Write the request */
    str     w2, [x3, #MBOX_WRITE]

    /* Poll for response on our channel */
.Lmbox_read_wait:
    ldr     w4, [x3, #MBOX_STATUS]
    tbnz    w4, #30, .Lmbox_read_wait    /* bit 30 = EMPTY */

    ldr     w4, [x3, #MBOX_READ]

    /* Check channel matches */
    and     w5, w4, #0xF
    cmp     w5, w1
    b.ne    .Lmbox_read_wait      /* Not our channel, keep polling */

    /* Check buffer response code (offset 4 in buffer = request/response code) */
    ldr     w0, [x0, #4]
    and     w0, w0, #0x80000000
    cmp     w0, #0
    cset    w0, eq                 /* w0 = 1 if no response bit (failure), 0 if set (success) */
    ret
