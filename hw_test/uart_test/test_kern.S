/*
 * test_kern.S — Hardware integration test kernel
 *
 * Loaded at 0x100000 by step5 loader. Runs at EL1.
 * Links against production drivers (mailbox.S, dwc2.S).
 *
 * Current tests:
 *   - Production MMU (4 GB identity map)
 *   - UART3 output
 *   - Mailbox: TAG_GET_BOARD_REV
 *   - DWC2: USB host init + port connect
 *   - Watchdog reset
 */

.equ UART0_BASE_PI4, 0xFE201000
.equ DWC2_BASE_PI4,  0xFE980000
.equ MBOX_BASE_PI4,  0xFE00B880
.equ GENET_BASE_PI4, 0xFD580000
.equ PM_WDOG,        0xFE100024
.equ PM_RSTC,        0xFE10001C

/* GENET register offsets */
.equ GENET_SYS_REV,           0x000
.equ GENET_SYS_PORT_CTRL,     0x004
.equ GENET_SYS_RBUF_FLUSH,    0x008
.equ GENET_EXT_RGMII_OOB,     0x08C
.equ GENET_INTRL2_0_CLEAR,    0x208
.equ GENET_INTRL2_0_MASK_SET, 0x210
.equ GENET_INTRL2_1_CLEAR,    0x248
.equ GENET_INTRL2_1_MASK_SET, 0x250
.equ GENET_RBUF_CTRL,         0x300
.equ GENET_UMAC_CMD,          0x808
.equ GENET_UMAC_MAC0,         0x80C
.equ GENET_UMAC_MAC1,         0x810
.equ GENET_UMAC_MAX_FRAME,    0x814
.equ GENET_UMAC_TX_FLUSH,     0xB34
.equ GENET_UMAC_MIB_CTRL,     0xD80
.equ UMAC_MDIO_CMD,           0xE14

/* RX DMA */
.equ GENET_RX_DESC_BASE,      0x2000
.equ RDMA_WRITE_PTR,          0x3000
.equ RDMA_PROD_INDEX,         0x3008
.equ RDMA_CONS_INDEX,         0x300C
.equ RDMA_RING_BUF_SIZE,      0x3010
.equ RDMA_START_ADDR,         0x3014
.equ RDMA_END_ADDR,           0x301C
.equ RDMA_XON_XOFF_THRESH,    0x3028
.equ RDMA_READ_PTR,           0x302C
.equ RDMA_DMA_RING_CFG,       0x3040
.equ RDMA_DMA_CTRL,           0x3044
.equ RDMA_DMA_SCB_BURST_SIZE, 0x304C

/* TX DMA */
.equ GENET_TX_DESC_BASE,      0x4000
.equ TDMA_READ_PTR,           0x5000
.equ TDMA_CONS_INDEX,         0x5008
.equ TDMA_PROD_INDEX,         0x500C
.equ TDMA_RING_BUF_SIZE,      0x5010
.equ TDMA_START_ADDR,         0x5014
.equ TDMA_END_ADDR,           0x501C
.equ TDMA_MBUF_DONE_THRESH,   0x5024
.equ TDMA_FLOW_PERIOD,        0x5028
.equ TDMA_WRITE_PTR,          0x502C
.equ TDMA_DMA_RING_CFG,       0x5040
.equ TDMA_DMA_CTRL,           0x5044
.equ TDMA_DMA_SCB_BURST_SIZE, 0x504C

/* DMA constants */
.equ DMA_DESC_SIZE,       12          /* 3 words per descriptor */
.equ DMA_DESC_COUNT,      256
.equ RX_BUF_LENGTH,       2048
.equ RX_POOL_ADDR,        0x200000   /* RX buffer pool in low RAM */
.equ DMA_BUS_OFFSET,      0xC0000000 /* CPU phys → DMA bus */
.equ DMA_RING_BUF_SIZE_VAL, ((DMA_DESC_COUNT << 16) | RX_BUF_LENGTH)
.equ DMA_END_ADDR_VAL,    ((DMA_DESC_COUNT * DMA_DESC_SIZE / 4) - 1)
.equ DMA_CTRL_EN,         0x00020001 /* ring 16 enable | DMA_EN */
.equ DMA_RING_CFG_EN,     0x00010000 /* ring 16 */
.equ DMA_BURST_SIZE,      0x08
.equ RX_INIT_LEN_STATUS,  ((RX_BUF_LENGTH << 16) | 0x8000)  /* len | OWN */
.equ TX_LEN_STATUS_FLAGS, 0x7FC0     /* SOP|EOP|QTAG|APPEND_CRC */

/* UMAC_CMD bits */
.equ UMAC_CMD_TX_EN,     (1 << 0)
.equ UMAC_CMD_RX_EN,     (1 << 1)
.equ UMAC_CMD_SW_RESET,  (1 << 13)
.equ UMAC_CMD_LCL_LOOP,  (1 << 15)

/* MDIO */
.equ MDIO_START_BUSY,  (1 << 29)
.equ MDIO_READ,        (1 << 27)
.equ MDIO_WRITE,       (1 << 26)
.equ MDIO_PMD_SHIFT,   21
.equ MDIO_REG_SHIFT,   16
.equ PHY_ADDR,         1

/* PHY registers */
.equ PHY_BMCR,    0
.equ PHY_BMSR,    1
.equ PHY_AUX_STS, 0x19

/* Mailbox constants */
.equ MBOX_CH_PROP,     8
.equ MBOX_REQUEST,     0x00000000
.equ TAG_GET_BOARD_REV, 0x00010002

/* PL011 */
.equ DR,           0x000
.equ FR,           0x018
.equ IBRD,         0x024
.equ FBRD,         0x028
.equ LCRH,         0x02C
.equ CR,           0x030
.equ ICR,          0x044
.equ FR_TXFF,      0x20
.equ FR_RXFE,      0x10

/* DWC2 — just HPRT for status check */
.equ DWC2_HPRT,    0x440

.section .text._start

.global _start

_start:
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    /* EL2 → EL1 drop (needed for direct boot — firmware starts at EL2) */
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    .Lel1_ready

    mrs     x0, HCR_EL2
    orr     x0, x0, #(1 << 31)
    msr     HCR_EL2, x0
    mov     x0, #3
    msr     CNTHCTL_EL2, x0
    msr     CNTVOFF_EL2, xzr
    mov     x0, #0x33FF
    msr     CPTR_EL2, x0
    mov     x0, #0x3C5
    msr     SPSR_EL2, x0
    adr     x0, .Lel1_ready
    msr     ELR_EL2, x0
    eret

.Lel1_ready:
    /* --- Stack --- */
    ldr     x0, =_stack_top
    mov     sp, x0

    /* --- Zero BSS --- */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.ge    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    /* --- MMU setup: 4 GB identity map --- */
    mov     x0, #0xFF
    msr     MAIR_EL1, x0
    ldr     x0, =0x80803520
    msr     TCR_EL1, x0

    ldr     x0, =__mmu_l1_table
    ldr     x1, =__mmu_l2_table
    mov     x2, #0x701
    str     x2, [x0, #0]
    mov     x3, #0x40000000
    orr     x3, x3, x2
    str     x3, [x0, #8]
    mov     x3, #0x80000000
    orr     x3, x3, x2
    str     x3, [x0, #16]
    orr     x1, x1, #0x3
    str     x1, [x0, #24]

    ldr     x0, =__mmu_l2_table
    mov     x1, #0xC0000000
    mov     x2, #0x701
    mov     x3, #0x405
    mov     w4, #0
.Lfn:
    orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #480
    b.lt    .Lfn
.Lfd:
    orr     x5, x1, x3
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #512
    b.lt    .Lfd

    ldr     x0, =__mmu_l1_table
    msr     TTBR0_EL1, x0
    isb
    mrs     x0, SCTLR_EL1
    orr     x0, x0, #(1 << 0)
    orr     x0, x0, #(1 << 2)
    orr     x0, x0, #(1 << 12)
    msr     SCTLR_EL1, x0
    isb

    /* --- UART0 init (GPIO 14/15 default pin mux) --- */
    ldr     x9, =UART0_BASE_PI4
    str     wzr, [x9, #CR]
    mov     w0, #0x7FF
    str     w0, [x9, #ICR]
    mov     w0, #26
    str     w0, [x9, #IBRD]
    mov     w0, #3
    str     w0, [x9, #FBRD]
    mov     w0, #0x70
    str     w0, [x9, #LCRH]
    mov     w0, #0x301
    str     w0, [x9, #CR]

    /* ===== TEST 1: Mailbox — get board revision ===== */

    ldr     x19, =mbox_test_buf
    mov     w0, #32
    str     w0, [x19, #0]
    mov     w0, #MBOX_REQUEST
    str     w0, [x19, #4]
    ldr     w0, =TAG_GET_BOARD_REV
    str     w0, [x19, #8]
    mov     w0, #4
    str     w0, [x19, #12]
    str     wzr, [x19, #16]
    str     wzr, [x19, #20]
    str     wzr, [x19, #24]

    /* Flush buffer, call, invalidate */
    dc      civac, x19
    dsb     sy
    mov     x0, x19
    mov     w1, #MBOX_CH_PROP
    ldr     x2, =MBOX_BASE_PI4
    bl      mbox_call
    dc      civac, x19
    dsb     sy

    cbnz    w0, .Lmbox_fail

    adr     x10, msg_mbox_ok
    bl      puts
    ldr     w0, [x19, #20]
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc
    b       .Ltest_genet

.Lmbox_fail:
    adr     x10, msg_mbox_fail
    bl      puts

    /* ===== TEST 2: GENET version register read ===== */

.Ltest_genet:
    ldr     x0, =GENET_BASE_PI4
    ldr     w19, [x0, #GENET_SYS_REV]

    /* GENET v5 should have major version 6 in upper bits */
    adr     x10, msg_genet_ver
    bl      puts
    mov     w0, w19
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* ===== TEST 3: MDIO — read PHY ID ===== */

.Ltest_phy:
    ldr     x19, =GENET_BASE_PI4

    /* Read PHYSID1 (reg 2): expect 0x600D */
    mov     w0, #2                  /* register 2 */
    bl      mdio_read
    mov     w20, w0                 /* save PHYSID1 */

    /* Read PHYSID2 (reg 3): expect 0x84A2 */
    mov     w0, #3
    bl      mdio_read
    mov     w22, w0                 /* save PHYSID2 (w21 clobbered by print_hex32) */

    /* Print "PHY ID=XXXX.XXXX" */
    adr     x10, msg_phy_id
    bl      puts
    mov     w0, w20
    bl      print_hex32
    mov     w0, #'.'
    bl      putc
    mov     w0, w22
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* ===== TEST 4: UMAC reset + PHY link ===== */

.Ltest_link:
    ldr     x19, =GENET_BASE_PI4

    /* --- UMAC reset --- */

    /* Flush RBUF and TBUF */
    mov     w0, #2                  /* bit 1 */
    str     w0, [x19, #GENET_SYS_RBUF_FLUSH]
    mov     w0, #1
    str     w0, [x19, #0x00C]      /* SYS_TBUF_FLUSH_CTRL */
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    str     wzr, [x19, #GENET_SYS_RBUF_FLUSH]
    str     wzr, [x19, #0x00C]     /* clear TBUF flush */
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b

    /* UMAC SW_RESET */
    ldr     w0, [x19, #GENET_UMAC_CMD]
    orr     w0, w0, #UMAC_CMD_SW_RESET
    str     w0, [x19, #GENET_UMAC_CMD]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b

    /* Port mode: EXT_GPHY (3) — RMW to preserve other bits */
    ldr     w0, [x19, #GENET_SYS_PORT_CTRL]
    bic     w0, w0, #7              /* clear mode bits [2:0] */
    orr     w0, w0, #3              /* set EXT_GPHY */
    str     w0, [x19, #GENET_SYS_PORT_CTRL]

    /* Reset MIB counters */
    mov     w0, #7
    str     w0, [x19, #GENET_UMAC_MIB_CTRL]
    str     wzr, [x19, #GENET_UMAC_MIB_CTRL]

    /* Max frame length */
    mov     w0, #1536
    str     w0, [x19, #GENET_UMAC_MAX_FRAME]

    /* Mask all interrupts */
    mov     w0, #-1                /* 0xFFFFFFFF */
    str     w0, [x19, #GENET_INTRL2_0_MASK_SET]
    str     w0, [x19, #GENET_INTRL2_0_CLEAR]
    str     w0, [x19, #GENET_INTRL2_1_MASK_SET]
    str     w0, [x19, #GENET_INTRL2_1_CLEAR]

    adr     x10, msg_umac_ok
    bl      puts

    /* (pre-init diagnostic removed — w28 needed for tx_frame) */

    /* EXT_EXT_PWR_MGMT: leave as firmware set (PiOS = 0x051F02C3, works) */

    /* --- Configure RGMII: MODE_EN only, LINK added after speed (like Linux) --- */
    ldr     w0, [x19, #GENET_EXT_RGMII_OOB]
    bic     w0, w0, #(1 << 5)      /* clear OOB_DISABLE */
    orr     w0, w0, #(1 << 6)      /* RGMII_MODE_EN */
    /* RGMII_LINK added later, after UMAC_CMD speed is set */
    str     w0, [x19, #GENET_EXT_RGMII_OOB]

    /* --- PHY reset --- */
    mov     w0, #PHY_BMCR
    mov     w1, #0x8000             /* bit 15 = reset */
    bl      mdio_write

    /* Poll BMCR bit 15 until clear (reset complete) */
    mov     w22, #50000
.Lphy_rst_poll:
    mov     w0, #PHY_BMCR
    bl      mdio_read
    tbz     w0, #15, .Lphy_rst_done
    subs    w22, w22, #1
    b.ne    .Lphy_rst_poll
    adr     x10, msg_phy_rst_fail
    bl      puts
    b       .Ltests_done

.Lphy_rst_done:
    /* Enable auto-negotiation + restart */
    mov     w0, #PHY_BMCR
    ldr     w1, =0x1340             /* AN enable + restart AN + 1000M */
    bl      mdio_write

    adr     x10, msg_phy_an
    bl      puts

    /* Poll BMSR bit 5 for AN complete (up to ~5 seconds) */
    ldr     w22, =5000000
.Lan_poll:
    mov     w0, #PHY_BMSR
    bl      mdio_read
    tbnz    w0, #5, .Lan_done
    subs    w22, w22, #1
    b.ne    .Lan_poll
    adr     x10, msg_an_fail
    bl      puts
    b       .Ltests_done

.Lan_done:
    /* Check link (BMSR bit 2) */
    mov     w0, #PHY_BMSR
    bl      mdio_read
    tbz     w0, #2, .Lno_link

    /* Read negotiated speed from AUX_STS reg 0x19, bits [10:8] */
    mov     w0, #PHY_AUX_STS
    bl      mdio_read
    lsr     w0, w0, #8
    and     w20, w0, #7             /* speed code */

    adr     x10, msg_link_ok
    bl      puts
    mov     w0, w20
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc
    b       .Ltest_dma

.Lno_link:
    adr     x10, msg_no_link
    bl      puts
    b       .Ltests_done

    /* ===== TEST 5: DMA ring init + MAC enable ===== */

.Ltest_dma:
    ldr     x19, =GENET_BASE_PI4

    /* Compute base registers for regions with large offsets */
    add     x26, x19, #5, lsl #12  /* x26 = GENET + 0x5000 (TDMA ring 16) */
    add     x27, x19, #4, lsl #12  /* x27 = GENET + 0x4000 (TX descs) */

    /* --- Disable DMA (read-modify-write to preserve firmware bits) --- */
    /* Disable DMA: clear only DMA_EN + ring enables, preserve other bits */
    ldr     w0, [x26, #0x044]      /* TDMA_DMA_CTRL */
    ldr     w1, =0x0003FFFF        /* DMA_EN + all ring enables */
    bic     w0, w0, w1
    str     w0, [x26, #0x044]

    ldr     w0, [x19, #RDMA_DMA_CTRL]
    ldr     w1, =0x0003FFFF
    bic     w0, w0, w1
    str     w0, [x19, #RDMA_DMA_CTRL]

    /* Flush TX */
    mov     w0, #1
    str     w0, [x19, #GENET_UMAC_TX_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    str     wzr, [x19, #GENET_UMAC_TX_FLUSH]

    /* RX buffer flush — BIT(0), NOT BIT(1) (Linux dma_disable with flush_rx) */
    ldr     w0, [x19, #GENET_SYS_RBUF_FLUSH]
    orr     w0, w0, #1              /* BIT(0) = RBUF flush */
    str     w0, [x19, #GENET_SYS_RBUF_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    ldr     w0, [x19, #GENET_SYS_RBUF_FLUSH]
    bic     w0, w0, #1
    str     w0, [x19, #GENET_SYS_RBUF_FLUSH]

    /* RBUF_TBUF_SIZE_CTRL: must be 1 for TX to work */
    mov     w0, #1
    str     w0, [x19, #0x3B4]

    /* --- Set MAC address (hardcoded for testing) --- */
    /* Using DE:AD:BE:EF:CA:FE */
    ldr     w0, =0xDEADBEEF
    str     w0, [x19, #GENET_UMAC_MAC0]
    mov     w0, #0xCAFE
    str     w0, [x19, #GENET_UMAC_MAC1]

    /* --- Init RX descriptors (256 entries) --- */
    ldr     x23, =RX_POOL_ADDR
    add     x24, x19, #2, lsl #12  /* x24 = GENET + 0x2000 (RX descs) */
    mov     w25, #0

.Lrx_desc_init:
    /* Use CPU physical address directly (no bus offset) */
    mov     w0, w23

    /* Write descriptor: length_status, addr_lo, addr_hi */
    ldr     w2, =RX_INIT_LEN_STATUS
    str     w2, [x24, #0]
    str     w0, [x24, #4]
    str     wzr, [x24, #8]

    add     x23, x23, #RX_BUF_LENGTH
    add     x24, x24, #DMA_DESC_SIZE
    add     w25, w25, #1
    cmp     w25, #DMA_DESC_COUNT
    b.lt    .Lrx_desc_init

    /* --- Configure RX ring 16 (offsets from x19, all < 0x3FFC) --- */
    str     wzr, [x19, #RDMA_WRITE_PTR]
    str     wzr, [x19, #RDMA_PROD_INDEX]
    str     wzr, [x19, #RDMA_CONS_INDEX]
    ldr     w0, =DMA_RING_BUF_SIZE_VAL
    str     w0, [x19, #RDMA_RING_BUF_SIZE]
    str     wzr, [x19, #RDMA_START_ADDR]
    ldr     w0, =DMA_END_ADDR_VAL
    str     w0, [x19, #RDMA_END_ADDR]
    ldr     w0, =0x00050010
    str     w0, [x19, #RDMA_XON_XOFF_THRESH]
    str     wzr, [x19, #RDMA_READ_PTR]

    /* --- Init TX ring 16 (U-Boot simple: all 256 descs, START=0) --- */
    str     wzr, [x26, #0x000]     /* READ_PTR = 0 */
    ldr     w0, [x26, #0x008]      /* read CONS_INDEX */
    str     w0, [x26, #0x00C]      /* PROD_INDEX = CONS */
    ldr     w0, =DMA_RING_BUF_SIZE_VAL  /* (256<<16)|2048 = 0x01000800 */
    str     w0, [x26, #0x010]      /* RING_BUF_SIZE */
    str     wzr, [x26, #0x014]     /* START_ADDR = 0 */
    ldr     w0, =DMA_END_ADDR_VAL
    str     w0, [x26, #0x01C]      /* END_ADDR = 0x2FF */
    mov     w0, #1
    str     w0, [x26, #0x024]      /* MBUF_DONE_THRESH */
    str     wzr, [x26, #0x028]     /* FLOW_PERIOD */
    str     wzr, [x26, #0x02C]     /* WRITE_PTR = 0 */
    /* No arbiter, no priority — U-Boot doesn't set them */

    /* --- Enable DMA --- */
    mov     w0, #DMA_BURST_SIZE
    str     w0, [x19, #RDMA_DMA_SCB_BURST_SIZE]
    str     w0, [x26, #0x04C]      /* TDMA_DMA_SCB_BURST_SIZE */

    /* RBUF_CTRL: set RBUF_64B_EN + RBUF_ALIGN_2B (Linux init_umac) */
    ldr     w0, [x19, #GENET_RBUF_CTRL]
    orr     w0, w0, #3
    str     w0, [x19, #GENET_RBUF_CTRL]

    /* TBUF_CTRL: TBUF_64B_EN (Linux init_umac) */
    ldr     w0, [x19, #0x600]
    orr     w0, w0, #1
    str     w0, [x19, #0x600]

    /* --- Set UMAC_CMD: speed + TX_EN + RX_EN (clean write like PiOS 0x0B) --- */
    mov     w0, #0
    cmp     w20, #7
    b.eq    .Lspeed_1000
    cmp     w20, #6
    b.eq    .Lspeed_1000
    cmp     w20, #5
    b.eq    .Lspeed_100
    cmp     w20, #3
    b.eq    .Lspeed_100
    b       .Lspeed_set
.Lspeed_1000:
    orr     w0, w0, #0x08
    b       .Lspeed_set
.Lspeed_100:
    orr     w0, w0, #0x04
.Lspeed_set:
    /* --- Enable DMA FIRST (PiOS enables DMA while UMAC in SW_RESET) --- */
    mov     w25, w0                 /* save speed bits */

    ldr     w0, =DMA_RING_CFG_EN   /* ring 16 only */
    str     w0, [x19, #RDMA_DMA_RING_CFG]
    str     w0, [x26, #0x040]      /* TDMA RING_CFG: ring 16 only */

    ldr     w0, =DMA_CTRL_EN      /* ring 16 + DMA_EN = 0x00020001 */
    str     w0, [x19, #RDMA_DMA_CTRL]
    str     w0, [x26, #0x044]      /* TDMA CTRL: ring 16 + DMA_EN */

    /* --- THEN bring UMAC out of reset (like Linux mac_config after DMA) --- */
    /* RGMII_LINK */
    ldr     w0, [x19, #GENET_EXT_RGMII_OOB]
    orr     w0, w0, #(1 << 4)
    str     w0, [x19, #GENET_EXT_RGMII_OOB]

    /* UMAC_CMD: speed (clears SW_RESET) */
    mov     w0, w25
    str     w0, [x19, #GENET_UMAC_CMD]
    mov     w1, #10000
1:  subs    w1, w1, #1
    b.ne    1b

    /* UMAC_CMD: add TX_EN + RX_EN */
    orr     w0, w0, #(UMAC_CMD_TX_EN | UMAC_CMD_RX_EN)
    str     w0, [x19, #GENET_UMAC_CMD]

    /* Wait for TDMA DESC_RAM_INIT_BUSY (bit 1) to clear */
    ldr     w1, =100000
.Ltdma_init_wait:
    ldr     w0, [x26, #0x048]      /* TDMA DMA_STATUS */
    tbz     w0, #1, .Ltdma_init_done
    subs    w1, w1, #1
    b.ne    .Ltdma_init_wait
.Ltdma_init_done:

    /* --- Verify DMA enabled --- */
    ldr     w0, [x19, #RDMA_DMA_CTRL]
    tst     w0, #1
    b.eq    .Ldma_fail

    ldr     w0, [x26, #0x044]      /* TDMA_DMA_CTRL */
    tst     w0, #1
    b.eq    .Ldma_fail

    adr     x10, msg_dma_ok
    bl      puts
    b       .Ltest_rx

.Ldma_fail:
    adr     x10, msg_dma_fail
    bl      puts
    b       .Ltests_done

    /* ===== TEST 6: Receive + dump frames (up to 10) ===== */

.Ltest_rx:
    ldr     x19, =GENET_BASE_PI4

    /* Read initial PROD_INDEX */
    ldr     w22, [x19, #RDMA_PROD_INDEX]
    and     w22, w22, #0xFFFF       /* c_index */
    and     w23, w22, #0xFF         /* rx_index */

    adr     x10, msg_rx_wait
    bl      puts

    mov     w27, #0                 /* frame counter */

.Lrx_next:
    /* Poll for a frame (up to ~3 seconds per frame) */
    ldr     w24, =3000000
.Lrx_poll:
    ldr     w0, [x19, #RDMA_PROD_INDEX]
    and     w0, w0, #0xFFFF
    cmp     w0, w22
    b.ne    .Lrx_got_frame
    subs    w24, w24, #1
    b.ne    .Lrx_poll

    /* Timeout — print count and continue to TX test */
    adr     x10, msg_rx_count
    bl      puts
    mov     w0, w27
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc
    b       .Ltest_tx

.Lrx_got_frame:
    /* Read descriptor */
    add     x24, x19, #2, lsl #12
    mov     w0, #DMA_DESC_SIZE
    mul     w1, w23, w0
    add     x24, x24, x1

    ldr     w25, [x24, #0]         /* length_status */
    lsr     w20, w25, #16
    and     w20, w20, #0xFFF       /* raw length (includes 2-byte pad) */

    /* Compute CPU buffer address */
    ldr     x0, =RX_POOL_ADDR
    lsl     w1, w23, #11
    add     x28, x0, x1

    /* Invalidate D-cache */
    mov     x0, x28
    mov     w1, #0
.Lrx_inval:
    dc      civac, x0
    add     x0, x0, #64
    add     w1, w1, #64
    cmp     w1, w20
    b.lt    .Lrx_inval
    dsb     sy

    /* Check ethertype at buffer+14,+15 (after 2-byte pad + 12-byte MACs)
     * ARP = 0x08 0x06 in network order */
    ldrb    w0, [x28, #14]
    cmp     w0, #0x08
    b.ne    .Lrx_skip
    ldrb    w0, [x28, #15]
    cmp     w0, #0x06
    b.ne    .Lrx_skip

    /* === ARP frame — print it === */
    sub     w20, w20, #2            /* actual frame length */
    add     x28, x28, #2           /* skip RBUF pad */

    /* Print "ARP len=XXXX" */
    adr     x10, msg_arp
    bl      puts
    mov     w0, w20
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* Print first 42 bytes (full ARP frame: 14 ETH + 28 ARP) */
    mov     w25, #0
    mov     w26, #42
    cmp     w20, #42
    csel    w26, w20, w26, lt
.Lrx_dump:
    cmp     w25, w26
    b.ge    .Lrx_dump_done
    ldrb    w0, [x28, x25]
    bl      print_hex8
    mov     w0, #' '
    bl      putc
    add     w25, w25, #1
    b       .Lrx_dump

.Lrx_dump_done:
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* Count ARP frame */
    add     w27, w27, #1
    b       .Lrx_consume

.Lrx_skip:
    /* Print '.' for non-ARP */
    mov     w0, #'.'
    bl      putc

.Lrx_consume:
    /* Update consumer index */
    add     w22, w22, #1
    and     w22, w22, #0xFFFF
    str     w22, [x19, #RDMA_CONS_INDEX]
    add     w23, w23, #1
    and     w23, w23, #0xFF

    /* Stop after 5 ARP frames or keep going */
    cmp     w27, #5
    b.lt    .Lrx_next

    /* ===== TEST 7: TX — send a broadcast ARP request ===== */

.Ltest_tx:
    ldr     x19, =GENET_BASE_PI4
    add     x26, x19, #5, lsl #12  /* x26 = GENET + 0x5000 (TDMA ring 16) */

    /* Build ARP request at 0x200000 (RX pool area — known DMA-accessible) */
    ldr     x28, =0x200000

    /* Ethernet header: dst=broadcast, src=DE:AD:BE:EF:CA:FE, type=0x0806 (ARP) */
    mov     w0, #-1                 /* 0xFFFFFFFF */
    str     w0, [x28, #0]          /* dst[0:3] = FF:FF:FF:FF */
    strh    w0, [x28, #4]          /* dst[4:5] = FF:FF */
    ldr     w0, =0xDEADBEEF
    str     w0, [x28, #6]          /* src[0:3] */
    mov     w0, #0xCAFE
    strh    w0, [x28, #10]         /* src[4:5] */
    mov     w0, #0x0608             /* 0x0806 byte-swapped (little-endian store) */
    strh    w0, [x28, #12]         /* ethertype = ARP */

    /* ARP payload: request for 10.0.0.1 from 10.0.0.2 */
    mov     w0, #0x0100             /* htype = 1 (Ethernet), byte-swapped */
    strh    w0, [x28, #14]
    mov     w0, #0x0008             /* ptype = 0x0800 (IPv4), byte-swapped */
    strh    w0, [x28, #16]
    mov     w0, #0x0406             /* hlen=6, plen=4 */
    strh    w0, [x28, #18]
    mov     w0, #0x0100             /* oper = 1 (request), byte-swapped */
    strh    w0, [x28, #20]

    /* Sender hardware addr: DE:AD:BE:EF:CA:FE */
    ldr     w0, =0xDEADBEEF
    str     w0, [x28, #22]
    mov     w0, #0xCAFE
    strh    w0, [x28, #26]

    /* Sender protocol addr: 10.0.0.2 = 0x0A000002 */
    mov     w0, #0x000A             /* 10.0 byte-swapped in first halfword */
    strh    w0, [x28, #28]
    mov     w0, #0x0200             /* 0.2 byte-swapped */
    strh    w0, [x28, #30]

    /* Target hardware addr: 00:00:00:00:00:00 */
    str     wzr, [x28, #32]
    strh    wzr, [x28, #36]

    /* Target protocol addr: 10.0.0.1 = 0x0A000001 */
    mov     w0, #0x000A
    strh    w0, [x28, #38]
    mov     w0, #0x0100             /* 0.1 byte-swapped */
    strh    w0, [x28, #40]

    /* Frame total: 14 (eth) + 28 (arp) = 42 bytes */
    mov     w20, #42                /* frame length */

    /* Flush TX buffer from D-cache to RAM */
    bic     x0, x28, #63
    add     x1, x28, x20
.Ltx_flush:
    dc      civac, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    .Ltx_flush
    dsb     sy

    /* Read current TDMA_PROD_INDEX */
    ldr     w22, [x26, #0x00C]     /* TDMA_PROD_INDEX */

    /* Descriptor at index (PROD & 0xFF) — all 256 descs for ring 16 */
    and     w23, w22, #0xFF
    add     x24, x19, #4, lsl #12  /* x24 = GENET + 0x4000 (TX descs) */
    mov     w0, #DMA_DESC_SIZE
    mul     w1, w23, w0
    add     x24, x24, x1

    mov     w0, w28

    /* Write descriptor: addr first, length_status last */
    str     w0, [x24, #4]          /* addr_lo */
    str     wzr, [x24, #8]         /* addr_hi */

    /* length_status: (length << 16) | TX_LEN_STATUS_FLAGS */
    lsl     w0, w20, #16
    ldr     w1, =TX_LEN_STATUS_FLAGS
    orr     w0, w0, w1
    str     w0, [x24, #0]          /* length_status — triggers HW */

    /* Increment and write PROD_INDEX */
    add     w22, w22, #1
    and     w22, w22, #0xFFFF
    str     w22, [x26, #0x00C]     /* TDMA_PROD_INDEX — kicks DMA */

    /* Poll TDMA_CONS_INDEX until it catches up (TX complete) */
    ldr     w24, =100000
.Ltx_poll:
    ldr     w0, [x26, #0x008]     /* TDMA_CONS_INDEX */
    and     w0, w0, #0xFFFF
    cmp     w0, w22
    b.eq    .Ltx_done
    subs    w24, w24, #1
    b.ne    .Ltx_poll

    adr     x10, msg_tx_fail
    bl      puts
    b       .Ltests_done

.Ltx_done:
    adr     x10, msg_tx_ok
    bl      puts

    /* LOOPBACK CHECK: did the TX frame appear on RX? */
    ldr     x19, =GENET_BASE_PI4
    mov     w0, #'L'
    bl      putc

    /* Wait briefly for loopback frame to arrive */
    ldr     w0, =1000000
1:  subs    w0, w0, #1
    b.ne    1b

    /* Check if RX PROD_INDEX advanced (new frame received via loopback) */
    ldr     w0, [x19, #RDMA_PROD_INDEX]
    and     w0, w0, #0xFFFF
    bl      print_hex32
    mov     w0, #' '
    bl      putc

    /* Read UMAC MIB counters to verify actual TX/RX at MAC level */

    adr     x10, msg_txpkt
    bl      puts
    ldr     w0, [x19, #0xA2C]
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    adr     x10, msg_rxpkt
    bl      puts
    ldr     w0, [x19, #0xC2C]
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* Dump TDMA state */
    add     x26, x19, #5, lsl #12

    adr     x10, msg_umac_cmd
    bl      puts
    ldr     w0, [x19, #0x808]
    bl      print_hex32

    /* TDMA DMA_STATUS */
    adr     x10, msg_dma_stat
    bl      puts
    ldr     w0, [x26, #0x048]
    bl      print_hex32

    /* TDMA CONS/PROD after TX */
    adr     x10, msg_cons
    bl      puts
    ldr     w0, [x26, #0x008]
    bl      print_hex32

    adr     x10, msg_prod
    bl      puts
    ldr     w0, [x26, #0x00C]
    bl      print_hex32

    /* TX descriptor at ring 16 position (desc 128 = byte offset 1536) */
    adr     x10, msg_txdesc
    bl      puts
    add     x0, x19, #4, lsl #12
    add     x0, x0, #(128 * 12)    /* skip to descriptor 128 */
    ldr     w1, [x0, #0]
    mov     w0, w1
    bl      print_hex32
    mov     w0, #' '
    bl      putc
    add     x0, x19, #4, lsl #12
    add     x0, x0, #(128 * 12)
    ldr     w1, [x0, #4]
    mov     w0, w1
    bl      print_hex32

    /* Critical diagnostics from analysis report */

    /* EXT_EXT_PWR_MGMT (+0x080) — check for PHY TX power-down */
    /* Pre-init TDMA DMA_CTRL value */
    /* Current TDMA_CTRL (should match PiOS 0x0002001F) */
    adr     x10, msg_prectrl
    bl      puts
    ldr     w0, [x26, #0x044]
    bl      print_hex32

    adr     x10, msg_pwr
    bl      puts
    ldr     w0, [x19, #0x080]
    bl      print_hex32

    /* UMAC_TX_FIFO_STATUS (+0xB3C) — is data entering the FIFO? */
    adr     x10, msg_txfifo
    bl      puts
    ldr     w0, [x19, #0xB3C]
    bl      print_hex32

    /* RBUF_TBUF_SIZE_CTRL (+0x3B4) — verify TBUF allocation */
    adr     x10, msg_tbsz
    bl      puts
    ldr     w0, [x19, #0x3B4]
    bl      print_hex32

    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

.Ltests_done:
    adr     x10, msg_done
    bl      puts

    /* Drain TX */
.Ldrain:
    ldr     w0, [x9, #FR]
    tst     w0, #0x08
    b.ne    .Ldrain

    /* Wait for reset byte */
.Lwait_cmd:
    ldr     w0, [x9, #FR]
    tst     w0, #FR_RXFE
    b.ne    .Lwait_cmd

    /* Watchdog reset */
    ldr     x0, =PM_WDOG
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x000A
    str     w1, [x0]
    ldr     x0, =PM_RSTC
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x0020
    str     w1, [x0]
.Lwait_reset:
    wfe
    b       .Lwait_reset

/* ===== UART helpers ===== */

putc:
1:  ldr     w1, [x9, #FR]
    tst     w1, #FR_TXFF
    b.ne    1b
    str     w0, [x9, #DR]
    ret

puts:
    stp     x30, xzr, [sp, #-16]!
.Lps:
    ldrb    w0, [x10], #1
    cbz     w0, .Lpsd
    bl      putc
    b       .Lps
.Lpsd:
    ldp     x30, xzr, [sp], #16
    ret

print_hex32:
    stp     x30, x20, [sp, #-16]!
    mov     w20, w0
    mov     w21, #28
.Lph:
    lsr     w0, w20, w21
    and     w0, w0, #0xF
    cmp     w0, #10
    b.lt    1f
    add     w0, w0, #('A' - 10)
    b       2f
1:  add     w0, w0, #'0'
2:  bl      putc
    cbz     w21, .Lphd
    sub     w21, w21, #4
    b       .Lph
.Lphd:
    ldp     x30, x20, [sp], #16
    ret

/* print_hex8: print w0 low byte as 2-digit hex */
print_hex8:
    stp     x30, x20, [sp, #-16]!
    and     w20, w0, #0xFF
    lsr     w0, w20, #4
    bl      .Lnibble
    and     w0, w20, #0xF
    bl      .Lnibble
    ldp     x30, x20, [sp], #16
    ret
.Lnibble:
    cmp     w0, #10
    b.lt    1f
    add     w0, w0, #('A' - 10)
    b       putc
1:  add     w0, w0, #'0'
    b       putc

/*
 * mdio_write — Write a PHY register via UMAC MDIO
 * x19: GENET base address
 * w0: register number
 * w1: 16-bit value to write
 */
mdio_write:
    stp     x30, xzr, [sp, #-16]!

    lsl     w2, w0, #MDIO_REG_SHIFT
    mov     w0, #(PHY_ADDR << MDIO_PMD_SHIFT)
    orr     w0, w0, w2
    orr     w0, w0, #MDIO_WRITE
    orr     w0, w0, #MDIO_START_BUSY
    and     w1, w1, #0xFFFF
    orr     w0, w0, w1
    str     w0, [x19, #UMAC_MDIO_CMD]

    mov     w2, #10000
.Lmw_poll:
    ldr     w0, [x19, #UMAC_MDIO_CMD]
    tbz     w0, #29, .Lmw_done
    subs    w2, w2, #1
    b.ne    .Lmw_poll
.Lmw_done:
    ldp     x30, xzr, [sp], #16
    ret

/*
 * mdio_read — Read a PHY register via UMAC MDIO
 * x19: GENET base address
 * w0: register number
 * Returns: w0 = 16-bit register value (or 0xFFFF on timeout)
 */
mdio_read:
    stp     x30, xzr, [sp, #-16]!

    /* Build MDIO command: START_BUSY | READ | (PHY_ADDR << 21) | (reg << 16) */
    lsl     w1, w0, #MDIO_REG_SHIFT
    mov     w0, #(PHY_ADDR << MDIO_PMD_SHIFT)
    orr     w0, w0, w1
    orr     w0, w0, #MDIO_READ
    orr     w0, w0, #MDIO_START_BUSY
    str     w0, [x19, #UMAC_MDIO_CMD]

    /* Poll until START_BUSY clears */
    mov     w2, #10000
.Lmdio_poll:
    ldr     w0, [x19, #UMAC_MDIO_CMD]
    tbz     w0, #29, .Lmdio_done
    subs    w2, w2, #1
    b.ne    .Lmdio_poll
    /* Timeout */
    mov     w0, #0xFFFF
    b       .Lmdio_ret

.Lmdio_done:
    /* Check read-fail bit (28) */
    tbnz    w0, #28, .Lmdio_fail
    and     w0, w0, #0xFFFF         /* result in bits [15:0] */
    b       .Lmdio_ret

.Lmdio_fail:
    mov     w0, #0xFFFF

.Lmdio_ret:
    ldp     x30, xzr, [sp], #16
    ret

.Lpark:
    wfe
    b       .Lpark

/* ===== Data ===== */

.section .rodata
msg_mbox_ok:    .asciz "MBOX OK rev="
msg_mbox_fail:  .asciz "MBOX FAIL\r\n"
msg_genet_ver:  .asciz "GENET ver="
msg_phy_id:     .asciz "PHY ID="
msg_umac_ok:    .asciz "UMAC RESET OK\r\n"
msg_phy_rst_fail: .asciz "PHY RESET FAIL\r\n"
msg_phy_an:     .asciz "PHY AN started\r\n"
msg_an_fail:    .asciz "AN TIMEOUT\r\n"
msg_link_ok:    .asciz "LINK UP speed="
msg_no_link:    .asciz "NO LINK\r\n"
msg_dma_ok:     .asciz "DMA INIT OK\r\n"
msg_dma_fail:   .asciz "DMA INIT FAIL\r\n"
msg_rx_wait:    .asciz "RX waiting...\r\n"
msg_rx_count:   .asciz "ARP frames="
msg_arp:        .asciz "ARP len="
msg_tx_ok:      .asciz "TX OK\r\n"
msg_tx_fail:    .asciz "TX TIMEOUT\r\n"
msg_txpkt:      .asciz "TX_GD_PKTS="
msg_rxpkt:      .asciz "RX_GD_PKTS="
msg_umac_cmd:   .asciz " CMD="
msg_dma_stat:   .asciz " STAT="
msg_cons:       .asciz " C="
msg_prod:       .asciz " P="
msg_txdesc:     .asciz "\r\nDESC="
msg_fake:       .asciz "FAKE_CONS="
msg_prectrl:    .asciz "\r\nTDMA_CTRL="
msg_pwr:        .asciz "\r\nPWR="
msg_txfifo:     .asciz " TXFIFO="
msg_tbsz:       .asciz " TBSZ="
msg_done:       .asciz "DONE\r\n"

.section .data
.balign 16
mbox_test_buf:
    .space 32

.balign 64
tx_frame:
    .space 64
