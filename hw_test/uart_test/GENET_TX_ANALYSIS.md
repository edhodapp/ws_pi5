# GENET TX Analysis: Why TX_GD_PKTS MIB Stays at 0

Comprehensive analysis of U-Boot, Linux, and bare-metal GENET TX initialization
sequences to diagnose why TX descriptors are consumed (CONS_INDEX advances) but
no packets appear on the wire (TX_GD_PKTS MIB counter stays 0).

## Table of Contents
1. [U-Boot Complete TX Init Sequence](#1-u-boot-complete-tx-init-sequence)
2. [Linux Complete TX Init Sequence](#2-linux-complete-tx-init-sequence)
3. [Comparison: Linux vs U-Boot vs Bare-Metal](#3-comparison)
4. [Specific Area Analysis](#4-specific-area-analysis)
5. [Power Management and Clock Gating](#5-power-management-and-clock-gating)
6. [GENET v5 Quirks and Workarounds](#6-genet-v5-quirks)
7. [Root Cause Analysis](#7-root-cause-analysis)
8. [Concrete Checklist](#8-concrete-checklist)

---

## 1. U-Boot Complete TX Init Sequence

GENET_BASE = 0xFD580000. All offsets are from GENET_BASE.

### Phase 1: Probe (bcmgenet_eth_probe)

```
# Read version
read  [+0x000]  SYS_REV_CTRL        (verify major == 6 for v5)

# Set port mode
write [+0x004]  SYS_PORT_CTRL       = 3 (PORT_MODE_EXT_GPHY)

# Clear RBUF flush
write [+0x008]  SYS_RBUF_FLUSH_CTRL = 0
udelay(10)

# Disable MAC
write [+0x808]  UMAC_CMD            = 0

# Soft reset with loopback
write [+0x808]  UMAC_CMD            = 0x00008200 (CMD_SW_RESET | CMD_LCL_LOOP_EN)
```

### Phase 2: Start (bcmgenet_gmac_eth_start)

#### 2a. UMAC Reset (bcmgenet_umac_reset)
```
read  [+0x008]  SYS_RBUF_FLUSH_CTRL
write [+0x008]  SYS_RBUF_FLUSH_CTRL |= 0x02 (BIT(1))
udelay(10)
write [+0x008]  SYS_RBUF_FLUSH_CTRL &= ~0x02
udelay(10)
write [+0x008]  SYS_RBUF_FLUSH_CTRL = 0
udelay(10)
write [+0x808]  UMAC_CMD            = 0
write [+0x808]  UMAC_CMD            = 0x00008200 (CMD_SW_RESET | CMD_LCL_LOOP_EN)
udelay(2)
write [+0x808]  UMAC_CMD            = 0

# Clear MIB counters
write [+0xD80]  UMAC_MIB_CTRL       = 0x07 (MIB_RESET_RX|TX|RUNT)
write [+0xD80]  UMAC_MIB_CTRL       = 0

# Max frame length
write [+0x814]  UMAC_MAX_FRAME_LEN  = 1536 (0x0600)

# RBUF_CTRL: enable 2-byte alignment
read  [+0x300]  RBUF_CTRL
write [+0x300]  RBUF_CTRL           |= 0x02 (RBUF_ALIGN_2B)

# RBUF_TBUF_SIZE_CTRL (critical!)
write [+0x3B4]  RBUF_TBUF_SIZE_CTRL = 1
```

#### 2b. Write MAC Address
```
write [+0x80C]  UMAC_MAC0           = addr[0]<<24 | addr[1]<<16 | addr[2]<<8 | addr[3]
write [+0x810]  UMAC_MAC1           = addr[4]<<8 | addr[5]
```

#### 2c. Disable DMA (bcmgenet_disable_dma)
```
read  [+0x5044] TDMA_REG_BASE+DMA_CTRL
write [+0x5044] TDMA_REG_BASE+DMA_CTRL &= ~0x01 (clear DMA_EN)
read  [+0x3044] RDMA_REG_BASE+DMA_CTRL
write [+0x3044] RDMA_REG_BASE+DMA_CTRL &= ~0x01

# TX flush
write [+0xB34]  UMAC_TX_FLUSH       = 1
udelay(10)
write [+0xB34]  UMAC_TX_FLUSH       = 0
```

#### 2d. RX Ring Init (rx_ring_init)
```
write [+0x304C] RDMA_REG_BASE+DMA_SCB_BURST_SIZE = 8

write [+0x2C14] RDMA_RING16+DMA_START_ADDR     = 0
write [+0x302C] RDMA_READ_PTR                   = 0
write [+0x3000] RDMA_WRITE_PTR                  = 0
write [+0x2C1C] RDMA_RING16+DMA_END_ADDR        = (256*12/4 - 1) = 0x2FF

# Align CONS_INDEX to PROD_INDEX (can't write PROD to 0)
read  [+0x3008] RDMA_PROD_INDEX → c_index
write [+0x300C] RDMA_CONS_INDEX                 = c_index

write [+0x2C10] RDMA_RING16+DMA_RING_BUF_SIZE  = (256<<16) | 2048 = 0x01000800
write [+0x3028] RDMA_XON_XOFF_THRESH            = (5<<16)|16 = 0x00050010

write [+0x3040] RDMA_REG_BASE+DMA_RING_CFG     = (1<<16) = 0x10000
```

#### 2e. RX Descriptors (rx_descs_init)
For each of 256 descriptors at GENET_BASE + 0x2000:
```
write [+0x2000 + i*12 + 0x04] addr_lo = lower_32(buffer_phys)
write [+0x2000 + i*12 + 0x08] addr_hi = upper_32(buffer_phys)
write [+0x2000 + i*12 + 0x00] length_status = (2048<<16) | 0x8000 (DMA_OWN)
```

#### 2f. TX Ring Init (tx_ring_init)
```
write [+0x504C] TDMA_REG_BASE+DMA_SCB_BURST_SIZE = 8

write [+0x4C14] TDMA_RING16+DMA_START_ADDR     = 0
write [+0x5000] TDMA_READ_PTR                   = 0
write [+0x502C] TDMA_WRITE_PTR                  = 0
write [+0x4C1C] TDMA_RING16+DMA_END_ADDR        = 0x2FF

# Align PROD_INDEX to CONS_INDEX (can't write CONS to 0)
read  [+0x5008] TDMA_CONS_INDEX → tx_index
write [+0x500C] TDMA_PROD_INDEX                 = tx_index

write [+0x4C24] TDMA_RING16+DMA_MBUF_DONE_THRESH = 1
write [+0x5028] TDMA_FLOW_PERIOD                = 0
write [+0x4C10] TDMA_RING16+DMA_RING_BUF_SIZE  = (256<<16) | 2048 = 0x01000800

write [+0x5040] TDMA_REG_BASE+DMA_RING_CFG     = (1<<16) = 0x10000
```

#### 2g. Enable DMA (bcmgenet_enable_dma)
```
# dma_ctrl = (1 << (16+1)) | 1 = 0x00020001
write [+0x5044] TDMA_REG_BASE+DMA_CTRL          = 0x00020001
read  [+0x3044] RDMA_REG_BASE+DMA_CTRL
write [+0x3044] RDMA_REG_BASE+DMA_CTRL          |= 0x00020001
```

#### 2h. Adjust Link
```
# RGMII OOB: clear OOB_DISABLE, set RGMII_LINK | RGMII_MODE_EN
read  [+0x08C]  EXT_RGMII_OOB_CTRL
write [+0x08C]  EXT_RGMII_OOB_CTRL = (val & ~0x20) | 0x50
# If RGMII (no internal delay): also set ID_MODE_DIS (bit 16)
write [+0x08C]  EXT_RGMII_OOB_CTRL |= 0x10000

# Set speed (speed alone, no other bits)
write [+0x808]  UMAC_CMD            = speed << 2
```

#### 2i. Enable TX/RX
```
read  [+0x808]  UMAC_CMD
write [+0x808]  UMAC_CMD            |= 0x03 (CMD_TX_EN | CMD_RX_EN)
```

### U-Boot TX Descriptor Format (bcmgenet_gmac_eth_send)
```
Offset 0x04: addr_lo    = lower_32(packet_phys_addr)
Offset 0x08: addr_hi    = upper_32(packet_phys_addr)
Offset 0x00: len_status = (length << 16) | (0x3F << 7) | DMA_TX_APPEND_CRC | DMA_SOP | DMA_EOP
                        = (length << 16) | 0x1FC0 | 0x0040 | 0x2000 | 0x4000
                        = (length << 16) | 0x7FC0
```

Key: QTAG field = 0x3F << 7 = 0x1F80. This is `qtag_mask << DMA_TX_QTAG_SHIFT`.
No DMA_OWN bit set for TX.

---

## 2. Linux Complete TX Init Sequence

### Phase 1: Probe (bcmgenet_probe)
```
# Clock enable
clk_prepare_enable(clk)   ← CRITICAL: enables GENET clock domain

# Set version/params
priv->version = GENET_V5
priv->dma_max_burst_length = 0x08  (BCM2711-specific, capped at 8)

# bcmgenet_set_hw_params: sets register tables for v4+ ring layout
# For v5: words_per_bd = 3, tdma_offset = 0x4000, rdma_offset = 0x2000
#          tbuf_offset = 0x0600, GENET_HAS_40BITS = 1

# Power up internal PHY (skipped for Pi 4 — external RGMII PHY)
```

### Phase 2: Open (bcmgenet_open)
```
# Turn on clock
clk_prepare_enable(clk)   ← "enet" clock

# Power up (skipped for external PHY on Pi 4)
```

#### 2a. UMAC Reset (bcmgenet_umac_reset)
```
read  [+0x008]  SYS_RBUF_FLUSH_CTRL
write [+0x008]  SYS_RBUF_FLUSH_CTRL |= 0x02
udelay(10)
write [+0x008]  SYS_RBUF_FLUSH_CTRL &= ~0x02
udelay(10)
```
Note: Linux does NOT write SYS_RBUF_FLUSH_CTRL=0 third time (U-Boot does).

#### 2b. init_umac → reset_umac
```
# Clear bad default
write [+0x008]  SYS_RBUF_FLUSH_CTRL = 0
udelay(10)

# Soft reset
write [+0x808]  UMAC_CMD            = 0x2000 (CMD_SW_RESET only, NO loopback)
udelay(2)
```

#### 2c. init_umac continued
```
# Clear MIB counters
write [+0xD80]  UMAC_MIB_CTRL       = 0x07
write [+0xD80]  UMAC_MIB_CTRL       = 0

# Max frame length
write [+0x814]  UMAC_MAX_FRAME_LEN  = 1536

#############################################
# CRITICAL: Enable TSB (Transmit Status Block)
#############################################
read  [+0x600]  TBUF_CTRL
write [+0x600]  TBUF_CTRL           |= 0x01 (TBUF_64B_EN)

# Enable RSB (Receive Status Block) + 2B alignment
read  [+0x300]  RBUF_CTRL
write [+0x300]  RBUF_CTRL           |= 0x03 (RBUF_64B_EN | RBUF_ALIGN_2B)

# Enable RX checksumming
read  [+0x314]  RBUF_CHK_CTRL
write [+0x314]  RBUF_CHK_CTRL       |= 0x21 (RBUF_RXCHK_EN | RBUF_L3_PARSE_DIS)

# RBUF_TBUF_SIZE_CTRL
write [+0x3B4]  RBUF_TBUF_SIZE_CTRL = 1

# Mask all interrupts
write [+0x210]  INTRL2_0_MASK_SET   = 0xFFFFFFFF
write [+0x208]  INTRL2_0_CLEAR      = 0xFFFFFFFF
write [+0x250]  INTRL2_1_MASK_SET   = 0xFFFFFFFF
write [+0x248]  INTRL2_1_CLEAR      = 0xFFFFFFFF

# Enable MDIO interrupts (GENETv3+)
write [+0x214]  INTRL2_0_MASK_CLEAR = (1<<23)|(1<<24)
```

#### 2d. Set Features
```
read  [+0x808]  UMAC_CMD → check CMD_CRC_FWD bit
```

#### 2e. Write MAC Address
```
write [+0x80C]  UMAC_MAC0
write [+0x810]  UMAC_MAC1
```

#### 2f. Disable DMA (bcmgenet_dma_disable)
```
# Build full disable mask: ring 16 + rings 0-3 + DMA_EN
dma_ctrl = (1<<17) | (1<<2) | (1<<3) | (1<<4) | (1<<5) | 1 = 0x0002003F

read  [+0x5044] TDMA DMA_CTRL
write [+0x5044] TDMA DMA_CTRL &= ~dma_ctrl

read  [+0x3044] RDMA DMA_CTRL
write [+0x3044] RDMA DMA_CTRL &= ~dma_ctrl

# TX flush
write [+0xB34]  UMAC_TX_FLUSH       = 1
udelay(10)
write [+0xB34]  UMAC_TX_FLUSH       = 0

# RX flush
read  [+0x008]  SYS_RBUF_FLUSH_CTRL
write [+0x008]  SYS_RBUF_FLUSH_CTRL |= 0x01 (BIT(0))
udelay(10)
write [+0x008]  SYS_RBUF_FLUSH_CTRL &= ~0x01
udelay(10)
```

#### 2g. Init DMA (bcmgenet_init_dma)
```
# RDMA SCB burst size
write [+0x304C] RDMA DMA_SCB_BURST_SIZE = 0x08

# (init RX queues - ring 16 only for Pi 4 since rx_queues=0)

# TDMA SCB burst size
write [+0x504C] TDMA DMA_SCB_BURST_SIZE = 0x08

# (init TX queues)
```

#### 2h. Init TX Queue 16 (bcmgenet_init_tx_ring, index=16)

For v4/v5, ring 16 register base = GENET_TDMA_REG_OFF + 16 * 0x40
= 0x4000 + 256*12 + 16*0x40 = 0x4C00 + 0x400 = BUT WAIT...

Actually: GENET_TDMA_REG_OFF = tdma_offset + TOTAL_DESC * DMA_DESC_SIZE
= 0x4000 + 256 * 12 = 0x4000 + 0xC00 = 0x4C00.
Ring 16 offset = 0x4C00 + 16 * 0x40 = 0x4C00 + 0x400 = 0x5000.

v4 ring register mapping (genet_dma_ring_regs_v4):
```
TDMA_READ_PTR      = ring_base + 0x00
TDMA_READ_PTR_HI   = ring_base + 0x04
TDMA_CONS_INDEX    = ring_base + 0x08
TDMA_PROD_INDEX    = ring_base + 0x0C
DMA_RING_BUF_SIZE  = ring_base + 0x10
DMA_START_ADDR     = ring_base + 0x14
DMA_START_ADDR_HI  = ring_base + 0x18
DMA_END_ADDR       = ring_base + 0x1C
DMA_END_ADDR_HI    = ring_base + 0x20
DMA_MBUF_DONE_THRESH = ring_base + 0x24
TDMA_FLOW_PERIOD   = ring_base + 0x28
TDMA_WRITE_PTR     = ring_base + 0x2C
TDMA_WRITE_PTR_HI  = ring_base + 0x30
```

For ring 16 at base 0x5000:
```
write [+0x500C] TDMA_PROD_INDEX    = 0
write [+0x5008] TDMA_CONS_INDEX    = 0
write [+0x5024] DMA_MBUF_DONE_THRESH = 10   ← NOTE: 10, not 1!
write [+0x5028] TDMA_FLOW_PERIOD   = 0      (no rate control for ring 16)
write [+0x5010] DMA_RING_BUF_SIZE  = (256<<16)|2048 = 0x01000800
                ^^^ if GENET_Q16_TX_BD_CNT = 128 (256 - 4*32), then:
                    = (128<<16)|2048 = 0x00800800

# For ring 16 with start_ptr=128, end_ptr=256, words_per_bd=3:
write [+0x5014] DMA_START_ADDR     = 128 * 3 = 384 = 0x180
write [+0x5000] TDMA_READ_PTR      = 128 * 3 = 384
write [+0x502C] TDMA_WRITE_PTR     = 128 * 3 = 384
write [+0x501C] DMA_END_ADDR       = 256 * 3 - 1 = 767 = 0x2FF
```

**HOWEVER** — Linux has 4 priority queues (tx_queues=4, tx_bds_per_q=32),
so ring 16 only gets descriptors 128-255. The first 128 are split among rings 0-3.

For a minimal bare-metal driver using only ring 16 with ALL 256 descriptors:
```
start_ptr = 0, end_ptr = 256, words_per_bd = 3
write [+0x500C] TDMA_PROD_INDEX    = 0
write [+0x5008] TDMA_CONS_INDEX    = 0
write [+0x5024] DMA_MBUF_DONE_THRESH = 10
write [+0x5028] TDMA_FLOW_PERIOD   = 0
write [+0x5010] DMA_RING_BUF_SIZE  = (256<<16)|2048 = 0x01000800
write [+0x5014] DMA_START_ADDR     = 0
write [+0x5000] TDMA_READ_PTR      = 0
write [+0x502C] TDMA_WRITE_PTR     = 0
write [+0x501C] DMA_END_ADDR       = 256*3 - 1 = 767 = 0x2FF
```

#### 2i. Init TX Queues (bcmgenet_init_tx_queues)
```
# Set strict priority arbiter
write [+0x506C] TDMA DMA_ARB_CTRL  = 0x02 (DMA_ARBITER_SP)

# Set priority registers (for ring 16 only)
write [+0x5070] TDMA DMA_PRIORITY_0 = ...
write [+0x5074] TDMA DMA_PRIORITY_1 = ...
write [+0x5078] TDMA DMA_PRIORITY_2 = ...

# Enable ring 16
write [+0x5040] TDMA DMA_RING_CFG   = (1<<16) = 0x10000

# Enable DMA
write [+0x5044] TDMA DMA_CTRL       = (1<<17) | DMA_EN = 0x00020001
```

Wait — the DMA_CTRL actually accumulates ring enables.
For Linux with rings 0-3 + 16: `(1<<17)|(1<<2)|(1<<3)|(1<<4)|(1<<5)|1 = 0x0002003F`

For bare-metal with ring 16 only: `(1<<17)|1 = 0x00020001`

#### 2j. Enable DMA (bcmgenet_enable_dma)
```
# Re-enable with the full ring enable mask
read  [+0x3044] RDMA DMA_CTRL
write [+0x3044] RDMA DMA_CTRL |= dma_ctrl

read  [+0x5044] TDMA DMA_CTRL
write [+0x5044] TDMA DMA_CTRL |= dma_ctrl
```

#### 2k. HFB Init
```
# Disable all HFB filters, clear filter memory
```

#### 2l. PHY Connect + MII Config
```
# bcmgenet_mii_config:
write [+0x004]  SYS_PORT_CTRL = PORT_MODE_EXT_GPHY (3)

# For external RGMII PHY:
read  [+0x08C]  EXT_RGMII_OOB_CTRL
write [+0x08C]  EXT_RGMII_OOB_CTRL &= ~OOB_DISABLE (clear bit 5)
write [+0x08C]  EXT_RGMII_OOB_CTRL |= RGMII_MODE_EN (bit 6)
# For RGMII (no delay): set ID_MODE_DIS (bit 16)
write [+0x08C]  EXT_RGMII_OOB_CTRL |= ID_MODE_DIS (bit 16)
```

#### 2m. bcmgenet_netif_start
```
# Set RX mode (promiscuous or MDF filters)
read  [+0x808]  UMAC_CMD
write [+0x808]  UMAC_CMD |= CMD_PROMISC (bit 4) if needed

# Enable TX + RX
read  [+0x808]  UMAC_CMD
# Verify CMD_SW_RESET is clear, then:
write [+0x808]  UMAC_CMD |= CMD_TX_EN | CMD_RX_EN
```

#### 2n. Link Up Callback (bcmgenet_mac_config)
```
# Set RGMII_LINK
read  [+0x08C]  EXT_RGMII_OOB_CTRL
write [+0x08C]  EXT_RGMII_OOB_CTRL |= RGMII_LINK (bit 4)

# Set speed + duplex in UMAC_CMD
read  [+0x808]  UMAC_CMD
# Clear speed bits, HD_EN, PAUSE_IGNORE bits
# Set new speed, pause settings
write [+0x808]  UMAC_CMD = <new value>
# If CMD_SW_RESET was set, clear it, then also set TX_EN|RX_EN
```

### Linux TX Descriptor Format (bcmgenet_xmit)

**Critical difference from U-Boot**: Linux prepends a 64-byte TSB
(Transmit Status Block) to the packet data when TBUF_64B_EN is set.

```
# TSB is prepended to packet data in memory (64 bytes)
# Then the DMA descriptor points to the start of the TSB+packet:

Offset 0x04: addr_lo    = lower_32(dma_addr)  ← points to TSB+data
Offset 0x08: addr_hi    = upper_32(dma_addr)  ← only if GENET_HAS_40BITS
Offset 0x00: len_status = (size << 16) | (qtag_mask << 7) | DMA_TX_APPEND_CRC
                         | DMA_SOP (first frag) | DMA_EOP (last frag)
                         | DMA_TX_DO_CSUM (if checksum offload)
```

`qtag_mask` for v5 = 0x3F, so `0x3F << 7 = 0x1F80`.

**No DMA_OWN bit is set for TX descriptors** in either Linux or U-Boot.
The hardware uses PROD_INDEX/CONS_INDEX to determine which descriptors to process.

---

## 3. Comparison

### What Linux does that U-Boot does NOT:

| Register | Offset | Linux | U-Boot | Bare-metal |
|----------|--------|-------|--------|------------|
| **TBUF_CTRL** | **+0x600** | **Sets TBUF_64B_EN (bit 0)** | **MISSING** | **MISSING** |
| **RBUF_CTRL** | +0x300 | Sets RBUF_64B_EN + RBUF_ALIGN_2B (0x03) | Only RBUF_ALIGN_2B (0x02) | 0xC043 |
| reset_umac | +0x808 | CMD_SW_RESET only (0x2000) | CMD_SW_RESET\|CMD_LCL_LOOP_EN | CMD_SW_RESET\|CMD_LCL_LOOP |
| DMA_ARB_CTRL | +0x506C | DMA_ARBITER_SP (0x02) | Not written | Not written |
| DMA_PRIORITY | +0x5070 | Written | Not written | Not written |
| PROD/CONS init | | Writes both to 0 | Reads CONS, aligns PROD | Reads CONS, aligns PROD |
| MBUF_DONE_THRESH | +0x5024 | 10 | 1 | 1 |
| RBUF_CHK_CTRL | +0x314 | RXCHK_EN\|L3_PARSE_DIS | Not written | Not written |
| RX flush | +0x008 | BIT(0) toggle | Not done | Not done |
| TX flush | +0xB34 | Done in dma_disable | Done in disable_dma | Done in init |

### What U-Boot does that Linux does NOT:
- Nothing significant for TX. They are very similar in structure.

### What bare-metal is MISSING vs both:

**TBUF_CTRL (0x600) — TBUF_64B_EN is NOT set.**

This is the single most important finding. However, there is a subtlety:

**If TBUF_64B_EN is set, the hardware expects the first 64 bytes of each TX buffer
to be a Transmit Status Block (TSB).** The DMA will interpret those 64 bytes as
control information (checksum offsets, etc.) and not transmit them on the wire.

**If TBUF_64B_EN is NOT set (U-Boot's case), the hardware does NOT expect a TSB,
and the packet data starts immediately at the DMA address.**

So the question is: **does U-Boot work without TBUF_64B_EN?** Yes, it does!
U-Boot does NOT set TBUF_64B_EN and does NOT prepend a TSB. It transmits
raw packet data directly.

This means TBUF_64B_EN is **not** the root cause. Our bare-metal code also
does not set it and does not prepend a TSB, which matches U-Boot.

---

## 4. Specific Area Analysis

### 4a. TDMA DMA Descriptor Format

For GENET v5 (GENET_HAS_40BITS), each descriptor is 3 words (12 bytes):

```
+0x00: length_status   (u32)
+0x04: address_lo      (u32) — lower 32 bits of physical address
+0x08: address_hi      (u32) — upper 32 bits of physical address
```

**Our code writes addr_hi = 0, which is correct** since Pi 4 ARM memory is in the
lower 4 GB. Both U-Boot and Linux write upper_32_bits() which would be 0.

The length_status field for TX:
```
Bits [31:16]: buffer length in bytes
Bits [15:14]: DMA_OWN=0x8000 (NOT used for TX), DMA_EOP=0x4000
Bit  [13]:    DMA_SOP=0x2000
Bit  [12]:    DMA_WRAP=0x1000 (NOT used in ring mode)
Bits [11:7]:  QTAG = qtag_mask (0x3F for v5, shifted by 7)
Bit  [6]:     DMA_TX_APPEND_CRC=0x0040
Bit  [5]:     DMA_TX_OW_CRC=0x0020
Bit  [4]:     DMA_TX_DO_CSUM=0x0010
```

**Our bare-metal TX_LEN_STATUS_FLAGS = 0x7FC0**:
- Bits 14-13: SOP|EOP = 0x6000
- Bits 12-7: QTAG = 0x1FC0... wait, let's check:
  0x7FC0 = 0111_1111_1100_0000
  - Bit 14 (EOP) = 1
  - Bit 13 (SOP) = 1
  - Bit 12 (WRAP) = 1  ← **PROBLEM?** DMA_WRAP should NOT be set!
  - Bits 11-7: QTAG = 11111 = 0x1F (but v5 qtag_mask is 0x3F)
  - Bit 6: APPEND_CRC = 1
  - Bits 5-0: 0

Wait: 0x7FC0:
```
0x7FC0 = 0111 1111 1100 0000
bit 14 = 1 (EOP)
bit 13 = 1 (SOP)
bit 12 = 1 (WRAP)  ← DMA_WRAP=0x1000, this IS set!
bit 11 = 1
bit 10 = 1
bit 9  = 1
bit 8  = 1
bit 7  = 1
bit 6  = 1 (APPEND_CRC)
```

**ANALYSIS**: U-Boot sets `0x3F << 7 = 0x1F80`, plus `DMA_SOP|DMA_EOP|DMA_TX_APPEND_CRC
= 0x2000|0x4000|0x0040 = 0x6040`. Total = `0x1F80 | 0x6040 = 0x7FC0`.

So bits 12-7: `0x1F80 >> 7 = 0x3F`. The QTAG field is bits [12:7], which overlaps
with the DMA_WRAP bit position. The QTAG value 0x3F means bits 12:7 = `0b111111`.
Bit 12 being set is part of the QTAG field, NOT the DMA_WRAP flag. The DMA_WRAP
bit is only meaningful for RX; for TX, those bit positions are the QTAG field.

So **TX_LEN_STATUS_FLAGS = 0x7FC0 is correct** and matches U-Boot exactly.

### 4b. TBUF Block (GENET + 0x600)

For GENET v5, tbuf_offset = 0x0600. Registers:

| Offset | Register | Description |
|--------|----------|-------------|
| +0x600 | TBUF_CTRL | Bit 0: TBUF_64B_EN (enable 64B TSB) |
| +0x60C | TBUF_BP_MC | Backpressure/MoCA control |
| +0x614 | TBUF_ENERGY_CTRL | Bit 0: TBUF_EEE_EN, Bit 1: TBUF_PM_EN |

**Linux writes**: TBUF_CTRL |= TBUF_64B_EN (but only for TSB checksum offload)
**U-Boot does NOT write any TBUF registers**.
**Our code does NOT write any TBUF registers**.

Since U-Boot works without TBUF_64B_EN, this is not the cause.

### 4c. EXT Block (GENET + 0x80)

| Offset | Register | Description |
|--------|----------|-------------|
| +0x080 | EXT_EXT_PWR_MGMT | Power management bits (see below) |
| +0x08C | EXT_RGMII_OOB_CTRL | RGMII out-of-band control |
| +0x09C | EXT_GPHY_CTRL | Internal GPHY control (v4+) |

**EXT_RGMII_OOB_CTRL (0x08C)**:
- Bit 4: RGMII_LINK — **MUST be set** for TX to work!
- Bit 5: OOB_DISABLE — **MUST be clear**
- Bit 6: RGMII_MODE_EN — **MUST be set** for external PHY
- Bit 16: ID_MODE_DIS — Set for RGMII (no delay)

Our code writes 0x00F00050:
```
0x00F00050 = bit 4 (RGMII_LINK) | bit 6 (RGMII_MODE_EN) | bits 20-23
```
Wait: 0x00F00050 = 0000_0000_1111_0000_0000_0000_0101_0000
- Bit 4: RGMII_LINK = 1 (good)
- Bit 5: OOB_DISABLE = 0 (good)
- Bit 6: RGMII_MODE_EN = 1 (good)
- Bit 16: ID_MODE_DIS = 0 (NOT set — means internal delay enabled)
- Bits 20-23: 0xF (unknown bits — copied from PiOS?)

This looks acceptable. The ID_MODE_DIS=0 means GENET adds TX delay, which is
correct for RGMII_TXID mode (Pi 4's default).

**EXT_EXT_PWR_MGMT (0x080)**:

For GENET v5, Linux's bcmgenet_power_up(PASSIVE) clears:
```
EXT_PWR_DOWN_PHY_EN  (bit 20)
EXT_PWR_DOWN_PHY_RD  (bit 19)
EXT_PWR_DOWN_PHY_SD  (bit 18)
EXT_PWR_DOWN_PHY_RX  (bit 17)
EXT_PWR_DOWN_PHY_TX  (bit 16) ← CRITICAL: TX PHY power!
EXT_IDDQ_GLBL_PWR    (bit 7)
EXT_PWR_DOWN_DLL     (bit 1)
EXT_PWR_DOWN_BIAS    (bit 0)
```

**FINDING**: If EXT_PWR_DOWN_PHY_TX (bit 16) is set, the PHY TX is powered down!
Linux explicitly clears this. U-Boot does NOT touch EXT_EXT_PWR_MGMT at all.
Our bare-metal code does NOT touch it either.

**However**, this register controls the *internal* PHY. The Pi 4 uses an
*external* BCM54213PE PHY. The power_up function is only called when
`priv->internal_phy` is true OR for `GENET_POWER_PASSIVE` mode in open().

Actually, looking more carefully: `bcmgenet_power_up` checks
`if (!(priv->hw_params->flags & GENET_HAS_EXT)) return;` — for v5,
GENET_HAS_EXT IS set, so it would proceed. But it's only called if
`priv->internal_phy` is true. For Pi 4 with external RGMII PHY,
this is NOT called during open().

So EXT_EXT_PWR_MGMT should already be in a good state from the firmware/bootloader.

### 4d. UMAC TX Path Registers

Beyond UMAC_CMD, these UMAC registers affect TX:

| Offset (from UMAC) | Absolute | Register | Notes |
|-----|----------|----------|-------|
| 0x008 | 0x808 | UMAC_CMD | TX_EN, speed, pause control |
| 0x014 | 0x814 | UMAC_MAX_FRAME_LEN | Max TX frame size |
| 0x018 | 0x818 | UMAC_PAUSE_QUANTA | Pause frame quanta |
| 0x05C | 0x85C | UMAC_TX_IPG_LEN | TX inter-packet gap |
| 0x310 | 0xB10 | UMAC_MACSEC_PROG_TX_CRC | MACSEC TX CRC |
| 0x314 | 0xB14 | UMAC_MACSEC_CTRL | MACSEC control |
| 0x330 | 0xB30 | UMAC_PAUSE_CTRL | Pause frame control |
| 0x334 | 0xB34 | UMAC_TX_FLUSH | TX FIFO flush |
| 0x33C | 0xB3C | UMAC_TX_FIFO_STATUS | TX FIFO status (RO) |

Neither Linux nor U-Boot explicitly initializes TX_IPG_LEN, PAUSE_QUANTA,
or PAUSE_CTRL during init — these use hardware defaults.

**UMAC_CMD bits affecting TX**:
- Bit 0: CMD_TX_EN
- Bits 3:2: CMD_SPEED (must match PHY)
- Bit 5: CMD_PAD_EN (pad short frames)
- Bit 6: CMD_CRC_FWD (forward CRC to DMA)
- Bit 8: CMD_RX_PAUSE_IGNORE
- Bit 28: CMD_TX_PAUSE_IGNORE

### 4e. DMA_SCB_BURST_SIZE

Both Linux (BCM2711) and U-Boot use value **8** (0x08).

Our bare-metal code: `DMA_BURST_SIZE = 8` — **correct**.

The generic GENETv5 Linux driver uses `DMA_MAX_BURST_LENGTH = 0x08`, and the
BCM2711-specific variant caps it at 0x08. So 8 is the right value.

### 4f. Descriptor Address Format (40-bit)

For GENET v5 with GENET_HAS_40BITS, descriptors are 12 bytes (3 words):
```
+0: length_status (u32)
+4: address_lo    (u32)
+8: address_hi    (u32)
```

Linux only writes addr_hi when `CONFIG_PHYS_ADDR_T_64BIT` is set AND
`GENET_HAS_40BITS` is in flags. On a 32-bit system or when the address is
in the low 4 GB, addr_hi = 0.

**Our code writes addr_hi = 0, which is correct for Pi 4** (all RAM is below 4 GB
from the GENET's perspective).

**Critical**: The START_ADDR and END_ADDR for rings use word counts
(words_per_bd * descriptor_index), NOT byte offsets. For v5, words_per_bd = 3.
So END_ADDR = 256 * 3 - 1 = 767 = 0x2FF. Our code computes
`DMA_DESC_COUNT * DMA_DESC_SIZE / 4 - 1 = 256 * 12 / 4 - 1 = 767`. **Correct**.

### 4g. Flow Control / Pause Frames

**Could pause frames block TX?**

If the link partner is sending PAUSE frames and our UMAC is NOT ignoring them,
TX could be paused indefinitely.

U-Boot: writes `speed << CMD_SPEED_SHIFT` to UMAC_CMD, clearing ALL other bits
including CMD_RX_PAUSE_IGNORE and CMD_TX_PAUSE_IGNORE. This means **pause frames
are honored** — but it works in practice because the link partner (a switch)
typically doesn't send PAUSE unless it's congested.

Our code: same as U-Boot, does not set PAUSE_IGNORE bits.

Linux: default is `priv->tx_pause = 1; priv->rx_pause = 1;` (honor pause).

**Unlikely to be the root cause** unless the switch is actively sending PAUSE,
but worth checking: read UMAC_PAUSE_CTRL and RX_FIFO_STATUS.

---

## 5. Power Management and Clock Gating

### Clocks

Linux calls `clk_prepare_enable(priv->clk)` for the "enet" clock.

On Pi 4 with firmware boot, the GENET clock is typically already enabled by
the VideoCore firmware. **If the firmware has not enabled the clock, the GENET
registers will read as 0 or return bus errors.**

Since RX works, the clock is clearly enabled. The GENET block is powered.

### EXT_GPHY_CTRL (0x09C)

For GENETv4+ with internal GPHY, this register controls:
- EXT_CK25_DIS (bit 4): 25 MHz clock disable
- EXT_CFG_IDDQ_BIAS (bit 0): IDDQ bias
- EXT_CFG_PWR_DOWN (bit 1): Power down
- EXT_GPHY_RESET (bit 5): GPHY reset

**Not relevant for Pi 4 with external PHY** — the BCM54213PE has its own crystal.

### No TX-specific Power Gate

There is no GENET_PCGCCTL or separate TX power gate register. The GENET block
is monolithic — if RX works, the TX datapath hardware is also powered.

---

## 6. GENET v5 / BCM2711 Quirks

1. **DMA burst length**: BCM2711 uses 0x08 (not the generic 0x08 — same value).

2. **Link interrupt at 10 Mbps**: Internal PHY can't signal link UP at 10 Mbps.
   Not relevant for external PHY.

3. **40-bit addressing**: v5 has 3-word descriptors. Must write all 3 words.

4. **Ring register layout**: v4/v5 use genet_dma_ring_regs_v4 which has _HI
   registers interspersed (READ_PTR_HI at +0x04, etc.), shifting all other
   register offsets compared to v1-v3.

5. **TSB/RSB**: When TBUF_64B_EN is set, hardware expects 64-byte TSB prepended.
   When RBUF_64B_EN is set, hardware prepends 64-byte RSB. U-Boot does NOT use
   TSB but DOES set RBUF_ALIGN_2B (not RBUF_64B_EN).

---

## 7. Root Cause Analysis

### Symptom Recap
- TX descriptors are consumed (CONS_INDEX advances to match PROD_INDEX)
- TX_GD_PKTS MIB counter stays at 0
- RX works
- CONS_INDEX advancing means the DMA engine IS reading descriptors

### Possible Causes, Ranked by Likelihood

#### CAUSE 1: UMAC_CMD Speed Bits Incorrect (HIGH PROBABILITY)

Our code uses these speed bit definitions:
```
UMAC_CMD_SPEED_100  = (1 << 2) = 0x04
UMAC_CMD_SPEED_1000 = (1 << 3) = 0x08
```

But the correct encoding from the unimac.h header is:
```
CMD_SPEED_SHIFT = 2
CMD_SPEED_MASK  = 3
CMD_SPEED_10    = 0
CMD_SPEED_100   = 1
CMD_SPEED_1000  = 2
CMD_SPEED_2500  = 3
```

So the correct values are:
```
Speed 10:   (0 << 2) = 0x00
Speed 100:  (1 << 2) = 0x04
Speed 1000: (2 << 2) = 0x08
```

Wait — our definitions happen to match:
- UMAC_CMD_SPEED_100 = 0x04 = (1 << 2) = correct for 100 Mbps
- UMAC_CMD_SPEED_1000 = 0x08 = (2 << 2) = correct for 1000 Mbps

So the speed encoding is actually correct. Let me check the code flow more
carefully. Our code reads AUX_STS register bits [10:8] and maps:
- 7 or 6 → 1000 Mbps
- 5 or 3 → 100 Mbps
- else → 10 Mbps (speed=0)

BCM54213PE AUX_STS (reg 0x19) bits [10:8] HW mode indicator:
- 111 = 1000BASE-T Full ← maps to w23=7, SPEED_1000
- 110 = 1000BASE-T Half ← maps to w23=6, SPEED_1000
- 101 = 100BASE-TX Full ← maps to w23=5, SPEED_100
- 011 = 100BASE-TX Half ← maps to w23=3, SPEED_100
- Others = 10 Mbps

This mapping looks correct.

#### CAUSE 2: RGMII_LINK Not Set (MEDIUM PROBABILITY)

Our code writes EXT_RGMII_OOB_CTRL = 0x00F00050, which has bit 4 (RGMII_LINK) set.
Both Linux and U-Boot set this bit. **This is correct.**

But wait — the comment in the Linux driver says:
> "The speed set in umac->cmd tell RGMII block which clock to use for
> transmit -- 25MHz(100Mbps) or 125MHz(1Gbps). Receive clock is
> provided by the PHY."

The RGMII TX clock is derived from UMAC_CMD speed setting. If the speed is wrong,
the TX clock will be wrong and frames won't be transmitted properly.

#### CAUSE 3: UMAC_CMD Write Order / SW_RESET Issue (HIGH PROBABILITY)

Looking at our init sequence carefully:

```asm
# Line 266: Set speed (clearing ALL other bits including TX_EN/RX_EN)
str     w0, [x19, #GENET_UMAC_CMD]

# Lines 269-271: Read-modify-write to add TX_EN|RX_EN
ldr     w0, [x19, #GENET_UMAC_CMD]
orr     w0, w0, #(UMAC_CMD_TX_EN | UMAC_CMD_RX_EN)
str     w0, [x19, #GENET_UMAC_CMD]
```

This matches U-Boot's sequence exactly. The UMAC should be enabled.

**BUT** — Linux does something different. After calling `init_umac()` which writes
`CMD_SW_RESET` and **does NOT clear it**, the UMAC remains in reset until
`bcmgenet_mac_config` is called from the PHY link-up callback, which does:

```c
reg = bcmgenet_umac_readl(priv, UMAC_CMD);
if (reg & CMD_SW_RESET) {
    reg &= ~CMD_SW_RESET;
    bcmgenet_umac_writel(priv, reg, UMAC_CMD);
    udelay(2);
    reg |= CMD_TX_EN | CMD_RX_EN;
}
bcmgenet_umac_writel(priv, reg, UMAC_CMD);
```

Wait, actually `reset_umac()` in Linux writes `CMD_SW_RESET` with no clear
afterwards. Then `umac_enable_set()` checks for CMD_SW_RESET and returns
early if it's set! So Linux relies on the PHY link-up callback to clear
CMD_SW_RESET. But `bcmgenet_netif_start` calls `umac_enable_set` which
reads UMAC_CMD first — if SW_RESET is still set, it silently returns!

Actually, looking more carefully at U-Boot's probe vs Linux's reset_umac:

**U-Boot bcmgenet_umac_reset** (called from eth_start):
```c
writel(CMD_SW_RESET | CMD_LCL_LOOP_EN, UMAC_CMD);
udelay(2);
writel(0, UMAC_CMD);                          ← CLEARS SW_RESET
```

**Linux reset_umac**:
```c
bcmgenet_umac_writel(priv, CMD_SW_RESET, UMAC_CMD);
udelay(2);
// NO CLEAR OF SW_RESET
```

**Linux umac_enable_set**:
```c
reg = bcmgenet_umac_readl(priv, UMAC_CMD);
if (reg & CMD_SW_RESET) {
    return;  ← EARLY RETURN, does nothing!
}
```

So in Linux, after `init_umac()`, the UMAC is in SW_RESET state. The
`umac_enable_set(CMD_TX_EN|CMD_RX_EN, true)` in `bcmgenet_netif_start()`
will do NOTHING because SW_RESET is still set!

Then when the PHY link comes up, `bcmgenet_mac_config()` is called from
`bcmgenet_mii_setup()`, which clears SW_RESET and sets TX_EN|RX_EN.

**Our bare-metal code** clears SW_RESET at line 68:
```asm
str     wzr, [x19, #GENET_UMAC_CMD]    ← clears SW_RESET
```

This matches U-Boot's approach. So SW_RESET should be clear when we enable TX.

#### CAUSE 4: DMA Descriptor Address Issue (MEDIUM-HIGH PROBABILITY)

**This is a strong candidate.** Let me look at the descriptor write order:

Our bare-metal TX send:
```asm
# Line 345-350:
str     w0, [x5, #4]          # addr_lo
str     wzr, [x5, #8]         # addr_hi = 0
lsl     w0, w22, #16
ldr     w1, =TX_LEN_STATUS_FLAGS
orr     w0, w0, w1
str     w0, [x5, #0]          # length_status (LAST)
```

U-Boot TX send:
```c
writel(lower_32_bits((ulong)packet), (desc_base + DMA_DESC_ADDRESS_LO));
writel(upper_32_bits((ulong)packet), (desc_base + DMA_DESC_ADDRESS_HI));
writel(len_stat, (desc_base + DMA_DESC_LENGTH_STATUS));
```

Both write addr first, then length_status last. This is correct — the DMA
doesn't start processing until PROD_INDEX is bumped.

**BUT**: The physical address must be valid from the DMA engine's perspective.
On Pi 4, ARM physical addresses are the same as bus addresses for the GENET
(unlike USB DWC2 which needs 0xC0000000 offset for the legacy bus).

However — **if the buffer is in cached memory and the cache hasn't been flushed,
the DMA will read stale/zero data from RAM.**

Our code does flush the D-cache before TX:
```asm
bic     x0, x21, #63
add     x1, x21, x22
.Ltx_flush:
dc      civac, x0
add     x0, x0, #64
cmp     x0, x1
b.lo    .Ltx_flush
dsb     sy
```

This looks correct. `dc civac` (Clean and Invalidate by VA to PoC) ensures
the data is written to RAM.

#### CAUSE 5: TDMA_WRITE_PTR Not Updated (POSSIBLE)

Looking at U-Boot's send:
```c
prod_index = readl(priv->mac_reg + TDMA_PROD_INDEX);
// ... set up descriptor ...
prod_index++;
writel(prod_index, priv->mac_reg + TDMA_PROD_INDEX);
```

U-Boot does NOT update TDMA_WRITE_PTR during send. Neither does our code.
Neither does Linux (it only initializes WRITE_PTR during ring init).

The WRITE_PTR is initialized to start_ptr in both U-Boot and Linux.
In our code, it's initialized to 0 at line 228. This is correct.

#### CAUSE 6: PROD_INDEX Comparison with CONS_INDEX (POSSIBLE BUG)

Our send poll loop:
```asm
ldr     w0, [x5, #TDMA_CONS_INDEX_OFS]
and     w0, w0, #0xFFFF
cmp     w0, w3                          # w3 = new prod_index
b.eq    .Ltx_ok
```

This waits for CONS_INDEX == PROD_INDEX. **U-Boot uses `<` comparison**:
```c
do {
    cons = readl(priv->mac_reg + TDMA_CONS_INDEX);
} while ((cons & 0xffff) < prod_index && --tries);
```

If CONS_INDEX wraps around 0xFFFF → 0, the `<` comparison would fail
spuriously. But with `==`, we'd wait forever if CONS passes PROD due to
overflow. This is a minor difference but not the TX failure cause.

**The key question is**: CONS_INDEX IS advancing (per the symptom description).
This means the DMA IS processing descriptors. So the DMA path is working.

#### CAUSE 7: UMAC TX FIFO Not Draining (HIGH PROBABILITY)

**The DMA feeds the UMAC TX FIFO. The UMAC then transmits on the wire.**

If CONS_INDEX advances (DMA consumed the descriptor) but TX_GD_PKTS stays at 0,
the problem is between the DMA and the wire:
1. DMA reads the buffer and writes data to the UMAC TX FIFO (works — CONS advances)
2. UMAC reads from TX FIFO and transmits via RGMII (broken)

This points to a **UMAC or RGMII configuration issue**, not a DMA issue.

Possible sub-causes:
- **Speed mismatch**: UMAC_CMD speed doesn't match PHY speed → garbled TX clock
- **RGMII timing**: TX clock delay incorrect → PHY can't lock onto data
- **UMAC_CMD not fully enabled**: some bit preventing TX from actually outputting
- **TX_FLUSH stuck**: if UMAC_TX_FLUSH is still asserted

Let me check: do we properly clear TX_FLUSH? Yes, at lines 172-176. But we write
it early in init, before DMA setup. Then we never write it again.

**Check**: is UMAC_TX_FIFO_STATUS showing data stuck?
Read [+0xB3C] UMAC_TX_FIFO_STATUS — if non-zero, data is sitting in the FIFO.

#### CAUSE 8: The "0xC043" RBUF_CTRL Value (SUSPICIOUS)

Our code writes:
```asm
ldr     w0, =0xC043
str     w0, [x19, #GENET_RBUF_CTRL]
```

RBUF_CTRL at +0x300:
- Bit 0: RBUF_64B_EN (enable 64-byte RSB)
- Bit 1: RBUF_ALIGN_2B (2-byte alignment)
- Bit 2: RBUF_BAD_DIS (discard bad frames)
- Other bits: unknown at offset 0x300

0xC043 = bit 0 (RBUF_64B_EN) + bit 1 (RBUF_ALIGN_2B) + bit 6 + bits 14-15.
This was supposedly "matched from PiOS". The bit 0 (RBUF_64B_EN) enables
the 64-byte Receive Status Block, which is fine for RX.

**This should NOT affect TX at all**, since RBUF is the receive buffer path.

#### CAUSE 9: Missing SYS_RBUF_FLUSH_CTRL Final Clear (LOW)

After the UMAC reset, our code writes:
```asm
str     wzr, [x19, #GENET_SYS_RBUF_FLUSH]  # line 57 — final clear
```

But Linux's `reset_umac` toggles BIT(1) on and off (no final zero write).
Then `init_umac` -> `reset_umac` writes 0 to clear any bad default.

The SYS_RBUF_FLUSH_CTRL register:
- Bit 0: RX FIFO flush
- Bit 1: Reset (toggles UMAC)

Our sequence looks correct for reset purposes.

---

## 7. Root Cause Analysis — Most Likely Culprit

Given that:
1. DMA is consuming TX descriptors (CONS_INDEX advances)
2. MIB TX_GD_PKTS stays at 0
3. RX works fine

The DMA-to-UMAC path works. The problem is UMAC-to-wire.

### **PRIMARY SUSPECT: UMAC_CMD Speed/Configuration**

Our code writes UMAC_CMD = speed_bits, then ORs in TX_EN|RX_EN. The write at
line 266 **clears ALL other bits** including:

- CMD_PAD_EN (bit 5) — pad short frames (< 64 bytes). If the frame is a
  runt (< 64 bytes) and PAD_EN is not set, AND APPEND_CRC is set in the
  descriptor, the UMAC might not pad it properly. But frames > 64 bytes
  should still work.

- CMD_RX_PAUSE_IGNORE (bit 8) and CMD_TX_PAUSE_IGNORE (bit 28) — both 0
  means pause frames are honored. If the switch/link partner is sending
  PAUSE, TX would be paused.

These are probably not the issue for standard-size frames.

### **SECONDARY SUSPECT: Order of Operations**

In U-Boot:
1. UMAC reset
2. Disable DMA + TX flush
3. Init RX ring and descriptors
4. Init TX ring
5. Enable DMA
6. PHY startup + link negotiation
7. RGMII config (EXT_RGMII_OOB)
8. Set speed in UMAC_CMD
9. Enable TX_EN|RX_EN

In our code:
1. UMAC reset
2. Port mode, MIB clear, max frame, interrupts
3. RGMII config (hardcoded 0x00F00050) ← **before link is known**
4. PHY reset + configure timing + auto-negotiate
5. Wait for AN complete + link
6. Read speed
7. Disable DMA + TX flush
8. RBUF_TBUF_SIZE_CTRL = 1
9. Init RX descriptors
10. Init RX ring registers
11. Init TX ring registers
12. Enable DMA
13. Set RBUF_CTRL
14. Set speed in UMAC_CMD
15. Enable TX_EN|RX_EN

This is mostly the same order. One difference: we set RGMII_OOB before
PHY negotiation. But this should be fine — U-Boot also sets it after
link is up, but the register value is the same.

### **THIRD SUSPECT: Descriptor write uses `w` register for address**

At line 342:
```asm
mov     w0, w21          # w0 = lower 32 bits of buf address
```

If x21 is a 64-bit address (e.g., in the range above 4 GB in EL1 virtual
address space), `mov w0, w21` truncates to 32 bits. But we're running
bare-metal on Pi 4, so physical addresses should be below 4 GB.

**However**: if the MMU is enabled and the virtual address differs from the
physical address, the DMA needs the PHYSICAL address, not the virtual address.
Our code passes the buffer pointer (x2) directly to genet_send. If MMU
identity-maps (VA == PA), this is fine. If not, the DMA will read from
the wrong location.

**This could explain the symptoms**: DMA reads garbage (zeros) from the wrong
physical address, UMAC tries to transmit it but the frame is malformed,
so TX_GD_PKTS doesn't increment (the frame fails some internal check).

Check: is the MMU using identity mapping for the TX buffer region?

### **FOURTH SUSPECT: Cache Coherency**

Even if the VA matches the PA, the data must be in RAM (not just in the L1/L2
cache). Our code uses `dc civac` which cleans and invalidates to the Point of
Coherency. On Pi 4, PoC is main memory. This should be sufficient.

But: the memory type matters. If the TX buffer region is mapped as Device
memory (nGnRnE), writes go directly to "memory" but the GENET DMA might
not see them if it's accessing via a different bus path. For Normal memory
types, the cache clean operation ensures data reaches RAM.

Check: what memory type is the TX buffer region mapped with?

---

## 8. Concrete Checklist

### Immediate Diagnostic Steps

Read these registers and print their values via UART:

```
1. [+0x000] SYS_REV_CTRL         — verify GENET version
2. [+0x004] SYS_PORT_CTRL        — should be 3
3. [+0x008] SYS_RBUF_FLUSH_CTRL  — should be 0
4. [+0x08C] EXT_RGMII_OOB_CTRL   — check RGMII_LINK, MODE_EN, OOB_DIS
5. [+0x080] EXT_EXT_PWR_MGMT     — check power bits
6. [+0x600] TBUF_CTRL            — check TBUF_64B_EN
7. [+0x300] RBUF_CTRL            — check current value
8. [+0x3B4] RBUF_TBUF_SIZE_CTRL  — should be 1
9. [+0x808] UMAC_CMD             — check speed, TX_EN, RX_EN, SW_RESET
10. [+0x814] UMAC_MAX_FRAME_LEN  — should be 1536
11. [+0xB34] UMAC_TX_FLUSH       — should be 0
12. [+0xB3C] UMAC_TX_FIFO_STATUS — check if frames are stuck
13. [+0xB38] UMAC_RX_FIFO_STATUS — reference (should show RX activity)
14. [+0xD80] UMAC_MIB_CTRL       — should be 0
15. [+0x5044] TDMA DMA_CTRL      — check DMA_EN + ring enables
16. [+0x5048] TDMA DMA_STATUS    — check status
17. [+0x5008] TDMA CONS_INDEX    — should advance after send
18. [+0x500C] TDMA PROD_INDEX    — should match what we wrote
```

Also read TX MIB counters (base +0xC80 for TSV area):
```
19. [+0xCA8] TX pkts             — should increment on success
20. [+0xCF0] TX good pkt (unicast)
21. [+0xCCC] TX FCS error
22. [+0xCD0] TX oversize
23. [+0xCD8] TX excessive deferral
24. [+0xCE8] TX excessive collision
25. [+0xCF4] TX byte count
```

### Register Writes for Correct TX Init

Apply these in order. All offsets from GENET_BASE (0xFD580000):

```
# Phase 1: UMAC Reset
write [+0x008] = 0x00000002          # SYS_RBUF_FLUSH: assert BIT(1)
delay 10us
write [+0x008] = 0x00000000          # SYS_RBUF_FLUSH: clear
delay 10us

write [+0x808] = 0x00000000          # UMAC_CMD: clear all
write [+0x808] = 0x0000A200          # UMAC_CMD: SW_RESET | LCL_LOOP_EN
delay 2us
write [+0x808] = 0x00000000          # UMAC_CMD: clear SW_RESET

# Phase 2: Port + MIB + Frame Size
write [+0x004] = 0x00000003          # SYS_PORT_CTRL: EXT_GPHY
write [+0xD80] = 0x00000007          # UMAC_MIB_CTRL: reset all
write [+0xD80] = 0x00000000          # UMAC_MIB_CTRL: clear reset
write [+0x814] = 0x00000600          # UMAC_MAX_FRAME_LEN: 1536

# Phase 3: RBUF/TBUF config
write [+0x3B4] = 0x00000001          # RBUF_TBUF_SIZE_CTRL: 1 (allocate TBUF space)
write [+0x300] = (read) | 0x02       # RBUF_CTRL: add RBUF_ALIGN_2B
# Note: Do NOT set RBUF_64B_EN or TBUF_64B_EN unless using TSB/RSB

# Phase 4: Interrupts
write [+0x210] = 0xFFFFFFFF          # INTRL2_0_MASK_SET: mask all
write [+0x208] = 0xFFFFFFFF          # INTRL2_0_CLEAR: clear all
write [+0x250] = 0xFFFFFFFF          # INTRL2_1_MASK_SET: mask all
write [+0x248] = 0xFFFFFFFF          # INTRL2_1_CLEAR: clear all

# Phase 5: MAC address
write [+0x80C] = (mac[0]<<24|mac[1]<<16|mac[2]<<8|mac[3])
write [+0x810] = (mac[4]<<8|mac[5])

# Phase 6: Disable DMA
write [+0x5044] = 0x00000000         # TDMA DMA_CTRL: disable
write [+0x3044] = 0x00000000         # RDMA DMA_CTRL: disable
write [+0xB34] = 0x00000001          # UMAC_TX_FLUSH: flush
delay 10us
write [+0xB34] = 0x00000000          # UMAC_TX_FLUSH: clear

# Phase 7: RGMII + PHY
# ... PHY init, auto-negotiate, get speed ...
# Then set RGMII OOB:
read  [+0x08C]
write [+0x08C] = (val & ~0x20) | 0x50    # clear OOB_DIS, set LINK|MODE_EN
# For RGMII (no delay from MAC): also set ID_MODE_DIS
write [+0x08C] |= 0x10000

# Phase 8: DMA burst size
write [+0x304C] = 0x00000008         # RDMA SCB_BURST_SIZE
write [+0x504C] = 0x00000008         # TDMA SCB_BURST_SIZE

# Phase 9: RX ring 16 init
write [+0x2C14] = 0x00000000         # RX ring 16 START_ADDR: 0
write [+0x302C] = 0x00000000         # RDMA READ_PTR: 0
write [+0x3000] = 0x00000000         # RDMA WRITE_PTR: 0
write [+0x2C1C] = 0x000002FF         # RX ring 16 END_ADDR: 767
read  [+0x3008] → c_index
write [+0x300C] = c_index            # RDMA CONS_INDEX: align to PROD
write [+0x2C10] = 0x01000800         # RX RING_BUF_SIZE: 256 descs, 2048 buf
write [+0x3028] = 0x00050010         # RDMA XON_XOFF_THRESH

# Phase 10: RX descriptors (256 entries at +0x2000)
for i in 0..255:
    write [+0x2000+i*12+0] = (2048<<16)|0x8000    # length|DMA_OWN
    write [+0x2000+i*12+4] = phys_addr(rx_buf[i])
    write [+0x2000+i*12+8] = 0

# Phase 11: TX ring 16 init
read  [+0x5008] → cons
write [+0x500C] = cons               # TDMA PROD_INDEX: align to CONS
write [+0x5000] = 0                  # TDMA READ_PTR
write [+0x502C] = 0                  # TDMA WRITE_PTR
write [+0x4C14] = 0                  # TX ring 16 START_ADDR
write [+0x4C1C] = 0x2FF              # TX ring 16 END_ADDR
write [+0x4C24] = 1                  # MBUF_DONE_THRESH
write [+0x5028] = 0                  # TDMA FLOW_PERIOD
write [+0x4C10] = 0x01000800         # TX RING_BUF_SIZE

# Phase 12: Enable DMA
write [+0x3040] = 0x00010000         # RDMA RING_CFG: enable ring 16
write [+0x3044] = 0x00020001         # RDMA DMA_CTRL: ring 16 + DMA_EN
write [+0x5040] = 0x00010000         # TDMA RING_CFG: enable ring 16
write [+0x5044] = 0x00020001         # TDMA DMA_CTRL: ring 16 + DMA_EN

# Phase 13: Set UMAC speed + enable
# speed_val = 0 (10M), 0x04 (100M), 0x08 (1000M)
write [+0x808] = speed_val           # UMAC_CMD: speed only
read  [+0x808]
write [+0x808] |= 0x03               # UMAC_CMD: + TX_EN | RX_EN
```

### TX Descriptor Format (per packet)

```
At descriptor base + tx_ring_index * 12:
+0x00: (length << 16) | 0x7FC0       # SOP|EOP|QTAG(0x3F)|APPEND_CRC
+0x04: lower_32(phys_addr_of_packet)
+0x08: 0x00000000                     # upper 32 bits (always 0 on Pi 4)

Then: PROD_INDEX = (old_prod_index + 1) & 0xFFFF
Write [+0x500C] = PROD_INDEX
```

### Things to Verify on Hardware

1. **Read UMAC_TX_FIFO_STATUS (+0xB3C)** after sending a frame.
   If non-zero, data is entering the FIFO but not draining → UMAC config issue.
   If zero, the DMA isn't even writing data to the FIFO → DMA address issue.

2. **Read all TX MIB error counters** (FCS error, oversize, late collision,
   excessive collision, etc.) — any non-zero counter reveals what's happening.

3. **Check the memory type** of the TX buffer region in the MMU page tables.
   Must be Normal Write-Back (not Device, not Normal Non-Cacheable with incorrect
   shareability).

4. **Verify the physical address** being written to the descriptor matches the
   actual RAM location of the packet. Print both the address written to the
   descriptor and a few bytes of the buffer content.

5. **Try sending with UMAC_CMD promiscuous mode** (bit 4 set) to eliminate
   any MDF filter issue (shouldn't affect TX, but worth ruling out).

6. **Try a loopback test**: set CMD_LCL_LOOP_EN (bit 15) in UMAC_CMD along
   with TX_EN|RX_EN. Send a frame and see if it appears on the RX ring.
   If loopback works, the issue is RGMII/PHY. If it doesn't, the issue is
   UMAC/DMA.

7. **Check EXT_EXT_PWR_MGMT (+0x080)**: If any power-down bits are set
   (especially bit 16 EXT_PWR_DOWN_PHY_TX), try clearing them all to 0.

### Summary of Differences Between Working (U-Boot) and Our Code

| Aspect | U-Boot | Our code | Impact |
|--------|--------|----------|--------|
| RBUF_TBUF_SIZE_CTRL | Set to 1 | Set to 1 | OK |
| TBUF_CTRL (0x600) | Not set | Not set | OK (no TSB) |
| RBUF_CTRL | ALIGN_2B only (0x02) | 0xC043 (ALIGN_2B + 64B_EN + unknown) | RX only |
| UMAC reset | SW_RESET\|LCL_LOOP, then clear | SW_RESET\|LCL_LOOP, then clear | OK |
| TX flush | Done after DMA disable | Done after DMA disable | OK |
| TDMA PROD init | Read CONS, write to PROD | Read CONS, write to PROD | OK |
| DMA_CTRL | 0x00020001 (ring16+EN) | 0x0002001F (ring16+rings0-3+EN) | Possible issue — rings 0-3 enabled but not configured? |
| Speed setting | speed<<2 only in UMAC_CMD | speed bits only, then add TX/RX | OK |
| TX descriptor flags | 0x7FC0 | 0x7FC0 | OK |
| DMA_ARB_CTRL | Not set | Not set | Probably OK |
| MBUF_DONE_THRESH | 1 | 1 | OK (Linux uses 10) |

### **CRITICAL FINDING: TDMA DMA_CTRL = 0x0002001F**

Our code at line 242:
```asm
ldr     w0, =0x0002001F
str     w0, [x22, #TDMA_DMA_CTRL_OFS]
```

This enables:
- DMA_EN (bit 0) = 1
- Ring 0 (bit 1) = 1
- Ring 1 (bit 2) = 1
- Ring 2 (bit 3) = 1
- Ring 3 (bit 4) = 1
- Ring 16 (bit 17) = 1

**BUT rings 0-3 were never configured** (no START_ADDR, END_ADDR, etc.).

U-Boot uses `0x00020001` — only ring 16 + DMA_EN.

Linux enables rings 0-3 + 16 BUT configures all of them first in
`bcmgenet_init_tx_queues`.

**Enabling unconfigured rings could cause the DMA engine to malfunction.**
The DMA might try to process descriptors from ring 0-3 using uninitialized
register values, potentially causing it to lock up or behave unpredictably
on the TX path.

**FIX**: Change TDMA DMA_CTRL from 0x0002001F to 0x00020001.

### Second Finding: RDMA PROD_INDEX Written to 0

At line 204:
```asm
str     wzr, [x19, #RDMA_PROD_INDEX]
```

U-Boot's comment says: "cannot init RDMA_PROD_INDEX to 0" — it reads PROD_INDEX
and writes that value to CONS_INDEX to align them.

Linux also writes PROD_INDEX to 0 for RX rings (line 2737). So writing 0 is
actually allowed for RDMA. The "cannot init to 0" comment in U-Boot refers to
the fact that PROD_INDEX may have been non-zero from previous use, and they
want to start from the current state.

Since our code writes PROD=0 and CONS=0, the RX ring starts clean. This is fine
for a cold boot.

### Third Finding: TX Ring CONS_INDEX Behavior

U-Boot reads TDMA_CONS_INDEX and uses it as the starting PROD_INDEX. This
accounts for the hardware possibly not being freshly reset.

Our code also does this (line 218-219):
```asm
ldr     w0, [x22, #TDMA_CONS_INDEX_OFS]
str     w0, [x22, #TDMA_PROD_INDEX_OFS]
```

Then in state init (lines 279-283), we save both as starting indices.
This is correct.

---

## RECOMMENDED FIX ORDER

1. **Change TDMA DMA_CTRL to 0x00020001** (only ring 16 + DMA_EN).
   This is the most likely cause. Unconfigured rings 0-3 being enabled
   could corrupt the DMA controller's state.

2. **Add diagnostic register reads** (UMAC_TX_FIFO_STATUS, TX MIB error
   counters) to determine if frames are reaching the UMAC.

3. **Read and print EXT_EXT_PWR_MGMT (+0x080)** to verify no TX power-down
   bits are set by the firmware.

4. **Try loopback mode** (CMD_LCL_LOOP_EN) to isolate UMAC vs RGMII/PHY.

5. **Verify TX buffer physical address** is correct (identity mapped, in
   lower 1 GB).

6. If loopback works but normal TX doesn't: focus on RGMII timing
   configuration (EXT_RGMII_OOB_CTRL and PHY shadow register settings).
