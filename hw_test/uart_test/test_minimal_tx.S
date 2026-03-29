/*
 * test_minimal_tx.S — Minimal GENET TX test
 *
 * Follows U-Boot's EXACT init sequence with nothing extra.
 * Loaded at 0x100000 by chainloader.
 */

.equ UART0_BASE, 0xFE201000
.equ GENET_BASE, 0xFD580000
.equ PM_WDOG,    0xFE100024
.equ PM_RSTC,    0xFE10001C

/* PL011 */
.equ DR,    0x000
.equ FR,    0x018
.equ FR_TXFF, 0x20
.equ FR_RXFE, 0x10

/* GENET offsets */
.equ SYS_PORT_CTRL,    0x004
.equ SYS_RBUF_FLUSH,   0x008
.equ RBUF_CTRL,         0x300
.equ RBUF_TBUF_SIZE,    0x3B4
.equ TBUF_CTRL,         0x600
.equ UMAC_CMD,           0x808
.equ UMAC_MAC0,          0x80C
.equ UMAC_MAC1,          0x810
.equ UMAC_MAX_FRAME,     0x814
.equ UMAC_MIB_CTRL,      0xD80
.equ UMAC_TX_FLUSH,      0xB34
.equ MDIO_CMD,           0xE14
.equ EXT_RGMII_OOB,      0x08C
.equ INTRL2_0_MASK_SET,  0x210
.equ INTRL2_0_CLEAR,     0x208
.equ INTRL2_1_MASK_SET,  0x250
.equ INTRL2_1_CLEAR,     0x248

/* TDMA ring 16 regs at GENET+0x5000 */
/* TDMA global regs at GENET+0x5040 */
.equ TX_DESC_BASE, 0x4000
.equ RDMA_RING_CFG, 0x3040
.equ RDMA_DMA_CTRL,  0x3044
.equ RDMA_BURST,     0x304C

.section .text._start
.global _start

_start:
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    .Lel1

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
    adr     x0, .Lel1
    msr     ELR_EL2, x0
    eret

.Lel1:
    ldr     x0, =_stack_top
    mov     sp, x0

    /* Zero BSS */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.ge    2f
    str     xzr, [x0], #8
    b       1b
2:

    /* MMU: 4GB identity map */
    mov     x0, #0xFF
    msr     MAIR_EL1, x0
    ldr     x0, =0x80803520
    msr     TCR_EL1, x0

    ldr     x0, =__mmu_l1_table
    ldr     x1, =__mmu_l2_table
    mov     x2, #0x701          /* Normal WB-WA, Inner Shareable, AF */
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
    mov     x3, #0x405          /* Device-nGnRnE */
    mov     w4, #0
.Lfn:
    orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #480            /* 0xFC000000 boundary */
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

    /* UART0 init */
    ldr     x9, =UART0_BASE
    str     wzr, [x9, #0x030]
    mov     w0, #0x7FF
    str     w0, [x9, #0x044]
    mov     w0, #26
    str     w0, [x9, #0x024]
    mov     w0, #3
    str     w0, [x9, #0x028]
    mov     w0, #0x70
    str     w0, [x9, #0x02C]
    mov     w0, #0x301
    str     w0, [x9, #0x030]

    /* Print WAIT, wait for 0xFF */
    adr     x10, msg_wait
    bl      puts
.Lwait:
    ldr     w0, [x9, #FR]
    tst     w0, #FR_RXFE
    b.ne    .Lwait
    ldr     w0, [x9, #DR]
    and     w0, w0, #0xFF
    cmp     w0, #0xFF
    b.ne    .Lwait

    ldr     x19, =GENET_BASE
    add     x26, x19, #5, lsl #12  /* ring 16 per-ring = GENET+0x5000 */

    /* ======== U-Boot bcmgenet_gmac_probe ======== */
    /* bcmgenet_interface_set: PORT_CTRL = 3 */
    mov     w0, #3
    str     w0, [x19, #SYS_PORT_CTRL]

    str     wzr, [x19, #SYS_RBUF_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b

    str     wzr, [x19, #UMAC_CMD]
    ldr     w0, =0xA000         /* SW_RESET | LCL_LOOP_EN */
    str     w0, [x19, #UMAC_CMD]
    /* probe leaves UMAC in reset */

    /* PHY init (minimal — just wait for existing link) */
    /* Skip full PHY reset for speed — link should be up from previous run */

    /* ======== U-Boot bcmgenet_gmac_eth_start ======== */

    /* 1. bcmgenet_umac_reset */
    ldr     w0, [x19, #SYS_RBUF_FLUSH]
    orr     w0, w0, #2
    str     w0, [x19, #SYS_RBUF_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    ldr     w0, [x19, #SYS_RBUF_FLUSH]
    bic     w0, w0, #2
    str     w0, [x19, #SYS_RBUF_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    str     wzr, [x19, #SYS_RBUF_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b

    str     wzr, [x19, #UMAC_CMD]
    ldr     w0, =0xA000
    str     w0, [x19, #UMAC_CMD]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    str     wzr, [x19, #UMAC_CMD]

    /* MIB reset */
    mov     w0, #7
    str     w0, [x19, #UMAC_MIB_CTRL]
    str     wzr, [x19, #UMAC_MIB_CTRL]

    /* Max frame */
    mov     w0, #1536
    str     w0, [x19, #UMAC_MAX_FRAME]

    /* RBUF_CTRL: RMW set ALIGN_2B */
    ldr     w0, [x19, #RBUF_CTRL]
    orr     w0, w0, #2
    str     w0, [x19, #RBUF_CTRL]

    /* RBUF_TBUF_SIZE = 1 */
    mov     w0, #1
    str     w0, [x19, #RBUF_TBUF_SIZE]

    adr     x10, msg_reset_ok
    bl      puts

    /* 2. MAC address */
    ldr     w0, =0xDEADBEEF
    str     w0, [x19, #UMAC_MAC0]
    mov     w0, #0xCAFE
    str     w0, [x19, #UMAC_MAC1]

    /* 3. bcmgenet_disable_dma */
    ldr     w0, [x26, #0x044]      /* TDMA_DMA_CTRL */
    bic     w0, w0, #1
    str     w0, [x26, #0x044]
    ldr     w0, [x19, #RDMA_DMA_CTRL]
    bic     w0, w0, #1
    str     w0, [x19, #RDMA_DMA_CTRL]

    /* TX_FLUSH */
    mov     w0, #1
    str     w0, [x19, #UMAC_TX_FLUSH]
    mov     w0, #10000
1:  subs    w0, w0, #1
    b.ne    1b
    str     wzr, [x19, #UMAC_TX_FLUSH]

    /* 4. TX ring 16 init (U-Boot bcmgenet_tdma_ring_init) */
    mov     w0, #8
    str     w0, [x26, #0x04C]      /* SCB_BURST = 8 */

    str     wzr, [x26, #0x014]     /* START_ADDR = 0 */
    str     wzr, [x26, #0x000]     /* READ_PTR = 0 */
    str     wzr, [x26, #0x02C]     /* WRITE_PTR = 0 */
    ldr     w0, =0x2FF
    str     w0, [x26, #0x01C]      /* END_ADDR */

    ldr     w0, [x26, #0x008]      /* read CONS_INDEX */
    str     w0, [x26, #0x00C]      /* PROD_INDEX = CONS */

    mov     w0, #1
    str     w0, [x26, #0x024]      /* MBUF_DONE_THRESH = 1 */
    str     wzr, [x26, #0x028]     /* FLOW_PERIOD = 0 */

    ldr     w0, =0x01000800        /* (256<<16)|2048 */
    str     w0, [x26, #0x010]      /* RING_BUF_SIZE */

    ldr     w0, =0x00010000        /* ring 16 */
    str     w0, [x26, #0x040]      /* RING_CFG */

    /* 5. bcmgenet_enable_dma */
    ldr     w0, =0x00020001        /* ring 16 buf + DMA_EN */
    str     w0, [x26, #0x044]      /* TDMA_DMA_CTRL */

    /* Also enable RDMA (for RX) */
    mov     w0, #8
    str     w0, [x19, #RDMA_BURST]
    ldr     w0, =0x00010000
    str     w0, [x19, #RDMA_RING_CFG]
    ldr     w0, =0x00020001
    str     w0, [x19, #RDMA_DMA_CTRL]

    /* 6. PHY reset + auto-negotiation */
    /* Reset PHY */
    mov     w0, #0                  /* BMCR */
    mov     w1, #0x8000             /* reset */
    bl      mdio_write
    ldr     w1, =50000
1:  mov     w0, #0
    bl      mdio_read
    tbz     w0, #15, 2f
    subs    w1, w1, #1
    b.ne    1b
2:
    /* Start auto-negotiation */
    mov     w0, #0
    ldr     w1, =0x1340             /* AN enable + restart + 1000M */
    bl      mdio_write

    adr     x10, msg_an
    bl      puts

    /* Poll BMSR bit 5 (AN complete) — up to ~5s */
    ldr     w1, =5000000
3:  mov     w0, #1
    bl      mdio_read
    tbnz    w0, #5, 4f
    subs    w1, w1, #1
    b.ne    3b
    adr     x10, msg_no_link
    bl      puts
    b       .Ldone
4:
    /* Check link */
    mov     w0, #1
    bl      mdio_read
    tbz     w0, #2, .Lno_link

    adr     x10, msg_link
    bl      puts

    /* 7. bcmgenet_adjust_link */
    /* EXT_RGMII_OOB: clear OOB_DISABLE, set LINK + MODE_EN + ID_MODE_DIS */
    ldr     w0, [x19, #EXT_RGMII_OOB]
    bic     w0, w0, #(1 << 5)
    orr     w0, w0, #(1 << 4)      /* LINK */
    orr     w0, w0, #(1 << 6)      /* MODE_EN */
    orr     w0, w0, #(1 << 16)     /* ID_MODE_DIS */
    str     w0, [x19, #EXT_RGMII_OOB]

    /* UMAC_CMD = speed (1000M = 0x08) — direct write clears all */
    mov     w0, #0x08
    str     w0, [x19, #UMAC_CMD]

    /* 8. UMAC_CMD |= TX_EN | RX_EN */
    mov     w0, #0x0B              /* 0x08 | TX_EN | RX_EN */
    str     w0, [x19, #UMAC_CMD]

    adr     x10, msg_enabled
    bl      puts

    /* === Wait 2 seconds for DMA to settle === */
    ldr     w0, =20000000
1:  subs    w0, w0, #1
    b.ne    1b

    /* === BUILD AND SEND TX FRAME === */
    ldr     x28, =0x300000

    /* Broadcast ARP: who-has 10.0.0.1 tell 10.0.0.2 */
    mov     w0, #-1
    str     w0, [x28, #0]
    strh    w0, [x28, #4]
    ldr     w0, =0xDEADBEEF
    str     w0, [x28, #6]
    mov     w0, #0xCAFE
    strh    w0, [x28, #10]
    mov     w0, #0x0608
    strh    w0, [x28, #12]
    mov     w0, #0x0100
    strh    w0, [x28, #14]
    mov     w0, #0x0008
    strh    w0, [x28, #16]
    mov     w0, #0x0406
    strh    w0, [x28, #18]
    mov     w0, #0x0100
    strh    w0, [x28, #20]
    ldr     w0, =0xDEADBEEF
    str     w0, [x28, #22]
    mov     w0, #0xCAFE
    strh    w0, [x28, #26]
    mov     w0, #0x000A
    strh    w0, [x28, #28]
    mov     w0, #0x0200
    strh    w0, [x28, #30]
    str     wzr, [x28, #32]
    strh    wzr, [x28, #36]
    mov     w0, #0x000A
    strh    w0, [x28, #38]
    mov     w0, #0x0100
    strh    w0, [x28, #40]
    /* Pad to 64 bytes */
    str     xzr, [x28, #48]
    str     xzr, [x28, #56]
    mov     w0, #0x0100
    strh    w0, [x28, #40]

    /* Flush cache */
    mov     x0, x28
    dc      civac, x0
    add     x0, x0, #64
    dc      civac, x0
    dsb     sy

    /* Write descriptor at current PROD index */
    ldr     w22, [x26, #0x00C]     /* PROD_INDEX */
    and     w23, w22, #0xFF
    add     x24, x19, #4, lsl #12  /* TX desc base */
    mov     w0, #12
    mul     w1, w23, w0
    add     x24, x24, x1

    /* addr_lo, addr_hi, length_status */
    mov     w0, w28
    str     w0, [x24, #4]
    str     wzr, [x24, #8]
    mov     w0, #(64 << 16)
    ldr     w1, =0x7FC0            /* SOP|EOP|QTAG|APPEND_CRC */
    orr     w0, w0, w1
    str     w0, [x24, #0]
    dsb     sy

    /* Kick PROD */
    add     w22, w22, #1
    and     w22, w22, #0xFFFF
    str     w22, [x26, #0x00C]

    /* Poll CONS */
    ldr     w24, =1000000
.Ltx_poll:
    ldr     w0, [x26, #0x008]
    and     w0, w0, #0xFFFF
    cmp     w0, w22
    b.eq    .Ltx_ok
    subs    w24, w24, #1
    b.ne    .Ltx_poll
    adr     x10, msg_tx_timeout
    bl      puts
    b       .Ldone
.Ltx_ok:
    adr     x10, msg_tx_ok
    bl      puts

    /* Check MIB: TX_GOOD_PKTS candidates */
    adr     x10, msg_mib
    bl      puts
    /* Read a range of offsets where TX counters might be */
    ldr     w0, [x19, #0xC4C]      /* possible tx_pkts */
    bl      print_hex32
    mov     w0, #' '
    bl      putc
    ldr     w0, [x19, #0xC54]      /* possible tx_good_pkts */
    bl      print_hex32
    mov     w0, #' '
    bl      putc
    ldr     w0, [x19, #0xC28]      /* possible tx_underrun or rx */
    bl      print_hex32
    mov     w0, #' '
    bl      putc
    ldr     w0, [x19, #0xB3C]      /* TX_FIFO_STATUS */
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    b       .Ldone

.Lno_link:
    adr     x10, msg_no_link
    bl      puts

.Ldone:
    adr     x10, msg_done
    bl      puts

    /* Drain UART */
1:  ldr     w0, [x9, #FR]
    tst     w0, #0x08
    b.ne    1b

    /* Wait for reset byte */
2:  ldr     w0, [x9, #FR]
    tst     w0, #FR_RXFE
    b.ne    2b
    ldr     w0, [x9, #DR]

    /* Watchdog reset */
    ldr     x0, =PM_WDOG
    ldr     w1, =0x5A000020
    str     w1, [x0]
    ldr     x0, =PM_RSTC
    ldr     w1, =0x5A000020
    str     w1, [x0]
3:  wfe
    b       3b

/* === MDIO === */
mdio_read:
    /* w0 = reg number, returns w0 = value */
    ldr     w1, =(1 << 29) | (1 << 27) | (1 << 21) /* START|READ|PHY1 */
    orr     w1, w1, w0, lsl #16
    str     w1, [x19, #MDIO_CMD]
1:  ldr     w0, [x19, #MDIO_CMD]
    tbnz    w0, #29, 1b
    and     w0, w0, #0xFFFF
    ret

mdio_write:
    /* w0 = reg, w1 = value */
    ldr     w2, =(1 << 29) | (1 << 26) | (1 << 21) /* START|WRITE|PHY1 */
    orr     w2, w2, w0, lsl #16
    orr     w2, w2, w1
    str     w2, [x19, #MDIO_CMD]
1:  ldr     w0, [x19, #MDIO_CMD]
    tbnz    w0, #29, 1b
    ret

/* === UART helpers === */
putc:
1:  ldr     w1, [x9, #FR]
    tst     w1, #FR_TXFF
    b.ne    1b
    str     w0, [x9, #DR]
    ret

puts:
    stp     x30, xzr, [sp, #-16]!
1:  ldrb    w0, [x10], #1
    cbz     w0, 2f
    bl      putc
    b       1b
2:  ldp     x30, xzr, [sp], #16
    ret

print_hex32:
    stp     x30, x20, [sp, #-16]!
    stp     x21, xzr, [sp, #-16]!
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
    cbz     w21, 3f
    sub     w21, w21, #4
    b       .Lph
3:  ldp     x21, xzr, [sp], #16
    ldp     x30, x20, [sp], #16
    ret

.Lpark:
    wfe
    b       .Lpark

msg_wait:       .asciz "WAIT\r\n"
msg_reset_ok:   .asciz "RST OK\r\n"
msg_an:         .asciz "AN...\r\n"
msg_link:       .asciz "LINK UP\r\n"
msg_enabled:    .asciz "MAC ON\r\n"
msg_tx_ok:      .asciz "TX OK\r\n"
msg_tx_timeout: .asciz "TX TIMEOUT\r\n"
msg_no_link:    .asciz "NO LINK\r\n"
msg_mib:        .asciz "MIB: "
msg_done:       .asciz "DONE\r\n"
