/*
 * genet.inc — BCM2711 GENET v5 Ethernet controller definitions
 *
 * Base address: 0xFD580000 (extended peripherals, Pi 4 only)
 */

.ifdef PLATFORM_PI4
    .equ GENET_BASE,           0xFD580000
.endif

/* System registers */
.equ GENET_SYS_REV,           0x000
.equ GENET_SYS_PORT_CTRL,     0x004
.equ GENET_SYS_RBUF_FLUSH,    0x008

/* EXT block */
.equ GENET_EXT_RGMII_OOB,     0x08C

/* Interrupt registers */
.equ GENET_INTRL2_0_CLEAR,    0x208
.equ GENET_INTRL2_0_MASK_SET, 0x210
.equ GENET_INTRL2_1_CLEAR,    0x248
.equ GENET_INTRL2_1_MASK_SET, 0x250

/* RBUF */
.equ GENET_RBUF_CTRL,         0x300

/* UMAC registers (offset from GENET_BASE) */
.equ GENET_UMAC_CMD,          0x808
.equ GENET_UMAC_MAC0,         0x80C
.equ GENET_UMAC_MAC1,         0x810
.equ GENET_UMAC_MAX_FRAME,    0x814
.equ GENET_UMAC_TX_FLUSH,          0xB34
.equ GENET_UMAC_RX_FIFO_STATUS,    0xB38
.equ GENET_UMAC_TX_FIFO_STATUS,    0xB3C
.equ GENET_UMAC_MIB_CTRL,     0xD80
.equ GENET_UMAC_MDIO_CMD,     0xE14

/* UMAC_CMD bits */
.equ UMAC_CMD_TX_EN,          (1 << 0)
.equ UMAC_CMD_RX_EN,          (1 << 1)
.equ UMAC_CMD_SPEED_100,      (1 << 2)
.equ UMAC_CMD_SPEED_1000,     (1 << 3)
.equ UMAC_CMD_PROMISC,        (1 << 4)
.equ UMAC_CMD_SW_RESET,       (1 << 13)
.equ UMAC_CMD_LCL_LOOP,       (1 << 15)

/* MDIO command bits */
.equ MDIO_START_BUSY,         (1 << 29)
.equ MDIO_READ_FAIL,          (1 << 28)
.equ MDIO_READ,               (1 << 27)
.equ MDIO_WRITE,              (1 << 26)
.equ MDIO_PMD_SHIFT,          21
.equ MDIO_REG_SHIFT,          16

/* PHY */
.equ GENET_PHY_ADDR,          1
.equ PHY_BMCR,                0
.equ PHY_BMSR,                1
.equ PHY_AUX_STS,             0x19

/* RX DMA — descriptors at GENET_BASE + 0x2000, ring 16 regs at + 0x3000 */
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

/* TX DMA — descriptors at + 0x4000, ring 16 regs at + 0x5000
 * TDMA offsets exceed str immediate range from GENET_BASE.
 * Use: add x_td, x_base, #5, lsl #12  (GENET + 0x5000)
 * Then access as [x_td, #offset_from_0x5000] */
.equ GENET_TX_DESC_BASE,      0x4000
.equ TDMA_R16_OFS,            0x5000   /* add to base, then use small offsets */
.equ TDMA_READ_PTR_OFS,       0x000
.equ TDMA_CONS_INDEX_OFS,     0x008
.equ TDMA_PROD_INDEX_OFS,     0x00C
.equ TDMA_RING_BUF_SIZE_OFS,  0x010
.equ TDMA_START_ADDR_OFS,     0x014
.equ TDMA_END_ADDR_OFS,       0x01C
.equ TDMA_MBUF_DONE_THRESH_OFS, 0x024
.equ TDMA_FLOW_PERIOD_OFS,    0x028
.equ TDMA_WRITE_PTR_OFS,      0x02C
.equ TDMA_DMA_RING_CFG_OFS,   0x040
.equ TDMA_DMA_CTRL_OFS,       0x044
.equ TDMA_DMA_SCB_BURST_OFS,  0x04C

/* DMA constants */
.equ DMA_DESC_SIZE,            12
.equ DMA_DESC_COUNT,           256
.equ RX_BUF_LENGTH,           2048
/* GENET DMA uses CPU physical addresses directly (no bus offset needed) */
.equ DMA_BURST_SIZE,          8
.equ DMA_RING_CFG_EN,         0x00010000   /* ring 16 only (non-checksum builds) */
.equ DMA_CTRL_EN,             0x00020001   /* ring 16 enable | DMA_EN */
/* Linux bcmgenet enables TX priority queues 0-3 alongside ring 16
 * in BOTH DMA_RING_CFG and DMA_CTRL. The queues are unused by
 * ws_pi5 but enabling them appears necessary for DMA_TX_DO_CSUM
 * to function — the checksum engine may route through queue
 * descriptors internally.
 *
 * DMA_RING_CFG: bits 0-3 = queue enables, bit 16 = ring 16
 * DMA_CTRL:     bits 1-4 = queue enables (shifted by 1), bit 0 = DMA_EN, bit 17 = ring 16 */
.equ DMA_RING_CFG_EN_CSUM,   0x0001000F   /* ring 16 + queues 0-3 */
.equ DMA_CTRL_EN_CSUM,       0x0002001F   /* ring 16 + queues 0-3 + DMA_EN */

/* TBUF registers (offset from GENET_BASE + 0x0600) */
.equ GENET_TBUF_CTRL,         0x600
.equ TBUF_64B_EN,             (1 << 0)  /* enable 64-byte TX status block */

/* TX descriptor length_status flags */
.equ TX_SOP,                  (1 << 13)
.equ TX_EOP,                  (1 << 14)
.equ TX_APPEND_CRC,           (1 << 6)
.equ TX_DO_CSUM,              (1 << 4)  /* request HW checksum insertion */
.equ TX_LEN_STATUS_FLAGS,     0x7FC0    /* SOP|EOP|QTAG(0x3F)|APPEND_CRC */
.equ TX_LEN_STATUS_FLAGS_CSUM, 0x7FD0  /* same + TX_DO_CSUM */

/* TX Status Block (TSB) — 64-byte prefix prepended to frame data
 * when TBUF_64B_EN is set. The GENET reads the TSB for checksum
 * control and does NOT transmit it on the wire.
 *
 * Only the tx_csum_info field at offset 0x30 is used; the rest
 * is reserved / zero. */
.equ TSB_SIZE,                64
.equ TSB_TX_CSUM_INFO,        0x30

/* tx_csum_info bit layout:
 *   [31]     STATUS_TX_CSUM_LV         — checksum valid (enable)
 *   [30:16]  STATUS_TX_CSUM_START      — byte offset from DMA buf start
 *                                        to L4 header (= TSB + ETH + IP)
 *   [15]     STATUS_TX_CSUM_PROTO_UDP  — set for UDP, clear for TCP/ICMP
 *   [14:0]   csum_offset               — byte offset from csum_start
 *                                        to the L4 checksum field
 *
 * The GENET computes ones' complement sum over [csum_start, end),
 * SKIPPING the 2-byte checksum field at csum_start + csum_offset,
 * adds the result to the existing field value, and writes back.
 * For TCP/UDP the field must contain the pseudo-header checksum;
 * for ICMP it must be 0. */
.equ TX_CSUM_LV,              0x80000000
.equ TX_CSUM_PROTO_UDP,       0x00008000

/* Pre-computed tx_csum_info values for ws_pi5's fixed IHL=5 layout.
 *
 * From Linux bcmgenet_add_tsb():
 *   offset = skb_checksum_start_offset(skb) - sizeof(status_64);
 *   tx_csum_info = (offset << 16) | (offset + skb->csum_offset) | LV;
 *
 * bits [30:16] = csum_start = ETH(14) + IP(20) = 34  (from frame start)
 * bits [14:0]  = csum_start + csum_offset = ABSOLUTE position of the
 *                checksum field from the frame start (NOT relative!)
 * bit  [31]    = LV (valid)
 * bit  [15]    = proto_udp (UDP only)
 *
 *   ICMP: checksum at L4+2 → absolute = 34+2 = 36
 *   TCP:  checksum at L4+16 → absolute = 34+16 = 50
 *   UDP:  checksum at L4+6  → absolute = 34+6 = 40
 */
.equ TX_CSUM_INFO_ICMP, 0x80220024  /* LV | start=34 | abs=36 */
.equ TX_CSUM_INFO_TCP,  0x80220032  /* LV | start=34 | abs=50 */
.equ TX_CSUM_INFO_UDP,  0x80228028  /* LV | start=34 | proto_udp | abs=40 */

/* RX descriptor length_status */
.equ RX_DMA_OWN,              0x8000

/* RX descriptor error bits (bits 0-4 of length_status word).
 * Source: Linux bcmgenet.h DMA_RX_FI_MASK. If ANY of these are set
 * the frame the HW deposited in the rx_pool slot is damaged and
 * must be dropped (not passed to net_recv_one). */
.equ DMA_RX_OV,               0x0001   /* RX FIFO overrun */
.equ DMA_RX_CRC_ERROR,        0x0002   /* bad FCS (CRC) */
.equ DMA_RX_RXER,             0x0004   /* generic receive error */
.equ DMA_RX_NO,               0x0008   /* no SOP/EOP (truncated) */
.equ DMA_RX_LG,               0x0010   /* oversize frame */
.equ DMA_RX_FI_MASK,          0x001F   /* any of the above */

/* GENET state struct — tracks DMA ring indices and cached PHY state */
.equ GENET_STATE_RX_CIDX,     0    /* RX consumer index (16-bit) */
.equ GENET_STATE_RX_RIDX,     4    /* RX ring index (0-255) */
.equ GENET_STATE_TX_PIDX,     8    /* TX producer index (16-bit) */
.equ GENET_STATE_TX_RIDX,     12   /* TX ring index (0-255) */
.equ GENET_STATE_RX_POOL,     16   /* RX buffer pool CPU address (8 bytes) */
.equ GENET_STATE_PHY_SPEED,   24   /* cached PHY speed code from AUX_STS */
.equ GENET_STATE_SIZE,        32   /* padded to 8-byte alignment */
