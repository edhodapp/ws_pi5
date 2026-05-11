.include "mailbox.inc"

.global mbox_call
.global mailbox_get_board_mac

.section .text

/*
 * mbox_call - Send a property tag buffer to the VideoCore mailbox
 *
 * x0: physical address of 16-byte-aligned tag buffer
 * w1: channel number (typically MBOX_CH_PROP = 8)
 * x2: mailbox base address (MBOX_BASE)
 *
 * Returns:
 *   w0: 0 on success (buffer code has response-ok bit set)
 *   w0: 1 on failure
 *
 * The buffer must be 16-byte aligned (low 4 bits available for channel).
 * Caller must construct a valid property tag buffer before calling.
 *
 * Cache coherency: The VideoCore reads/writes the buffer directly in RAM,
 * bypassing the ARM's D-cache. This function cleans the buffer to RAM
 * before the request and invalidates the cache line after the response,
 * so the ARM reads the VC's actual reply, not stale cached data.
 *
 * Clobbers: x0-x5
 */
mbox_call:
    mov     x3, x2                  /* x3 = mbox base */

    /* Combine buffer address with channel in low 4 bits */
    and     w2, w1, #0xF
    orr     x2, x0, x2             /* x2 = buffer | channel */

    /* Flush buffer from D-cache to RAM so VC sees our request */
    dc      civac, x0
    dsb     sy

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

    /* Invalidate buffer cache line — VC wrote response to RAM, not our cache */
    dc      civac, x0
    dsb     sy

    /* Check buffer response code (offset 4 in buffer = request/response code) */
    ldr     w0, [x0, #4]
    and     w0, w0, #0x80000000
    cmp     w0, #0
    cset    w0, eq                 /* w0 = 1 if no response bit (failure), 0 if set (success) */
    ret

/*
 * mailbox_get_board_mac — Read the factory MAC from VC OTP fuses
 *                          via property tag 0x00010003.
 *
 * x0: pointer to caller-owned 6-byte output buffer (any alignment)
 *
 * Returns: w0 = 0 on success (output buffer populated with MAC),
 *          w0 = 1 on failure (mailbox call failed, tag response
 *          missing the response bit, or returned MAC is obviously
 *          invalid — all-zero, all-0xFF, or multicast bit set).
 *
 * The Pi firmware property interface lays out tag 0x00010003 as:
 *   offset 0:  total buffer size (32)
 *   offset 4:  request/response code (0 in / 0x80000000 out)
 *   offset 8:  tag identifier (TAG_GET_BOARD_MAC)
 *   offset 12: tag value buffer size (8 — 6 MAC bytes + 2 padding)
 *   offset 16: tag request/response code (0 in / response bit set out)
 *   offset 20: tag value buffer (MAC bytes 0..5, two bytes padding)
 *   offset 28: end tag (0)
 *
 * The MAC is returned in network byte order at buffer[20..25].
 *
 * Validation: a working Pi 4 OTP returns a Raspberry Pi Foundation
 * OUI MAC (e.g. b8:27:eb, dc:a6:32, d8:3a:dd, e4:5f:01). We reject
 * three categories of "obviously garbage" responses to halt early
 * via the caller's panic_m path:
 *   - All-zero      (OTP not blown / read-back-error on Pi 4 boards
 *                    with no factory MAC)
 *   - All-0xFF      (firmware returned an unspecified-default fill)
 *   - Multicast bit (LSB of byte 0 set — a unicast MAC must have
 *                    this bit clear; any value with it set is
 *                    malformed)
 *
 * Pi 4 only. The .ifdef guard in main.S's call site keeps the
 * Pi 3 / QEMU branches out of this path.
 *
 * Clobbers: x0-x6 (caller-saved). Callee-saved x19 preserved via
 * stp/ldp pair.
 */
mailbox_get_board_mac:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    mov     x29, sp
    mov     x19, x0                 /* save output buffer ptr */

    /* Build request buffer at mbox_buf. */
    ldr     x0, =mbox_buf
    mov     w1, #32
    str     w1, [x0, #0]            /* total buffer size */
    str     wzr, [x0, #4]           /* request code = 0 */
    ldr     w1, =TAG_GET_BOARD_MAC
    str     w1, [x0, #8]            /* tag ID */
    mov     w1, #8
    str     w1, [x0, #12]           /* tag value buffer size */
    str     wzr, [x0, #16]          /* tag request code = 0 */
    str     xzr, [x0, #20]          /* value buffer cleared (8 bytes) */
    str     wzr, [x0, #28]          /* end tag */

    mov     w1, #MBOX_CH_PROP
    ldr     x2, =MBOX_BASE
    bl      mbox_call
    cbnz    w0, .Lmac_fail

    /* Verify the tag's own response bit (in case the buffer-level
     * code is set but this particular tag didn't populate — defensive
     * against multi-tag bundles, which we don't use today but the
     * check is cheap). */
    ldr     x0, =mbox_buf
    ldr     w1, [x0, #16]
    tbz     w1, #31, .Lmac_fail

    /* Copy 6 MAC bytes from buffer+20 to output. ldrb / strb chosen
     * over a ldp pair because the output buffer has no required
     * alignment and we only need 6 bytes — paying for byte access
     * is simpler than handling possible misalignment of x19. */
    add     x0, x0, #20
    ldrb    w1, [x0, #0]
    strb    w1, [x19, #0]
    ldrb    w2, [x0, #1]
    strb    w2, [x19, #1]
    orr     w3, w1, w2              /* accumulate for zero-check */
    ldrb    w1, [x0, #2]
    strb    w1, [x19, #2]
    orr     w3, w3, w1
    ldrb    w2, [x0, #3]
    strb    w2, [x19, #3]
    orr     w3, w3, w2
    ldrb    w1, [x0, #4]
    strb    w1, [x19, #4]
    orr     w3, w3, w1
    ldrb    w2, [x0, #5]
    strb    w2, [x19, #5]
    orr     w3, w3, w2

    /* All-zero check: w3 holds the OR of all 6 bytes. */
    cbz     w3, .Lmac_fail

    /* All-0xFF check: AND of all 6 bytes == 0xFF means every bit was
     * 1. Re-read for clarity; the cost is 6 ldrb's which dominate the
     * function anyway. */
    ldrb    w1, [x19, #0]
    ldrb    w2, [x19, #1]
    and     w3, w1, w2
    ldrb    w2, [x19, #2]
    and     w3, w3, w2
    ldrb    w2, [x19, #3]
    and     w3, w3, w2
    ldrb    w2, [x19, #4]
    and     w3, w3, w2
    ldrb    w2, [x19, #5]
    and     w3, w3, w2
    cmp     w3, #0xFF
    b.eq    .Lmac_fail

    /* Multicast bit check: byte 0 LSB must be 0 for a unicast MAC. */
    ldrb    w1, [x19, #0]
    tbnz    w1, #0, .Lmac_fail

    mov     w0, #0
    b       .Lmac_done

.Lmac_fail:
    mov     w0, #1

.Lmac_done:
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

.section .bss
.balign 16
mbox_buf:
    .space  32                     /* property-tag request/response buffer */
.section .text
