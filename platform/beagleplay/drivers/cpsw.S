/*
 * cpsw.S — CPSW Ethernet top-level driver (TI AM625)
 *
 * Wires MDIO, port/ALE, and (future) PKTDMA layers into a single
 * init/send/recv interface matching the Pi's CDC-ECM calling convention.
 *
 * cpsw_init does real work (calls sub-drivers).
 * cpsw_send/cpsw_recv are stubs until PKTDMA is implemented.
 */

.include "cpsw.inc"

.section .text

/* -----------------------------------------------------------------------
 * cpsw_init — Bring up CPSW Ethernet subsystem
 *
 * Input:  x0 = pointer to CPSW state struct (CPSW_ST_SIZE, zeroed)
 *         x1 = pointer to 6-byte MAC address
 *         x2 = CPSW base address (tests: fake block; production: CPSW_BASE)
 * Output: w0 = 0 success, 1 failure
 * ----------------------------------------------------------------------- */
.global cpsw_init
cpsw_init:
    stp     x19, x30, [sp, #-48]!
    stp     x20, x21, [sp, #16]
    stp     x22, x23, [sp, #32]
    mov     x19, x0                 /* state struct */
    mov     x20, x1                 /* mac addr */

    /* Compute and store MDIO base = cpsw_base + 0xF00 */
    add     x21, x2, #CPSW_MDIO_OFFSET
    str     x21, [x19, #CPSW_ST_MDIO_BASE]

    /* NU base = cpsw_base + 0x20000 */
    add     x22, x2, #0x20, lsl #12
    str     x22, [x19, #CPSW_ST_NU_BASE]

    /* ALE base = nu_base + 0x1E000 */
    add     x23, x22, #0x1E, lsl #12
    str     x23, [x19, #CPSW_ST_ALE_BASE]

    /* MACSL base = nu_base + 0x2000 + 0x330 */
    add     x23, x22, #0x2, lsl #12
    add     x23, x23, #PN_MACSL_OFFSET
    str     x23, [x19, #CPSW_ST_MACSL_BASE]

    /* --- Step 1: MDIO init --- */
    mov     x0, x21
    bl      cpsw_mdio_init
    cbnz    w0, .Linit_fail

    /* --- Step 2: PHY detect (read PHYID1 at PHY 0) --- */
    mov     x0, x21
    mov     w1, #0                  /* PHY address 0 */
    mov     w2, #MII_PHYID1
    bl      cpsw_mdio_read
    cbnz    w1, .Linit_fail         /* w1=1 → read failed */

    /* Store PHY address and default link speed */
    str     wzr, [x19, #CPSW_ST_PHY_ADDR]
    mov     w0, #SPEED_1000
    str     w0, [x19, #CPSW_ST_LINK_SPEED]

    /* --- Step 3: NU core init --- */
    mov     x0, x22
    bl      cpsw_nu_init

    /* --- Step 4: Host port (port 0) --- */
    mov     x0, x22
    mov     w1, #0
    mov     x2, xzr
    bl      cpsw_port_init

    /* --- Step 5: External port (port 1) with MAC --- */
    mov     x0, x22
    mov     w1, #1
    mov     x2, x20
    bl      cpsw_port_init

    /* --- Step 6: MACSL reset --- */
    ldr     x0, [x19, #CPSW_ST_MACSL_BASE]
    bl      cpsw_macsl_reset
    cbnz    w0, .Linit_fail

    /* --- Step 7: MACSL config (1000 Mbps default) --- */
    ldr     x0, [x19, #CPSW_ST_MACSL_BASE]
    mov     w1, #SPEED_1000
    bl      cpsw_macsl_config

    /* --- Step 8: ALE bypass forwarding --- */
    ldr     x0, [x19, #CPSW_ST_ALE_BASE]
    bl      cpsw_ale_init

    /* --- Step 9: PKTDMA (stub — skip, return success) --- */

    mov     w0, #0
    ldp     x22, x23, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #48
    ret

.Linit_fail:
    mov     w0, #1
    ldp     x22, x23, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #48
    ret

/* -----------------------------------------------------------------------
 * cpsw_send — Send an Ethernet frame (stub)
 *
 * Input:  x0 = CPSW base, x1 = state, x2 = frame buf, w3 = frame len
 * Output: w0 = 1 (always fails — no PKTDMA yet)
 * Leaf function.
 * ----------------------------------------------------------------------- */
.global cpsw_send
cpsw_send:
    mov     w0, #1
    ret

/* -----------------------------------------------------------------------
 * cpsw_recv — Receive an Ethernet frame (stub)
 *
 * Input:  x0 = CPSW base, x1 = state, x2 = recv buf, w3 = buf len
 * Output: w0 = 1 (always fails), w1 = 0 (no bytes)
 * Leaf function.
 * ----------------------------------------------------------------------- */
.global cpsw_recv
cpsw_recv:
    mov     w0, #1
    mov     w1, #0
    ret
