# Circle GENET TX Initialization Analysis

Source: `rsta2/circle` commit master, `lib/bcm54213.cpp` + `include/circle/bcm54213.h`
Compared with: U-Boot `drivers/net/bcmgenet.c` (master)

## Base Address

Circle: `ARM_BCM54213_BASE = 0xFD580000` (from `include/circle/bcm2711.h`)

Register block offsets (both drivers agree):
- SYS:     base + 0x0000
- EXT:     base + 0x0080
- INTRL2:  base + 0x0200 / 0x0240
- RBUF:    base + 0x0300
- UMAC:    base + 0x0800
- RDMA:    base + 0x2000
- TDMA:    base + 0x4000

---

## 1. Registers Circle Writes That U-Boot Does NOT

### EXT_GPHY_CTRL (base + 0x0080 + 0x1C = base + 0x009C)

Circle does NOT write EXT_GPHY_CTRL. It is defined with bit fields:
```
EXT_CFG_IDDQ_BIAS  (1 << 0)
EXT_CFG_PWR_DOWN   (1 << 1)
EXT_CK25_DIS       (1 << 4)
EXT_GPHY_RESET     (1 << 5)
```
But no code in `bcm54213.cpp` reads or writes this register. Linux kernel does
write it during power management (bcmgenet_power_up / power_down), but Circle
skips all power management. U-Boot also does not touch it.

**Neither driver writes EXT_GPHY_CTRL.** Both rely on firmware having configured
it before handoff.

### EXT_EXT_PWR_MGMT (base + 0x0080 + 0x00 = base + 0x0080)

Circle defines it (`EXT_EXT_PWR_MGMT = 0x00` within EXT block) with many bits:
```
EXT_PWR_DOWN_BIAS      (1 << 0)
EXT_PWR_DOWN_DLL       (1 << 1)
EXT_PWR_DOWN_PHY       (1 << 2)
EXT_PWR_DN_EN_LD       (1 << 3)
EXT_ENERGY_DET         (1 << 4)
EXT_IDDQ_FROM_PHY      (1 << 5)
EXT_IDDQ_GLBL_PWR      (1 << 7)
EXT_PHY_RESET          (1 << 8)
EXT_ENERGY_DET_MASK    (1 << 12)
EXT_PWR_DOWN_PHY_TX    (1 << 16)
EXT_PWR_DOWN_PHY_RX    (1 << 17)
EXT_PWR_DOWN_PHY_SD    (1 << 18)
EXT_PWR_DOWN_PHY_RD    (1 << 19)
EXT_PWR_DOWN_PHY_EN    (1 << 20)
```

**Neither Circle nor U-Boot writes EXT_EXT_PWR_MGMT.** Again, both rely on
firmware (VideoCore) having already powered up the PHY.

### Registers Circle writes that U-Boot skips:

| Register | Circle | U-Boot | Notes |
|----------|--------|--------|-------|
| UMAC_EEE_CTRL (UMAC+0x064) | Defined, not written | Not defined | Both skip |
| RBUF_ENERGY_CTRL (RBUF+0x9C) | Defined, not written | Not defined | Both skip |
| TBUF_ENERGY_CTRL (TBUF+0x14) | Defined, not written | Not defined | Both skip |
| UMAC_MPD_CTRL (UMAC+0x620) | Defined, not written | Not defined | Both skip |
| RBUF_CHK_CTRL (RBUF+0x14) | Defined, not written | Not defined | Both skip |
| UMAC_MDF_CTRL (UMAC+0x650) | **Written** | Not used | Multicast filter |
| UMAC_MDF_ADDR (UMAC+0x654) | **Written** | Not used | MAC filter addresses |
| INTRL2_0/1 mask regs | **Written** | Not used | Interrupt management |
| HFB_CTRL (base+0xFC00) | **Written** (cleared) | Not used | Hardware filter block |
| TDMA DMA_ARB_CTRL | **Written** (SP arbiter) | Not used | Strict priority arbiter |
| TDMA DMA_PRIORITY_0/1/2 | **Written** | Not used | Queue priority config |
| TDMA per-ring FLOW_PERIOD | **Written** | Not used | Per-queue flow control |
| TDMA per-ring MBUF_DONE_THRESH | **10** | **1** | Interrupt coalescing |

### Key Circle-only TX-relevant writes:
1. **DMA_ARB_CTRL = 0x02** (strict priority arbiter mode) at TDMA_REG + 0x2C
2. **DMA_PRIORITY_0/1/2** set per-queue priorities at TDMA_REG + 0x30/0x34/0x38
3. **MBUF_DONE_THRESH = 10** per ring (U-Boot uses 1)
4. **FLOW_PERIOD** = ENET_MAX_MTU_SIZE << 16 for priority queues, 0 for Q16

---

## 2. TX DMA Enable Order of Operations

### Circle's init sequence (Initialize method):

```
1. sys_readl(SYS_REV_CTRL)          — version check
2. reset_umac()                      — clear RBUF_FLUSH, soft reset UMAC
3. umac_reset2()                     — toggle RBUF_FLUSH_CTRL bit 1
4. init_umac()                       — reset again, clear MIB, set MTU, RBUF_ALIGN
5. set_hw_addr()                     — MAC via mailbox, write UMAC_MAC0/MAC1
6. dma_disable()                     — RMW clear DMA_EN + Q16 ring bit in TDMA_CTRL & RDMA_CTRL, flush TX
7. init_dma()                        — allocate CBs, set SCB burst, init RX queues, init TX queues
   7a. rdma_writel(8, DMA_SCB_BURST_SIZE)
   7b. init_rx_queues()              — init ring 16, write RDMA ring regs, enable ring, RMW DMA_CTRL
   7c. tdma_writel(8, DMA_SCB_BURST_SIZE)
   7d. init_tx_queues(enable=true)   — *** SEE DETAILED BREAKDOWN BELOW ***
8. enable_dma(dma_ctrl)             — RMW set DMA_EN + Q16 bit in RDMA_CTRL, then TDMA_CTRL
9. hfb_init()                        — clear HFB
10. Connect IRQs
11. mii_probe()                      — MDIO reset, read PHY status, configure RGMII
12. netif_start()                    — UMAC CMD_TX_EN | CMD_RX_EN, enable TX interrupts
13. set_rx_mode()                    — configure MDF filter
```

### U-Boot's init sequence (bcmgenet_gmac_eth_start):

```
1. bcmgenet_umac_reset()             — RBUF_FLUSH toggle, soft reset, MIB clear, MTU, RBUF_ALIGN
2. bcmgenet_gmac_write_hwaddr()      — UMAC_MAC0/MAC1
3. bcmgenet_disable_dma()            — clrbits DMA_EN in TDMA/RDMA CTRL, TX flush
4. rx_ring_init() + rx_descs_init()  — SCB burst, ring regs, descriptors
5. tx_ring_init()                    — SCB burst, ring regs (Q16 only)
6. bcmgenet_enable_dma()             — FULL WRITE to TDMA_CTRL, setbits to RDMA_CTRL
7. phy_startup()                     — PHY link
8. bcmgenet_adjust_link()            — RGMII OOB, speed
9. setbits CMD_TX_EN | CMD_RX_EN
```

### Critical difference: DMA_CTRL write strategy

**Circle** does **RMW** (read-modify-write) in `enable_dma()`:
```cpp
void enable_dma(u32 dma_ctrl) {
    u32 reg = rdma_readl(DMA_CTRL);    // READ current
    reg |= dma_ctrl;                    // OR in enable bits
    rdma_writel(reg, DMA_CTRL);         // WRITE back

    reg = tdma_readl(DMA_CTRL);        // READ current
    reg |= dma_ctrl;                    // OR in enable bits
    tdma_writel(reg, DMA_CTRL);        // WRITE back
}
```

But `init_tx_queues()` does something more nuanced — see section 4.

**U-Boot** does a **full write** for TDMA, **setbits** for RDMA in `enable_dma()`:
```c
void bcmgenet_enable_dma() {
    u32 dma_ctrl = (1 << (DEFAULT_Q + DMA_RING_BUF_EN_SHIFT)) | DMA_EN;
    writel(dma_ctrl, TDMA_CTRL);       // FULL WRITE — overwrites everything
    setbits_32(RDMA_CTRL, dma_ctrl);   // RMW — preserves other bits
}
```

---

## 3. How Circle Handles EXT_GPHY_CTRL and EXT_EXT_PWR_MGMT

**Answer: It doesn't.** Circle defines the register offsets and bit fields but
never reads or writes either register. Circle assumes the VideoCore firmware
has already:
- Powered up the GPHY
- Deasserted PHY reset
- Enabled the 25 MHz clock

This matches U-Boot's approach. Both bare-metal drivers rely on the Pi 4
firmware boot sequence to handle PHY power management.

The Linux kernel's `bcmgenet_power_up()` does write these registers, but only
when resuming from suspend — a state that never occurs in bare-metal or
bootloader contexts.

---

## 4. How Circle Writes DMA_CTRL (Full Write vs RMW)

Circle has THREE places that touch TDMA DMA_CTRL:

### 4a. `dma_disable()` — RMW to CLEAR bits
```cpp
u32 dma_ctrl = (1 << (16 + 1)) | DMA_EN;   // = 0x00020001 (Q16 ring enable + DMA_EN)
u32 reg = tdma_readl(DMA_CTRL);             // READ
reg &= ~dma_ctrl;                            // CLEAR those bits
tdma_writel(reg, DMA_CTRL);                  // WRITE — preserves other ring enable bits
```

### 4b. `init_tx_queues(enable=true)` — Careful rebuild
```cpp
// Step 1: READ current, SAVE dma_enable flag, CLEAR DMA_EN
u32 dma_ctrl = tdma_readl(DMA_CTRL);       // READ
u32 dma_enable = dma_ctrl & DMA_EN;        // save whether DMA was enabled
dma_ctrl &= ~DMA_EN;                        // clear DMA_EN
tdma_writel(dma_ctrl, DMA_CTRL);            // WRITE — DMA off but ring bits preserved

// Step 2: Build new dma_ctrl from scratch
dma_ctrl = 0;
// For each priority queue i (0..3):
//   dma_ctrl |= (1 << (i + 1));           // enable ring i
// Then for Q16:
//   dma_ctrl |= (1 << (16 + 1));          // enable Q16 ring

// Step 3: Write arbiter, priorities, ring config, then DMA_CTRL
tdma_writel(DMA_ARBITER_SP, DMA_ARB_CTRL);         // strict priority
tdma_writel(dma_priority[0..2], DMA_PRIORITY_0..2); // per-queue priority
tdma_writel(ring_cfg, DMA_RING_CFG);                // which rings active
if (dma_enable) dma_ctrl |= DMA_EN;                // re-enable if was enabled
tdma_writel(dma_ctrl, DMA_CTRL);                    // FULL WRITE — all ring enables + DMA_EN
```

The computed `dma_ctrl` value = rings 0..3 + Q16 enables + DMA_EN:
```
bit 0:  DMA_EN          = 1
bit 1:  ring 0 enable   = 1  (1 << (0 + 1))
bit 2:  ring 1 enable   = 1  (1 << (1 + 1))
bit 3:  ring 2 enable   = 1  (1 << (2 + 1))
bit 4:  ring 3 enable   = 1  (1 << (3 + 1))
bit 17: ring 16 enable  = 1  (1 << (16 + 1))
= 0x0002001F
```

### 4c. `enable_dma()` — RMW to SET bits
```cpp
// Called from Initialize() after init_dma()
// dma_ctrl passed in = 0x00020001 (Q16 + DMA_EN)
u32 reg = tdma_readl(DMA_CTRL);    // READ (already has 0x0002001F from init_tx_queues)
reg |= dma_ctrl;                    // OR in Q16 + DMA_EN (redundant, already set)
tdma_writel(reg, DMA_CTRL);        // WRITE
```

**Key insight:** Circle's `init_tx_queues()` already enables all rings + DMA.
The subsequent `enable_dma()` call is effectively a no-op for TDMA because
all bits are already set. But it's NOT a no-op for RDMA — `init_rx_queues()`
configures Q16 ring enable but the outer `enable_dma()` ensures DMA_EN is set.

### U-Boot's approach:
```c
// bcmgenet_enable_dma() — FULL WRITE to TDMA
u32 dma_ctrl = (1 << (16 + 1)) | 1;  // = 0x00020001 (Q16 only + DMA_EN)
writel(dma_ctrl, TDMA_CTRL);          // Overwrites everything — only Q16 enabled
```

**U-Boot only enables ring 16. Circle enables rings 0-3 AND ring 16.**

---

## 5. Clock Enable and Power Management Calls

### Circle: NONE

Circle does not:
- Write EXT_GPHY_CTRL (no clock enable/disable)
- Write EXT_EXT_PWR_MGMT (no power management)
- Call any clock framework
- Write RBUF_ENERGY_CTRL or TBUF_ENERGY_CTRL (no EEE)

### U-Boot: NONE

U-Boot also does not touch any of these registers.

### What DOES handle power/clocks:

The VideoCore firmware (GPU) initializes the GENET hardware before ARM boot:
1. Enables the 25 MHz reference clock
2. Powers up the GPHY
3. Deasserts PHY reset
4. Configures EXT_GPHY_CTRL and EXT_EXT_PWR_MGMT

Both Circle and U-Boot just reconfigure the MAC/DMA layer on top of what
firmware already set up.

---

## 6. TDMA Descriptor Format

Both Circle and U-Boot use identical 12-byte DMA descriptors:

```
Offset 0x00: DMA_DESC_LENGTH_STATUS  (32-bit)
Offset 0x04: DMA_DESC_ADDRESS_LO     (32-bit, lower PA)
Offset 0x08: DMA_DESC_ADDRESS_HI     (32-bit, upper PA, GENETv4+)
```

Total: 12 bytes per descriptor (`WORDS_PER_BD = 3`, each 4 bytes).

### LENGTH_STATUS field for TX (both drivers identical):

```
Bits [31:16]: buffer length (DMA_BUFLENGTH_SHIFT = 16, MASK = 0x0FFF)
Bit  15:      DMA_OWN       (0x8000) — not set by either for TX
Bit  14:      DMA_EOP       (0x4000) — end of packet
Bit  13:      DMA_SOP       (0x2000) — start of packet
Bit  12:      DMA_WRAP      (0x1000) — not used by either
Bits [12:7]:  QTAG          (0x3F << 7 = 0x1F80) — queue tag
Bit  9:       DMA_TX_UNDERRUN  (0x0200) — status
Bit  6:       DMA_TX_APPEND_CRC (0x0040) — append FCS
Bit  5:       DMA_TX_OW_CRC    (0x0020) — overwrite CRC
Bit  4:       DMA_TX_DO_CSUM   (0x0010) — HW checksum
```

### Circle's TX descriptor write (SendFrame):
```cpp
dmadesc_set(cb->bd_addr, pTxBuffer,
    (nLength << 16)          // length
    | (0x3F << 7)            // QTAG = 0x3F (all queues)
    | DMA_TX_APPEND_CRC      // 0x0040
    | DMA_SOP                // 0x2000
    | DMA_EOP                // 0x4000
);
// Combined status = length<<16 | 0x7FC0 (for short frames)
```

### U-Boot's TX descriptor write (bcmgenet_gmac_eth_send):
```c
len_stat = length << 16;
len_stat |= 0x3F << 7;           // QTAG = 0x3F
len_stat |= DMA_TX_APPEND_CRC | DMA_SOP | DMA_EOP;
writel(len_stat, desc_base + DMA_DESC_LENGTH_STATUS);
```

**Identical descriptor format and flags.**

### Descriptor address layout in MMIO:

TX descriptors start at base + TDMA_OFFSET (0x4000):
- Descriptor 0: base + 0x4000
- Descriptor 1: base + 0x400C
- Descriptor N: base + 0x4000 + N * 12
- Descriptor 255: base + 0x4000 + 255 * 12 = base + 0x4BF4

TX DMA ring registers start after all 256 descriptors:
- GENET_TDMA_REG_OFF = 0x4000 + 256 * 12 = 0x4000 + 0xC00 = 0x4C00

Per-ring register base for ring N:
- base + 0x4C00 + N * 0x40

Global TDMA registers (after all 17 ring register blocks):
- DMA_RINGS_SIZE = 0x40 * 17 = 0x440
- TDMA global base = 0x4C00 + 0x440 = 0x5040
- DMA_RING_CFG:    base + 0x5040
- DMA_CTRL:        base + 0x5044
- DMA_STATUS:      base + 0x5048
- DMA_SCB_BURST_SIZE: base + 0x504C

---

## Summary: Key Differences Between Circle and U-Boot TX Init

| Aspect | Circle | U-Boot |
|--------|--------|--------|
| TX queues used | Q0-Q3 (priority) + Q16 (default) | Q16 only |
| Actual TX ring used | Ring 0 (highest priority) | Ring 16 |
| DMA arbiter | Strict priority (SP=0x02) | Not configured |
| DMA_CTRL write | Built up carefully, all 5 rings | Full write, Q16 only |
| Ring enables in DMA_CTRL | bits 1-4 + bit 17 (0x0002001F) | bit 17 only (0x00020001) |
| MBUF_DONE_THRESH | 10 | 1 |
| FLOW_PERIOD (Q0-3) | ENET_MAX_MTU_SIZE << 16 | N/A |
| DMA_RING_CFG | bits 0-3 + bit 16 | bit 16 only |
| Interrupt management | Full INTRL2 setup | None |
| HFB init | Clears all filters | Skipped |
| MDF filter | Configured (broadcast + own MAC) | Skipped |
| Power management | None (firmware handles) | None (firmware handles) |
| EXT_GPHY_CTRL | Not touched | Not touched |
| EXT_EXT_PWR_MGMT | Not touched | Not touched |

### For a minimal bare-metal TX-only driver

U-Boot's approach is simpler and sufficient: use only Q16, skip priority queues,
skip interrupts, poll for completion. Circle adds priority queue infrastructure
that is unnecessary for a single-use bare-metal driver.

The registers that matter for TX (both agree on):
1. UMAC reset sequence (CMD_SW_RESET + CMD_LCL_LOOP_EN, then clear)
2. MIB counter reset
3. UMAC_MAX_FRAME_LEN = 1536
4. RBUF_CTRL |= RBUF_ALIGN_2B
5. RBUF_TBUF_SIZE_CTRL = 1
6. UMAC_MAC0 / UMAC_MAC1
7. DMA_SCB_BURST_SIZE = 8
8. Ring registers: START_ADDR, END_ADDR, READ_PTR, WRITE_PTR, PROD/CONS_INDEX
9. DMA_RING_BUF_SIZE, MBUF_DONE_THRESH, FLOW_PERIOD
10. DMA_RING_CFG (enable ring)
11. DMA_CTRL (enable DMA + ring buffer)
12. EXT_RGMII_OOB_CTRL: RGMII_LINK | RGMII_MODE_EN, clear OOB_DISABLE
13. UMAC_CMD: speed bits + CMD_TX_EN | CMD_RX_EN
