# GENET v5 (BCM2711) Complete Initialization Trace

From `bcmgenet_open()` through first TX frame transmission.

Source: Linux kernel `bcmgenet.c`, `bcmgenet.h`, `bcmmii.c`
(driver version from linux-6.x, SPDX: GPL-2.0-only, Broadcom copyright)

## Conventions

- **GENET_BASE** = 0xFD580000 (physical), ioremap'd to virtual by Linux
- All register writes use `writel_relaxed()` (on ARM64, NOT MIPS)
  - `writel_relaxed` = `__raw_writel` + no barrier (but the store itself is
    to Device-nGnRnE memory, so it is ordered w.r.t. other Device writes)
  - NO explicit dmb/dsb in the write path itself
  - Linux ioremap maps GENET MMIO as Device-nGnRnE (non-Gathering,
    non-Reordering, non-Early-write-acknowledgement)
- All addresses in this trace are **virtual** (ioremap'd), backed by
  physical Device memory mapping with MMU **enabled**
- Offsets shown as hex from GENET_BASE
- For DMA addresses: Linux uses `dma_map_single()` which on BCM2711
  goes through the DMA-capable IOMMU or identity maps with a 0xC0000000
  bus offset stripped (BCM2711 DMA sees physical addresses with the
  upper bits masked)

## Key GENET v5 / BCM2711 Hardware Parameters

```
version              = GENET_V5
words_per_bd         = 3           (12 bytes per descriptor)
tx_queues            = 4
tx_bds_per_q         = 32
rx_queues            = 0           (BCM2711 DT: no priority RX queues)
rx_bds_per_q         = 0
TOTAL_DESC           = 256
DMA_DESC_SIZE        = 3 * 4 = 12 bytes
tbuf_offset          = 0x0600
hfb_offset           = 0x8000
hfb_reg_offset       = 0xFC00
rdma_offset          = 0x2000
tdma_offset          = 0x4000
dma_max_burst_length = 0x08        (BCM2711-specific)
flags                = GENET_HAS_40BITS | GENET_HAS_EXT |
                       GENET_HAS_MDIO_INTR | GENET_HAS_MOCA_LINK_DET
qtag_mask            = 0x3F
hfb_filter_cnt       = 48
hfb_filter_size      = 128
bp_in_en_shift       = 17
bp_in_mask           = 0x1ffff
internal_phy         = false       (BCM2711 uses external Broadcom PHY)
ephy_16nm            = false
phy_interface        = PHY_INTERFACE_MODE_RGMII_RXID
```

## Register Block Base Offsets (from GENET_BASE)

```
SYS    = 0x0000     (GENET_SYS_OFF)
GR_BR  = 0x0040     (GENET_GR_BRIDGE_OFF)
EXT    = 0x0080     (GENET_EXT_OFF)
INTRL2_0 = 0x0200   (GENET_INTRL2_0_OFF)
INTRL2_1 = 0x0240   (GENET_INTRL2_1_OFF)
RBUF   = 0x0300     (GENET_RBUF_OFF)
TBUF   = 0x0600     (tbuf_offset)
UMAC   = 0x0800     (GENET_UMAC_OFF)
RDMA   = 0x2000     (rdma_offset) -- descriptor RAM starts here
TDMA   = 0x4000     (tdma_offset) -- descriptor RAM starts here
HFB    = 0x8000     (hfb_offset)
HFB_REG = 0xFC00    (hfb_reg_offset)
```

## DMA Register Offsets (v3plus regs, after ring area)

For TDMA global registers:
```
GENET_TDMA_REG_OFF = tdma_offset + TOTAL_DESC * DMA_DESC_SIZE
                   = 0x4000 + 256 * 12 = 0x4000 + 0xC00 = 0x4C00
DMA_RINGS_SIZE     = DMA_RING_SIZE * (DESC_INDEX + 1) = 0x40 * 17 = 0x440
TDMA global base   = GENET_TDMA_REG_OFF + DMA_RINGS_SIZE
                   = 0x4C00 + 0x440 = 0x5040
```

For RDMA global registers:
```
GENET_RDMA_REG_OFF = rdma_offset + TOTAL_DESC * DMA_DESC_SIZE
                   = 0x2000 + 256 * 12 = 0x2000 + 0xC00 = 0x2C00
RDMA global base   = GENET_RDMA_REG_OFF + DMA_RINGS_SIZE
                   = 0x2C00 + 0x440 = 0x3040
```

DMA global register offsets within block (bcmgenet_dma_regs_v3plus):
```
DMA_RING_CFG      = +0x00
DMA_CTRL           = +0x04
DMA_STATUS         = +0x08
DMA_SCB_BURST_SIZE = +0x0C
DMA_ARB_CTRL       = +0x2C
DMA_PRIORITY_0     = +0x30
DMA_PRIORITY_1     = +0x34
DMA_PRIORITY_2     = +0x38
DMA_INDEX2RING_0   = +0x70
...
DMA_INDEX2RING_7   = +0x8C
```

## DMA Ring Register Offsets (v4 ring regs)

Ring N base = GENET_{T,R}DMA_REG_OFF + (DMA_RING_SIZE * N)
            = {0x4C00,0x2C00} + (0x40 * N)

Within each ring (genet_dma_ring_regs_v4):
```
TDMA_READ_PTR      / RDMA_WRITE_PTR     = +0x00
TDMA_READ_PTR_HI   / RDMA_WRITE_PTR_HI  = +0x04
TDMA_CONS_INDEX    / RDMA_PROD_INDEX     = +0x08
TDMA_PROD_INDEX    / RDMA_CONS_INDEX     = +0x0C
DMA_RING_BUF_SIZE                         = +0x10
DMA_START_ADDR                            = +0x14
DMA_START_ADDR_HI                         = +0x18
DMA_END_ADDR                              = +0x1C
DMA_END_ADDR_HI                           = +0x20
DMA_MBUF_DONE_THRESH                      = +0x24
TDMA_FLOW_PERIOD   / RDMA_XON_XOFF_THRESH = +0x28
TDMA_WRITE_PTR     / RDMA_READ_PTR       = +0x2C
TDMA_WRITE_PTR_HI  / RDMA_READ_PTR_HI    = +0x30
```

## UniMAC Register Offsets (from UMAC base = GENET_BASE + 0x0800)

These come from the Broadcom unimac.h header (not provided in the files,
values are the standard Broadcom UniMAC register map):
```
UMAC_CMD             = 0x008
UMAC_MAC0            = 0x00C      (upper 4 bytes of MAC)
UMAC_MAC1            = 0x010      (lower 2 bytes of MAC)
UMAC_MAX_FRAME_LEN   = 0x014
UMAC_EEE_CTRL        = 0x064
UMAC_EEE_LPI_TIMER   = 0x068
UMAC_TX_FLUSH        = 0x334
UMAC_MODE            = 0x044
UMAC_MIB_CTRL        = 0x580
UMAC_MDIO_CMD        = 0x614
UMAC_MPD_CTRL        = 0x620
UMAC_MDF_CTRL        = 0x650
UMAC_MDF_ADDR        = 0x654

CMD_TX_EN            = BIT(0)
CMD_RX_EN            = BIT(1)
CMD_SPEED_SHIFT      = 2
CMD_SPEED_10         = 0
CMD_SPEED_100        = 1
CMD_SPEED_1000       = 2
CMD_SPEED_MASK       = 3
CMD_SW_RESET         = BIT(13)
CMD_HD_EN            = BIT(10)
CMD_RX_PAUSE_IGNORE  = BIT(28)
CMD_TX_PAUSE_IGNORE  = BIT(29)
CMD_PROMISC          = BIT(4)
CMD_CRC_FWD          = BIT(6)
```

---

## THE TRACE

### Phase A: bcmgenet_open() entry -- Clock Enable

```c
clk_prepare_enable(priv->clk);
```

**What this does on BCM2711:**

The BCM2711 device tree declares the GENET clock as the "enet" clock
sourced from the clock controller. On the Pi 4 Linux kernel, the
`clk_prepare_enable()` call goes through the BCM2711 clock framework:

1. `clk_prepare()` -- calls the clock driver's `.prepare` callback.
   For BCM2711, the GENET clock is gated via the Clock Manager (CM)
   registers at physical 0xFE101000 area OR via the firmware mailbox.
   In practice, on Pi 4 with the Raspberry Pi firmware:
   - The clock is managed via the VideoCore firmware mailbox interface
   - A mailbox property tag `SET_CLOCK_STATE` (tag 0x00038001) is sent
     to enable clock ID 6 (EMMC/GENET clock) or similar
   - This writes to the ARM-to-VC mailbox at 0xFE00B880 (MBOX_WRITE)
   - The firmware enables the PLL and configures the clock divider

2. `clk_enable()` -- enables the clock gate.

**Register writes for clock enable:**
- Mailbox write: physical 0xFE00B880+0x20 (MBOX_WRITE register)
- Value: physical address of mailbox buffer | channel 8
- This is NOT a GENET register -- it is a platform clock operation
- No GENET registers are touched during this step

**Delays:** The mailbox call polls for completion (reads MBOX_READ
register 0xFE00B880+0x00 until response arrives). Typical latency:
a few microseconds to low milliseconds.

**Net effect:** The 250 MHz reference clock to GENET is now running.
Without this clock, all GENET register accesses would hang.

---

### Phase A.1: bcmgenet_power_up() -- SKIPPED for BCM2711

```c
if (priv->internal_phy)
    bcmgenet_power_up(priv, GENET_POWER_PASSIVE);
```

On BCM2711, `internal_phy = false`, so this entire block is **SKIPPED**.
No EXT_EXT_PWR_MGMT writes, no bcmgenet_phy_power_set() call at this
point.

---

### Phase B: bcmgenet_umac_reset()

```c
bcmgenet_umac_reset(priv);
```

**Step B.1: Read SYS_RBUF_FLUSH_CTRL**
```
READ  [GENET_BASE + 0x0000 + 0x08] = [+0x0008]   SYS_RBUF_FLUSH_CTRL
```
(bcmgenet_rbuf_ctrl_get reads SYS_RBUF_FLUSH_CTRL for GENET v5)

**Step B.2: Set BIT(1) in SYS_RBUF_FLUSH_CTRL** (assert UMAC reset)
```
WRITE [+0x0008] = (read_value | BIT(1))           SYS_RBUF_FLUSH_CTRL
```
BIT(1) = 0x02. This asserts the UniMAC software reset via the
SYS_RBUF_FLUSH_CTRL register.

**Step B.3: udelay(10)**
```
DELAY 10 us
```

**Step B.4: Clear BIT(1) in SYS_RBUF_FLUSH_CTRL** (deassert UMAC reset)
```
WRITE [+0x0008] = (read_value & ~BIT(1))          SYS_RBUF_FLUSH_CTRL
```
(Uses the `reg` variable which had BIT(1) cleared)

**Step B.5: udelay(10)**
```
DELAY 10 us
```

The UniMAC is now out of hardware reset.

---

### Phase C: init_umac() -> reset_umac()

`init_umac()` first calls `reset_umac()`:

**Step C.1: Clear SYS_RBUF_FLUSH_CTRL** (bcmgenet_rbuf_ctrl_set with 0)
```
WRITE [+0x0008] = 0x00000000                      SYS_RBUF_FLUSH_CTRL
```
(For v5, this writes to SYS block offset 0x08. This clears the
bad-default umac_sw_rst bit on some older chips; on v5 it's a
defensive clear.)

**Step C.2: udelay(10)**
```
DELAY 10 us
```

**Step C.3: (skip_umac_reset check -- default is false, so we continue)**

**Step C.4: Write CMD_SW_RESET to UMAC_CMD**
```
WRITE [+0x0800 + 0x008] = [+0x0808] = CMD_SW_RESET (0x00002000)   UMAC_CMD
```
This issues a UniMAC software reset and disables the MAC while its
registers are being programmed.

**Step C.5: udelay(2)**
```
DELAY 2 us
```

---

### Phase D: init_umac() -- remaining writes

**Step D.1: Reset MIB counters**
```
WRITE [+0x0800 + 0x580] = [+0x0D80] = 0x00000007  UMAC_MIB_CTRL
```
Value = MIB_RESET_RX | MIB_RESET_TX | MIB_RESET_RUNT = BIT(0)|BIT(2)|BIT(1) = 0x07

**Step D.2: Clear MIB reset**
```
WRITE [+0x0D80] = 0x00000000                       UMAC_MIB_CTRL
```

**Step D.3: Set max frame length**
```
WRITE [+0x0800 + 0x014] = [+0x0814] = 0x00000600   UMAC_MAX_FRAME_LEN
```
ENET_MAX_MTU_SIZE = 1500+14+4+6+4+8 = 1536 = 0x600

**Step D.4: Enable TBUF 64B (TSB)**
```
READ  [+0x0600 + 0x00] = [+0x0600]                 TBUF_CTRL
WRITE [+0x0600] = (read_value | TBUF_64B_EN)       TBUF_CTRL
```
TBUF_64B_EN = BIT(0). For v5, tbuf_offset=0x0600, TBUF_CTRL=0x00.
This enables the 64-byte Transmit Status Block prepended to each TX frame.

**Step D.5: Enable RBUF 2-byte align + 64B RSB**
```
READ  [+0x0300 + 0x00] = [+0x0300]                 RBUF_CTRL
WRITE [+0x0300] = (read_value | RBUF_ALIGN_2B | RBUF_64B_EN)  RBUF_CTRL
```
RBUF_ALIGN_2B = BIT(1), RBUF_64B_EN = BIT(0). Combined = 0x03.
The 2-byte alignment shift puts IP headers on 4-byte boundaries.
64B RSB = 64-byte Receive Status Block prepended to each RX frame.

**Step D.6: Enable RX checksum offload**
```
READ  [+0x0300 + 0x14] = [+0x0314]                 RBUF_CHK_CTRL
WRITE [+0x0314] = (read_value | RBUF_RXCHK_EN | RBUF_L3_PARSE_DIS & ~RBUF_SKIP_FCS)
```
RBUF_RXCHK_EN = BIT(0), RBUF_L3_PARSE_DIS = BIT(5). Combined with
clearing RBUF_SKIP_FCS = BIT(4) (since crc_fwd_en starts false).
Typical value written: 0x21 (bits 0 and 5 set, bit 4 clear).

**Step D.7: Set RBUF_TBUF_SIZE_CTRL to 1**
```
WRITE [+0x0300 + 0xB4] = [+0x03B4] = 0x00000001    RBUF_TBUF_SIZE_CTRL
```
(Only for v3+, which v5 is.)

**Step D.8: bcmgenet_intr_disable() -- Mask all interrupts**
```
WRITE [+0x0200 + 0x10] = [+0x0210] = 0xFFFFFFFF    INTRL2_0_CPU_MASK_SET
WRITE [+0x0200 + 0x08] = [+0x0208] = 0xFFFFFFFF    INTRL2_0_CPU_CLEAR
WRITE [+0x0240 + 0x10] = [+0x0250] = 0xFFFFFFFF    INTRL2_1_CPU_MASK_SET
WRITE [+0x0240 + 0x08] = [+0x0248] = 0xFFFFFFFF    INTRL2_1_CPU_CLEAR
```

**Step D.9: (MoCA backpressure -- SKIPPED)**
PHY_INTERFACE_MODE_RGMII_RXID != PHY_INTERFACE_MODE_MOCA, so the
backpressure vector configuration is skipped.

**Step D.10: Enable MDIO interrupts**
GENET_HAS_MDIO_INTR is set for v5, so:
```
int0_enable = UMAC_IRQ_MDIO_DONE | UMAC_IRQ_MDIO_ERROR
            = BIT(23) | BIT(24) = 0x01800000
WRITE [+0x0200 + 0x14] = [+0x0214] = 0x01800000    INTRL2_0_CPU_MASK_CLEAR
```
This unmasks MDIO completion and error interrupts.

---

### Phase E: bcmgenet_set_features() -- Read UMAC_CMD

```c
bcmgenet_set_features(dev, dev->features);
```

This is called right after init_umac(). It calls clk_prepare_enable()
again (nested ref-count, no HW effect) then:

**Step E.1: Read UMAC_CMD to check CRC_FWD**
```
READ  [+0x0808]                                     UMAC_CMD
```
Sets `priv->crc_fwd_en = !!(reg & CMD_CRC_FWD)`.
CMD_SW_RESET was set in phase C.4, so CMD_CRC_FWD (BIT(6)) is likely
clear. `crc_fwd_en = false`.

Then `clk_disable_unprepare()` (decrements refcount, clock stays on).

No register writes in this phase.

---

### Phase F: bcmgenet_set_hw_addr()

```c
bcmgenet_set_hw_addr(priv, dev->dev_addr);
```

**Step F.1: Write upper 4 bytes of MAC address**
```
WRITE [+0x0800 + 0x00C] = [+0x080C] = BE32(addr[0..3])   UMAC_MAC0
```
For example, if MAC = DC:A6:32:xx:yy:zz, value = 0xDCA632xx.

**Step F.2: Write lower 2 bytes of MAC address**
```
WRITE [+0x0800 + 0x010] = [+0x0810] = BE16(addr[4..5])    UMAC_MAC1
```
Value = 0x0000yyzz (upper 16 bits zero).

---

### Phase G: bcmgenet_dma_disable(priv, flush_rx=true)

Returns a `dma_ctrl` bitmask to be passed to `bcmgenet_enable_dma()` later.

**Step G.1: Build TDMA disable mask and disable TDMA**

```
dma_ctrl = (1 << (16 + 1)) | DMA_EN  // Ring 16 enable + DMA_EN
         = BIT(17) | BIT(0) = 0x00020001

For tx_queues=4: also set BIT(1), BIT(2), BIT(3), BIT(4)
dma_ctrl = 0x00020001 | 0x1E = 0x0002001F
```

```
READ  [+0x5040 + 0x04] = [+0x5044]                 TDMA DMA_CTRL
WRITE [+0x5044] = (read_value & ~0x0002001F)        TDMA DMA_CTRL
```
This clears DMA_EN + all ring buffer enable bits for TDMA.

**Step G.2: Build RDMA disable mask and disable RDMA**

```
dma_ctrl = (1 << (16 + 1)) | DMA_EN = 0x00020001
For rx_queues=0: no additional bits
dma_ctrl stays 0x00020001
```

```
READ  [+0x3040 + 0x04] = [+0x3044]                 RDMA DMA_CTRL
WRITE [+0x3044] = (read_value & ~0x00020001)        RDMA DMA_CTRL
```

**Step G.3: TX flush**
```
WRITE [+0x0800 + 0x334] = [+0x0B34] = 0x00000001   UMAC_TX_FLUSH
DELAY 10 us
WRITE [+0x0B34] = 0x00000000                        UMAC_TX_FLUSH
```
The TX flush pulse drains any pending frames from the UMAC TX FIFO.

**Step G.4: RX flush (flush_rx=true)**
```
READ  [+0x0008]                                     SYS_RBUF_FLUSH_CTRL
WRITE [+0x0008] = (read_value | BIT(0))             SYS_RBUF_FLUSH_CTRL
```
BIT(0) = 0x01 = RBUF flush enable. This is **different** from BIT(1)
which was the UMAC reset in phase B. BIT(0) flushes the receive buffer.

```
DELAY 10 us
WRITE [+0x0008] = read_value (original, BIT(0) cleared)   SYS_RBUF_FLUSH_CTRL
DELAY 10 us
```

**Return value:** `dma_ctrl = 0x00020001` (the RDMA mask, which is what
gets passed to `bcmgenet_enable_dma()` later).

**IMPORTANT:** The returned `dma_ctrl` is the RDMA disable mask:
`1 << (DESC_INDEX + DMA_RING_BUF_EN_SHIFT) | DMA_EN` plus any RX queue
ring enables. For BCM2711 with rx_queues=0, this is exactly 0x00020001.

---

### Phase H: bcmgenet_init_dma()

**Step H.1: Set up RX descriptor control blocks (software only)**

`priv->rx_bds = priv->base + 0x2000` (rdma_offset)
Each cb->bd_addr = priv->rx_bds + i * 12

**Step H.2: Set up TX descriptor control blocks (software only)**

`priv->tx_bds = priv->base + 0x4000` (tdma_offset)
Each cb->bd_addr = priv->tx_bds + i * 12

**Step H.3: Set RDMA SCB burst size**
```
WRITE [+0x3040 + 0x0C] = [+0x304C] = 0x00000008    RDMA DMA_SCB_BURST_SIZE
```
Value = dma_max_burst_length = 0x08 for BCM2711.

**Step H.4: bcmgenet_init_rx_queues()**

Since rx_queues=0, no priority RX queue initialization.

**Sub-step H.4a: Disable RDMA (defensive)**
```
READ  [+0x3044]                                     RDMA DMA_CTRL
```
Saves dma_enable = reg & DMA_EN (should be 0 since we disabled it).
```
WRITE [+0x3044] = (read_value & ~DMA_EN)            RDMA DMA_CTRL
```

**Sub-step H.4b: Initialize RX ring 16 (DESC_INDEX)**

Ring 16 parameters (rx_queues=0, rx_bds_per_q=0):
- start_ptr = 0 * 0 = 0
- end_ptr = TOTAL_DESC = 256
- size = GENET_Q16_RX_BD_CNT = 256 - 0*0 = 256

bcmgenet_alloc_rx_buffers() allocates skbs and DMA-maps them, then
for each of the 256 descriptors writes the DMA address into the
descriptor. Each descriptor write:

```
For i = 0..255:
  WRITE [+0x2000 + i*12 + 0x04] = dma_addr_lo      RDMA desc[i] ADDRESS_LO
  WRITE [+0x2000 + i*12 + 0x08] = dma_addr_hi       RDMA desc[i] ADDRESS_HI
```
(GENET_HAS_40BITS is set, so the high 8 bits are written too)

These are descriptor RAM writes, not register writes. They program
the hardware DMA descriptors with the physical addresses of RX buffers.

Address range: [+0x2004] through [+0x2000 + 255*12 + 0x08] = [+0x2BF8]

Then the ring registers:

RX Ring 16 base = GENET_RDMA_REG_OFF + DMA_RING_SIZE * 16
               = 0x2C00 + 0x40 * 16 = 0x2C00 + 0x400 = 0x3000

```
WRITE [+0x3000 + 0x08] = [+0x3008] = 0x00000000     RDMA ring16 PROD_INDEX
WRITE [+0x3000 + 0x0C] = [+0x300C] = 0x00000000     RDMA ring16 CONS_INDEX
WRITE [+0x3000 + 0x10] = [+0x3010] = (256 << 16) | 2048
                                    = 0x01000800     RDMA ring16 RING_BUF_SIZE
WRITE [+0x3000 + 0x28] = [+0x3028] = (5 << 16) | 16
                                    = 0x00050010     RDMA ring16 XON_XOFF_THRESH
```
DMA_FC_THRESH_LO = 5, DMA_FC_THRESH_HI = TOTAL_DESC >> 4 = 16.

```
WRITE [+0x3000 + 0x14] = [+0x3014] = 0 * 3 = 0     RDMA ring16 START_ADDR
WRITE [+0x3000 + 0x2C] = [+0x302C] = 0              RDMA ring16 READ_PTR
WRITE [+0x3000 + 0x00] = [+0x3000] = 0              RDMA ring16 WRITE_PTR
WRITE [+0x3000 + 0x1C] = [+0x301C] = 256*3 - 1 = 767 = 0x2FF
                                                      RDMA ring16 END_ADDR
```

Then coalesce settings (bcmgenet_init_rx_coalesce):
```
WRITE [+0x3000 + 0x24] = [+0x3024] = pkts           RDMA ring16 MBUF_DONE_THRESH
READ  [+0x3040 + 0x6C] = [+0x30AC]                  RDMA DMA_RING16_TIMEOUT
WRITE [+0x30AC] = (read_value & ~0xFFFF) | timeout   RDMA DMA_RING16_TIMEOUT
```

**Sub-step H.4c: Enable RX ring 16 in RING_CFG and DMA_CTRL**

```
ring_cfg = BIT(16) = 0x00010000
dma_ctrl = BIT(17) = 0x00020000    (DESC_INDEX + DMA_RING_BUF_EN_SHIFT)
```

```
WRITE [+0x3040 + 0x00] = [+0x3040] = 0x00010000     RDMA DMA_RING_CFG
```

dma_enable was 0, so DMA_EN is NOT re-added:
```
WRITE [+0x3044] = 0x00020000                         RDMA DMA_CTRL
```
Note: DMA_EN (BIT(0)) is NOT set yet. Only ring buffer enable is set.

**Step H.5: Set TDMA SCB burst size**
```
WRITE [+0x5040 + 0x0C] = [+0x504C] = 0x00000008     TDMA DMA_SCB_BURST_SIZE
```

**Step H.6: bcmgenet_init_tx_queues()**

**Sub-step H.6a: Disable TDMA (defensive)**
```
READ  [+0x5044]                                      TDMA DMA_CTRL
```
Saves dma_enable = reg & DMA_EN (should be 0).
```
WRITE [+0x5044] = (read_value & ~DMA_EN)             TDMA DMA_CTRL
```

**Sub-step H.6b: Set strict priority arbiter**
```
WRITE [+0x5040 + 0x2C] = [+0x506C] = DMA_ARBITER_SP = 0x02
                                                      TDMA DMA_ARB_CTRL
```

**Sub-step H.6c: Initialize TX priority queues 0-3**

For each queue i = 0..3:
  bcmgenet_init_tx_ring(priv, i, 32, i*32, (i+1)*32)

TX Ring i base = GENET_TDMA_REG_OFF + DMA_RING_SIZE * i
              = 0x4C00 + 0x40 * i

**Ring 0** (base = 0x4C00):
```
WRITE [+0x4C00 + 0x0C] = [+0x4C0C] = 0              TDMA ring0 PROD_INDEX
WRITE [+0x4C00 + 0x08] = [+0x4C08] = 0              TDMA ring0 CONS_INDEX
WRITE [+0x4C00 + 0x24] = [+0x4C24] = 10             TDMA ring0 MBUF_DONE_THRESH
WRITE [+0x4C00 + 0x28] = [+0x4C28] = (1536 << 16) | 0
                                    = 0x06000000     TDMA ring0 FLOW_PERIOD
```
flow_period_val = ENET_MAX_MTU_SIZE << 16 for non-ring-16 queues.
```
WRITE [+0x4C00 + 0x10] = [+0x4C10] = (32 << 16) | 2048
                                    = 0x00200800     TDMA ring0 RING_BUF_SIZE
WRITE [+0x4C00 + 0x14] = [+0x4C14] = 0*3 = 0        TDMA ring0 START_ADDR
WRITE [+0x4C00 + 0x00] = [+0x4C00] = 0               TDMA ring0 READ_PTR
WRITE [+0x4C00 + 0x2C] = [+0x4C2C] = 0               TDMA ring0 WRITE_PTR
WRITE [+0x4C00 + 0x1C] = [+0x4C1C] = 32*3 - 1 = 95 = 0x5F
                                                      TDMA ring0 END_ADDR
```

**Ring 1** (base = 0x4C40):
```
WRITE [+0x4C4C] = 0                                  TDMA ring1 PROD_INDEX
WRITE [+0x4C48] = 0                                  TDMA ring1 CONS_INDEX
WRITE [+0x4C64] = 10                                 TDMA ring1 MBUF_DONE_THRESH
WRITE [+0x4C68] = 0x06000000                          TDMA ring1 FLOW_PERIOD
WRITE [+0x4C50] = 0x00200800                          TDMA ring1 RING_BUF_SIZE
WRITE [+0x4C54] = 32*3 = 96                           TDMA ring1 START_ADDR
WRITE [+0x4C40] = 96                                  TDMA ring1 READ_PTR
WRITE [+0x4C6C] = 96                                  TDMA ring1 WRITE_PTR
WRITE [+0x4C5C] = 64*3 - 1 = 191 = 0xBF              TDMA ring1 END_ADDR
```

**Ring 2** (base = 0x4C80):
```
WRITE [+0x4C8C] = 0                                  TDMA ring2 PROD_INDEX
WRITE [+0x4C88] = 0                                  TDMA ring2 CONS_INDEX
WRITE [+0x4CA4] = 10                                 TDMA ring2 MBUF_DONE_THRESH
WRITE [+0x4CA8] = 0x06000000                          TDMA ring2 FLOW_PERIOD
WRITE [+0x4C90] = 0x00200800                          TDMA ring2 RING_BUF_SIZE
WRITE [+0x4C94] = 64*3 = 192                          TDMA ring2 START_ADDR
WRITE [+0x4C80] = 192                                 TDMA ring2 READ_PTR
WRITE [+0x4CAC] = 192                                 TDMA ring2 WRITE_PTR
WRITE [+0x4C9C] = 96*3 - 1 = 287 = 0x11F              TDMA ring2 END_ADDR
```

**Ring 3** (base = 0x4CC0):
```
WRITE [+0x4CCC] = 0                                  TDMA ring3 PROD_INDEX
WRITE [+0x4CC8] = 0                                  TDMA ring3 CONS_INDEX
WRITE [+0x4CE4] = 10                                 TDMA ring3 MBUF_DONE_THRESH
WRITE [+0x4CE8] = 0x06000000                          TDMA ring3 FLOW_PERIOD
WRITE [+0x4CD0] = 0x00200800                          TDMA ring3 RING_BUF_SIZE
WRITE [+0x4CD4] = 96*3 = 288                          TDMA ring3 START_ADDR
WRITE [+0x4CC0] = 288                                 TDMA ring3 READ_PTR
WRITE [+0x4CEC] = 288                                 TDMA ring3 WRITE_PTR
WRITE [+0x4CDC] = 128*3 - 1 = 383 = 0x17F             TDMA ring3 END_ADDR
```

**Sub-step H.6d: Initialize TX ring 16 (DESC_INDEX = 16)**

Ring 16 parameters:
- start_ptr = 4 * 32 = 128
- end_ptr = TOTAL_DESC = 256
- size = GENET_Q16_TX_BD_CNT = 256 - 4*32 = 128

TX Ring 16 base = 0x4C00 + 0x40 * 16 = 0x4C00 + 0x400 = 0x5000

```
WRITE [+0x5000 + 0x0C] = [+0x500C] = 0              TDMA ring16 PROD_INDEX
WRITE [+0x5000 + 0x08] = [+0x5008] = 0              TDMA ring16 CONS_INDEX
WRITE [+0x5000 + 0x24] = [+0x5024] = 10             TDMA ring16 MBUF_DONE_THRESH
WRITE [+0x5000 + 0x28] = [+0x5028] = 0              TDMA ring16 FLOW_PERIOD
```
For ring 16 (DESC_INDEX), flow_period_val = 0 (no rate limiting).

```
WRITE [+0x5000 + 0x10] = [+0x5010] = (128 << 16) | 2048
                                    = 0x00800800     TDMA ring16 RING_BUF_SIZE
WRITE [+0x5000 + 0x14] = [+0x5014] = 128*3 = 384 = 0x180
                                                     TDMA ring16 START_ADDR
WRITE [+0x5000 + 0x00] = [+0x5000] = 384 = 0x180    TDMA ring16 READ_PTR
WRITE [+0x5000 + 0x2C] = [+0x502C] = 384 = 0x180    TDMA ring16 WRITE_PTR
WRITE [+0x5000 + 0x1C] = [+0x501C] = 256*3 - 1 = 767 = 0x2FF
                                                     TDMA ring16 END_ADDR
```

**Sub-step H.6e: Set TX priorities**

dma_priority[0] through dma_priority[2] encode the priority of each ring.

For 4 queues (i=0..3) with GENET_Q0_PRIORITY=0:
```
DMA_PRIO_REG_INDEX(0) = 0/6 = 0     shift = (0%6)*5 = 0
DMA_PRIO_REG_INDEX(1) = 1/6 = 0     shift = (1%6)*5 = 5
DMA_PRIO_REG_INDEX(2) = 2/6 = 0     shift = (2%6)*5 = 10
DMA_PRIO_REG_INDEX(3) = 3/6 = 0     shift = (3%6)*5 = 15

dma_priority[0] = (0 << 0) | (1 << 5) | (2 << 10) | (3 << 15)
                = 0x00000000 | 0x00000020 | 0x00000800 | 0x00018000
                = 0x00018820
```

For ring 16 (DESC_INDEX):
```
DMA_PRIO_REG_INDEX(16) = 16/6 = 2   shift = (16%6)*5 = 4*5 = 20

dma_priority[2] = (4 << 20) = 0x00400000
```

dma_priority[1] = 0

```
WRITE [+0x5040 + 0x30] = [+0x5070] = 0x00018820     TDMA DMA_PRIORITY_0
WRITE [+0x5040 + 0x34] = [+0x5074] = 0x00000000     TDMA DMA_PRIORITY_1
WRITE [+0x5040 + 0x38] = [+0x5078] = 0x00400000     TDMA DMA_PRIORITY_2
```

**Sub-step H.6f: Enable TX ring config**

```
ring_cfg = BIT(0) | BIT(1) | BIT(2) | BIT(3) | BIT(16)
         = 0x0001000F

WRITE [+0x5040 + 0x00] = [+0x5040] = 0x0001000F     TDMA DMA_RING_CFG
```

**Sub-step H.6g: Enable TX DMA (conditional)**

```
dma_ctrl = BIT(1) | BIT(2) | BIT(3) | BIT(4) | BIT(17)
         = 0x0002001E
```
dma_enable was 0, so DMA_EN is NOT added:
```
WRITE [+0x5044] = 0x0002001E                         TDMA DMA_CTRL
```
Note: DMA_EN (BIT(0)) is NOT set yet. Only ring buffer enables.

---

### Phase I: bcmgenet_enable_dma(priv, dma_ctrl)

The `dma_ctrl` value passed in is the return from `bcmgenet_dma_disable()`:
`0x00020001` = BIT(17) | BIT(0) = ring 16 enable + DMA_EN.

**Step I.1: Enable RDMA**
```
READ  [+0x3044]                                      RDMA DMA_CTRL
```
Current value should be 0x00020000 (from phase H.4c).
```
reg |= 0x00020001   -> 0x00020001
WRITE [+0x3044] = 0x00020001                         RDMA DMA_CTRL
```

**THIS IS THE MOMENT RDMA IS ENABLED.** DMA_EN (BIT(0)) is now set.
The RX DMA engine begins operating. It will start filling RX
descriptors with received frames.

**Step I.2: Enable TDMA**
```
READ  [+0x5044]                                      TDMA DMA_CTRL
```
Current value should be 0x0002001E (from phase H.6g).
```
reg |= 0x00020001   -> 0x0002001F
WRITE [+0x5044] = 0x0002001F                         TDMA DMA_CTRL
```

**THIS IS THE MOMENT TDMA IS ENABLED.** DMA_EN (BIT(0)) is now set.
The TX DMA engine begins operating, but no frames are queued yet.

The final TDMA DMA_CTRL value = 0x0002001F means:
- BIT(0): DMA_EN
- BIT(1): Ring 0 buffer enable
- BIT(2): Ring 1 buffer enable
- BIT(3): Ring 2 buffer enable
- BIT(4): Ring 3 buffer enable
- BIT(17): Ring 16 buffer enable

---

### Phase J: bcmgenet_hfb_init()

```c
bcmgenet_hfb_init(priv);
```

This calls `bcmgenet_hfb_clear()` since v5 is not V1 or V2.

**Step J.1: Clear HFB_CTRL**
```
WRITE [+0xFC00 + 0x00] = [+0xFC00] = 0x00000000     HFB_REG HFB_CTRL
```

**Step J.2: Clear filter enable registers**
```
WRITE [+0xFC00 + 0x04] = [+0xFC04] = 0x00000000     HFB_REG FLT_ENABLE[0]
WRITE [+0xFC00 + 0x08] = [+0xFC08] = 0x00000000     HFB_REG FLT_ENABLE[1]
```

**Step J.3: Clear RDMA INDEX2RING mappings**

DMA_INDEX2RING_0 through DMA_INDEX2RING_7 (indices 7..14 in the enum):
Offsets in bcmgenet_dma_regs_v3plus: 0x70, 0x74, 0x78, 0x7C, 0x80, 0x84, 0x88, 0x8C

```
WRITE [+0x3040 + 0x70] = [+0x30B0] = 0              RDMA INDEX2RING_0
WRITE [+0x3040 + 0x74] = [+0x30B4] = 0              RDMA INDEX2RING_1
WRITE [+0x3040 + 0x78] = [+0x30B8] = 0              RDMA INDEX2RING_2
WRITE [+0x3040 + 0x7C] = [+0x30BC] = 0              RDMA INDEX2RING_3
WRITE [+0x3040 + 0x80] = [+0x30C0] = 0              RDMA INDEX2RING_4
WRITE [+0x3040 + 0x84] = [+0x30C4] = 0              RDMA INDEX2RING_5
WRITE [+0x3040 + 0x88] = [+0x30C8] = 0              RDMA INDEX2RING_6
WRITE [+0x3040 + 0x8C] = [+0x30CC] = 0              RDMA INDEX2RING_7
```

**Step J.4: Clear HFB filter length registers**

hfb_filter_cnt = 48, so 48/4 = 12 length registers.
HFB_FLT_LEN_V3PLUS = 0x1C

```
For i = 0..11:
  WRITE [+0xFC00 + 0x1C + i*4] = 0                  HFB_REG FLT_LEN[i]
```
Addresses: [+0xFC1C] through [+0xFC48]

**Step J.5: Clear all 48 HFB filter data blocks**

Each filter is 128 words (hfb_filter_size=128).
Filter data lives in HFB block at hfb_offset = 0x8000.

```
For f = 0..47:
  For w = 0..127:
    WRITE [+0x8000 + (f*128 + w)*4] = 0             HFB filter data
```
Address range: [+0x8000] through [+0x8000 + 48*128*4 - 4] = [+0xDFFC]

Total: 48 * 128 = 6144 writes of 0x00000000.

**Does this affect DMA operation?** No -- HFB is a receive-side filter
that steers packets to specific RX queues. With RBUF_HFB_EN cleared
(HFB_CTRL = 0), all filtering is disabled and all RX packets go to
the default ring 16. DMA itself is already running but HFB does not
gate DMA operation.

---

### Phase K: IRQ registration (no register writes)

```c
request_irq(priv->irq0, bcmgenet_isr0, ...);
request_irq(priv->irq1, bcmgenet_isr1, ...);
```

These register interrupt handlers with the kernel IRQ subsystem.
The GIC distributor/redistributor may be programmed by the generic
IRQ code, but no GENET registers are written.

---

### Phase L: bcmgenet_mii_probe() -> bcmgenet_mii_config()

```c
ret = bcmgenet_mii_probe(dev);
```

This connects to the external Broadcom PHY and then calls
`bcmgenet_mii_config(dev, true)`.

For PHY_INTERFACE_MODE_RGMII_RXID:

**Step L.1: Write SYS_PORT_CTRL**
```
port_ctrl = PORT_MODE_EXT_GPHY = 3

WRITE [+0x0000 + 0x04] = [+0x0004] = 0x00000003     SYS_PORT_CTRL
```

**Step L.2: Configure EXT_RGMII_OOB_CTRL**

`priv->ext_phy = true` (not internal, not MoCA)
`id_mode_dis = 0` (RGMII_RXID case does NOT set ID_MODE_DIS)

```
READ  [+0x0080 + 0x0C] = [+0x008C]                  EXT_RGMII_OOB_CTRL
```

Modifications:
- Clear OOB_DISABLE (BIT(5))
- Clear ID_MODE_DIS (BIT(16)) -- then OR in id_mode_dis=0, so it stays clear
- Set RGMII_MODE_EN (BIT(6)) -- for v4/v5

```
reg &= ~OOB_DISABLE;           // clear BIT(5)
reg &= ~ID_MODE_DIS;           // clear BIT(16)
reg |= 0;                      // id_mode_dis = 0 for RGMII_RXID
reg |= RGMII_MODE_EN;          // set BIT(6)

WRITE [+0x008C] = (modified reg)                     EXT_RGMII_OOB_CTRL
```

Typical value: BIT(6) set, BIT(5) and BIT(16) clear. The exact value
depends on the reset state of the register. Expected: 0x00000040 plus
any other bits that were already set (like RGMII_LINK=BIT(4) if it was
set by the bootloader).

---

### Phase L.1: bcmgenet_phy_power_set() -- called from bcmgenet_mii_probe path

For BCM2711: `GENET_IS_V4(priv)` is false, and `priv->ephy_16nm` is false.
`GENET_IS_V5(priv)` is true, but the condition is:
```c
if (GENET_IS_V4(priv) || priv->ephy_16nm)
```

This is `false || false = false`, so the function goes to the else branch:
```c
mdelay(1);
```

**Step L1.1:**
```
DELAY 1 ms
```

No register writes. For GENET v5 with external PHY (not ephy_16nm),
the EXT_GPHY_CTRL register is NOT touched because it controls the
internal PHY's power.

**IMPORTANT:** This is the actual bcmgenet_phy_power_set() behavior.
The function is called from bcmgenet_mii_probe() -> of_phy_connect() ->
PHY driver's resume path, NOT directly from bcmgenet_open().

---

### Phase M: bcmgenet_phy_pause_set()

```c
bcmgenet_phy_pause_set(dev, priv->rx_pause, priv->tx_pause);
```

This calls `phy_start_aneg()` (PHY autonegotiation restart via MDIO)
and then `bcmgenet_mac_config()` if the PHY link is currently up.

The MDIO writes go through the UniMAC MDIO controller at +0x0E14
(GENET_UMAC_OFF + UMAC_MDIO_CMD = 0x0800 + 0x614 = 0x0E14).
These are managed by the separate unimac-mdio driver, not directly
by bcmgenet.

If the link is not up yet (typical at this point), bcmgenet_mac_config()
is skipped and we proceed.

---

### Phase N: bcmgenet_netif_start()

**Step N.1: bcmgenet_set_rx_mode()**

```
READ  [+0x0808]                                      UMAC_CMD
```

If promiscuous mode is needed:
```
WRITE [+0x0808] = (read_value | CMD_PROMISC)          UMAC_CMD
WRITE [+0x0800 + 0x650] = [+0x0E50] = 0x00000000     UMAC_MDF_CTRL
```

If NOT promiscuous (normal path, assume 2 filters: broadcast + self):
```
WRITE [+0x0808] = (read_value & ~CMD_PROMISC)          UMAC_CMD
```

Then for each address (broadcast, own MAC, multicast, unicast) --
writes to UMAC_MDF_ADDR registers:
```
WRITE [+0x0E54] = (broadcast[0] << 8) | broadcast[1]  UMAC_MDF_ADDR[0]
WRITE [+0x0E58] = broadcast[2..5] packed               UMAC_MDF_ADDR[1]
WRITE [+0x0E5C] = (own_mac[0] << 8) | own_mac[1]      UMAC_MDF_ADDR[2]
WRITE [+0x0E60] = own_mac[2..5] packed                 UMAC_MDF_ADDR[3]
```

Then enable MDF filters:
```
nfilter = 2 (broadcast + own)
reg = GENMASK(16, 15) = 0x00018000
WRITE [+0x0E50] = 0x00018000                           UMAC_MDF_CTRL
```

**Step N.2: bcmgenet_enable_rx_napi() -- enable RX interrupts**

Since rx_queues=0, only ring 16 NAPI is enabled:
```
WRITE [+0x0200 + 0x14] = [+0x0214] = UMAC_IRQ_RXDMA_DONE
                                    = BIT(13) = 0x00002000
                                                       INTRL2_0_MASK_CLEAR
```
(This unmasks the RX DMA done interrupt for ring 16.)

**Step N.3: umac_enable_set(priv, CMD_TX_EN | CMD_RX_EN, true)**

This is the critical moment where the MAC starts forwarding frames.

```
READ  [+0x0808]                                        UMAC_CMD
```
If CMD_SW_RESET is still set (from phase C.4), this function returns
without writing (defensive check). **However**, by this point CMD_SW_RESET
should still be set since nothing has cleared it!

**Wait** -- let me re-examine. In reset_umac() (phase C.4), CMD_SW_RESET
was written. Nothing clears it until bcmgenet_mac_config() checks and
clears it. So at this point UMAC_CMD still has CMD_SW_RESET set.

The umac_enable_set() function checks:
```c
if (reg & CMD_SW_RESET) {
    spin_unlock_bh(&priv->reg_lock);
    return;   // <-- RETURNS WITHOUT ENABLING TX/RX!
}
```

This means TX_EN and RX_EN are NOT set here. They will be set later
when the PHY link comes up and `bcmgenet_mac_config()` is called from
`bcmgenet_mii_setup()`.

So **Step N.3 does NOT write any registers** -- it returns early.

**Step N.4: bcmgenet_enable_tx_napi() -- enable TX interrupts**

For tx_queues=4, rings 0-3:
```
WRITE [+0x0240 + 0x14] = [+0x0254] = BIT(0)=0x01     INTRL2_1_MASK_CLEAR (ring 0)
WRITE [+0x0254] = BIT(1)=0x02                          INTRL2_1_MASK_CLEAR (ring 1)
WRITE [+0x0254] = BIT(2)=0x04                          INTRL2_1_MASK_CLEAR (ring 2)
WRITE [+0x0254] = BIT(3)=0x08                          INTRL2_1_MASK_CLEAR (ring 3)
```

Ring 16 TX:
```
WRITE [+0x0200 + 0x14] = [+0x0214] = UMAC_IRQ_TXDMA_DONE
                                    = BIT(16) = 0x00010000
                                                       INTRL2_0_MASK_CLEAR
```

**Step N.5: bcmgenet_link_intr_enable()**

For external PHY (ext_phy=true):
```
int0_enable = UMAC_IRQ_LINK_EVENT = UMAC_IRQ_LINK_UP | UMAC_IRQ_LINK_DOWN
            = BIT(4) | BIT(5) = 0x30

WRITE [+0x0214] = 0x00000030                          INTRL2_0_MASK_CLEAR
```

**Step N.6: phy_start()**

This starts the PHY state machine. The PHY driver begins polling or
waiting for link. When link comes up, it calls bcmgenet_mii_setup()
which calls bcmgenet_mac_config().

---

### Phase O: bcmgenet_mac_config() -- when link comes up

This is called asynchronously from the PHY state machine when the
link is established. For Gigabit RGMII with full duplex:

**Step O.1: Build speed/duplex command bits**

For SPEED_1000:
```
cmd_bits = CMD_SPEED_1000 = 2
cmd_bits <<= CMD_SPEED_SHIFT = 2
cmd_bits = 2 << 2 = 0x08
```

For DUPLEX_FULL with default pause settings (autoneg_pause=1, rx_pause=1,
tx_pause=1), the pause negotiation result determines whether
CMD_TX_PAUSE_IGNORE or CMD_RX_PAUSE_IGNORE is set. Assume full pause:
```
cmd_bits = 0x08  (no pause ignore bits set)
```

**Step O.2: Set RGMII_LINK in EXT_RGMII_OOB_CTRL**
```
READ  [+0x008C]                                        EXT_RGMII_OOB_CTRL
reg |= RGMII_LINK (BIT(4))
WRITE [+0x008C] = (read_value | 0x10)                  EXT_RGMII_OOB_CTRL
```

**Step O.3: Update UMAC_CMD with speed/duplex**
```
READ  [+0x0808]                                        UMAC_CMD
```

Clear speed/duplex/pause fields:
```
reg &= ~((CMD_SPEED_MASK << CMD_SPEED_SHIFT) | CMD_HD_EN |
          CMD_RX_PAUSE_IGNORE | CMD_TX_PAUSE_IGNORE)
```
This clears bits [3:2] (speed), bit 10 (half-duplex), bits 28-29 (pause).

```
reg |= cmd_bits   // set new speed/duplex
```

**Step O.4: Check and clear CMD_SW_RESET**

```c
if (reg & CMD_SW_RESET) {
    reg &= ~CMD_SW_RESET;
    bcmgenet_umac_writel(priv, reg, UMAC_CMD);
    udelay(2);
    reg |= CMD_TX_EN | CMD_RX_EN;
}
bcmgenet_umac_writel(priv, reg, UMAC_CMD);
```

CMD_SW_RESET IS set (from phase C.4), so:

**Step O.4a: Clear SW_RESET and write**
```
WRITE [+0x0808] = (reg with SW_RESET cleared, speed set, no TX/RX_EN yet)
                                                       UMAC_CMD
```
Typical value: 0x00000008 (speed=1000, no SW_RESET, no TX/RX_EN yet).

**Step O.4b: udelay(2)**
```
DELAY 2 us
```

**Step O.4c: Set TX_EN and RX_EN and write**
```
reg |= CMD_TX_EN | CMD_RX_EN
     = BIT(0) | BIT(1) = 0x03

WRITE [+0x0808] = 0x0000000B                          UMAC_CMD
```
Value 0x0B = CMD_TX_EN (BIT(0)) | CMD_RX_EN (BIT(1)) | CMD_SPEED_1000 (0x08).

**THIS IS THE MOMENT THE MAC STARTS TRANSMITTING AND RECEIVING.**

The sequence is critical: DMA was already enabled (phase I), but the
MAC TX/RX paths were gated by CMD_SW_RESET. The MAC is enabled AFTER
DMA, which means DMA is ready to service the MAC immediately.

**Step O.5: EEE setup (bcmgenet_eee_enable_set)**

```c
priv->eee.eee_active = phy_init_eee(phydev, 0) >= 0;
bcmgenet_eee_enable_set(dev, ...);
```

If EEE is negotiated (common for Gigabit):
```
READ  [+0x0800 + 0x064] = [+0x0864]                   UMAC_EEE_CTRL
WRITE [+0x0864] = (read_value | EEE_EN)                UMAC_EEE_CTRL

READ  [+0x0600 + 0x14] = [+0x0614]                    TBUF_ENERGY_CTRL
WRITE [+0x0614] = (read_value | TBUF_EEE_EN | TBUF_PM_EN)
                                                       TBUF_ENERGY_CTRL

READ  [+0x0300 + 0x9C] = [+0x039C]                    RBUF_ENERGY_CTRL
WRITE [+0x039C] = (read_value | RBUF_EEE_EN | RBUF_PM_EN)
                                                       RBUF_ENERGY_CTRL
```

If EEE is NOT negotiated, the writes clear those bits instead.

---

### Phase P: First TX Frame Transmission

When the network stack calls `dev_queue_xmit()`, it invokes
`bcmgenet_xmit()`:

**Assumptions for trace:**
- Single-fragment frame (no scatter-gather)
- Queue mapping = 0 -> ring 16 (DESC_INDEX)
- Frame size = 64 bytes (minimum Ethernet frame)
- TSB (Transmit Status Block) prepended: 64 bytes

**Step P.1: bcmgenet_add_tsb()**

Software prepends a 64-byte status_64 structure to the skb data.
The TSB contains:
- tx_csum_info: checksum offload parameters
- length_status: 0 (filled by hardware)

No register writes -- this modifies the skb in memory.

**Step P.2: DMA-map the frame**

```c
mapping = dma_map_single(kdev, skb->data, size, DMA_TO_DEVICE);
```

On BCM2711, this creates a DMA-capable address. The BCM2711 has a
1:1 DMA mapping (with possible 0xC0000000 bus address translation
handled by the DMA/IOMMU layer). The DMA address is a bus address
that the GENET DMA engine can use to read from system memory.

No GENET register writes -- this is a CPU cache flush + IOMMU/SWIOTLB
operation.

**Step P.3: Write the TX descriptor**

`tx_cb_ptr->bd_addr` points to the TX descriptor for this frame.
For ring 16, the first available descriptor starts at index 128:

Descriptor address = priv->tx_bds + 128 * 12 = GENET_BASE + 0x4000 + 0x600
                   = GENET_BASE + 0x4600

```c
dmadesc_set(priv, tx_cb_ptr->bd_addr, mapping, len_stat);
```

This calls dmadesc_set_addr() then dmadesc_set_length_status():

**Step P.3a: Write DMA address low**
```
WRITE [+0x4600 + 0x04] = [+0x4604] = lower_32(dma_addr)
                                                       TDMA desc[128] ADDR_LO
```

**Step P.3b: Write DMA address high** (GENET_HAS_40BITS)
```
WRITE [+0x4600 + 0x08] = [+0x4608] = upper_32(dma_addr)
                                                       TDMA desc[128] ADDR_HI
```

**Step P.3c: Write length/status**

```
size = 64 + 64 = 128 bytes (frame + TSB)
len_stat = (128 << 16) | (0x3F << 7) | DMA_TX_APPEND_CRC | DMA_SOP | DMA_EOP

Breaking down:
  size << DMA_BUFLENGTH_SHIFT = 128 << 16 = 0x00800000
  qtag_mask << DMA_TX_QTAG_SHIFT = 0x3F << 7 = 0x1F80
  DMA_TX_APPEND_CRC = 0x0040
  DMA_SOP = 0x2000    (Start of Packet -- first and only fragment)
  DMA_EOP = 0x4000    (End of Packet -- single fragment)
  DMA_TX_DO_CSUM = 0x0010 if checksum offload (assume no for first frame)

len_stat = 0x00800000 | 0x00001F80 | 0x0040 | 0x2000 | 0x4000
         = 0x00807FC0

If checksum offload: add 0x0010 -> 0x00807FD0

WRITE [+0x4600 + 0x00] = [+0x4600] = 0x00807FC0       TDMA desc[128] LEN_STATUS
```

**Step P.4: Update producer index**

```c
ring->prod_index += 1;    // 0 + 1 = 1
ring->prod_index &= 0xFFFF;

bcmgenet_tdma_ring_writel(priv, ring->index, ring->prod_index, TDMA_PROD_INDEX);
```

```
WRITE [+0x5000 + 0x0C] = [+0x500C] = 0x00000001       TDMA ring16 PROD_INDEX
```

**THIS IS THE TRIGGER.** Writing the producer index tells the DMA engine
that a new descriptor is ready. The GENET TDMA hardware compares
PROD_INDEX with CONS_INDEX and begins DMA'ing the frame from system
memory into the GENET TX FIFO.

The DMA engine:
1. Reads the descriptor at the current READ_PTR position (desc 128)
2. Fetches the frame data from the DMA address in the descriptor
3. Strips the 64-byte TSB and uses it for checksum/status info
4. Pushes the remaining frame bytes into the UMAC TX FIFO
5. The UMAC appends CRC (DMA_TX_APPEND_CRC) and transmits on the wire
6. CONS_INDEX is incremented
7. The DMA engine signals completion via UMAC_IRQ_TXDMA_DONE interrupt

---

## Summary: Complete Register Write Sequence

### Offset Table (all from GENET_BASE = 0xFD580000)

```
Phase   Offset    Value        Register                    Delay After
-----   ------    -----        --------                    -----------
B.2     +0x0008   R|BIT(1)     SYS_RBUF_FLUSH_CTRL (set)  10 us
B.4     +0x0008   R&~BIT(1)    SYS_RBUF_FLUSH_CTRL (clr)  10 us
C.1     +0x0008   0x00000000   SYS_RBUF_FLUSH_CTRL        10 us
C.4     +0x0808   0x00002000   UMAC_CMD (SW_RESET)          2 us
D.1     +0x0D80   0x00000007   UMAC_MIB_CTRL (reset)
D.2     +0x0D80   0x00000000   UMAC_MIB_CTRL (clear)
D.3     +0x0814   0x00000600   UMAC_MAX_FRAME_LEN
D.4     +0x0600   R|BIT(0)     TBUF_CTRL (64B_EN)
D.5     +0x0300   R|0x03       RBUF_CTRL (ALIGN_2B+64B_EN)
D.6     +0x0314   R|0x21       RBUF_CHK_CTRL
D.7     +0x03B4   0x00000001   RBUF_TBUF_SIZE_CTRL
D.8a    +0x0210   0xFFFFFFFF   INTRL2_0 MASK_SET
D.8b    +0x0208   0xFFFFFFFF   INTRL2_0 CLEAR
D.8c    +0x0250   0xFFFFFFFF   INTRL2_1 MASK_SET
D.8d    +0x0248   0xFFFFFFFF   INTRL2_1 CLEAR
D.10    +0x0214   0x01800000   INTRL2_0 MASK_CLEAR (MDIO)
F.1     +0x080C   MAC[0..3]    UMAC_MAC0
F.2     +0x0810   MAC[4..5]    UMAC_MAC1
G.1     +0x5044   R&~mask      TDMA DMA_CTRL (disable)
G.2     +0x3044   R&~mask      RDMA DMA_CTRL (disable)
G.3a    +0x0B34   0x00000001   UMAC_TX_FLUSH (assert)     10 us
G.3b    +0x0B34   0x00000000   UMAC_TX_FLUSH (deassert)
G.4a    +0x0008   R|BIT(0)     SYS_RBUF_FLUSH_CTRL        10 us
G.4b    +0x0008   R (no BIT0)  SYS_RBUF_FLUSH_CTRL        10 us
H.3     +0x304C   0x00000008   RDMA SCB_BURST_SIZE
H.4a    +0x3044   R&~DMA_EN    RDMA DMA_CTRL
H.4b    [256 RX desc writes: +0x2004..+0x2BF8, addr_lo+addr_hi]
H.4c    [RX ring 16 regs: +0x3000..+0x302C, 9 writes]
H.4d    +0x3024   pkts         RDMA ring16 MBUF_DONE_THRESH
H.4e    +0x30AC   timeout      RDMA DMA_RING16_TIMEOUT
H.4f    +0x3040   0x00010000   RDMA DMA_RING_CFG
H.4g    +0x3044   0x00020000   RDMA DMA_CTRL (ring en, no DMA_EN)
H.5     +0x504C   0x00000008   TDMA SCB_BURST_SIZE
H.6a    +0x5044   R&~DMA_EN    TDMA DMA_CTRL
H.6b    +0x506C   0x00000002   TDMA DMA_ARB_CTRL (SP)
H.6c    [TX rings 0-3: ~36 writes to +0x4C00..+0x4CEC]
H.6d    [TX ring 16: 9 writes to +0x5000..+0x502C]
H.6e    +0x5070   0x00018820   TDMA DMA_PRIORITY_0
H.6f    +0x5074   0x00000000   TDMA DMA_PRIORITY_1
H.6g    +0x5078   0x00400000   TDMA DMA_PRIORITY_2
H.6h    +0x5040   0x0001000F   TDMA DMA_RING_CFG
H.6i    +0x5044   0x0002001E   TDMA DMA_CTRL (ring en, no DMA_EN)
I.1     +0x3044   0x00020001   RDMA DMA_CTRL **DMA_EN SET**
I.2     +0x5044   0x0002001F   TDMA DMA_CTRL **DMA_EN SET**
J.1     +0xFC00   0x00000000   HFB_CTRL
J.2a    +0xFC04   0x00000000   HFB FLT_ENABLE[0]
J.2b    +0xFC08   0x00000000   HFB FLT_ENABLE[1]
J.3     +0x30B0..30CC  0x0 x8  RDMA INDEX2RING 0-7
J.4     +0xFC1C..FC48  0x0 x12 HFB FLT_LEN
J.5     +0x8000..DFFC  0x0 x6144  HFB filter data
L.1     +0x0004   0x00000003   SYS_PORT_CTRL (EXT_GPHY)
L.2     +0x008C   R|BIT(6)     EXT_RGMII_OOB_CTRL        1 ms (phy_power)
N.1     +0x0808   R&~PROMISC   UMAC_CMD
N.1b    +0x0E54..0E60  MDF addr  UMAC_MDF_ADDR
N.1c    +0x0E50   filter_mask  UMAC_MDF_CTRL
N.2     +0x0214   0x00002000   INTRL2_0 MASK_CLEAR (RX)
N.3     (skipped -- CMD_SW_RESET still set)
N.4a    +0x0254   BIT(0..3)    INTRL2_1 MASK_CLEAR (TX 0-3)
N.4b    +0x0214   0x00010000   INTRL2_0 MASK_CLEAR (TX 16)
N.5     +0x0214   0x00000030   INTRL2_0 MASK_CLEAR (LINK)
--- PHY link comes up (asynchronous) ---
O.2     +0x008C   R|BIT(4)     EXT_RGMII_OOB_CTRL (LINK)
O.4a    +0x0808   speed|no_rst UMAC_CMD (SW_RESET cleared)  2 us
O.4c    +0x0808   0x0B         UMAC_CMD **TX_EN + RX_EN**
O.5     [EEE writes if negotiated]
--- First TX frame ---
P.3a    +0x4604   dma_addr_lo  TDMA desc[128] ADDR_LO
P.3b    +0x4608   dma_addr_hi  TDMA desc[128] ADDR_HI
P.3c    +0x4600   len_stat     TDMA desc[128] LEN_STATUS
P.4     +0x500C   0x00000001   TDMA ring16 PROD_INDEX **TX TRIGGER**
```

---

## Notes on Barriers

`bcmgenet_writel()` uses `writel_relaxed()` on ARM64. This means:

- **No explicit dmb/dsb** instruction in the write path
- The store is to Device-nGnRnE memory (ioremap'd), which provides:
  - Writes are non-gathering (each write hits the bus individually)
  - Writes are non-reordering (ordered with respect to other Device writes)
  - Writes are non-early-write-acknowledgement (write completes to device)
- This means Device-to-Device write ordering is guaranteed by the
  memory type, NOT by explicit barriers
- Normal memory (DMA buffer) to Device memory ordering is NOT guaranteed
  by writel_relaxed. The `dma_map_single()` call handles the cache
  maintenance (clean to PoC) before the descriptor write.
- There IS an implicit ordering: `dma_map_single()` calls a cache
  clean/flush which acts as a barrier before the descriptor writes

## Notes on DMA Address Translation

On BCM2711 (Raspberry Pi 4):

- ARM physical addresses and DMA bus addresses differ
- The BCM2711 has a "DMA to physical" address translation:
  - ARM physical 0x00000000..0x3BFFFFFF -> DMA bus 0xC0000000..0xFBFFFFFF
  - ARM physical 0x40000000..0xFFFFFFFF -> DMA bus 0x00000000..0xBFFFFFFF
- The Linux DMA framework handles this via `dma-ranges` in the device tree
- `dma_map_single()` returns a bus address suitable for the GENET DMA engine
- The Pi 4 device tree specifies: `dma-ranges = <0xc0000000 0x0 0x00000000 0x40000000>`
- So a physical address like 0x1000000 becomes DMA address 0xC1000000
- The GENET DMA engine uses these translated addresses to access system memory

## Notes on Clock Enable

On BCM2711 (Raspberry Pi 4):

- The "enet" clock is the GENET reference clock (typically 250 MHz)
- It is managed by the Raspberry Pi firmware via the mailbox interface
- `clk_prepare_enable()` sends a SET_CLOCK_STATE mailbox message
- The firmware programs the VideoCore clock manager PLL/divider
- This does NOT write to any GENET register
- The clock MUST be running before any GENET register access
- At probe time, the clock is already enabled (for `bcmgenet_set_hw_params`)
- At open time, it may have been disabled during a previous close
- The clock enable has no fixed latency -- firmware response time varies

## Critical Ordering Summary

1. Clock must be enabled FIRST (phase A)
2. UMAC reset (phases B, C) before any UMAC register configuration
3. DMA disabled (phase G) before DMA ring initialization (phase H)
4. DMA ring initialization BEFORE DMA enable (phase I)
5. DMA enable (phase I) BEFORE MAC TX/RX enable (phase O)
6. HFB init (phase J) happens AFTER DMA enable -- safe because HFB
   only steers RX packets and doesn't gate DMA
7. RGMII_OOB_CTRL (phase L) must be configured before PHY link up
8. CMD_SW_RESET must be cleared (phase O) before TX_EN/RX_EN
9. The 2 us delay between SW_RESET clear and TX_EN/RX_EN set is required
10. TX descriptor must be written BEFORE PROD_INDEX update (phase P)
