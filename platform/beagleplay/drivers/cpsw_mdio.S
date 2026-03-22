/*
 * cpsw_mdio.S — CPSW MDIO bus driver (TI AM625)
 *
 * Reads/writes PHY registers over the MDIO management interface.
 * All functions take the MDIO base address as x0 for dependency
 * injection — tests pass a pointer to a fake register block in RAM.
 *
 * Poll loops are factored through function pointers in .data so
 * tests can inject fakes that return immediately.
 */

.include "cpsw.inc"

.section .text

/* -----------------------------------------------------------------------
 * cpsw_mdio_init — Enable MDIO controller and wait for ready
 *
 * Input:  x0 = MDIO base address
 * Output: w0 = 0 success, 1 failure (IDLE didn't clear)
 * ----------------------------------------------------------------------- */
.global cpsw_mdio_init
cpsw_mdio_init:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0

    /* Write CONTROL = ENABLE | CLKDIV_DEFAULT */
    mov     w1, #MDIO_CLKDIV_DEFAULT
    orr     w1, w1, #MDIO_CTRL_ENABLE
    str     w1, [x19, #MDIO_CONTROL]

    /* Poll IDLE via injectable function pointer */
    mov     x0, x19
    ldr     x1, =cpsw_mdio_poll_idle_fn
    ldr     x1, [x1]
    blr     x1

    /* Poll returns w0 = CONTROL value (success) or 0 (timeout) */
    cbz     w0, .Linit_fail

    /* Verify IDLE cleared */
    tbnz    w0, #MDIO_CTRL_IDLE_BIT, .Linit_fail

    mov     w0, #0
    ldp     x19, x30, [sp], #16
    ret

.Linit_fail:
    mov     w0, #1
    ldp     x19, x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * cpsw_mdio_read — Read a PHY register via USERACCESS0
 *
 * Input:  x0 = MDIO base, w1 = phy_addr (0-31), w2 = reg_addr (0-31)
 * Output: w0 = 16-bit data, w1 = 0 success / 1 failure (timeout or NACK)
 * ----------------------------------------------------------------------- */
.global cpsw_mdio_read
cpsw_mdio_read:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    mov     x19, x0

    /* Compose USERACCESS0 = GO | (reg << 21) | (phy << 16) */
    mov     w3, #MDIO_UA_GO
    bfi     w3, w2, #MDIO_UA_REGADDR_SHIFT, #5
    bfi     w3, w1, #MDIO_UA_PHYADDR_SHIFT, #5
    str     w3, [x19, #MDIO_USERACCESS0]

    /* Poll GO via injectable function pointer */
    mov     x0, x19
    ldr     x1, =cpsw_mdio_poll_go_fn
    ldr     x1, [x1]
    blr     x1

    /* Poll returns w0 = USERACCESS0 value (GO cleared) or 0 (timeout) */
    cbz     w0, .Lread_fail

    /* Check ACK bit */
    tbz     w0, #MDIO_UA_ACK_BIT, .Lread_nack

    /* Extract 16-bit DATA */
    ubfx    w0, w0, #0, #16
    mov     w1, #0
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

.Lread_nack:
.Lread_fail:
    mov     w0, #0
    mov     w1, #1
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* -----------------------------------------------------------------------
 * cpsw_mdio_write — Write a PHY register via USERACCESS0
 *
 * Input:  x0 = MDIO base, w1 = phy_addr, w2 = reg_addr, w3 = 16-bit value
 * Output: w0 = 0 success, 1 timeout
 * ----------------------------------------------------------------------- */
.global cpsw_mdio_write
cpsw_mdio_write:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0

    /* Compose USERACCESS0 = GO | WRITE | (reg << 21) | (phy << 16) | data */
    and     w4, w3, #MDIO_UA_DATA_MASK
    mov     w5, #MDIO_UA_GO
    orr     w5, w5, #MDIO_UA_WRITE
    orr     w4, w4, w5
    bfi     w4, w2, #MDIO_UA_REGADDR_SHIFT, #5
    bfi     w4, w1, #MDIO_UA_PHYADDR_SHIFT, #5
    str     w4, [x19, #MDIO_USERACCESS0]

    /* Poll GO via injectable function pointer */
    mov     x0, x19
    ldr     x1, =cpsw_mdio_poll_go_fn
    ldr     x1, [x1]
    blr     x1

    /* Poll returns non-zero on success, 0 on timeout */
    cbz     w0, .Lwrite_fail

    mov     w0, #0
    ldp     x19, x30, [sp], #16
    ret

.Lwrite_fail:
    mov     w0, #1
    ldp     x19, x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * cpsw_mdio_link_status — Check PHY link via MDIO LINK register
 *
 * Input:  x0 = MDIO base, w1 = phy_addr (0-31)
 * Output: w0 = 1 link up, 0 link down
 * Leaf function — no stack frame.
 * ----------------------------------------------------------------------- */
.global cpsw_mdio_link_status
cpsw_mdio_link_status:
    ldr     w2, [x0, #MDIO_LINK]
    lsr     w0, w2, w1
    and     w0, w0, #1
    ret

/* -----------------------------------------------------------------------
 * cpsw_mdio_phy_alive — Check PHY presence via MDIO ALIVE register
 *
 * Input:  x0 = MDIO base, w1 = phy_addr (0-31)
 * Output: w0 = 1 alive, 0 not detected
 * Leaf function — no stack frame.
 * ----------------------------------------------------------------------- */
.global cpsw_mdio_phy_alive
cpsw_mdio_phy_alive:
    ldr     w2, [x0, #MDIO_ALIVE]
    lsr     w0, w2, w1
    and     w0, w0, #1
    ret

/* -----------------------------------------------------------------------
 * Default poll implementations — overridable via function pointers
 * ----------------------------------------------------------------------- */

/*
 * cpsw_mdio_poll_idle — Poll CONTROL register until IDLE clears
 * Input:  x0 = MDIO base
 * Output: w0 = CONTROL value (IDLE clear) or 0 (timeout)
 */
cpsw_mdio_poll_idle:
    mov     w1, #MDIO_POLL_LIMIT
.Lpoll_idle_loop:
    ldr     w2, [x0, #MDIO_CONTROL]
    tbz     w2, #MDIO_CTRL_IDLE_BIT, .Lpoll_idle_done
    subs    w1, w1, #1
    b.ne    .Lpoll_idle_loop
    mov     w0, #0
    ret
.Lpoll_idle_done:
    mov     w0, w2
    ret

/*
 * cpsw_mdio_poll_go — Poll USERACCESS0 until GO clears
 * Input:  x0 = MDIO base
 * Output: w0 = USERACCESS0 value (GO clear) or 0 (timeout)
 */
cpsw_mdio_poll_go:
    mov     w1, #MDIO_POLL_LIMIT
.Lpoll_go_loop:
    ldr     w2, [x0, #MDIO_USERACCESS0]
    tbz     w2, #MDIO_UA_GO_BIT, .Lpoll_go_done
    subs    w1, w1, #1
    b.ne    .Lpoll_go_loop
    mov     w0, #0
    ret
.Lpoll_go_done:
    mov     w0, w2
    ret

/* -----------------------------------------------------------------------
 * Injectable function pointers
 * ----------------------------------------------------------------------- */
.section .data
.balign 8
.global cpsw_mdio_poll_idle_fn
cpsw_mdio_poll_idle_fn: .quad cpsw_mdio_poll_idle

.balign 8
.global cpsw_mdio_poll_go_fn
cpsw_mdio_poll_go_fn:   .quad cpsw_mdio_poll_go
