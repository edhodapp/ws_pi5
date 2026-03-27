/*
 * genet.S — BCM2711 GENET v5 Ethernet driver for Pi 4
 *
 * Provides genet_init, genet_send, genet_recv with signatures compatible
 * with the protocol stack's function-pointer send interface.
 *
 * Send: genet_send(x0=genet_base, x1=genet_state, x2=buf, w3=len) → w0
 * Recv: genet_recv(x0=genet_base, x1=genet_state, x2=buf, w3=max) → w0, w1=len
 */

.include "genet.inc"
.include "mailbox.inc"

.global genet_init
.global genet_send
.global genet_recv

.section .text

/*
 * genet_init — Full GENET initialization
 *
 * x0: GENET base address
 * x1: pointer to genet_state struct (GENET_STATE_SIZE bytes, zeroed)
 * x2: RX buffer pool CPU address (DMA_DESC_COUNT * RX_BUF_LENGTH bytes,
 *     cache-line aligned, in lower 1 GB of RAM)
 *
 * Sequence: UMAC reset → RGMII → PHY reset + auto-negotiate →
 *           DMA ring init → MAC enable
 *
 * Returns: w0 = 0 on success, 1 on failure
 * Clobbers: x0-x5, x19-x27 saved/restored
 */
genet_init:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    mov     x29, sp

    mov     x19, x0                 /* x19 = GENET base */
    mov     x20, x1                 /* x20 = genet_state */
    mov     x21, x2                 /* x21 = RX pool addr */

    /* Save RX pool address in state */
    str     x21, [x20, #GENET_STATE_RX_POOL]

    /* Compute TDMA register base (offsets > str immediate range) */
    add     x22, x19, #5, lsl #12  /* x22 = GENET + 0x5000 */

    /* --- UMAC reset --- */
    mov     w0, #2
    str     w0, [x19, #GENET_SYS_RBUF_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    str     wzr, [x19, #GENET_SYS_RBUF_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b

    str     wzr, [x19, #GENET_UMAC_CMD]
    mov     w0, #(UMAC_CMD_LCL_LOOP | UMAC_CMD_SW_RESET)
    str     w0, [x19, #GENET_UMAC_CMD]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    str     wzr, [x19, #GENET_UMAC_CMD]

    /* Port mode: EXT_GPHY */
    mov     w0, #3
    str     w0, [x19, #GENET_SYS_PORT_CTRL]

    /* Reset MIB counters */
    mov     w0, #7
    str     w0, [x19, #GENET_UMAC_MIB_CTRL]
    str     wzr, [x19, #GENET_UMAC_MIB_CTRL]

    /* Max frame length */
    mov     w0, #1536
    str     w0, [x19, #GENET_UMAC_MAX_FRAME]

    /* Mask all interrupts */
    mov     w0, #-1
    str     w0, [x19, #GENET_INTRL2_0_MASK_SET]
    str     w0, [x19, #GENET_INTRL2_0_CLEAR]
    str     w0, [x19, #GENET_INTRL2_1_MASK_SET]
    str     w0, [x19, #GENET_INTRL2_1_CLEAR]

    /* --- RGMII interface --- */
    ldr     w0, [x19, #GENET_EXT_RGMII_OOB]
    bic     w0, w0, #(1 << 5)      /* clear OOB_DISABLE */
    orr     w0, w0, #(1 << 6)      /* RGMII_MODE_EN */
    orr     w0, w0, #(1 << 4)      /* RGMII_LINK */
    orr     w0, w0, #(1 << 16)     /* SET ID_MODE_DIS (no GENET internal delay) */
    str     w0, [x19, #GENET_EXT_RGMII_OOB]

    /* --- PHY reset --- */
    mov     w0, #PHY_BMCR
    mov     w1, #0x8000
    bl      genet_mdio_write

    mov     w23, #50000
.Lphy_rst:
    mov     w0, #PHY_BMCR
    bl      genet_mdio_read
    tbz     w0, #15, .Lphy_rst_ok
    subs    w23, w23, #1
    b.ne    .Lphy_rst
    b       .Linit_fail

.Lphy_rst_ok:
    /* --- Configure BCM54213PE RGMII timing via shadow registers --- */

    /* AUXCTL shadow 7: enable RGMII RXC-RXD skew
     * Read: write (7 << 12 | 0x7) to reg 0x18, read reg 0x18
     * Write: write (7 << 12 | value | 0x8000) to reg 0x18 */
    mov     w0, #0x18              /* AUXCTL register */
    ldr     w1, =0x7007            /* select shadow 7 for read */
    bl      genet_mdio_write
    mov     w0, #0x18
    bl      genet_mdio_read
    orr     w1, w0, #0x100         /* set bit 8: RGMII RXC DLY EN */
    orr     w1, w1, #0x8000        /* write enable */
    mov     w0, #0x18
    bl      genet_mdio_write

    /* Shadow register 3 via reg 0x1C: GTX clock delay
     * Read: write (3 << 10) to reg 0x1C, read reg 0x1C
     * Write: write (3 << 10 | value | 0x8000) to reg 0x1C */
    mov     w0, #0x1C              /* SHADOW register */
    mov     w1, #(3 << 10)         /* select shadow 3 */
    bl      genet_mdio_write
    mov     w0, #0x1C
    bl      genet_mdio_read
    orr     w1, w0, #(1 << 9)      /* set bit 9: GTX CLK delay enable */
    movz    w2, #0x8000
    orr     w1, w1, w2             /* write enable */
    orr     w1, w1, #(3 << 10)    /* keep shadow 3 selected */
    mov     w0, #0x1C
    bl      genet_mdio_write

    /* Auto-negotiate */
    mov     w0, #PHY_BMCR
    ldr     w1, =0x1340
    bl      genet_mdio_write

    /* Poll BMSR bit 5 for AN complete */
    ldr     w23, =5000000
.Lan_poll:
    mov     w0, #PHY_BMSR
    bl      genet_mdio_read
    tbnz    w0, #5, .Lan_ok
    subs    w23, w23, #1
    b.ne    .Lan_poll
    b       .Linit_fail

.Lan_ok:
    /* Check link */
    mov     w0, #PHY_BMSR
    bl      genet_mdio_read
    tbz     w0, #2, .Linit_fail

    /* Read speed from AUX_STS */
    mov     w0, #PHY_AUX_STS
    bl      genet_mdio_read
    lsr     w0, w0, #8
    and     w23, w0, #7             /* w23 = speed code */

    /* --- Disable DMA --- */
    str     wzr, [x22, #TDMA_DMA_CTRL_OFS]
    str     wzr, [x19, #RDMA_DMA_CTRL]

    mov     w0, #1
    str     w0, [x19, #GENET_UMAC_TX_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    str     wzr, [x19, #GENET_UMAC_TX_FLUSH]

    /* RBUF_TBUF_SIZE_CTRL: must be set to 1 for TX to work (allocates TBUF space) */
    mov     w0, #1
    str     w0, [x19, #0x3B4]

    /* --- Init RX descriptors --- */
    mov     x24, x21                /* current buffer addr */
    add     x25, x19, #2, lsl #12  /* x25 = RX descriptor base */
    mov     w26, #0

.Lrx_init:
    /* GENET DMA uses CPU physical addresses directly (no bus offset) */
    mov     w0, w24

    ldr     w2, =((RX_BUF_LENGTH << 16) | RX_DMA_OWN)
    str     w2, [x25, #0]
    str     w0, [x25, #4]
    str     wzr, [x25, #8]

    add     x24, x24, #RX_BUF_LENGTH
    add     x25, x25, #DMA_DESC_SIZE
    add     w26, w26, #1
    cmp     w26, #DMA_DESC_COUNT
    b.lt    .Lrx_init

    /* --- RX ring 16 registers --- */
    str     wzr, [x19, #RDMA_WRITE_PTR]
    str     wzr, [x19, #RDMA_PROD_INDEX]
    str     wzr, [x19, #RDMA_CONS_INDEX]
    ldr     w0, =((DMA_DESC_COUNT << 16) | RX_BUF_LENGTH)
    str     w0, [x19, #RDMA_RING_BUF_SIZE]
    str     wzr, [x19, #RDMA_START_ADDR]
    ldr     w0, =((DMA_DESC_COUNT * DMA_DESC_SIZE / 4) - 1)
    str     w0, [x19, #RDMA_END_ADDR]
    ldr     w0, =0x00050010
    str     w0, [x19, #RDMA_XON_XOFF_THRESH]
    str     wzr, [x19, #RDMA_READ_PTR]

    /* --- TX ring 16 registers --- */
    str     wzr, [x22, #TDMA_READ_PTR_OFS]
    /* CONS_INDEX is write-once — read it and align PROD_INDEX to match */
    ldr     w0, [x22, #TDMA_CONS_INDEX_OFS]
    str     w0, [x22, #TDMA_PROD_INDEX_OFS]
    ldr     w0, =((DMA_DESC_COUNT << 16) | RX_BUF_LENGTH)
    str     w0, [x22, #TDMA_RING_BUF_SIZE_OFS]
    str     wzr, [x22, #TDMA_START_ADDR_OFS]
    ldr     w0, =((DMA_DESC_COUNT * DMA_DESC_SIZE / 4) - 1)
    str     w0, [x22, #TDMA_END_ADDR_OFS]
    mov     w0, #1
    str     w0, [x22, #TDMA_MBUF_DONE_THRESH_OFS]
    str     wzr, [x22, #TDMA_FLOW_PERIOD_OFS]
    str     wzr, [x22, #TDMA_WRITE_PTR_OFS]

    /* --- Enable DMA --- */
    mov     w0, #DMA_BURST_SIZE
    str     w0, [x19, #RDMA_DMA_SCB_BURST_SIZE]
    str     w0, [x22, #TDMA_DMA_SCB_BURST_OFS]

    ldr     w0, =DMA_RING_CFG_EN
    str     w0, [x19, #RDMA_DMA_RING_CFG]
    str     w0, [x22, #TDMA_DMA_RING_CFG_OFS]

    ldr     w0, =DMA_CTRL_EN
    str     w0, [x19, #RDMA_DMA_CTRL]
    str     w0, [x22, #TDMA_DMA_CTRL_OFS]

    /* --- RBUF 2-byte align --- */
    ldr     w0, [x19, #GENET_RBUF_CTRL]
    orr     w0, w0, #2
    str     w0, [x19, #GENET_RBUF_CTRL]

    /* --- Set speed (U-Boot writes speed alone, clearing all other bits) --- */
    mov     w0, #0
    cmp     w23, #7
    b.eq    .Lsp_1000
    cmp     w23, #6
    b.eq    .Lsp_1000
    cmp     w23, #5
    b.eq    .Lsp_100
    cmp     w23, #3
    b.eq    .Lsp_100
    b       .Lsp_set
.Lsp_1000:
    mov     w0, #UMAC_CMD_SPEED_1000
    b       .Lsp_set
.Lsp_100:
    mov     w0, #UMAC_CMD_SPEED_100
.Lsp_set:
    str     w0, [x19, #GENET_UMAC_CMD]

    /* Then enable TX + RX (separate write, matching U-Boot sequence) */
    ldr     w0, [x19, #GENET_UMAC_CMD]
    orr     w0, w0, #(UMAC_CMD_TX_EN | UMAC_CMD_RX_EN)
    str     w0, [x19, #GENET_UMAC_CMD]

    /* Init state indices */
    ldr     w0, [x19, #RDMA_PROD_INDEX]
    and     w0, w0, #0xFFFF
    str     w0, [x20, #GENET_STATE_RX_CIDX]
    and     w0, w0, #0xFF
    str     w0, [x20, #GENET_STATE_RX_RIDX]
    ldr     w0, [x22, #TDMA_CONS_INDEX_OFS]
    and     w0, w0, #0xFFFF
    str     w0, [x20, #GENET_STATE_TX_PIDX]
    and     w0, w0, #0xFF
    str     w0, [x20, #GENET_STATE_TX_RIDX]

    mov     w0, #0
    b       .Linit_done

.Linit_fail:
    mov     w0, #1

.Linit_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * genet_send — Send an Ethernet frame
 *
 * x0: GENET base address
 * x1: pointer to genet_state
 * x2: pointer to frame buffer
 * w3: frame length
 *
 * Returns: w0 = 0 on success, 1 on timeout
 * Clobbers: x0-x5
 */
genet_send:
    stp     x19, x20, [sp, #-48]!
    stp     x21, x22, [sp, #16]
    stp     x29, x30, [sp, #32]

    mov     x19, x0                 /* GENET base */
    mov     x20, x1                 /* state */
    mov     x21, x2                 /* buf */
    mov     w22, w3                 /* len */

    /* Flush TX buffer from D-cache to RAM.
     * Buffer may not be cache-line aligned — align start down
     * so we cover every line the buffer touches. */
    bic     x0, x21, #63            /* align down to cache line */
    add     x1, x21, x22           /* end = buf + len */
.Ltx_flush:
    dc      civac, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    .Ltx_flush
    dsb     sy

    /* Get current TX indices from state */
    ldr     w3, [x20, #GENET_STATE_TX_PIDX]
    ldr     w4, [x20, #GENET_STATE_TX_RIDX]

    /* Compute descriptor address: GENET + 0x4000 + ridx * 12 */
    add     x5, x19, #4, lsl #12
    mov     w0, #DMA_DESC_SIZE
    mul     w1, w4, w0
    add     x5, x5, x1

    /* CPU physical address (GENET DMA uses physical directly) */
    mov     w0, w21

    /* Write descriptor: addr first, length_status last */
    str     w0, [x5, #4]
    str     wzr, [x5, #8]
    lsl     w0, w22, #16
    ldr     w1, =TX_LEN_STATUS_FLAGS
    orr     w0, w0, w1
    str     w0, [x5, #0]

    /* Increment and write PROD_INDEX */
    add     w3, w3, #1
    and     w3, w3, #0xFFFF
    add     x5, x19, #5, lsl #12   /* x5 = TDMA ring base */
    str     w3, [x5, #TDMA_PROD_INDEX_OFS]

    /* Update state */
    str     w3, [x20, #GENET_STATE_TX_PIDX]
    add     w4, w4, #1
    and     w4, w4, #0xFF
    str     w4, [x20, #GENET_STATE_TX_RIDX]

    /* Poll CONS_INDEX for completion (x5 = TDMA base, preserved) */
    ldr     w4, =100000
.Ltx_wait:
    ldr     w0, [x5, #TDMA_CONS_INDEX_OFS]
    and     w0, w0, #0xFFFF
    cmp     w0, w3
    b.eq    .Ltx_ok
    subs    w4, w4, #1
    b.ne    .Ltx_wait
    mov     w0, #1
    b       .Ltx_ret
.Ltx_ok:
    mov     w0, #0
.Ltx_ret:
    ldp     x29, x30, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp], #48
    ret

/*
 * genet_recv — Receive an Ethernet frame
 *
 * x0: GENET base address
 * x1: pointer to genet_state
 * x2: pointer to destination buffer
 * w3: max buffer length
 *
 * Returns:
 *   w0 = 0 on success (frame copied), 1 if no frame available
 *   w1 = actual frame length (valid when w0 = 0)
 * Clobbers: x0-x5
 */
genet_recv:
    stp     x19, x20, [sp, #-48]!
    stp     x21, x22, [sp, #16]
    stp     x29, x30, [sp, #32]

    mov     x19, x0                 /* GENET base */
    mov     x20, x1                 /* state */
    mov     x21, x2                 /* dst buf */
    mov     w22, w3                 /* max len */

    /* Check if frame available: PROD_INDEX != our CONS_INDEX */
    ldr     w0, [x19, #RDMA_PROD_INDEX]
    and     w0, w0, #0xFFFF
    ldr     w1, [x20, #GENET_STATE_RX_CIDX]
    cmp     w0, w1
    b.eq    .Lrx_none

    /* Read descriptor */
    ldr     w2, [x20, #GENET_STATE_RX_RIDX]
    add     x3, x19, #2, lsl #12   /* RX desc base */
    mov     w0, #DMA_DESC_SIZE
    mul     w4, w2, w0
    add     x3, x3, x4

    ldr     w4, [x3, #0]           /* length_status */
    lsr     w5, w4, #16
    and     w5, w5, #0xFFF          /* raw length (includes 2-byte pad) */

    /* Compute source buffer: pool + ridx * 2048 + 2 (skip pad) */
    ldr     x0, [x20, #GENET_STATE_RX_POOL]
    lsl     w3, w2, #11
    add     x0, x0, x3
    /* Invalidate D-cache for RX buffer */
    mov     x3, x0
    mov     w4, #0
.Lrx_inv:
    dc      civac, x3
    add     x3, x3, #64
    add     w4, w4, #64
    cmp     w4, w5
    b.lt    .Lrx_inv
    dsb     sy

    add     x0, x0, #2             /* skip 2-byte RBUF pad */
    sub     w5, w5, #2             /* actual frame length */

    /* Clamp to max buffer */
    cmp     w5, w22
    csel    w5, w5, w22, lt

    /* Copy frame to caller's buffer */
    mov     x3, x21                 /* dst */
    mov     w4, #0
.Lrx_copy:
    cmp     w4, w5
    b.ge    .Lrx_copy_done
    ldrb    w6, [x0, x4]
    strb    w6, [x3, x4]
    add     w4, w4, #1
    b       .Lrx_copy
.Lrx_copy_done:

    /* Update consumer index */
    ldr     w0, [x20, #GENET_STATE_RX_CIDX]
    add     w0, w0, #1
    and     w0, w0, #0xFFFF
    str     w0, [x20, #GENET_STATE_RX_CIDX]
    str     w0, [x19, #RDMA_CONS_INDEX]

    /* Update ring index */
    ldr     w0, [x20, #GENET_STATE_RX_RIDX]
    add     w0, w0, #1
    and     w0, w0, #0xFF
    str     w0, [x20, #GENET_STATE_RX_RIDX]

    /* Return success + length */
    mov     w1, w5
    mov     w0, #0
    b       .Lrx_ret

.Lrx_none:
    mov     w0, #1
    mov     w1, #0

.Lrx_ret:
    ldp     x29, x30, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp], #48
    ret

/*
 * genet_mdio_read — Read a PHY register
 * x19: GENET base (preserved across calls in genet_init)
 * w0: register number
 * Returns: w0 = 16-bit value (0xFFFF on failure)
 */
genet_mdio_read:
    lsl     w1, w0, #MDIO_REG_SHIFT
    mov     w0, #(GENET_PHY_ADDR << MDIO_PMD_SHIFT)
    orr     w0, w0, w1
    orr     w0, w0, #MDIO_READ
    orr     w0, w0, #MDIO_START_BUSY
    str     w0, [x19, #GENET_UMAC_MDIO_CMD]

    mov     w2, #10000
1:  ldr     w0, [x19, #GENET_UMAC_MDIO_CMD]
    tbz     w0, #29, 2f
    subs    w2, w2, #1
    b.ne    1b
    mov     w0, #0xFFFF
    ret
2:  tbnz    w0, #28, 3f
    and     w0, w0, #0xFFFF
    ret
3:  mov     w0, #0xFFFF
    ret

/*
 * genet_mdio_write — Write a PHY register
 * x19: GENET base
 * w0: register number
 * w1: 16-bit value
 */
genet_mdio_write:
    lsl     w2, w0, #MDIO_REG_SHIFT
    mov     w0, #(GENET_PHY_ADDR << MDIO_PMD_SHIFT)
    orr     w0, w0, w2
    orr     w0, w0, #MDIO_WRITE
    orr     w0, w0, #MDIO_START_BUSY
    and     w1, w1, #0xFFFF
    orr     w0, w0, w1
    str     w0, [x19, #GENET_UMAC_MDIO_CMD]

    mov     w2, #10000
1:  ldr     w0, [x19, #GENET_UMAC_MDIO_CMD]
    tbz     w0, #29, 2f
    subs    w2, w2, #1
    b.ne    1b
2:  ret

/*
 * genet_set_mac — Set the MAC address
 * x0: GENET base address
 * x1: pointer to 6-byte MAC address
 */
.global genet_set_mac
genet_set_mac:
    ldrb    w2, [x1, #0]
    ldrb    w3, [x1, #1]
    orr     w2, w3, w2, lsl #8
    ldrb    w3, [x1, #2]
    orr     w2, w2, w3, lsl #16     /* wrong — need big-endian */

    /* MAC0 = [0]<<24 | [1]<<16 | [2]<<8 | [3] */
    ldrb    w2, [x1, #0]
    lsl     w2, w2, #24
    ldrb    w3, [x1, #1]
    orr     w2, w2, w3, lsl #16
    ldrb    w3, [x1, #2]
    orr     w2, w2, w3, lsl #8
    ldrb    w3, [x1, #3]
    orr     w2, w2, w3
    str     w2, [x0, #GENET_UMAC_MAC0]

    /* MAC1 = [4]<<8 | [5] */
    ldrb    w2, [x1, #4]
    lsl     w2, w2, #8
    ldrb    w3, [x1, #5]
    orr     w2, w2, w3
    str     w2, [x0, #GENET_UMAC_MAC1]
    ret
