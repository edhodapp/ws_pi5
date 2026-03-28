# Complete Pi 4 (BCM2711) Hardware Initialization: Power-On Through Ethernet TX

Traces the FULL hardware initialization sequence from power-on through GENET TX
operational under Raspberry Pi OS, for bare-metal driver development.

Date: 2026-03-28

---

## Phase 1: GPU Firmware (start4.elf)

The Pi 4 boot sequence differs from Pi 3. There is no `bootcode.bin` — an
on-chip Boot ROM in the BCM2711 SoC loads the second-stage bootloader from
SPI EEPROM. That bootloader reads the SD card's FAT partition and loads
`start4.elf` (the VideoCore VI GPU firmware) plus `fixup4.dat` (memory
split fixup) into GPU memory.

### 1.1 What clocks does the firmware enable?

The firmware enables ALL SoC clocks needed by the peripherals referenced in
the device tree. For GENET/Ethernet specifically:

**There is no dedicated "GENET clock" in the firmware mailbox interface.**

The firmware mailbox clock IDs (from `raspberrypi-firmware.h`) are:

| ID | Name | Notes |
|----|------|-------|
| 1 | EMMC | SD card clock |
| 2 | UART | PL011 UART clock (48 MHz) |
| 3 | ARM | ARM core clock |
| 4 | CORE | VPU core clock (250/400 MHz) |
| 5 | V3D | 3D graphics |
| 6 | H264 | Video decode |
| 7 | ISP | Camera ISP |
| 8 | SDRAM | Memory clock |
| 9 | PIXEL | Display pixel clock |
| 10 | PWM | PWM clock |
| 11 | HEVC | HEVC decode |
| 12 | EMMC2 | SD card (Pi 4 secondary) |
| 13 | M2MC | Memory-to-memory copy |
| 14 | PIXEL_BVB | Pixel BVB |

**No ethernet/GENET clock ID exists.** The GENET block receives its clock
from an internal SoC clock tree that the firmware configures as part of
the general peripheral bring-up. The GENET peripheral is clocked by the
VPU/system bus clock infrastructure — it does not have a separate gatable
clock from the firmware's perspective.

Evidence: The BCM2711 device tree for the GENET node has NO `clocks`
property:

```dts
genet: ethernet@7d580000 {
    compatible = "brcm,bcm2711-genet-v5";
    reg = <0x0 0x7d580000 0x10000>;
    interrupts = <GIC_SPI 157 IRQ_TYPE_LEVEL_HIGH>,
                 <GIC_SPI 158 IRQ_TYPE_LEVEL_HIGH>;
    status = "disabled";
};
```

The Linux driver uses `devm_clk_get_optional(&pdev->dev, "enet")` — note
**optional**. On BCM2711, this returns NULL (no clock). The subsequent
`clk_prepare_enable(NULL)` is a no-op. The Linux kernel log on Pi 4 shows:
`bcmgenet fd580000.genet: failed to get enet clock` (demoted to debug level
since it is expected).

**Conclusion: The GENET clock is always on once the firmware has initialized
the SoC. There is no mailbox call needed to enable it. Since RX DMA works in
our bare-metal driver, the GENET block is definitely clocked and powered.**

### 1.2 What power domains does the firmware configure?

The firmware manages power domains via the `raspberrypi,bcm2835-power`
driver. The mailbox power device IDs are:

| ID | Device |
|----|--------|
| 0 | SD Card |
| 1 | UART0 |
| 2 | UART1 |
| 3 | USB HCD |
| 4 | I2C0 |
| 5 | I2C1 |
| 6 | I2C2 |
| 7 | SPI |
| 8 | CCP2TX |
| 9 | Unknown (RPi4) |
| 10 | Unknown (RPi4) |

**There is no GENET/Ethernet power domain ID.** The GENET block is part of
an always-on power domain within the BCM2711 SoC.

The GENET DT node has no `power-domains` property. Only V3D has an explicit
power domain: `power-domains = <&pm BCM2835_POWER_DOMAIN_GRAFX_V3D>`.

**Conclusion: No power domain enable is needed for GENET. The firmware
enables the SoC power domains that require explicit control; GENET is not
one of them.**

### 1.3 What does `enable_uart=1` do at the firmware level?

`enable_uart=1` in `config.txt` tells the firmware to:

1. **Fix the VPU core clock frequency** to 250 MHz (or 400 MHz if
   `force_turbo` is set). This is critical because the mini-UART's baud rate
   is derived from the VPU core clock — without a fixed frequency, the baud
   rate drifts as the governor changes speed.

2. **Enable the primary UART** as the Linux console. On Pi 4, by default:
   - PL011 (UART0) is connected to the Bluetooth module
   - Mini-UART is the primary UART on GPIO 14/15

   With `enable_uart=1` alone (without `disable-bt`), the mini-UART is
   enabled as the console on GPIO 14/15.

3. **Configure the UART clock**: The firmware sets the PL011 UART clock to
   48 MHz (tag `SET_CLOCK_RATE`, clock ID 2). This is a fixed rate that
   the PL011 baud rate divisor calculations depend on.

### 1.4 What does `dtoverlay=disable-bt` do at the firmware level?

`dtoverlay=disable-bt` tells the firmware to:

1. **Disable the Bluetooth module** (the BCM43455 wireless/BT chip).

2. **Reassign PL011 (UART0) to GPIO 14/15** (the GPIO header pins). Without
   this overlay, PL011 is connected to the BT module and the mini-UART gets
   GPIO 14/15.

3. **Modify the device tree blob in memory** before ARM handoff: the firmware
   applies the overlay, which changes the `uart0` node's pin mux from BT to
   GPIO header and disables the BT UART.

Combined with `enable_uart=1`, this gives us PL011 (full-featured UART) on
GPIO 14/15 at a stable 48 MHz clock, which is the configuration our
bare-metal `config.txt` uses.

### 1.5 Does the firmware initialize any GENET registers?

**Partially, yes.** The firmware initializes the GENET block enough for
network boot (PXE) and device tree fixups. Specifically:

1. **MAC address**: The firmware reads the board's MAC address from OTP
   (one-time programmable memory) and writes it into the device tree `local-mac-address`
   property for the GENET node.

2. **PHY initialization**: The firmware brings up the BCM54213PE external PHY
   via MDIO, at minimum to check for network boot capability. This means:
   - The 25 MHz reference clock to the PHY is enabled
   - The GPHY control register (EXT_GPHY_CTRL at +0x09C) is configured
   - PHY reset is deasserted

3. **Write-once registers may be set**: If the firmware touches GENET DMA
   ring registers for PXE boot, those write-once registers (TDMA_CONS_INDEX,
   TDMA_READ_PTR, RDMA_PROD_INDEX, RDMA_WRITE_PTR) retain their values and
   subsequent bare-metal writes are silently ignored. On a cold boot without
   network boot, these registers should be at their reset defaults (0).

4. **EXT_EXT_PWR_MGMT (+0x080)**: The firmware configures the PHY power
   management register. Since the Pi 4 uses an external PHY, the internal
   PHY power-down bits should be in a benign state. The firmware does NOT
   power down PHY TX (bit 16) since it may need the network.

### 1.6 ARM state when firmware jumps to kernel8.img

When the firmware loads `kernel8.img` to address 0x80000 and jumps to it:

| Register/State | Value | Notes |
|---------------|-------|-------|
| Exception Level | EL2 | Non-secure EL2 (via armstub8.bin) |
| x0 | DTB physical address | Device tree blob location in RAM |
| x1-x3 | 0 | Reserved |
| MMU | **OFF** | SCTLR_EL2.M = 0 |
| D-cache | **OFF** | SCTLR_EL2.C = 0 |
| I-cache | **OFF** | SCTLR_EL2.I = 0 |
| SP | undefined | Must be set by kernel |
| DAIF | all masked | Interrupts disabled |
| HCR_EL2.RW | 1 | EL1 is AArch64 |
| PC | 0x80000 | Entry point |
| Core 0 | running | Executes kernel |
| Cores 1-3 | parked (WFE) | Spinning at defined addresses |

The default `armstub8.bin` (built into the firmware) handles the EL3 to EL2
transition. For `arm_64bit=1`, the stub:
1. Runs at EL3, configures SCR_EL3 for non-secure EL2
2. Sets HCR_EL2.RW = 1 (AArch64 EL1)
3. Places DTB address in x0
4. ERETss to EL2 at 0x80000

**For bare-metal**: Our `boot.S` detects EL2 via `CurrentEL`, then drops to
EL1 using ERET. This matches the expected firmware handoff.

### 1.7 DMA controllers and bus fabric

The firmware configures the BCM2711's address translation:

**Low Peripheral mode** (default for Pi 4):
- ARM sees peripherals at `0xFE000000` (legacy BCM2835 peripherals)
- ARM sees extended peripherals at `0xFC000000` - `0xFE000000`
  (GENET at `0xFD580000`, PCIe at `0xFD500000`)
- The VideoCore/GPU sees peripherals at `0x7E000000` (legacy bus address)
- GENET DMA sees RAM at physical addresses 0x00000000 - 0x3FFFFFFF (1 GB)

**Critical for GENET DMA**: The GENET's internal DMA engine accesses RAM
using **CPU physical addresses directly**. Unlike the legacy DMA controller
(which uses bus addresses with a `0xC0000000` offset for uncached access),
the GENET DMA does NOT apply the `0xC0000000` offset.

Evidence from U-Boot: `bcmgenet_gmac_eth_send()` uses the raw physical
address without any bus address translation. Circle, FreeBSD, and OpenBSD
do the same.

The firmware does NOT configure any IOMMU for GENET — the GENET DMA sees
the same physical address space as the ARM core (for the lower 1 GB).

---

## Phase 2: ARM Kernel Boot (Before GENET Driver)

### 2.1 MMU setup — how are peripheral addresses mapped?

Linux maps the BCM2711 address space during early boot:

1. **RAM**: Identity-mapped as Normal Cacheable (Write-Back, Inner Shareable)
   for the first 1-4 GB.

2. **Peripherals**: ioremap'd as Device-nGnRnE (non-Gathering, non-Reordering,
   non-Early-write-acknowledgement). The GENET block at physical 0xFD580000
   is mapped to a kernel virtual address via `devm_platform_ioremap_resource()`.

3. **Our bare-metal boot.S**: Maps GB 0-2 as Normal WB, GB 3 entries 0-479
   as Normal WB, entries 480-511 as Device (covering 0xFC000000-0xFFFFFFFF).
   GENET at 0xFD580000 falls in the Device region. **This matches Linux's
   approach.**

### 2.2 Clock framework init

The Linux clock framework on BCM2711 registers clocks in this order:

1. **bcm2835-cprman** (Clock/Power Manager): Registers the hardware PLLs
   and clock dividers directly accessible via CM registers at 0xFE101000.
   These include UART clock (BCM2835_CLOCK_UART = ID 19), VPU clock, etc.

2. **raspberrypi-clk**: Registered by the firmware driver's probe function.
   This driver provides firmware-managed clocks that are controlled via
   mailbox tags. It registers clocks named: "emmc", "uart", "arm", "core",
   "v3d", "h264", "isp", "sdram", "pixel", "pwm", "hevc", "emmc2",
   "m2mc", "pixel-bvb", "vec", "disp".

   **Note: No "enet" clock is registered by raspberrypi-clk.** The firmware
   clock name array does not contain an ethernet entry. The firmware does not
   expose a GENET clock through the mailbox interface.

3. The `clk-raspberrypi.c` driver's `is_prepared` callback queries the
   firmware via `RPI_FIRMWARE_GET_CLOCK_STATE` (tag 0x00030001) and checks
   `RPI_FIRMWARE_STATE_ENABLE_BIT`. But since no "enet" clock is registered,
   this is never called for GENET.

### 2.3 Power domain init

The `raspberrypi,bcm2835-power` driver registers power domains during probe.
It communicates with the firmware via mailbox tags:
- `RPI_FIRMWARE_GET_DOMAIN_STATE` (tag 0x00030030)
- `RPI_FIRMWARE_SET_DOMAIN_STATE` (tag 0x00038030)

Only V3D has an explicit power domain in the device tree. GENET has none.

### 2.4 Device tree processing for GENET

The GENET node is processed during device model init:

```dts
/* From bcm2711.dtsi */
genet: ethernet@7d580000 {
    compatible = "brcm,bcm2711-genet-v5";
    reg = <0x0 0x7d580000 0x10000>;
    interrupts = <GIC_SPI 157 IRQ_TYPE_LEVEL_HIGH>,
                 <GIC_SPI 158 IRQ_TYPE_LEVEL_HIGH>;
    status = "disabled";
};

/* From bcm2711-rpi-4-b.dts */
&genet {
    phy-handle = <&phy1>;
    phy-mode = "rgmii-rxid";
    status = "okay";
};

&genet_mdio {
    phy1: ethernet-phy@1 {
        reg = <0x1>;
    };
};
```

Key observations:
- **No `clocks` property** — the "enet" clock is optional and absent
- **No `power-domains` property** — GENET is always-on
- **PHY mode is `rgmii-rxid`** — RGMII with RX internal delay (the PHY
  adds delay on the RX path; TX delay is handled by GENET's ID_MODE)
- **PHY address is 1** — MDIO address of the BCM54213PE
- The firmware patches `local-mac-address` into this node at boot

### 2.5 The raspberrypi-clk driver

The `clk-raspberrypi.c` driver is registered as a platform device by
`rpi_register_clk_driver()` in the firmware probe function. During its own
probe, it iterates over the `rpi_firmware_clk_names` array and registers
each clock with the Linux clock framework.

The clock names registered are:
```
emmc, uart, arm, core, v3d, h264, isp, sdram,
pixel, pwm, hevc, emmc2, m2mc, pixel-bvb, vec, disp
```

**"enet" is NOT in this list.** The driver does not register an Ethernet
clock because the firmware does not expose one.

The driver has NO `.prepare`/`.unprepare` or `.enable`/`.disable` callbacks.
It only implements: `is_prepared`, `recalc_rate`, `determine_rate`, and
`set_rate`. The `is_prepared` callback queries the firmware for the current
state of the clock.

### 2.6 The raspberrypi-firmware driver

During probe (`rpi_firmware_probe`), the firmware driver:

1. Requests the mailbox channel (`mbox_request_channel`)
2. Queries firmware revision (`RPI_FIRMWARE_GET_FIRMWARE_REVISION`)
3. Queries firmware hash (`RPI_FIRMWARE_GET_FIRMWARE_HASH`)
4. Registers the hwmon driver (throttle monitoring)
5. Registers the clock driver platform device

**No clock or power domain initialization occurs during firmware probe.**
The firmware driver simply provides the mailbox communication channel that
other drivers use.

Mailbox communication format:
- Channel: `MBOX_CHAN_PROPERTY = 8`
- Buffer: 16-byte aligned, DMA-coherent
- Format: `[total_size, request_code, {tag, buf_size, req_resp_size, data...}, end_tag]`
- Write: physical address | channel to `MBOX_WRITE` register
- Poll: `MBOX_STATUS` bit 30 (EMPTY), then read `MBOX_READ`
- Response: buffer code has bit 31 set on success

---

## Phase 3: GENET Probe (bcmgenet_probe)

### 3.1 Resources requested

```c
static int bcmgenet_probe(struct platform_device *pdev)
{
    // 1. Get IRQs (2 required, 1 optional WOL)
    priv->irq0 = platform_get_irq(pdev, 0);    // GIC_SPI 157
    priv->irq1 = platform_get_irq(pdev, 1);    // GIC_SPI 158
    priv->wol_irq = platform_get_irq_optional(pdev, 2);

    // 2. Map register space
    priv->base = devm_platform_ioremap_resource(pdev, 0);
    // Maps physical 0x7d580000, size 0x10000 to kernel virtual address

    // 3. Get platform data (version + DMA burst length)
    pdata = device_get_match_data(&pdev->dev);
    // For "brcm,bcm2711-genet-v5": version=GENET_V5, dma_max_burst_length=0x08

    // 4. Get optional clocks
    priv->clk = devm_clk_get_optional(&pdev->dev, "enet");
    // Returns NULL on BCM2711 — no "enet" clock in DT

    // 5. Enable clock (no-op when priv->clk is NULL)
    clk_prepare_enable(priv->clk);  // clk_prepare_enable(NULL) = no-op

    // 6. Set hardware parameters
    bcmgenet_set_hw_params(priv);
    // Sets: words_per_bd=3, tdma_offset=0x4000, rdma_offset=0x2000,
    //        tbuf_offset=0x0600, flags=GENET_HAS_40BITS|GENET_HAS_EXT|...

    // 7. Set DMA mask
    dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(40));

    // 8. Get optional WOL and EEE clocks (both NULL on BCM2711)
    priv->clk_wol = devm_clk_get_optional(&pdev->dev, "enet-wol");
    priv->clk_eee = devm_clk_get_optional(&pdev->dev, "enet-eee");

    // 9. Internal PHY power-up (SKIPPED for BCM2711 — external RGMII PHY)
    if (device_get_phy_mode(&pdev->dev) == PHY_INTERFACE_MODE_INTERNAL)
        bcmgenet_power_up(priv, GENET_POWER_PASSIVE);
    // PHY_INTERFACE_MODE_RGMII_RXID != INTERNAL, so SKIPPED

    // 10. Get MAC address from device tree (firmware-patched)
    device_get_ethdev_address(&pdev->dev, dev);

    // 11. Reset UMAC
    reset_umac(priv);

    // 12. Init MII/MDIO
    bcmgenet_mii_init(dev);

    // 13. Disable clock until open()
    clk_disable_unprepare(priv->clk);  // no-op (NULL clock)
}
```

### 3.2 Registers read/written during probe

During `bcmgenet_set_hw_params`:
```
READ  [+0x000]  SYS_REV_CTRL    — reads GENET version (major=6 for v5)
```

During `reset_umac`:
```
WRITE [+0x008]  SYS_RBUF_FLUSH_CTRL = 0
DELAY 10 us
WRITE [+0x808]  UMAC_CMD = CMD_SW_RESET (0x2000)
DELAY 2 us
```

### 3.3 clk_prepare_enable during probe

Called at line 4117 of `bcmgenet.c`:
```c
err = clk_prepare_enable(priv->clk);
```

On BCM2711, `priv->clk` is NULL (returned by `devm_clk_get_optional`).
`clk_prepare_enable(NULL)` is defined to return 0 (success) with no hardware
effect. **No clock hardware is touched.**

### 3.4 reset_umac and init_umac in probe

Only `reset_umac` is called during probe (not `init_umac`). The full
`init_umac` sequence runs during `bcmgenet_open()`.

`reset_umac` writes:
```
WRITE [+0x008] = 0           SYS_RBUF_FLUSH_CTRL (clear any stale reset)
DELAY 10 us
WRITE [+0x808] = 0x2000      UMAC_CMD (CMD_SW_RESET)
DELAY 2 us
```

---

## Phase 4: Device-Specific Init Sequences

### 4a. PL011 UART (UART0 on GPIO 14/15)

**Clock**: PL011 requires two clocks:
- `uartclk` = BCM2835_CLOCK_UART (48 MHz, set by firmware)
- `apb_pclk` = BCM2835_CLOCK_VPU (APB bus clock)

From the device tree:
```dts
uart0: serial@7e201000 {
    compatible = "arm,pl011", "arm,primecell";
    reg = <0x7e201000 0x200>;
    clocks = <&clocks BCM2835_CLOCK_UART>,
             <&clocks BCM2835_CLOCK_VPU>;
    clock-names = "uartclk", "apb_pclk";
};
```

**What `enable_uart=1` does at firmware level**:
1. Fixes VPU core_freq to 250 MHz (ensures stable baud rate)
2. Sets UART clock to 48 MHz via CM registers
3. Does NOT initialize PL011 registers — the Linux driver or bare-metal
   code must configure the baud rate divisor, line control, and enables

**What `dtoverlay=disable-bt` does**:
1. Remaps PL011 from BT module to GPIO 14/15
2. Disables BT module UART assignment
3. The firmware applies this as a DT overlay, modifying the pin mux in the
   DTB before ARM handoff

**For bare-metal**: The firmware has already:
- Set GPIO 14 to ALT0 (UART0 TXD)
- Set GPIO 15 to ALT0 (UART0 RXD)
- Enabled the UART clock at 48 MHz

Our `uart_init` then configures the PL011 registers:
- IBRD/FBRD for 115200 baud from 48 MHz clock
- LCRH for 8N1
- CR for TX/RX enable

**UART base address**:
- Pi 4 low-peripheral mode: `PERIPH_BASE + UART_OFFSET = 0xFE000000 + 0x201000 = 0xFE201000`
- UART3 (for GPIO 4/5): `0xFE000000 + 0x201600 = 0xFE201600`

### 4b. Mailbox

**The VideoCore mailbox is always available** — it does not need clock or
power enable. It is part of the always-on SoC infrastructure.

Mailbox registers:
```
MBOX_BASE = PERIPH_BASE + 0x00B880 = 0xFE00B880
MBOX_READ    = MBOX_BASE + 0x00
MBOX_STATUS  = MBOX_BASE + 0x18
MBOX_WRITE   = MBOX_BASE + 0x20
```

Status bits:
- Bit 31: FULL (wait before writing)
- Bit 30: EMPTY (wait before reading)

The mailbox is initialized by the firmware before ARM handoff. No ARM-side
initialization is needed beyond constructing properly formatted request
buffers and performing cache maintenance (clean before write, invalidate
after read).

### 4c. GPIO

**No global GPIO controller init is needed for basic pin I/O.**

The firmware initializes the GPIO controller and sets default pin functions
based on the device tree. For our config:
- GPIO 14: ALT0 (UART0 TXD) — set by firmware for `enable_uart=1`
- GPIO 15: ALT0 (UART0 RXD) — set by firmware for `enable_uart=1`

GPIO base: `PERIPH_BASE + 0x200000 = 0xFE200000`

The GPIO controller is always clocked and powered. Pin function registers
(GPFSELn) and pull-up/down registers are accessible immediately.

For additional GPIO pins (UART3 on GPIO 4/5, fan on GPIO 14), our bare-metal
code writes the appropriate GPFSEL register to set the alt function.

### 4d. GENET — The Full Clock/Power Analysis

#### What does `clk_prepare_enable(priv->clk)` ACTUALLY DO on BCM2711?

**Nothing.** On BCM2711:

1. `devm_clk_get_optional(&pdev->dev, "enet")` returns `NULL` because the
   GENET DT node has no `clocks` property.

2. `clk_prepare_enable(NULL)` is a no-op defined in `include/linux/clk.h`:
   ```c
   static inline int clk_prepare_enable(struct clk *clk)
   {
       if (!clk) return 0;
       // ...
   }
   ```

3. There is no firmware mailbox call, no register write, no clock gate
   toggle. The GENET block runs on an always-on internal clock.

#### Is there a power domain enable?

**No.** The GENET DT node has no `power-domains` property. The GENET block
is in an always-on power domain within the BCM2711 SoC.

The only devices with explicit power domains in the Pi 4 DT are:
- V3D (BCM2835_POWER_DOMAIN_GRAFX_V3D)
- USB (RPI_POWER_DOMAIN_USB)
- DSI, CSI, VEC (various video domains)

#### Clock/power trace through raspberrypi-clk.c → firmware mailbox

**This path is NOT taken for GENET.** The `clk-raspberrypi.c` driver does
not register an "enet" clock because the firmware does not expose one. The
firmware clock name list is: emmc, uart, arm, core, v3d, h264, isp, sdram,
pixel, pwm, hevc, emmc2, m2mc, pixel-bvb, vec, disp.

There is no firmware tag or clock ID for GENET Ethernet.

---

## Critical Question: Why Does GENET TX DMA Not Work?

### What the firmware and Linux do that we might be missing

Based on this complete trace, the firmware and Linux do NOT enable any
special clock or power domain for GENET. The following are the actual
differences between our bare-metal driver and working implementations:

### Root Cause: TDMA DMA_CTRL enables unconfigured rings

**This is identified in TDMA_RESEARCH.md and GENET_TX_ANALYSIS.md as the
primary suspect, and the analysis here confirms it is the ONLY significant
difference from working implementations.**

Every working bare-metal/bootloader GENET TX implementation uses:

| Implementation | TDMA DMA_CTRL | Status |
|---------------|---------------|--------|
| U-Boot | 0x00020001 (ring 16 + DMA_EN only) | Works |
| Circle | 0x0002001F (rings 0-3 + ring 16 + DMA_EN, but all configured) | Works |
| FreeBSD | ring 16 + DMA_EN | Works |
| OpenBSD | ring 16 + DMA_EN | Works |
| UEFI/EDK2 | ring 16 + DMA_EN | Works |
| **Our code** | **0x0002001F (rings 0-3 + ring 16, rings 0-3 NOT configured)** | **Broken** |

Circle uses 0x0002001F because it configures rings 0-3 with proper
START_ADDR, END_ADDR, RING_BUF_SIZE, etc. Our code enables rings 0-3 in
DMA_CTRL but does NOT configure their ring registers, leaving them with
garbage/zero values. The DMA arbiter attempts to service these unconfigured
rings, corrupting the TX data path.

**Fix**: Change TDMA DMA_CTRL from `0x0002001F` to `DMA_CTRL_EN` (`0x00020001`).

In `genet.S` line 242-243:
```asm
/* Currently: */
ldr     w0, =0x0002001F
str     w0, [x22, #TDMA_DMA_CTRL_OFS]

/* Fix: */
ldr     w0, =DMA_CTRL_EN       /* 0x00020001 = ring 16 + DMA_EN */
str     w0, [x22, #TDMA_DMA_CTRL_OFS]
```

### Secondary concerns (not clock/power related)

1. **Write-once registers**: On warm reboot, TDMA_READ_PTR write may be
   silently ignored. Read back and verify after writing.

2. **Speed encoding**: Verify UMAC_CMD speed bits match the PHY's negotiated
   speed. The encoding is:
   ```
   CMD_SPEED_SHIFT = 2
   speed_10  = 0 << 2 = 0x00
   speed_100 = 1 << 2 = 0x04
   speed_1000 = 2 << 2 = 0x08
   ```

3. **EXT_EXT_PWR_MGMT (+0x080)**: Read and verify bit 16
   (EXT_PWR_DOWN_PHY_TX) is not set. This controls the internal PHY TX
   power and should be clear for external PHY, but worth checking.

### What we can definitively rule out

Based on this trace, these are NOT the problem:

1. **Missing clock enable**: There is no GENET clock to enable. The block
   is always on. RX working proves this.

2. **Missing power domain**: There is no GENET power domain. The block is
   in an always-on domain.

3. **Missing firmware mailbox call**: No mailbox call is needed for GENET.
   The firmware does not expose a GENET clock ID or power domain ID.

4. **Missing DMA bus address translation**: GENET DMA uses CPU physical
   addresses directly. Our identity-mapped MMU with addresses in the lower
   1 GB is correct. U-Boot does the same.

5. **Missing MMU/cache configuration**: Our Device-nGnRnE mapping for the
   peripheral region matches Linux's ioremap. Our cache flush (dc civac +
   dsb sy) before TX is correct.

---

## Summary: Complete Init Sequence for Bare-Metal GENET TX

For a working bare-metal GENET TX on Pi 4, the FULL required init is:

### Prerequisites (handled by firmware, verified by RX working):
- SoC clocks: running (always-on for GENET)
- Power domains: on (always-on for GENET)
- PHY clock: enabled (25 MHz reference)
- GPIO: default state (GENET uses RGMII pins, not GPIO-muxed)

### ARM-side init:
```
1. MMU: identity-map, Device-nGnRnE for 0xFC000000-0xFFFFFFFF
2. UMAC reset: SYS_RBUF_FLUSH toggle, CMD_SW_RESET, MIB clear
3. SYS_PORT_CTRL = 3 (EXT_GPHY mode)
4. UMAC_MAX_FRAME_LEN = 1536
5. RBUF_TBUF_SIZE_CTRL = 1  (allocate TX buffer SRAM)
6. Mask all interrupts
7. EXT_RGMII_OOB_CTRL: set RGMII_LINK | RGMII_MODE_EN, clear OOB_DISABLE
8. PHY reset via MDIO, configure RGMII timing, auto-negotiate
9. Disable DMA (clear DMA_EN in both TDMA and RDMA DMA_CTRL)
10. TX flush (UMAC_TX_FLUSH toggle)
11. Init RX descriptors + ring 16 registers
12. Init TX ring 16 registers (START_ADDR=0, END_ADDR=0x2FF, etc.)
13. DMA_SCB_BURST_SIZE = 8 (both RDMA and TDMA)
14. DMA_RING_CFG = 0x10000 (ring 16 enable)
15. DMA_CTRL = 0x00020001 (ring 16 + DMA_EN)  *** NOT 0x0002001F ***
16. UMAC_CMD: set speed bits, then set CMD_TX_EN | CMD_RX_EN
17. Set MAC address (UMAC_MAC0, UMAC_MAC1)
```

No mailbox calls needed. No clock enables needed. No power domain enables
needed.

---

## Sources

- [Mailbox property interface](https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface) — complete clock and power device IDs
- [Hardware pitfalls with BCM2711 Genet Ethernet controller](https://forums.raspberrypi.com/viewtopic.php?t=349563) — write-once registers, hardware errata
- [BCM2711 ARM Peripherals datasheet](https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf) — address mapping, low peripheral mode
- [Trusted Firmware-A RPi 4 port](https://trustedfirmware-a.readthedocs.io/en/latest/plat/rpi4.html) — EL2 handoff, armstub8 behavior
- [Raspberry Pi config.txt documentation](https://www.raspberrypi.com/documentation/computers/config_txt.html) — enable_uart, dtoverlay
- [Linux bcmgenet.c driver](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/broadcom/genet/bcmgenet.c) — probe, open, clk_prepare_enable
- [Linux clk-raspberrypi.c](https://github.com/raspberrypi/linux/blob/rpi-6.6.y/drivers/clk/bcm/clk-raspberrypi.c) — firmware clock registration, no "enet" clock
- [Linux raspberrypi-firmware.h](https://github.com/raspberrypi/linux/blob/rpi-6.6.y/include/soc/bcm2835/raspberrypi-firmware.h) — clock/power IDs
- [Linux raspberrypi.c firmware driver](https://github.com/raspberrypi/linux/blob/rpi-6.6.y/drivers/firmware/raspberrypi.c) — probe, mailbox communication
- [Linux bcm2711.dtsi](https://github.com/raspberrypi/linux/blob/rpi-6.6.y/arch/arm/boot/dts/broadcom/bcm2711.dtsi) — GENET DT node (no clocks, no power-domains)
- [Linux bcm2711-rpi-4-b.dts](https://github.com/raspberrypi/linux/blob/rpi-6.6.y/arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts) — Pi 4 specific overrides
- [U-Boot bcmgenet.c](https://github.com/u-boot/u-boot/blob/master/drivers/net/bcmgenet.c) — minimal working TX (DMA_CTRL=0x00020001)
- [Circle bcm54213.cpp](https://github.com/rsta2/circle/blob/master/lib/bcm54213.cpp) — bare-metal C++ GENET driver
- [brcm,bcmgenet.txt DT binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/net/brcm,bcmgenet.txt) — clocks are optional
- [Reduce severity of missing clock warnings (patch)](https://patchwork.ozlabs.org/patch/1232215/) — confirms clocks optional on BCM2711
- [Firmware issue #1894](https://github.com/raspberrypi/firmware/issues/1894) — power domain mailbox behavior
- [Firmware issue #1374](https://github.com/raspberrypi/firmware/issues/1374) — low peripheral mode addressing
- [Bare metal networking on Pi 4](https://forums.raspberrypi.com/viewtopic.php?t=323242) — community discussion
