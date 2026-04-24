# U-Boot vs Test Kernel TX: Instruction-Level Comparison

Comparing U-Boot `bcmgenet_gmac_eth_send()` (drivers/net/bcmgenet.c, master)
against test_kern.S TEST 7 TX path (lines 760-864).

## 1. Descriptor Address Computation

**U-Boot:**
```c
void *desc_base = priv->tx_desc_base + priv->tx_index * DMA_DESC_SIZE;
// where tx_desc_base = mac_reg + GENET_TX_OFF (0x4000)
// and tx_index was set to (CONS_INDEX & 0xFF) during tx_ring_init
```

**Our code:**
```asm
and     w23, w22, #0xFF            @ descriptor index from PROD_INDEX
add     x24, x19, #4, lsl #12     @ x24 = GENET + 0x4000
mov     w0, #DMA_DESC_SIZE         @ 12
mul     w1, w23, w0
add     x24, x24, x1              @ x24 = desc base + index*12
```

**Verdict: MATCH.** Both compute `GENET_BASE + 0x4000 + (index * 12)`. We derive
the index from the current PROD_INDEX; U-Boot tracks it in a variable initialized
from CONS_INDEX. Since we set PROD = CONS during init, the first TX uses the same
index in both cases.

## 2. PROD_INDEX Read: Before or After Descriptor Write?

**U-Boot:** Reads PROD_INDEX **before** writing the descriptor:
```c
prod_index = readl(priv->mac_reg + TDMA_PROD_INDEX);
// ... flush cache ...
// ... write descriptor ...
prod_index++;
writel(prod_index, priv->mac_reg + TDMA_PROD_INDEX);
```

**Our code:** Also reads PROD_INDEX **before** writing the descriptor (line 826):
```asm
ldr     w22, [x26, #0x00C]        @ TDMA_PROD_INDEX (before descriptor write)
@ ... compute desc address, write descriptor ...
add     w22, w22, #1
str     w22, [x26, #0x00C]        @ write incremented PROD
```

**Verdict: MATCH.** Both read PROD first, write descriptor, then write PROD+1.

## 3. tx_index Calculation (PROD & 0xFF)

**U-Boot:** During `tx_ring_init`:
```c
priv->tx_index = readl(priv->mac_reg + TDMA_CONS_INDEX);
writel(priv->tx_index, priv->mac_reg + TDMA_PROD_INDEX);
priv->tx_index &= 0xFF;
```
Then in send: `desc_base + priv->tx_index * DMA_DESC_SIZE`, followed by
`if (++priv->tx_index >= TX_DESCS) priv->tx_index = 0;`

**Our code:** During TX ring init (lines 531-532):
```asm
ldr     w0, [x26, #0x008]         @ read CONS_INDEX
str     w0, [x26, #0x00C]         @ PROD_INDEX = CONS
```
Then at TX time (line 829): `and w23, w22, #0xFF`

**Verdict: MATCH.** Both use the low 8 bits as the 0-255 descriptor index.
Both initialize PROD = CONS during ring init.

## 4. D-Cache Flush Before DMA

**U-Boot:**
```c
flush_dcache_range(packet_aligned,
    packet_aligned + roundup(length, ARCH_DMA_MINALIGN));
```
On AArch64, `flush_dcache_range` executes `dc civac` per cache line, then `dsb sy`.
`ARCH_DMA_MINALIGN` = `CONFIG_SYS_CACHELINE_SIZE` = 64 on BCM2711.

**Our code (lines 816-823):**
```asm
bic     x0, x28, #63              @ align down to cache line
add     x1, x28, x20              @ end = buffer + length
.Ltx_flush:
dc      civac, x0
add     x0, x0, #64
cmp     x0, x1
b.lo    .Ltx_flush
dsb     sy
```

**Verdict: MATCH.** Both flush with `dc civac` + `dsb sy`. Both align to 64-byte
cache lines. Both flush before writing the descriptor.

**U-Boot does NOT skip the cache flush.** It always flushes because it runs with
MMU and D-cache enabled on Pi 4 (see question 9 below).

## 5. Descriptor Field Write Order

**U-Boot:**
```c
writel(lower_32_bits((ulong)packet), (desc_base + DMA_DESC_ADDRESS_LO));  // +0x04
writel(upper_32_bits((ulong)packet), (desc_base + DMA_DESC_ADDRESS_HI));  // +0x08
writel(len_stat, (desc_base + DMA_DESC_LENGTH_STATUS));                   // +0x00
```

**Our code (lines 838-845):**
```asm
str     w0, [x24, #4]             @ addr_lo
str     wzr, [x24, #8]            @ addr_hi
@ ... compute len_stat ...
str     w0, [x24, #0]             @ length_status
```

**Verdict: MATCH.** Both write addr_lo, addr_hi, then length_status last.

## 6. Barriers Around Descriptor / PROD Writes

**U-Boot:** Uses `writel()` which expands to `dmb oshst` + volatile store for EVERY
MMIO write. So there is an implicit `dmb oshst` before each of the 4 MMIO writes
(addr_lo, addr_hi, length_status, PROD_INDEX). The `flush_dcache_range` also ends
with `dsb sy`.

**Our code:** Uses plain `str` instructions to device-mapped memory (Device-nGnRnE).
There is a `dsb sy` after the cache flush (line 823), but NO explicit barrier
between the cache flush and the descriptor writes, and NO barrier between the
descriptor writes and the PROD_INDEX write.

**Verdict: POTENTIAL DIFFERENCE, but likely not the root cause.**

Device-nGnRnE memory provides strict ordering guarantees: all stores are observed
in program order. The `dsb sy` after the cache flush ensures data is in RAM before
the descriptor write begins. The descriptor writes at offsets +4, +8, +0 are all to
Device-nGnRnE addresses and will complete in order.

However, there is one subtle gap: between the `dsb sy` (which completes the cache
clean) and the first `str` to device memory, there is no explicit barrier. On
ARMv8, a DSB is stronger than a DMB — it ensures all preceding memory operations
(including cache maintenance) complete before subsequent instructions. So this should
be sufficient.

The `dmb oshst` that U-Boot inserts before each write is likely redundant given
Device-nGnRnE ordering, but it does provide an extra guarantee of Normal→Device
ordering. Our `dsb sy` is actually stronger.

## 7. CONS Polling Differences

**U-Boot:**
```c
do {
    cons = readl(priv->mac_reg + TDMA_CONS_INDEX);
} while ((cons & 0xffff) < prod_index && --tries);
```
Exits when `(cons & 0xffff) >= prod_index` (i.e., CONS caught up or passed PROD).

**Our code (lines 854-860):**
```asm
ldr     w0, [x26, #0x008]         @ TDMA_CONS_INDEX
and     w0, w0, #0xFFFF
cmp     w0, w22
b.eq    .Ltx_done                  @ exit only on exact equality
subs    w24, w24, #1
b.ne    .Ltx_poll
```

**Verdict: MINOR DIFFERENCE, not the root cause.** Our code exits on exact equality
(CONS == PROD). U-Boot exits on CONS >= PROD. In practice, CONS advances by exactly
1 per descriptor consumed, so both should work. The >= is more robust for edge cases
(e.g., counter wrapping), but this doesn't explain a TX failure — if CONS never
advances at all, neither polling strategy would help.

## 8. Could `dc civac` Be CAUSING a Problem?

**Short answer: No.**

`dc civac` (Clean and Invalidate by VA to Point of Coherency) does two things:
1. Writes back any dirty data in the cache line to RAM (clean)
2. Marks the cache line as invalid in the cache

After civac + dsb sy, the data is guaranteed to be in RAM and the cache line is
invalid. When the GENET DMA engine (which is not cache-coherent on BCM2711) reads
from that physical address, it will see the correct data in RAM.

The invalidation after clean does NOT erase the data from RAM — it only removes
the cache's copy. The data persists in RAM until overwritten. Since we don't write
to the packet buffer after the flush, the DMA engine will read correct data.

Could the cache line state prevent DMA from reading? No. DMA bus masters bypass the
cache hierarchy entirely. They read directly from the interconnect/RAM. Whether a
cache line is valid, invalid, clean, or dirty in the CPU's cache is invisible to
the DMA engine. What matters is that the data is in RAM (at PoC), which civac+dsb
guarantees.

**U-Boot uses the same `dc civac` operation** via its `flush_dcache_range()`.

## 9. Does U-Boot Enable MMU/Caches on Pi 4?

**Yes.** U-Boot enables MMU and D-cache on BCM2711 (Pi 4):

- `arch/arm/mach-bcm283x/init.c` defines `enable_caches()` which calls
  `dcache_enable()` (for LPAE/32-bit builds)
- For 64-bit ARM, the MMU is enabled during U-Boot's `board_init_f` sequence
  with the memory map from `bcm2711_mem_map[]`

The `flush_dcache_range()` call in the TX path confirms caches are on — if they
weren't, the flush would be a no-op (and U-Boot has a fast-path check for that).

## 10. U-Boot Memory Map for BCM2711

From `arch/arm/mach-bcm283x/init.c`:

```c
static struct mm_region bcm2711_mem_map[] = {
    {   // RAM
        .virt = 0x00000000, .phys = 0x00000000,
        .size = 0xfc000000,
        .attrs = PTE_BLOCK_MEMTYPE(MT_NORMAL) | PTE_BLOCK_INNER_SHARE
    }, {   // MMIO (peripherals)
        .virt = 0xfc000000, .phys = 0xfc000000,
        .size = 0x04000000,
        .attrs = PTE_BLOCK_MEMTYPE(MT_DEVICE_NGNRNE) |
                 PTE_BLOCK_NON_SHARE | PTE_BLOCK_PXN | PTE_BLOCK_UXN
    }, { /* ... PCIe XHCI at 0x600000000 ... */ }
};
```

**Our test kernel MMU setup (lines 165-212):**
- MAIR_EL1 = 0xFF → Attr0 = 0xFF (Normal WB RWA), Attr1 = 0x00 (Device-nGnRnE)
- L1 entries 0-2: 1GB blocks at 0x00/0x40/0x80 with attr 0x701 (Normal WB, ISH, AF)
- L2 for 0xC0000000-0xFFFFFFFF: 480 entries (to 0xFBFFFFFF) Normal WB, 32 entries
  (0xFC000000-0xFFFFFFFF) Device-nGnRnE

**Verdict: MATCH.** Both map RAM as Normal Write-Back cacheable with Inner Shareable,
and MMIO (>= 0xFC000000) as Device-nGnRnE. Our boundary is 0xFC000000, same as
U-Boot. GENET at 0xFD580000 is correctly in the device region.

---

## Summary of Differences Found

| Aspect | U-Boot | Our kernel | Impact |
|--------|--------|------------|--------|
| Descriptor address | mac_reg + 0x4000 + idx*12 | same | None |
| PROD read timing | Before descriptor write | Same | None |
| Index = PROD & 0xFF | Yes | Yes | None |
| Cache flush | dc civac + dsb sy | Same | None |
| Field write order | addr_lo, addr_hi, len_stat | Same | None |
| MMIO barriers | dmb oshst before each writel | dsb sy after flush only | **See below** |
| CONS polling | CONS >= PROD | CONS == PROD | Minor |
| MMU on? | Yes | Yes | None |
| Memory types | Normal WB / Device-nGnRnE | Same | None |
| DMA bus addresses | CPU phys direct (no offset) | Same | None |
| len_status flags | 0x7FC0 = SOP\|EOP\|QTAG(0x3F)\|CRC | Same (0x7FC0) | None |

## CRITICAL FINDING: The Code Paths Match

The TX path is instruction-equivalent in all material respects. If U-Boot TX works
and ours doesn't, the difference is NOT in the TX send function itself. The
difference must be in the **initialization sequence** or **system state** at the
time TX is attempted.

## Where to Look Next

### 1. UMAC Reset Sequence Differences

**U-Boot `bcmgenet_umac_reset()`:**
```c
reg = readl(SYS_RBUF_FLUSH_CTRL);
reg |= BIT(1);                            // set bit 1 (not bit 0!)
writel(reg, SYS_RBUF_FLUSH_CTRL);
udelay(10);
reg &= ~BIT(1);
writel(reg, SYS_RBUF_FLUSH_CTRL);
udelay(10);
writel(0, SYS_RBUF_FLUSH_CTRL);           // zero the whole register
udelay(10);
writel(0, UMAC_CMD);                       // clear UMAC_CMD first
writel(CMD_SW_RESET | CMD_LCL_LOOP_EN, UMAC_CMD);  // reset WITH loopback
udelay(2);
writel(0, UMAC_CMD);                       // clear reset
```

**Our TEST 4 reset:**
```asm
mov     w0, #2                    @ bit 1
str     w0, [x19, #GENET_SYS_RBUF_FLUSH]
mov     w0, #1
str     w0, [x19, #0x00C]        @ SYS_TBUF_FLUSH_CTRL (U-Boot doesn't do this here)
@ ... delay ...
str     wzr, [x19, #GENET_SYS_RBUF_FLUSH]
str     wzr, [x19, #0x00C]
@ ... delay ...
ldr     w0, [x19, #GENET_UMAC_CMD]
orr     w0, w0, #UMAC_CMD_SW_RESET    @ RMW: preserves existing bits
str     w0, [x19, #GENET_UMAC_CMD]    @ NOTE: no CMD_LCL_LOOP_EN
```

**Differences in reset:**
- U-Boot writes `0` to UMAC_CMD before reset, then sets `SW_RESET | LCL_LOOP_EN`.
  Our code does RMW on UMAC_CMD, preserving firmware bits, with SW_RESET only (no
  loopback).
- U-Boot writes `0` to UMAC_CMD after reset to clear everything. Our code doesn't
  explicitly clear after reset.
- U-Boot does NOT flush TBUF_FLUSH_CTRL during `umac_reset`. Our code does.
- U-Boot does a second `writel(0, SYS_RBUF_FLUSH_CTRL)` to fully zero the register.
  Our code does `str wzr` which is equivalent.
- U-Boot does NOT clear SW_RESET explicitly (writing 0 clears it). Our code
  doesn't clear it either before proceeding to port mode setup.

### 2. Missing UMAC_CMD Clear After Reset

The most significant difference: U-Boot explicitly writes 0 to UMAC_CMD after the
reset pulse (`writel(0, priv->mac_reg + UMAC_CMD)` after the SW_RESET+LCL_LOOP).
Our code sets SW_RESET but never clears UMAC_CMD before setting the speed. If
SW_RESET is still latched when we enable TX/RX, the MAC may not transmit.

Look at our flow:
1. TEST 4 line 336-338: Set UMAC_CMD |= SW_RESET (RMW, no clear after)
2. TEST 4 line 344-347: Set PORT_CTRL to EXT_GPHY
3. TEST 5 line 594-602: Write speed to UMAC_CMD (clean write, clears SW_RESET)
4. TEST 5 line 601: Write speed | TX_EN | RX_EN

This SHOULD clear SW_RESET because line 594 is `mov w0, w25` (speed only, no
SW_RESET bit) followed by `str w0, [x19, #GENET_UMAC_CMD]`. This overwrites the
entire register. So SW_RESET is cleared. This seems correct.

### 3. Missing CMD_LCL_LOOP_EN During Reset

U-Boot sets `CMD_LCL_LOOP_EN` (bit 15) during the SW_RESET phase. The Linux driver
comment explains: "issue soft reset with (rg)mii loopback to ensure a stable rxclk".
Our code omits this. Could an unstable rxclk during reset leave the MAC in a bad
state for TX? This is worth investigating.

### 4. RBUF_TBUF_SIZE_CTRL Timing

U-Boot writes `RBUF_TBUF_SIZE_CTRL = 1` inside `bcmgenet_umac_reset()` (the reset
function), before DMA init. Our code writes it at line 485-486 during TEST 5 (DMA
init). The value and the fact that it's written are the same, but timing relative
to the UMAC reset could matter.

### 5. DMA Disable Method

**U-Boot:**
```c
clrbits_32(TDMA_REG_BASE + DMA_CTRL, DMA_EN);  // just clear DMA_EN bit
```
Note: `TDMA_REG_BASE = GENET_TDMA_REG_OFF + DMA_RINGS_SIZE` which is a **different
offset** from the per-ring TDMA registers.

**Our code:**
```asm
ldr     w0, [x26, #0x044]      @ TDMA_DMA_CTRL (ring 16 base + 0x44)
ldr     w1, =0x0003FFFF        @ DMA_EN + all ring enables
bic     w0, w0, w1
str     w0, [x26, #0x044]
```

Our code reads/writes at `GENET + 0x5044`. U-Boot reads/writes at
`GENET + GENET_TDMA_REG_OFF + DMA_RINGS_SIZE + DMA_CTRL`.
Let's verify these are the same offset:
- GENET_TDMA_REG_OFF = GENET_TX_OFF + TOTAL_DESCS * DMA_DESC_SIZE
  = 0x4000 + 256*12 = 0x4000 + 0xC00 = 0x4C00
- DMA_RINGS_SIZE = DMA_RING_SIZE * (DEFAULT_Q + 1) = 0x40 * 17 = 0x440
- TDMA_REG_BASE = 0x4C00 + 0x440 = 0x5040
- DMA_CTRL = 0x04
- So U-Boot writes at GENET + 0x5044

Our code: `x26 = GENET + 0x5000`, offset 0x044, so GENET + 0x5044. **MATCH.**

### 6. tx_ring_init: U-Boot Does NOT Write PROD/CONS to Zero

This is important. U-Boot's `tx_ring_init()`:
```c
priv->tx_index = readl(priv->mac_reg + TDMA_CONS_INDEX);
writel(priv->tx_index, priv->mac_reg + TDMA_PROD_INDEX);
priv->tx_index &= 0xFF;
```

It reads CONS and sets PROD = CONS. It does NOT write CONS to zero, and does NOT
write PROD to zero. If the hardware has non-zero CONS/PROD from a previous boot or
firmware operation, U-Boot starts from where the hardware left off.

**Our code does the same (lines 531-532).** MATCH.

### 7. Packet Buffer DMA Address

U-Boot passes `(ulong)packet` — the CPU virtual address (= physical with identity
map). No bus address translation.

Our code passes `w28 = 0x200000` — the CPU physical address. No bus offset.

On BCM2711, GENET DMA uses ARM physical addresses directly (unlike BCM2835 which
used the 0xC0000000 VideoCore bus offset). This is correct.

**Verdict: MATCH.**

---

## Recommended Actions

1. **Add CMD_LCL_LOOP_EN to the SW_RESET write** — match U-Boot's reset sequence
   exactly: write 0 to UMAC_CMD, then write SW_RESET|LCL_LOOP_EN, delay, write 0.

2. **Move RBUF_TBUF_SIZE_CTRL=1 write into the UMAC reset sequence** (before DMA
   init) to match U-Boot's timing.

3. **Dump UMAC_CMD just before the PROD_INDEX write** to verify SW_RESET is clear
   and TX_EN is set at the moment of TX.

4. **Dump the exact descriptor content** (all 3 words at the computed address)
   immediately after writing them, to confirm the MMIO writes took effect.

5. **Compare TDMA_DMA_CTRL** value at TX time between U-Boot and our kernel.
   U-Boot's enable_dma writes `(1 << (16 + 1)) | 1 = 0x00020001`. Our code writes
   the same value. But verify the actual register reads match at TX time.

6. **Try without the cache flush** as a diagnostic — if the packet buffer address
   (0x200000) is in a region the DMA can access regardless of cache state, removing
   civac would confirm/eliminate cache interactions. (Only as a debug step — the
   flush is correct and should remain in production.)
