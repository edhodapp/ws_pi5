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
.include "net.inc"
.include "mailbox.inc"
.include "perf.inc"

.global genet_init
.global genet_send
.global genet_recv
.global genet_rx_drop_bookkeeping
.ifdef PLATFORM_PI4
.global genet_dump_state
.endif

.section .text

.ifdef PLATFORM_PI4
/*
 * genet_dump_state — Snapshot GENET hardware + driver state
 *
 * Writes a 64-byte register/state snapshot to a caller-provided
 * buffer. Layout (little-endian, host order, u32 per field):
 *
 *     off  name
 *     0    umac_cmd
 *     4    umac_tx_fifo_status
 *     8    umac_rx_fifo_status
 *     12   (reserved — zero)
 *     16   rdma_prod_index    (full 32-bit; upper 16 = discard count)
 *     20   rdma_cons_index
 *     24   rdma_dma_ctrl
 *     28   rdma_xon_xoff_thresh
 *     32   tdma_prod_index
 *     36   tdma_cons_index
 *     40   tdma_dma_ctrl
 *     44   (reserved — zero)
 *     48   state.rx_cidx       (software-side ring tracking)
 *     52   state.rx_ridx
 *     56   state.tx_pidx
 *     60   state.tx_ridx
 *
 * Used by lib/perf.S::perf_handle on PERF_CMD_DUMP_REGS. Exposed
 * to the test harness via the 0x88B6 query protocol so
 * test_l2_dump_state can assert on the runtime state of the
 * GENET driver + hardware without needing a JTAG probe.
 *
 * Guarded on PLATFORM_PI4 because it references GENET_BASE and
 * genet_state, both of which only exist in Pi 4 builds. The test
 * kernel (QEMU raspi3b) doesn't have GENET hardware at all.
 *
 * x0: destination buffer (at least 64 bytes, any alignment)
 * Clobbers: x1-x5
 * Leaf function — no prologue/epilogue.
 */
genet_dump_state:
    ldr     x1, =GENET_BASE

    /* UMAC block — bytes [0..11] */
    ldr     w2, [x1, #GENET_UMAC_CMD]
    str     w2, [x0, #0]
    ldr     w2, [x1, #GENET_UMAC_TX_FIFO_STATUS]
    str     w2, [x0, #4]
    ldr     w2, [x1, #GENET_UMAC_RX_FIFO_STATUS]
    str     w2, [x0, #8]
    str     wzr, [x0, #12]          /* reserved */

    /* RDMA block — bytes [16..31] */
    ldr     w2, [x1, #RDMA_PROD_INDEX]
    str     w2, [x0, #16]
    ldr     w2, [x1, #RDMA_CONS_INDEX]
    str     w2, [x0, #20]
    ldr     w2, [x1, #RDMA_DMA_CTRL]
    str     w2, [x0, #24]
    ldr     w2, [x1, #RDMA_XON_XOFF_THRESH]
    str     w2, [x0, #28]

    /* TDMA block — bytes [32..47]
     * TDMA ring 16 registers sit at GENET_BASE + 0x5000; the offsets
     * in genet.inc (TDMA_*_OFS) are relative to that base. Compute
     * the TDMA ring base in x3, then use the small offsets. */
    add     x3, x1, #5, lsl #12
    ldr     w2, [x3, #TDMA_PROD_INDEX_OFS]
    str     w2, [x0, #32]
    ldr     w2, [x3, #TDMA_CONS_INDEX_OFS]
    str     w2, [x0, #36]
    ldr     w2, [x3, #TDMA_DMA_CTRL_OFS]
    str     w2, [x0, #40]
    str     wzr, [x0, #44]          /* reserved */

    /* Software state — bytes [48..63]
     * genet_state is declared .global in platform/pi/main.S so
     * this cross-module reference resolves at link time. */
    ldr     x3, =genet_state
    ldr     w2, [x3, #GENET_STATE_RX_CIDX]
    str     w2, [x0, #48]
    ldr     w2, [x3, #GENET_STATE_RX_RIDX]
    str     w2, [x0, #52]
    ldr     w2, [x3, #GENET_STATE_TX_PIDX]
    str     w2, [x0, #56]
    ldr     w2, [x3, #GENET_STATE_TX_RIDX]
    str     w2, [x0, #60]

    ret

.endif  /* PLATFORM_PI4 — end of genet_dump_state guard */


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

    /* --- RGMII interface ---
     * 0x00F10050 = RGMII_LINK | RGMII_MODE_EN | ID_MODE_DIS | (bits 20-23)
     * ID_MODE_DIS (bit 16) disables MAC-side RGMII delay; PHY applies
     * delays via shadow regs instead. */
    ldr     w0, =0x00F10050
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

    /* Start auto-negotiate */
    mov     w0, #PHY_BMCR
    ldr     w1, =0x1340
    bl      genet_mdio_write

    /* Wait for link + AN complete — retry forever (cable plugged
     * after boot is a supported case). Periodically print "PHY:
     * waiting for link" so a stuck wait is visible on UART rather
     * than silent.
     *
     * Exit condition: BMSR bit 2 (link up) AND bit 5 (AN complete).
     * Read BMSR twice: bit 2 (link up) is latched-low.
     * Do NOT kick AN again — restart interrupts the negotiation state.
     *
     * Recovery envelope: this loop runs UNDER the boot-grace
     * watchdog (armed in main.S before genet_init). If the wait
     * persists past the 60 s budget, the SoC resets and boot
     * starts over — giving the user a loud reset cycle to
     * diagnose against rather than a silent kernel hang. Cable
     * plugged late: link comes up, AN completes within the next
     * 60 s window, kernel proceeds. */
.Lan_wait:
    mov     w0, #PHY_BMSR
    bl      genet_mdio_read
    mov     w0, #PHY_BMSR
    bl      genet_mdio_read
    tbz     w0, #2, .Lan_progress
    tbz     w0, #5, .Lan_progress
    b       .Lan_ok

.Lan_progress:
    /* Print "PHY: waiting for link" approximately every 4 s.
     * CNTPCT_EL0 is the architectural cycle counter (always
     * available after boot, no driver init needed); CNTFRQ_EL0
     * gives ticks/sec. 4 × freq fits in a single lsl, keeping
     * the math one shift instead of a runtime multiply. The
     * .Lphy_last_print BSS slot is zero on first entry, so the
     * very first iteration through the loop prints immediately,
     * giving the user feedback the moment the wait starts. */
    mrs     x10, CNTPCT_EL0
    ldr     x9, =genet_phy_last_print
    ldr     x11, [x9]
    sub     x12, x10, x11
    mrs     x13, CNTFRQ_EL0
    lsl     x13, x13, #2                /* 4 × freq ticks ≈ 4 s */
    cmp     x12, x13
    b.lo    .Lan_wait                   /* <4 s since last print, keep waiting silently */
    str     x10, [x9]                   /* update last_print timestamp */
    ldr     x0, =genet_phy_waiting_msg
    bl      uart_puts
    b       .Lan_wait

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

    /* --- Configure RBUF/TBUF BEFORE ring setup (matches Linux) ---
     *
     * Linux's bcmgenet_set_hw_params sets RBUF_64B_EN and RBUF_CHK_CTRL
     * BEFORE bcmgenet_init_dma configures the rings. The 64B mode
     * changes how the DMA interprets descriptors, so it must be
     * enabled before any descriptors are written. */

    /* RBUF_CTRL: 64B status + 2-byte alignment pad.
     * Only set the bits we understand — bits 6/14/15 from Linux's
     * 0xC043 value caused PAUSE frame flooding on the bare-metal
     * driver (those bits may be flow-control-related and require
     * matching RBUF/TBUF threshold configuration we don't have). */
    ldr     w0, [x19, #GENET_RBUF_CTRL]
    orr     w0, w0, #1              /* RBUF_64B_EN */
    orr     w0, w0, #2              /* RBUF_ALIGN_2B */
    str     w0, [x19, #GENET_RBUF_CTRL]

    /* RBUF_CHK_CTRL: enable checksum engine + disable L3 parser */
    ldr     w0, [x19, #GENET_RBUF_CHK_CTRL]
    orr     w0, w0, #1              /* RXCHK_EN */
    orr     w0, w0, #(1 << 5)      /* L3_PARSE_DIS */
    str     w0, [x19, #GENET_RBUF_CHK_CTRL]

    /* TBUF_CTRL: 64B TX status block */
    ldr     w0, [x19, #GENET_TBUF_CTRL]
    orr     w0, w0, #TBUF_64B_EN
    str     w0, [x19, #GENET_TBUF_CTRL]

    /* RBUF_TBUF_SIZE_CTRL: allocate TBUF space for TX. */
    mov     w0, #1
    str     w0, [x19, #GENET_RBUF_TBUF_SIZE]

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
    /* TDMA ring config: enable queues 0-3 alongside ring 16 —
     * matches Linux bcmgenet. Required for DO_CSUM. */
    ldr     w0, =DMA_RING_CFG_EN_CSUM
    str     w0, [x22, #TDMA_DMA_RING_CFG_OFS]

    ldr     w0, =DMA_CTRL_EN
    str     w0, [x19, #RDMA_DMA_CTRL]
    /* TDMA: match Linux's 0x0002001F — enables TX priority queues
     * 0-3 alongside ring 16. Without the queue enables (bits 1-4),
     * DMA_TX_DO_CSUM in the descriptor silently drops frames. */
    ldr     w0, =DMA_CTRL_EN_CSUM
    str     w0, [x22, #TDMA_DMA_CTRL_OFS]

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

    /* Cache the boot speed code in state. genet_phy_check uses this
     * to detect link renegotiation and update UMAC_CMD's SPEED bits
     * accordingly. Without this the MAC stays at the boot speed and
     * silently drops all RX after a link speed change. */
    str     w23, [x20, #GENET_STATE_PHY_SPEED]

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
 *
 * Under PERF=send (or PERF=all) the frame is bumped by 16 bytes to
 * save x23 (probe start tick) + x24 (pad; unused but paired with
 * x23 for ldp/stp). Other PERF flavors and the default build keep
 * the 48-byte frame — no extra cost.
 */
genet_send:
.ifdef PERF_SEND
    stp     x19, x20, [sp, #-64]!
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x29, x30, [sp, #48]
    PROBE_ENTRY x23
.else
    stp     x19, x20, [sp, #-48]!
    stp     x21, x22, [sp, #16]
    stp     x29, x30, [sp, #32]
.endif

    mov     x19, x0                 /* GENET base */
    mov     x20, x1                 /* state */
    mov     x21, x2                 /* buf (original frame) */
    mov     w22, w3                 /* len (frame only) */

    /* === Build combined TSB + frame in genet_tsb_buf ===
     *
     * TBUF_64B_EN is set in genet_init, so every DMA must start
     * with a 64-byte TSB. The GENET strips the TSB and transmits
     * only the frame portion on the wire. For IP frames whose L4
     * checksum field is zeroed / pseudo-header-only, tx_csum_info
     * tells the GENET to insert the correct checksum during DMA.
     * For non-IP frames the TSB is all-zero (LV=0 → HW ignores). */

    ldr     x0, =genet_tsb_buf

    /* Zero the 64-byte TSB (4 stp pairs) */
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]
    stp     xzr, xzr, [x0, #48]

    /* Default: no checksum offload (non-IP frames or unknown proto) */
    mov     w4, #0                  /* w4 = 0: no DO_CSUM flag */

    /* Detect IPv4 (ethertype 0x0800 at buf[12..13], big-endian) */
    ldrb    w1, [x21, #12]
    cmp     w1, #0x08
    b.ne    .Ltsb_copy
    ldrb    w1, [x21, #13]
    cbnz    w1, .Ltsb_copy

    /* IPv4 — read IP.protocol at buf[23] */
    ldrb    w1, [x21, #23]         /* ETH_PAYLOAD(14) + IP_PROTO(9) */
    cmp     w1, #1                  /* ICMP */
    b.eq    .Ltsb_icmp
    cmp     w1, #6                  /* TCP */
    b.eq    .Ltsb_tcp
    /* UDP TX is intentionally NOT offloaded. The GENET's TX
     * checksum engine does not implement the RFC 768 special
     * case where a computed UDP checksum of 0x0000 must be
     * transmitted as 0xFFFF (because on the wire, 0x0000 in the
     * UDP checksum field means "checksum not computed"). The
     * GENET would emit a raw 0x0000 roughly 1 in 65536 packets,
     * which receivers would silently accept as unchecksummed.
     * Falling through to .Ltsb_copy here leaves w4=0, so the
     * descriptor has no DO_CSUM bit and the software checksum
     * (which correctly handles the 0→0xFFFF rewrite — see
     * lib/udp.S) rides on the wire unchanged. UDP echo is the
     * only UDP TX path in the stack today, and the SW cost is
     * negligible for its tiny packets.
     */
    b       .Ltsb_copy              /* other IP proto: no checksum */

.Ltsb_icmp:
    ldr     w1, =TX_CSUM_INFO_ICMP
    b       .Ltsb_store
.Ltsb_tcp:
    ldr     w1, =TX_CSUM_INFO_TCP
.Ltsb_store:
    str     w1, [x0, #TSB_TX_CSUM_INFO]
    mov     w4, #TX_DO_CSUM         /* bit 4 only — no OW_CRC */

.Ltsb_copy:
    /* Copy frame data after the TSB. 16 bytes per iter via
     * ldp/stp with post-increment, byte loop for the tail —
     * mirrors .Lrx_copy16 in genet_recv. The previous byte
     * loop's "~200 ns / 1500 B" comment was off by an order of
     * magnitude (real cost was ~5 μs at ~5 instr/byte on Cortex-
     * A72); ldp/stp pulls that to ~1 μs by handling 16 bytes per
     * 2-instruction inner step, a ~5× reduction in the per-frame
     * copy cost. The L4 checksum offload savings still dwarf the
     * copy on supported protocols, but on every frame this path
     * trims ~4 μs that the protocol stack can use elsewhere. */
    add     x1, x0, #TSB_SIZE      /* dst = tsb_buf + 64 */
    mov     x2, x21                 /* src = original buf */
    mov     w3, w22                 /* count */
.Ltsb_copy16:
    cmp     w3, #16
    b.lt    .Ltsb_copy_tail
    ldp     x6, x7, [x2], #16
    stp     x6, x7, [x1], #16
    sub     w3, w3, #16
    b       .Ltsb_copy16
.Ltsb_copy_tail:
    cbz     w3, .Ltsb_copy_done
.Ltsb_copy_byte:
    ldrb    w6, [x2], #1
    strb    w6, [x1], #1
    subs    w3, w3, #1
    b.ne    .Ltsb_copy_byte
.Ltsb_copy_done:

    /* Switch buf/len to the combined buffer */
    ldr     x21, =genet_tsb_buf
    add     w22, w22, #TSB_SIZE     /* DMA len includes the TSB */

    /* Flush combined buffer from D-cache to RAM */
    bic     x0, x21, #63            /* align down to cache line */
    add     x1, x21, x22           /* end = tsb_buf + 64 + frame_len */
.Ltx_flush:
    dc      civac, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    .Ltx_flush
    dsb     sy

    /* Get current TX indices from state */
    ldr     w3, [x20, #GENET_STATE_TX_PIDX]
    ldr     w6, [x20, #GENET_STATE_TX_RIDX]

    /* Compute descriptor address: GENET + 0x4000 + ridx * 12 */
    add     x5, x19, #4, lsl #12
    mov     w0, #DMA_DESC_SIZE
    mul     w1, w6, w0
    add     x5, x5, x1

    /* CPU physical address (GENET DMA uses physical directly) */
    mov     w0, w21

    /* Write descriptor: addr_lo, addr_hi (must be 0 for 32-bit
     * addresses — GENET v5 uses 40-bit DMA), length_status last. */
    str     w0, [x5, #4]            /* address_lo */
    str     wzr, [x5, #8]           /* address_hi = 0 (32-bit addr) */
    lsl     w0, w22, #16            /* length (TSB + frame) in upper 16 */
    ldr     w1, =TX_LEN_STATUS_FLAGS
    orr     w0, w0, w1
    orr     w0, w0, w4              /* w4 = TX_DO_CSUM or 0 */
    str     w0, [x5, #0]            /* length_status */

    /* Barrier between descriptor write and doorbell ring. The
     * descriptor lives in GENET internal SRAM (MMIO window at
     * GENET+0x4000) and PROD_INDEX lives at GENET+0x500C. Both
     * are Device memory so CPU stores are strictly ordered from
     * the CPU's view, but the GENET's internal DMA fetch engine
     * is a separate AXI master that may observe memory through a
     * path not serialized with the CPU's doorbell write. Linux
     * bcmgenet uses wmb() at the equivalent point in
     * bcmgenet_xmit; on AArch64 that is `dsb ishst` (inner-
     * shareable, store-side), which we match here. */
    dsb     ishst

    /* Increment and write PROD_INDEX */
    add     w3, w3, #1
    and     w3, w3, #0xFFFF
    add     x5, x19, #5, lsl #12   /* x5 = TDMA ring base */
    str     w3, [x5, #TDMA_PROD_INDEX_OFS]

    /* Update state */
    str     w3, [x20, #GENET_STATE_TX_PIDX]
    add     w6, w6, #1
    and     w6, w6, #0xFF
    str     w6, [x20, #GENET_STATE_TX_RIDX]

    /* Poll CONS_INDEX for completion with a wall-clock deadline.
     *
     * The earlier "100000 iterations" budget was clock-speed
     * sensitive — at the Pi 4 1.5 GHz default it gave ~5 ms of
     * real wait, but a future CPU frequency scale (or QEMU's
     * faster effective clock) would shift that budget arbitrarily.
     * CNTPCT_EL0 + CNTFRQ_EL0/64 gives a stable ~16 ms wall-clock
     * deadline regardless of CPU speed.
     *
     * Normal Gigabit TX of a 1500 B frame completes in ~12 μs;
     * 16 ms is ~1300× that, so steady-state success is unaffected.
     * Far above 16 ms and something is genuinely wedged — fall
     * through to the genet_wd_record_timeout path which trips a
     * full reset once the consecutive-timeout threshold is hit.
     *
     * The architectural issue Gemini flagged separately (this is
     * still a synchronous PIO-style busy-wait that ties up the
     * CPU during every transmit) is a real concern, but converting
     * the stack to async TX completion is out of scope for a
     * Gemini fix-up commit — it would touch every send caller
     * across TCP, ARP, ICMP, etc. The wallclock deadline + yield
     * here is the largest defensible local improvement without
     * that architectural rework: yield is a hint to the core
     * (essentially a nop on Pi 4 which has no SMT) but keeps the
     * intent explicit and is the right primitive for any future
     * async retrofit.
     *
     * x5 = TDMA ring base (preserved from the doorbell write). */
    mrs     x4, CNTFRQ_EL0
    lsr     x4, x4, #6              /* ~16 ms = freq / 64 ticks */
    mrs     x6, CNTPCT_EL0
    add     x4, x4, x6              /* x4 = wall-clock deadline */
.Ltx_wait:
    ldr     w0, [x5, #TDMA_CONS_INDEX_OFS]
    and     w0, w0, #0xFFFF
    cmp     w0, w3
    b.eq    .Ltx_ok
    yield
    mrs     x6, CNTPCT_EL0
    cmp     x6, x4
    b.lo    .Ltx_wait

    /* Timeout path — bump PERF_SEND_FAIL only, do NOT accumulate
     * ticks. A timeout means we just spent ~100k MMIO reads on a
     * CONS_INDEX poll, which is orders of magnitude longer than a
     * normal send. Mixing that into PERF_SEND_TICKS would destroy
     * mean-per-successful-send as a useful number. Count only.
     *
     * Watchdog detection: bookkeeping is in genet_wd_record_timeout
     * (pure software, unit-testable). When that helper signals the
     * trip threshold, fire genet_watchdog_trip which performs the
     * GENET reset itself. The current send still returns failure
     * to the caller — they retry on their own schedule — but
     * subsequent sends should now succeed because GENET has been
     * reinitialised. */
    mov     x0, x20                 /* state ptr */
    bl      genet_wd_record_timeout
    cbz     w0, .Ltx_no_wd_trip
    mov     x0, x19                 /* GENET base */
    mov     x1, x20                 /* state */
    bl      genet_watchdog_trip
.Ltx_no_wd_trip:
    mov     w0, #1
.ifdef PERF_SEND
    PROBE_COUNT_INC PERF_SEND_FAIL, w2, x3
.endif
    b       .Ltx_ret

.Ltx_ok:
    /* Success path — accumulate ticks into PERF_SEND_TICKS (u64
     * at offset 32) and bump PERF_SEND_COUNT (u32 at offset 40).
     * w0 is set to the return value FIRST and is preserved across
     * the probe macros. x2 and x3 are dead at this point (x2 was
     * only used in the prologue; x3/w3 held the expected PROD_INDEX
     * which is no longer needed once the cmp matched).
     *
     * Watchdog: zero the consec-timeout counter on every success.
     * Any successful send proves the TX path is alive, so the
     * counter must restart from zero — otherwise N transient
     * timeouts spread across a long run would eventually trip
     * even though the hardware is healthy. */
    str     wzr, [x20, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    mov     w0, #0
.ifdef PERF_SEND
    PROBE_EXIT x23, PERF_SEND_TICKS, x2, x3
    PROBE_COUNT_INC PERF_SEND_COUNT, w2, x3
.endif

.Ltx_ret:
.ifdef PERF_SEND
    ldp     x29, x30, [sp, #48]
    ldp     x23, x24, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp], #64
.else
    ldp     x29, x30, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp], #48
.endif
    ret

/*
 * genet_wd_record_timeout — bookkeeping helper for the TX-timeout path.
 *
 * Bumps GENET_STATE_TX_CONSEC_TIMEOUTS by one and reports whether
 * the new value has reached GENET_WD_TX_TIMEOUT_THRESHOLD. The
 * caller (.Ltx_timeout) is responsible for actually firing
 * genet_watchdog_trip on a true return; keeping the trip side-
 * effect out of this function lets unit tests verify the counter
 * arithmetic and threshold logic without faking MMIO.
 *
 * x0: state pointer
 * Returns: w0 = 1 if the trip threshold has been met (caller
 *          should reset), else 0.
 * Clobbers: x0, x1.
 */
.global genet_wd_record_timeout
genet_wd_record_timeout:
    ldr     w1, [x0, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    add     w1, w1, #1
    str     w1, [x0, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    cmp     w1, #GENET_WD_TX_TIMEOUT_THRESHOLD
    cset    w0, ge
    ret

/*
 * genet_wd_record_reset — bookkeeping helper for the trip path.
 *
 * Bumps GENET_STATE_WD_RESET_COUNT and zeros
 * GENET_STATE_TX_CONSEC_TIMEOUTS. Does NOT call genet_init —
 * that's done by genet_watchdog_trip itself, which keeps this
 * helper testable without an MMIO-bearing dependency.
 *
 * Resetting TX_CONSEC_TIMEOUTS is critical: without it, the next
 * failed send (which happens immediately after the reset if
 * recovery wasn't actually achieved) would carry the pre-reset
 * count forward and trip again on the very first post-reset
 * timeout, burning the watchdog into a tight reset loop.
 *
 * x0: state pointer
 * Clobbers: x0, x1.
 */
.global genet_wd_record_reset
genet_wd_record_reset:
    ldr     w1, [x0, #GENET_STATE_WD_RESET_COUNT]
    add     w1, w1, #1
    str     w1, [x0, #GENET_STATE_WD_RESET_COUNT]
    str     wzr, [x0, #GENET_STATE_TX_CONSEC_TIMEOUTS]
    ret

/*
 * genet_watchdog_trip — full GENET reset after detected wedge.
 *
 * Called from .Ltx_timeout when consecutive timeouts reach the
 * threshold. The premise: if N consecutive genet_send calls have
 * all timed out on the CONS_INDEX poll, the TX engine is stuck —
 * not transient congestion, which would clear inside the 100k
 * iteration window. Recovery is a full genet_init: UMAC reset,
 * DMA ring re-init, MAC re-enable, PHY autoneg.
 *
 * x0: GENET base
 * x1: pointer to genet_state (must already have RX_POOL set, which
 *     it does because genet_init wrote it on first boot).
 *
 * Returns: nothing (the caller's send still failed; this just
 *          rebuilds the path so the next attempt can succeed).
 * Clobbers: same set as genet_init.
 *
 * Preserved state across the reset:
 *   - GENET_STATE_RX_POOL — re-supplied to genet_init from the
 *     state struct itself.
 *   - GENET_STATE_WD_RESET_COUNT — the trip counter is part of
 *     the telemetry contract, so it accumulates across resets.
 *
 * Reset state:
 *   - GENET_STATE_TX_CONSEC_TIMEOUTS — explicitly zeroed before
 *     calling genet_init so the post-reset window starts fresh.
 *   - All other GENET_STATE_* fields — genet_init re-zeroes
 *     RX_CIDX/RIDX, TX_PIDX/RIDX, and re-caches PHY_SPEED.
 *
 * Cost: PHY autoneg dominates wall time (~3-5 s on real
 * hardware). Acceptable since the alternative is indefinite
 * silent downtime. Optimisations (selective DMA-only reset that
 * skips PHY) deferred until empirical data shows trips are
 * frequent enough to care.
 */
.global genet_watchdog_trip
genet_watchdog_trip:
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    mov     x19, x0                 /* x19 = GENET base */
    mov     x20, x1                 /* x20 = state */

    /* Counter bookkeeping (bump WD_RESET_COUNT, zero
     * TX_CONSEC_TIMEOUTS) is in a pure-software helper so it can
     * be unit-tested without faking the GENET MMIO surface. */
    mov     x0, x20
    bl      genet_wd_record_reset

    /* One-line console signal so a real-time observer sees the
     * trip without flooding. The /status counter is the durable
     * record; this is for live debugging. */
    ldr     x0, =genet_wd_log_msg
    bl      uart_puts

    /* Call genet_init with the same arguments the original boot
     * used: GENET base, state, RX pool. The pool address lives in
     * the state struct (genet_init wrote it on first call), so we
     * just read it back. */
    mov     x0, x19
    mov     x1, x20
    ldr     x2, [x20, #GENET_STATE_RX_POOL]
    bl      genet_init
    /* genet_init's return value is discarded — there is no
     * meaningful caller action on a failed reset. If the second
     * init also fails, the next genet_send call will hit the
     * timeout path again, and the watchdog will trip a second
     * time. The reset_count delta is the diagnostic signal. */

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

.section .rodata
genet_wd_log_msg:
    .asciz "genet wd: TX wedge detected, full reset\n"
genet_phy_waiting_msg:
    .asciz "PHY: waiting for link\r\n"

.section .bss
.balign 8
genet_phy_last_print:
    .space 8                            /* CNTPCT_EL0 timestamp of last "PHY: waiting" UART line */
.section .text

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
 *
 * Under PERF=recv (or PERF=all) the frame is bumped by 16 bytes to
 * save x23 (probe start tick) + x24 (pad; unused but paired with
 * x23 for ldp/stp). Other PERF flavors and the default build keep
 * the 48-byte frame — no extra instructions execute in the hot
 * path.
 */
genet_recv:
.ifdef PERF_RECV
    stp     x19, x20, [sp, #-64]!
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x29, x30, [sp, #48]
    PROBE_ENTRY x23
.else
    stp     x19, x20, [sp, #-48]!
    stp     x21, x22, [sp, #16]
    stp     x29, x30, [sp, #32]
.endif

    mov     x19, x0                 /* GENET base */
    mov     x20, x1                 /* state */
    mov     x21, x2                 /* dst buf */
    mov     w22, w3                 /* max len */

    /* Check if frame available: PROD_INDEX != our CONS_INDEX.
     *
     * RDMA_PROD_INDEX is a 32-bit register whose LOWER 16 bits are
     * the producer index (frames the HW has published into the
     * ring) and whose UPPER 16 bits are the RDMA discard counter
     * (frames the HW dropped at the ring because no descriptor was
     * free). Under PERF_COUNTERS we snapshot the upper half into
     * perf_counters.rx_discards so the test harness can see it
     * via the 0x88B6 query. The snapshot overwrites on every call,
     * so the last-read value at end-of-burst is what the test sees
     * — close enough to "final discard count for the burst" given
     * the snapshot cadence. */
    ldr     w0, [x19, #RDMA_PROD_INDEX]
.ifdef PERF_COUNTERS
    lsr     w2, w0, #16
    ldr     x3, =perf_counters
    str     w2, [x3, #PERF_RX_DISCARDS]
.endif
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

    /* Hardware error check: if any DMA_RX_FI_MASK bit is set the
     * frame in this descriptor is damaged (bad CRC, overrun,
     * oversize, truncated, or generic rxer). Drop it without
     * processing, consume the descriptor so we don't see it again,
     * and return "no frame" so the caller retries. This is
     * L2 hardening queue item 3: exposes the HW error path to the
     * test harness via the PERF_DROP_COUNT counter. */
    tst     w4, #DMA_RX_FI_MASK
    b.ne    .Lrx_err

    lsr     w5, w4, #16
    and     w5, w5, #0xFFF          /* raw length (includes 64B RSB + 2B pad) */

    /* Compute source buffer: pool + ridx * 2048 */
    ldr     x0, [x20, #GENET_STATE_RX_POOL]
    lsl     w3, w2, #11
    add     x0, x0, x3
    /* Invalidate D-cache for RX buffer.
     *
     * `dc ivac` (invalidate only), NOT `dc civac` (clean +
     * invalidate): the DMA has just written this buffer in RAM
     * and we're about to read it. `civac` would clean any dirty
     * cache lines back to RAM first, which under MMU-off + cache-
     * dirty conditions could overwrite the freshly-DMA'd packet
     * with stale CPU writes. RX buffers are CPU-read-only by
     * convention so they should stay clean — `civac` was likely
     * defensive, but the cost of being wrong (silent packet
     * corruption) is too high to leave the latent risk. `ivac`
     * is the safe primitive for any DMA-written buffer the CPU
     * is about to consume. */
    mov     x3, x0
    mov     w4, #0
.Lrx_inv:
    dc      ivac, x3
    add     x3, x3, #64
    add     w4, w4, #64
    cmp     w4, w5
    b.lt    .Lrx_inv
    dsb     sy

    /* Skip 64-byte RSB (from RBUF_64B_EN) + 2-byte alignment pad.
     * The descriptor's raw length includes both; subtracting 66
     * yields the actual Ethernet frame length. Guard against
     * underflow (raw_len < 66) from corrupt descriptors AND
     * against a raw_len of exactly 66 producing a 0-length frame
     * — Ethernet has no 0-byte frames (smallest legal payload is
     * a 60-byte runt + FCS), so anything that decodes to length 0
     * is by definition malformed and routes to .Lrx_err for the
     * drop-bookkeeping path rather than handing 0 bytes to the
     * caller as if it were a valid packet. */
    cmp     w5, #66
    b.le    .Lrx_err
    add     x0, x0, #66            /* skip RSB(64) + pad(2) */
    sub     w5, w5, #66            /* actual frame length */

    /* Clamp to max buffer */
    cmp     w5, w22
    csel    w5, w5, w22, lt

    /* Copy frame to caller's buffer, 16 bytes per iteration via
     * ldp/stp with post-increment addressing. For a 60-byte ARP
     * frame: 3 × 16-byte copies (~12 cycles) + 12 × 1-byte tail
     * (~48 cycles) = ~60 cycles vs ~240 for the old byte loop.
     * For a 1500-byte TCP payload the speedup is ~10x because
     * the 16-byte inner loop dominates.
     *
     * The byte-copy to a fixed rx_buf is intentional, not legacy:
     * it's a cache-locality optimization. The protocol stack then
     * works on the same hot L1 line across frames, which is faster
     * than a "zero-copy" in-place approach that would miss on a
     * different rx_pool slot for each frame. See
     * project_genet_arp_burst_loss.md for the investigation. */
    mov     x3, x21                 /* dst (rx_buf) */
    mov     w9, w5                  /* save length for return (w5 is
                                     * clobbered by the copy loop) */
.Lrx_copy16:
    cmp     w5, #16
    b.lt    .Lrx_copy_tail
    ldp     x7, x8, [x0], #16
    stp     x7, x8, [x3], #16
    sub     w5, w5, #16
    b       .Lrx_copy16
.Lrx_copy_tail:
    cbz     w5, .Lrx_copy_done
.Lrx_copy_byte:
    ldrb    w6, [x0], #1
    strb    w6, [x3], #1
    subs    w5, w5, #1
    b.ne    .Lrx_copy_byte
.Lrx_copy_done:
    mov     w5, w9                  /* restore length for return */

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

.ifdef PERF_RECV
    /* Accumulate elapsed ticks into PERF_RECV_TICKS (u64 at off 0)
     * and bump PERF_RECV_COUNT (u32 at off 8). w0/w1 hold return
     * values and are preserved by the probe macros (they only touch
     * x23/x2/x3 + w2). x2/x3 are caller-saved scratch, free here
     * because we're on the return path. PROBE_COUNT_INC takes a
     * w-register first so the load/store is 4 bytes, not 8 —
     * critical for u32 fields. */
    PROBE_EXIT x23, PERF_RECV_TICKS, x2, x3
    PROBE_COUNT_INC PERF_RECV_COUNT, w2, x3
.endif

    b       .Lrx_ret

.Lrx_err:
    /* Hardware RX error path. The descriptor at w2 = current RIDX
     * contains a damaged frame. The state-bookkeeping side of the
     * drop (advance CIDX+RIDX, optionally bump PERF_DROP_COUNT) is
     * extracted into genet_rx_drop_bookkeeping so it can be
     * unit-tested off-hardware. We only keep the one MMIO operation
     * (publish the new CIDX to RDMA_CONS_INDEX) here, because the
     * helper is deliberately pure software. The MMIO publish is
     * mandatory — without it the hardware won't free the descriptor
     * slot and the ring stalls on the next wrap. */
    mov     x0, x20                 /* state pointer */
.ifdef PERF_COUNTERS
    ldr     x1, =perf_counters
.else
    mov     x1, xzr                 /* NULL → helper skips perf bump */
.endif
    bl      genet_rx_drop_bookkeeping
    /* Helper returned w0 = new CIDX value; publish to HW so the
     * hardware sees the descriptor as consumed. */
    str     w0, [x19, #RDMA_CONS_INDEX]

    mov     w0, #1
    mov     w1, #0

.ifdef PERF_RECV
    /* Count this as a "no frame" in the recv stats — the caller
     * sees it as a no-frame call, which matches the return code.
     * Do NOT accumulate ticks (path is trivial). */
    PROBE_COUNT_INC PERF_RECV_NONE, w2, x3
.endif

    b       .Lrx_ret

.Lrx_none:
    mov     w0, #1
    mov     w1, #0

.ifdef PERF_RECV
    /* Bump PERF_RECV_NONE on the no-frame path. Do NOT accumulate
     * ticks here: this path is trivial (one MMIO read + compare)
     * and mixing its time into PERF_RECV_TICKS would make
     * mean-per-successful-frame unreadable. Keeping recv_ticks
     * success-only means burst_stats.py can divide ticks by
     * recv_count for a clean per-frame number. */
    PROBE_COUNT_INC PERF_RECV_NONE, w2, x3
.endif

.Lrx_ret:
.ifdef PERF_RECV
    ldp     x29, x30, [sp, #48]
    ldp     x23, x24, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp], #64
.else
    ldp     x29, x30, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp], #48
.endif
    ret

/*
 * genet_rx_drop_bookkeeping — software state update for a dropped
 * RX descriptor.
 *
 * Called from genet_recv's .Lrx_err path. Extracted into its own
 * leaf function so the drop-path state mutation (advance CIDX+RIDX,
 * bump PERF_DROP_COUNT) can be unit-tested off-hardware by
 * tests/test_genet_rx_err.S without touching any MMIO. The caller
 * is still responsible for publishing the returned CIDX to the
 * hardware RDMA_CONS_INDEX register.
 *
 * The perf-counter bump is controlled by passing a pointer (or
 * NULL) rather than by an assemble-time .ifdef, so one build of
 * this function serves both the PERF_COUNTERS and default paths.
 * That also lets the test directly cover the "no perf counters"
 * branch by passing xzr.
 *
 * Inputs:
 *   x0 = pointer to genet_state struct (writable; bytes 0..7 touched)
 *   x1 = pointer to perf_counters struct, or 0 (NULL) to skip bump
 *
 * Outputs:
 *   w0 = new RX CIDX value (caller publishes to RDMA_CONS_INDEX)
 *
 * Clobbers: w0, w2, w3. Leaf (no stack frame).
 *
 * Pure software: no MMIO, no reference to perf_counters symbol.
 */
genet_rx_drop_bookkeeping:
    ldr     w2, [x0, #GENET_STATE_RX_CIDX]
    add     w2, w2, #1
    and     w2, w2, #0xFFFF
    str     w2, [x0, #GENET_STATE_RX_CIDX]

    ldr     w3, [x0, #GENET_STATE_RX_RIDX]
    add     w3, w3, #1
    and     w3, w3, #0xFF
    str     w3, [x0, #GENET_STATE_RX_RIDX]

    cbz     x1, .Lgrdb_done
    ldr     w3, [x1, #PERF_DROP_COUNT]
    add     w3, w3, #1
    str     w3, [x1, #PERF_DROP_COUNT]
.Lgrdb_done:
    mov     w0, w2                  /* return new CIDX */
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

/*
 * genet_phy_check — Poll the PHY for a speed change and update
 * UMAC_CMD's SPEED bits if the link has renegotiated.
 *
 * Without this, after the PHY auto-negotiates to a different speed
 * (e.g. the link partner restricts its advertise mask to 100M),
 * the GENET MAC remains configured for the boot speed and samples
 * RGMII at the wrong rate, silently dropping all RX traffic.
 *
 * x0: GENET base address
 * x1: pointer to genet_state struct (uses GENET_STATE_PHY_SPEED slot)
 *
 * Cost: ~one MDIO read per call (a few microseconds). Idempotent —
 * if the PHY speed hasn't changed since the last call, this is a
 * no-op except for the MDIO transaction. Safe to call from the main
 * net_loop on every iteration.
 *
 * Speed code from PHY_AUX_STS bits [10:8] per BCM54213PE datasheet:
 *   7 = 1000baseT/Full
 *   6 = 1000baseT/Half
 *   5 = 100baseTX/Full
 *   3 = 100baseTX/Half
 *   2 = 10baseT/Full
 *   1 = 10baseT/Half
 *   0 = no link
 *
 * Mapped to UMAC_CMD bits:
 *   1G  → UMAC_CMD_SPEED_1000 (bit 3)
 *   100 → UMAC_CMD_SPEED_100  (bit 2)
 *   10  → both bits clear
 */
.global genet_phy_check
genet_phy_check:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x0                       /* base */
    mov     x20, x1                       /* state */

    /* Read current PHY speed code */
    mov     w0, #PHY_AUX_STS
    bl      genet_mdio_read
    /* w0 = full register; speed code is bits [10:8] */
    lsr     w0, w0, #8
    and     w0, w0, #7                    /* w0 = current speed code */

    /* Compare to cached value; bail if unchanged */
    ldr     w1, [x20, #GENET_STATE_PHY_SPEED]
    cmp     w0, w1
    b.eq    .Lphy_check_done

    /* Speed changed: derive the new UMAC_CMD SPEED bits */
    mov     w2, #0                        /* w2 = new SPEED bits (default 10M) */
    cmp     w0, #7
    b.eq    .Lphy_set_1000
    cmp     w0, #6
    b.eq    .Lphy_set_1000
    cmp     w0, #5
    b.eq    .Lphy_set_100
    cmp     w0, #3
    b.eq    .Lphy_set_100
    b       .Lphy_apply
.Lphy_set_1000:
    mov     w2, #UMAC_CMD_SPEED_1000
    b       .Lphy_apply
.Lphy_set_100:
    mov     w2, #UMAC_CMD_SPEED_100

.Lphy_apply:
    /* RMW UMAC_CMD: clear both SPEED bits (mask 0xC), then OR in
     * the new ones. Preserves TX_EN, RX_EN, PROMISC, and any other
     * runtime state. The pre-computed mask 0xC = SPEED_100 |
     * SPEED_1000 is a hex literal because GNU as doesn't allow OR
     * of two .equ symbols in an immediate. */
    ldr     w3, [x19, #GENET_UMAC_CMD]
    bic     w3, w3, #0xc
    orr     w3, w3, w2
    str     w3, [x19, #GENET_UMAC_CMD]

    /* Cache the new speed code so the next call is a no-op */
    str     w0, [x20, #GENET_STATE_PHY_SPEED]

.Lphy_check_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* --- BSS: combined TSB + frame buffer for TX checksum offload --- */
.section .bss
.balign 64
genet_tsb_buf:
    .space  TSB_SIZE + ETH_FRAME_MAX   /* 64 + 1514 = 1578 bytes */

/* mdns_mac (the L2 multicast MAC for IPv4 mDNS, 01:00:5e:00:00:fb)
 * was originally defined here per D007 / I14. It moved to lib/mdns.S
 * during I15-2 so QEMU builds (which don't link genet.S) can link
 * the responder for unit tests. The label is unchanged — same
 * symbol, same bytes, just sourced from mdns.S now. */
