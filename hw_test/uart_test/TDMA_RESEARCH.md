# TDMA Research: Why CONS_INDEX Advances Without Data Transfer

Research into why BCM2711 GENET v5 TDMA advances CONS_INDEX to match
PROD_INDEX without actually performing DMA data transfers to the UMAC.

Date: 2026-03-28

---

## Symptom

On a bare-metal Pi 4:
- GENET RX DMA works (frames received, data in RAM, RX MIB counters increment)
- TX DMA descriptors are "consumed" (CONS_INDEX advances to match PROD_INDEX)
- No data is actually transferred to the UMAC (TX_GD_PKTS MIB = 0, TX FIFO empty)
- The DMA engine IS reading descriptors (CONS advances), but the UMAC-to-wire
  path is not transmitting

---

## Key Findings

### 1. CRITICAL: Unconfigured TX Rings 0-3 Enabled in DMA_CTRL

**This is the most likely root cause identified in the existing analysis.**

The bare-metal code writes TDMA DMA_CTRL = `0x0002001F`, which enables:
- Bit 0: DMA_EN
- Bits 1-4: Rings 0-3 (enabled but NEVER configured)
- Bit 17: Ring 16 (configured and used)

U-Boot writes `0x00020001` (only ring 16 + DMA_EN). Linux writes `0x0002003F`
but only AFTER configuring all rings 0-3 with START_ADDR, END_ADDR,
RING_BUF_SIZE, etc.

**Enabling unconfigured rings causes the DMA arbiter to attempt scheduling
descriptors from rings with uninitialized register values (random/zero).** This
can cause the DMA engine to:
- Read descriptors from address 0 (uninitialized START_ADDR)
- Process garbage descriptors that the UMAC rejects
- Consume ring 16 descriptors but corrupt the internal DMA state
- The arbiter tries to service rings 0-3, finds nothing valid, and the
  interleaving corrupts the ring 16 data path to the UMAC

**Fix: Change TDMA DMA_CTRL from `0x0002001F` to `0x00020001`.**

This is already identified in `GENET_TX_ANALYSIS.md` section 8 as the
primary recommended fix.

### 2. BCM2711 Write-Once Register Hardware Errata

Source: [Launchpad Bug #2000285](https://bugs.launchpad.net/raspbian/+bug/2000285)
and [Raspberry Pi Forums](https://forums.raspberrypi.com/viewtopic.php?t=349563)

The BCM2711 GENET has a critical undocumented hardware limitation: **several DMA
ring registers can only be written ONCE after a hardware reset.** Subsequent
writes are silently ignored.

**Write-once registers (cannot be re-written after first write):**
- TDMA_CONS_INDEX
- TDMA_READ_PTR
- RDMA_PROD_INDEX (lower 16 bits)
- RDMA_WRITE_PTR
- Possibly DMA_START_ADDR and DMA_END_ADDR

**Always-writable registers:**
- TDMA_PROD_INDEX (this is how software kicks TX)
- TDMA_WRITE_PTR
- RDMA_CONS_INDEX (this is how software acknowledges RX)
- RDMA_READ_PTR

**Workaround:** Write the desired value, then read it back and use the
actual hardware value. The first boot after power-on should succeed, but
warm reboots (watchdog reset without full BCM2711 reset) may leave stale
values that cannot be overwritten.

**Impact on bare-metal code:** If the Pi 4 firmware (start4.elf) has already
written these registers during network boot or initialization, the bare-metal
driver's writes to TDMA_CONS_INDEX, TDMA_READ_PTR, etc. would be silently
ignored. The code already reads CONS_INDEX and aligns PROD_INDEX to it (lines
218-219 of genet.S), which is the correct workaround. But TDMA_READ_PTR is
written to 0 (line 216) — if this write is ignored, READ_PTR could be stale.

**Recommendation:** After writing TDMA_READ_PTR, TDMA_START_ADDR, and
TDMA_END_ADDR, read them back and verify the values match. If they don't,
the hardware retained its previous state and the driver must adapt.

### 3. No Separate TDMA vs RDMA Clock Domain

There is **no evidence** of a separate clock domain for TDMA vs RDMA in any
reference (Linux, U-Boot, FreeBSD, OpenBSD, Circle, Ultibo, UEFI/EDK2).

The GENET block has a single clock gate controlled by the firmware. Since RX
DMA works, the entire GENET block is clocked and powered. The TDMA and RDMA
share the same system bus clock for DMA transfers.

The UMAC TX *output* clock is derived from the UMAC_CMD speed setting:
- 25 MHz for 100 Mbps
- 125 MHz for 1000 Mbps

This is the RGMII transmit clock, not a DMA clock. A speed mismatch between
UMAC_CMD and the PHY would cause garbled TX but would not explain CONS_INDEX
advancing without UMAC TX FIFO receiving data.

### 4. No Specific Pi 4 Firmware Power Domain for GENET TX

Linux calls `clk_prepare_enable(priv->clk)` for the "enet" clock, but on
Pi 4 the firmware enables this before the kernel boots. Since RX works, the
clock is enabled.

The `EXT_EXT_PWR_MGMT` register (+0x080) has per-function power-down bits:
- Bit 16: EXT_PWR_DOWN_PHY_TX — powers down PHY TX
- Bit 17: EXT_PWR_DOWN_PHY_RX
- Bits 18-20: Other PHY power-down bits
- Bit 7: EXT_IDDQ_GLBL_PWR — global IDDQ
- Bit 0-1: EXT_PWR_DOWN_BIAS, EXT_PWR_DOWN_DLL

**However**, these control the *internal* PHY. The Pi 4 uses an *external*
BCM54213PE PHY connected via RGMII. Linux only touches EXT_EXT_PWR_MGMT for
internal PHY systems. U-Boot never touches it. The firmware should leave it
in a benign state.

**Recommendation:** Read and print EXT_EXT_PWR_MGMT (+0x080) to verify no
TX power-down bits are set. If bit 16 is set, clear it.

### 5. No Known BCM2711 GENET TX DMA Errata (Beyond Write-Once)

There are no published BCM2711 errata sheets. The only documented hardware
bugs come from the community (the write-once register issue above and the
non-functional link status interrupts).

Known hardware issues:
1. **Write-once ring registers** (see #2 above)
2. **Link status interrupts do not work** — bits 0x10 and 0x20 in INTRL2
   never fire. Must poll PHY BMSR instead.
3. **UMAC_MODE register (0x0844) does not respond** — reads cause bus stalls.
   Cannot be used for link status detection.
4. **TX garbage after link reconnection** — without stopping TDMA and flushing
   TX FIFO before reconnecting, garbage can precede the first packet.

None of these explain CONS_INDEX advancing without data transfer on a fresh
cold boot.

### 6. TBUF_CTRL / TBUF_64B_EN Analysis

TBUF_CTRL at +0x600 controls the Transmit Status Block (TSB):
- Bit 0: TBUF_64B_EN — when set, hardware expects a 64-byte TSB prepended
  to each TX buffer

**Linux** sets TBUF_64B_EN and prepends a 64-byte TSB to each packet.
**U-Boot** does NOT set TBUF_64B_EN and does NOT prepend a TSB.
**Bare-metal** does NOT set TBUF_64B_EN and does NOT prepend a TSB.

Since U-Boot works without TBUF_64B_EN, this is **not the root cause**.
The TBUF_64B_EN flag is only needed for hardware checksum offload via the TSB.

### 7. RBUF_TBUF_SIZE_CTRL (+0x3B4)

This register must be written to `1` to allocate TX buffer space within the
GENET's internal SRAM. All drivers (Linux, U-Boot, FreeBSD, OpenBSD, Circle)
write this register to 1.

The bare-metal code writes it to 1 at line 179-180 of genet.S. **Correct.**

### 8. DMA Arbiter Configuration

Linux sets `DMA_ARB_CTRL` (+0x506C) to `DMA_ARBITER_SP` (0x02, strict
priority) and configures `DMA_PRIORITY_0/1/2` registers.

U-Boot does NOT set the arbiter. OpenBSD does NOT set the arbiter. The EDK2
UEFI driver does NOT set the arbiter.

The arbiter defaults likely work for a single-ring (ring 16 only) configuration.
**However**, if unconfigured rings 0-3 are enabled (the DMA_CTRL bug from #1),
the default arbiter mode could interleave service between the configured ring 16
and the unconfigured rings, causing unpredictable behavior.

**This reinforces the importance of fix #1** — only enable ring 16 in DMA_CTRL.

### 9. Cross-Implementation Comparison

| Implementation | DMA_CTRL value | TBUF_64B_EN | DMA_ARB | Rings used | Status |
|---------------|---------------|-------------|---------|------------|--------|
| Linux         | 0x0002003F    | Yes (TSB)   | SP (0x02) | 0-3 + 16  | Works  |
| U-Boot        | 0x00020001    | No          | Default   | 16 only   | Works  |
| FreeBSD       | ring16+EN     | No          | Default   | 16 only   | Works  |
| OpenBSD       | ring16+EN     | No          | Default   | 16 only   | Works  |
| Circle        | ring16+EN     | No          | Default   | 16 only   | Works  |
| UEFI/EDK2     | ring16+EN     | No          | Default   | 16 only   | Works  |
| **Bare-metal**| **0x0002001F**| No          | Default   | **0-3+16**| **Broken** |

Every working implementation that uses only ring 16 sets DMA_CTRL to enable
ONLY ring 16 + DMA_EN. The bare-metal code is the only one that enables
unconfigured rings.

---

## Hypotheses for CONS_INDEX Advancing Without TX

### Hypothesis A: Unconfigured ring corruption (HIGHEST PROBABILITY)

With rings 0-3 enabled but unconfigured, the DMA arbiter services them
in rotation. When it services ring 0 (START_ADDR=0, END_ADDR=0 or garbage),
the DMA may:
1. Read a "descriptor" from GENET internal register space (address 0 relative
   to descriptor base)
2. Transfer garbage to the UMAC TX FIFO
3. The UMAC detects an invalid frame (length=0, bad CRC setup, etc.) and
   silently drops it without incrementing TX_GD_PKTS
4. Meanwhile, ring 16 descriptors are also consumed by the DMA, but the
   interleaving with garbage from rings 0-3 corrupts the TX FIFO pipeline

The CONS_INDEX for ring 16 advances because the DMA engine does process
those descriptors. But the UMAC never successfully transmits because the
TX FIFO contains interleaved garbage.

### Hypothesis B: Stale TDMA_READ_PTR from firmware (MEDIUM PROBABILITY)

If the firmware wrote TDMA_READ_PTR during network boot (PXE, etc.), the
bare-metal write of READ_PTR=0 would be silently ignored (write-once).
The DMA would start reading descriptors from a non-zero offset into the
descriptor ring, potentially reading uninitialized memory.

### Hypothesis C: UMAC speed mismatch (LOW-MEDIUM PROBABILITY)

If UMAC_CMD speed bits don't match the negotiated PHY speed, the RGMII TX
clock frequency would be wrong. The PHY would not be able to lock onto the
data. The DMA would still consume descriptors (CONS advances) because the
DMA and UMAC TX FIFO are decoupled — the DMA feeds the FIFO, and the FIFO
drains to RGMII. If the RGMII clock is wrong, frames would be corrupted
on the wire but the UMAC might still count them (or might not, depending
on internal error detection).

The existing code's speed mapping looks correct based on analysis.

### Hypothesis D: Cache coherency / address mapping (LOW PROBABILITY)

If the TX buffer's physical address doesn't match what the DMA reads,
the DMA would transfer garbage. The bare-metal code uses `dc civac` to
clean the cache and writes `mov w0, w21` (truncating to 32-bit physical
address) into the descriptor. With identity-mapped MMU, this should be
correct. But worth verifying by reading back the descriptor after writing.

---

## Recommended Fix Order

### Fix 1: TDMA DMA_CTRL = 0x00020001 (ring 16 only + DMA_EN)

In `/home/edhodapp/ws_pi5/platform/pi/drivers/genet.S`, line 242-243:

Change:
```asm
ldr     w0, =0x0002001F
str     w0, [x22, #TDMA_DMA_CTRL_OFS]
```
To:
```asm
ldr     w0, =DMA_CTRL_EN       /* 0x00020001 = ring 16 + DMA_EN */
str     w0, [x22, #TDMA_DMA_CTRL_OFS]
```

This matches U-Boot, FreeBSD, OpenBSD, Circle, and UEFI — all of which work.

### Fix 2: Read-back write-once registers

After writing TDMA_READ_PTR, TDMA_START_ADDR, and TDMA_END_ADDR, read them
back and print via UART. If the values don't match what was written, the
firmware already set them and the writes were ignored.

```asm
/* After TX ring init, verify write-once registers */
ldr     w0, [x22, #TDMA_READ_PTR_OFS]
/* compare with 0, print if different */
ldr     w0, [x22, #TDMA_START_ADDR_OFS]
/* compare with 0 */
ldr     w0, [x22, #TDMA_END_ADDR_OFS]
/* compare with 0x2FF */
```

### Fix 3: Diagnostic register dump after TX attempt

Read and print these registers after a failed TX to narrow down the fault:

```
[+0xB3C] UMAC_TX_FIFO_STATUS  — non-zero = data stuck in FIFO (UMAC config)
                                 zero = DMA didn't write to FIFO (DMA/addr)
[+0x080] EXT_EXT_PWR_MGMT     — check bit 16 (EXT_PWR_DOWN_PHY_TX)
[+0x808] UMAC_CMD              — verify speed + TX_EN + no SW_RESET
[+0x5044] TDMA DMA_CTRL       — verify correct enable bits
[+0x5048] TDMA DMA_STATUS     — check for errors
[+0xCA8] TX pkts MIB          — any TX at all?
[+0xCCC] TX FCS error MIB     — frames with bad CRC?
[+0xCD8] TX excessive deferral — TX blocked?
```

### Fix 4: Loopback test to isolate UMAC vs RGMII/PHY

Set CMD_LCL_LOOP_EN (bit 15) in UMAC_CMD along with TX_EN|RX_EN. Send a
frame and check if it appears on the RX ring.
- **If loopback works**: problem is RGMII timing or PHY configuration
- **If loopback fails**: problem is UMAC or DMA configuration

---

## Summary

The primary suspect is **enabling unconfigured DMA rings 0-3 in TDMA DMA_CTRL**.
This is the single difference between the bare-metal configuration and every
known working implementation (U-Boot, FreeBSD, OpenBSD, Circle, UEFI).

The BCM2711 write-once register errata is a secondary concern that could
cause issues on warm reboot but should not affect a cold boot.

There is no separate TDMA/RDMA clock domain. There is no GENET-specific
firmware power domain beyond the global clock gate (which is clearly enabled
since RX works). There are no published BCM2711 errata for GENET TX DMA beyond
the write-once register behavior.

---

## Sources

- [Hardware pitfalls with BCM2711 Genet Ethernet controller](https://forums.raspberrypi.com/viewtopic.php?t=349563) — write-once registers, link interrupt failures, undocumented limitations
- [Bug #2000285: Genet driver not handling BCM2711 limitations](https://bugs.launchpad.net/raspbian/+bug/2000285) — write-once register details and affected register list
- [Linux bcmgenet.c driver](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/broadcom/genet/bcmgenet.c) — reference implementation with full TX queue init
- [Linux bcmgenet.h header](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/broadcom/genet/bcmgenet.h) — register definitions, DMA_CTRL bits
- [U-Boot bcmgenet.c driver](https://github.com/u-boot/u-boot/blob/master/drivers/net/bcmgenet.c) — minimal working TX implementation
- [Circle bcm54213.cpp](https://github.com/rsta2/circle/blob/master/lib/bcm54213.cpp) — bare-metal C++ GENET driver
- [OpenBSD bcmgenet.c](https://github.com/openbsd/src/blob/master/sys/dev/ic/bcmgenet.c) — BSD GENET driver
- [UEFI/EDK2 GENET driver](https://github.com/tianocore/edk2-platforms/commit/8f330caf903963aadae92372b3ef0a98335c0931) — UEFI bare-metal GENET driver
- [Bare metal networking on Pi 4](https://forums.raspberrypi.com/viewtopic.php?t=323242) — community discussion
- [Pi 4 GENET controller information](https://forums.raspberrypi.com/viewtopic.php?t=294815) — hardware architecture
- [eth0 bcmgenet transmit queue timed out](https://github.com/raspberrypi/linux/issues/4485) — Linux TX timeout issues
- [Ethernet fails to start on Pi 4](https://github.com/raspberrypi/linux/issues/3195) — link negotiation failures
- [FreeBSD genet(4) manual](https://man.freebsd.org/cgi/man.cgi?genet(4)) — FreeBSD driver documentation
- [Ultibo Unit GENET](https://ultibo.org/wiki/Unit_GENET) — Pascal bare-metal GENET driver
- [Linux bcmmii.c](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/broadcom/genet/bcmmii.c) — RGMII/PHY configuration
