/*
 * cpsw_port.S — CPSW port and ALE configuration (TI AM625)
 *
 * Configures the CPSW switch core, host/external ports, MAC sublayer,
 * and Address Lookup Engine for basic Ethernet forwarding.
 *
 * All functions take base addresses as parameters for dependency
 * injection — tests pass pointers to fake register blocks in RAM.
 */

.include "cpsw.inc"

.section .text

/* -----------------------------------------------------------------------
 * cpsw_nu_init — Configure CPSW NU core control registers
 *
 * Input:  x0 = NU base address
 * Output: (none)
 * Leaf function — no stack frame.
 * ----------------------------------------------------------------------- */
.global cpsw_nu_init
cpsw_nu_init:
    /* CTL: P0_ENABLE | P0_TX_CRC_REMOVE | P0_RX_PAD */
    mov     w1, #NU_CTL_INIT_VAL
    str     w1, [x0, #NU_CTL_REG]

    /* Enable statistics for ports 0, 1, 2 */
    mov     w1, #NU_STAT_PORT_EN_ALL
    str     w1, [x0, #NU_STAT_PORT_EN]

    /* Disable priority elevation */
    str     wzr, [x0, #NU_PTYPE_REG]
    ret

/* -----------------------------------------------------------------------
 * cpsw_port_init — Configure one CPSW port (host or external)
 *
 * Input:  x0 = NU base address
 *         w1 = port number (0 = host, 1+ = external)
 *         x2 = pointer to 6-byte MAC address (ignored for port 0)
 * Output: (none)
 * Leaf function.
 * ----------------------------------------------------------------------- */
.global cpsw_port_init
cpsw_port_init:
    /* Compute port base: NU + (port_num + 1) * 0x1000 */
    add     w3, w1, #1
    lsl     x3, x3, #12
    add     x0, x0, x3

    /* Set max frame length */
    mov     w3, #PN_MAXLEN_DEFAULT
    str     w3, [x0, #PN_RX_MAXLEN]

    /* Host port (port 0) vs external port */
    cbnz    w1, .Lext_port

    /* Host port: set flow ID base to 0 */
    str     wzr, [x0, #PN_FLOW_ID_REG]
    ret

.Lext_port:
    /* External port: write MAC address (network byte order → register) */
    /* SA_L = MAC[2]<<24 | MAC[3]<<16 | MAC[4]<<8 | MAC[5] */
    ldr     w3, [x2, #2]
    rev     w3, w3              /* little-endian load → big-endian register */
    str     w3, [x0, #PN_REG_SA_L]
    /* SA_H = MAC[0]<<8 | MAC[1] */
    ldrh    w3, [x2]
    rev16   w3, w3              /* swap bytes within halfword */
    str     w3, [x0, #PN_REG_SA_H]
    ret

/* -----------------------------------------------------------------------
 * cpsw_macsl_reset — Soft-reset the MAC sublayer and wait for completion
 *
 * Input:  x0 = MACSL base address (port base + PN_MACSL_OFFSET)
 * Output: w0 = 0 success, 1 timeout
 * ----------------------------------------------------------------------- */
.global cpsw_macsl_reset
cpsw_macsl_reset:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0

    /* Assert soft reset */
    mov     w1, #1
    str     w1, [x19, #MACSL_RESET]

    /* Poll via injectable function pointer */
    mov     x0, x19
    ldr     x1, =cpsw_macsl_poll_reset_fn
    ldr     x1, [x1]
    blr     x1

    /* Non-zero = reset cleared (success), 0 = timeout */
    cbz     w0, .Lreset_fail

    mov     w0, #0
    ldp     x19, x30, [sp], #16
    ret

.Lreset_fail:
    mov     w0, #1
    ldp     x19, x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * cpsw_macsl_config — Set MAC sublayer speed and duplex
 *
 * Input:  x0 = MACSL base address
 *         w1 = link speed (SPEED_10, SPEED_100, or SPEED_1000)
 * Output: (none)
 * Leaf function. Unknown speed defaults to 10 Mbps (safe fallback).
 * ----------------------------------------------------------------------- */
.global cpsw_macsl_config
cpsw_macsl_config:
    mov     w2, #MACSL_CTL_10
    cmp     w1, #SPEED_1000
    b.eq    .Lspeed_1000
    cmp     w1, #SPEED_100
    b.eq    .Lspeed_100
    b       .Lspeed_write

.Lspeed_1000:
    mov     w2, #MACSL_CTL_1000
    b       .Lspeed_write

.Lspeed_100:
    mov     w2, #MACSL_CTL_100
    b       .Lspeed_write

.Lspeed_write:
    str     w2, [x0, #MACSL_CTL]
    ret

/* -----------------------------------------------------------------------
 * cpsw_ale_init — Configure ALE for bypass forwarding
 *
 * Input:  x0 = ALE base address
 * Output: (none)
 * Leaf function.
 * ----------------------------------------------------------------------- */
.global cpsw_ale_init
cpsw_ale_init:
    /* ALE_CTL = ENABLE | RESET_TBL | BYPASS = 0xC0000010 */
    mov     w1, #0x10
    movk    w1, #0xC000, lsl #16
    str     w1, [x0, #ALE_CTL]

    /* Set port 0 and port 1 to FORWARD mode */
    mov     w1, #ALE_PN_FORWARD
    str     w1, [x0, #ALE_PN_CTL_BASE]
    str     w1, [x0, #(ALE_PN_CTL_BASE + ALE_PN_CTL_STRIDE)]
    ret

/* -----------------------------------------------------------------------
 * Default MACSL reset poll — poll RESET register until bit 0 clears
 * ----------------------------------------------------------------------- */
cpsw_macsl_poll_reset:
    mov     w1, #MACSL_POLL_LIMIT
.Lpoll_reset_loop:
    ldr     w2, [x0, #MACSL_RESET]
    tbz     w2, #MACSL_RESET_BIT, .Lpoll_reset_done
    subs    w1, w1, #1
    b.ne    .Lpoll_reset_loop
    mov     w0, #0
    ret
.Lpoll_reset_done:
    mov     w0, #1
    ret

/* -----------------------------------------------------------------------
 * Injectable function pointer for MACSL reset poll
 * ----------------------------------------------------------------------- */
.section .data
.balign 8
.global cpsw_macsl_poll_reset_fn
cpsw_macsl_poll_reset_fn: .quad cpsw_macsl_poll_reset
