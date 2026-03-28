# Firmware-Level GENET Initialization Research

## Date: 2026-03-28

## Problem Statement

BCM2711 GENET TX DMA does not work under BOTH our bare-metal kernel AND U-Boot
when booted from our SD card. PiOS works on the same Pi 4 hardware. The problem
is in the boot environment (firmware/config.txt/device tree), not the driver.

Our current config.txt:
```
arm_64bit=1
enable_uart=1
dtoverlay=disable-bt
```

---

## Finding 1: The Firmware (start4.elf) Initializes GENET BEFORE the ARM CPU Boots

This is the single most important finding. The VideoCore GPU firmware
(start4.elf) **initializes the GENET controller before the ARM CPU is even
powered on**. The firmware:

1. Loads the device tree blob (bcm2711-rpi-4-b.dtb)
2. Applies overlays from config.txt
3. Reads the GENET node properties from the DTB
4. **Initializes the GENET hardware** based on those properties
5. Sets up the RGMII GPIO pinmux (GPIO 46-57 high-speed mux)
6. Configures the PHY (BCM54213PE) via MDIO
7. Writes `local-mac-address` into the DTB for the kernel
8. Passes the modified DTB to the kernel at boot

**Critical implication**: If the firmware does not see a GENET node with
`status = "okay"` in the device tree, it may skip GENET hardware
initialization entirely. Our bare-metal kernel does not use a device tree
at all, which means **the firmware may not be initializing GENET**.

Sources:
- https://forums.raspberrypi.com/viewtopic.php?t=349563
- https://forums.raspberrypi.com/viewtopic.php?t=294815

---

## Finding 2: PiOS Default config.txt vs. Our config.txt

### PiOS Bookworm default config.txt:
```
# For more options and information see
# http://rptl.io/configtxt
# Some settings may impact device functionality.
# See link above for details

# Uncomment some or all of these to enable the optional hardware interfaces
#dtparam=i2c_arm=on
#dtparam=i2s=on
#dtparam=spi=on

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

# Automatically load overlays for detected cameras
camera_auto_detect=1

# Automatically load overlays for detected DSI displays
display_auto_detect=1

# Automatically load initramfs files, if found
auto_initramfs=1

# Enable DRM VC4 V3D driver
dtoverlay=vc4-kms-v3d
max_framebuffers=2

# Don't have the firmware create an initial video= setting in cmdline.txt.
# Use the kernel's default instead.
disable_fw_kms_setup=1

# Run in 64-bit mode
arm_64bit=1

# Disable compensation for displays with overscan
disable_overscan=1

# Run as fast as firmware / board allows
arm_boost=1
```

### Our config.txt:
```
arm_64bit=1
enable_uart=1
dtoverlay=disable-bt
```

### Key differences:
- PiOS does NOT explicitly set any ethernet dtparam values -- ethernet is
  enabled by default in the base DTB
- PiOS does NOT have `device_tree=` (which would disable DT processing)
- PiOS lets the firmware load `bcm2711-rpi-4-b.dtb` automatically
- **Our config.txt does not prevent DTB loading** -- the firmware should
  still load the DTB by default. BUT: if we are not providing kernel8.img
  as a Linux kernel, the firmware may behave differently.

Source:
- https://forums.raspberrypi.com/viewtopic.php?t=355619

---

## Finding 3: GENET Device Tree Node (What the Firmware Reads)

### In bcm2711.dtsi (base SoC definition):
```
genet: ethernet@7d580000 {
    compatible = "brcm,bcm2711-genet-v5";
    reg = <0x0 0x7d580000 0x10000>;
    #address-cells = <0x1>;
    #size-cells = <0x1>;
    interrupts = <GIC_SPI 157 IRQ_TYPE_LEVEL_HIGH>,
                 <GIC_SPI 158 IRQ_TYPE_LEVEL_HIGH>;
    status = "disabled";      // <-- DISABLED in base DTB

    genet_mdio: mdio@e14 {
        compatible = "brcm,genet-mdio-v5";
        reg = <0xe14 0x8>;
        reg-names = "mdio";
        #address-cells = <0x1>;
        #size-cells = <0x0>;
    };
};
```

### In bcm2711-rpi-4-b.dts (board-specific):
```
&genet {
    phy-handle = <&phy1>;
    phy-mode = "rgmii-rxid";
    status = "okay";           // <-- ENABLED for Pi 4B
};

&genet_mdio {
    phy1: ethernet-phy@1 {
        reg = <0x1>;           // PHY address 1
    };
};
```

**The firmware reads this DTB and sees `status = "okay"`, which triggers
GENET hardware initialization.** Without this, the GENET may be left in
its power-on-reset state with RGMII pins not configured.

Note: The GENET node has NO explicit `power-domains` or `clocks` properties
in the upstream device tree. This means either:
- The GENET clock/power is always-on in the BCM2711, OR
- The firmware handles clock/power setup based on the `status` property

Source:
- https://github.com/raspberrypi/linux/blob/rpi-6.6.y/arch/arm/boot/dts/broadcom/bcm2711.dtsi

---

## Finding 4: RGMII GPIO High-Speed Multiplexer

The GENET uses a **special high-speed multiplexer** for GPIO 46-57 that
is separate from the normal GPIO alt-function mux:

- GPIO 28: RGMII_MDIO (alt5)
- GPIO 29: RGMII_MDC (alt5)
- GPIO 46: RGMII_RXCLK (special high-speed mux)
- GPIO 47: RGMII_RXCTL
- GPIO 48-51: RGMII_RXD0-3
- GPIO 52: RGMII_TXCLK
- GPIO 53: RGMII_TXCTL
- GPIO 54-57: RGMII_TXD0-3

When the high-speed mux is activated, the normal alt-function settings
for GPIO 46-57 are irrelevant. The pull configuration still affects these
pins. **This mux is likely configured by the firmware during boot.**

`raspi-gpio get` cannot correctly display the state of GPIO 46-57 when
the high-speed mux is active.

Source:
- https://forums.raspberrypi.com/viewtopic.php?t=294815

---

## Finding 5: "Write-Once" Registers in GENET Hardware

Some GENET registers are **write-once** after hardware reset of the BCM2711.
After the first write, subsequent writes are silently ignored. Even the
GENET's own software reset does not restore writeability -- only a full
BCM2711 hardware reset does.

The affected registers are all related to **DMA ring configuration**:
- RX ring: Write Pointer, Producer Index, Start/End Addresses
- TX ring: Read Pointer, Consumer Index, Start/End Addresses

**Implication for our driver**: If the firmware writes these registers
during its GENET initialization, our driver's subsequent writes to
reinitialize the rings may be silently dropped. The U-Boot GENET driver
works around this by reading back the current values instead of assuming
zero:

```c
/* cannot init RDMA_PROD_INDEX to 0, so align RDMA_CONS_INDEX
   on it instead */
priv->c_index = readl(priv->mac_reg + RDMA_PROD_INDEX);
writel(priv->c_index, priv->mac_reg + RDMA_CONS_INDEX);

/* cannot init TDMA_CONS_INDEX to 0, so align TDMA_PROD_INDEX
   on it instead */
priv->tx_index = readl(priv->mac_reg + TDMA_CONS_INDEX);
writel(priv->tx_index, priv->mac_reg + TDMA_PROD_INDEX);
```

Source:
- https://forums.raspberrypi.com/viewtopic.php?t=349563

---

## Finding 6: Ethernet dtparam Options (Not the Root Cause)

The base DTB supports these ethernet-related dtparam values:

- `dtparam=eth_led0=<N>` -- LED0 mode (green on Pi4, default "0" = Speed/Activity)
- `dtparam=eth_led1=<N>` -- LED1 mode (amber on Pi4, default "8" = Link)
- `dtparam=eth_max_speed=<N>` -- Max negotiated speed (10/100/1000)
- `dtparam=eee=on|off` -- Energy Efficient Ethernet (default "on")

None of these are required for basic GENET operation. PiOS does not set
any of them in its default config.txt. These are cosmetic/optional.

Source:
- https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README

---

## Finding 7: U-Boot GENET Driver Has No Firmware/Mailbox Calls

The U-Boot bcmgenet driver (drivers/net/bcmgenet.c) performs **no firmware
mailbox calls and no power domain/clock management**. It assumes the
firmware has already:
1. Enabled the GENET clock domain
2. Configured the RGMII GPIO pinmux
3. Powered up the PHY

The driver only does: UMAC reset, DMA ring setup, PHY link via MDIO, and
MAC enable. This confirms that **the firmware must do the heavy lifting**.

The U-Boot driver reads `phy-mode` and `phy-handle` from the device tree
that was passed by the firmware. It uses the firmware-modified DTB.

Source:
- https://github.com/u-boot/u-boot/blob/master/drivers/net/bcmgenet.c

---

## Finding 8: Circle Bare-Metal Framework (Working GENET Driver)

The Circle C++ bare-metal environment (rsta2/circle) has a **working GENET
driver** for Raspberry Pi 4. Key observations from its BCM54213 driver:

1. Uses `CBcmPropertyTags` (mailbox) to get the MAC address from firmware
2. Reads `SYS_REV_CTRL` to verify GENET v5
3. Performs UMAC reset sequence
4. Initializes DMA rings
5. Connects interrupt handlers
6. Probes PHY via MDIO
7. Sets `SYS_PORT_CTRL` to `PORT_MODE_EXT_GPHY` (external gigabit PHY)

**Importantly**: Circle boots WITH the device tree. The firmware loads
bcm2711-rpi-4-b.dtb and initializes the GENET hardware before Circle's
kernel runs. Circle then drives the already-initialized hardware.

Register definitions from Circle confirm the GENET base is 0xFD580000
(ARM physical address space, mapped from bus address 0x7D580000).

Key power management registers in the GENET EXT block:
- `EXT_EXT_PWR_MGMT` (offset 0x80+0x00): PHY power control
  - `EXT_PWR_DOWN_PHY` (bit 2)
  - `EXT_PHY_RESET` (bit 8)
  - `EXT_PWR_DOWN_PHY_TX` (bit 16)
  - `EXT_PWR_DOWN_PHY_RX` (bit 17)
- `EXT_GPHY_CTRL` (offset 0x80+0x1C): GPHY control
  - `EXT_CFG_IDDQ_BIAS` (bit 0)
  - `EXT_CFG_PWR_DOWN` (bit 1)
  - `EXT_CK25_DIS` (bit 4) -- 25 MHz clock disable
  - `EXT_GPHY_RESET` (bit 5) -- PHY reset

Source:
- https://github.com/rsta2/circle/blob/master/lib/bcm54213.cpp

---

## Finding 9: UEFI GENET Driver (EDK2) Initialization

The Tianocore EDK2 UEFI firmware includes a GENET driver for Raspberry Pi 4.
Key aspects of its initialization:

1. Maps MMIO base from platform device
2. Allocates DMA buffers (TX: 256 x packet size, RX: 256 x 1536 bytes)
3. Configures MAC, frame length, speed
4. Sets up PHY via Broadcom shadow registers for RGMII timing
5. Programs DMA ring start/end addresses
6. Enables RX/TX DMA
7. Sets TXEN/RXEN in UMAC_CMD

Like U-Boot, the UEFI driver **relies on the firmware (start4.elf) having
already initialized clocks, power, and GPIO** before the driver runs.

Source:
- https://github.com/tianocore/edk2-platforms/commit/8f330caf903963aadae92372b3ef0a98335c0931

---

## Finding 10: config.txt Settings That Affect Firmware Behavior

Critical config.txt settings that may affect GENET initialization:

### `device_tree=` (empty value)
Completely disables device tree processing. If set, the firmware will NOT
load any DTB, will NOT initialize hardware based on DT nodes, and the
GENET will likely be left uninitialized.

### `enable_gic=1`
Required when device tree is disabled. Default is 1 with DT, 0 without.
Not directly related to GENET but indicates firmware behavior changes
when DT is absent.

### `os_check=0`
Disables firmware OS compatibility checks. Needed for bare-metal kernels.

### DTB Auto-Loading
By default (without `device_tree=` set), the firmware automatically loads
the appropriate DTB for the board. For Pi 4B: `bcm2711-rpi-4-b.dtb`.
The firmware then:
- Patches the DTB with MAC address
- Applies config.txt overlays
- Passes DTB address in x0 (AArch64)

Source:
- https://www.raspberrypi.com/documentation/computers/config_txt.html
- https://forums.raspberrypi.com/viewtopic.php?t=293320

---

## Root Cause Hypothesis

The most likely root cause of our GENET TX DMA failure is:

### Hypothesis A: Firmware GENET Initialization Depends on DTB

1. Our config.txt does NOT set `device_tree=` (so DTB should still load)
2. The firmware loads `bcm2711-rpi-4-b.dtb`
3. The firmware sees `genet` node with `status = "okay"`
4. The firmware **should** initialize GENET hardware (RGMII mux, PHY, clocks)
5. Our bare-metal kernel then needs to work with the firmware-initialized state

If this is correct, then the firmware IS initializing GENET, and the problem
is in our driver's interaction with the write-once registers or DMA setup.

### Hypothesis B: Firmware Does NOT Initialize GENET Without Linux Kernel

The firmware may detect that the kernel is not a Linux kernel (no device
tree cmdline, no initramfs, different binary format) and skip some hardware
initialization. This could leave GENET in its reset state with:
- RGMII high-speed mux not activated
- PHY not powered up or reset
- 25 MHz reference clock disabled
- GPIO 46-57 not configured for RGMII

This would explain why TX DMA "doesn't work" -- the physical layer is dead.

### Hypothesis C: Write-Once Register Conflict

The firmware initializes GENET DMA ring registers (which are write-once).
Our driver then tries to write different values, which are silently ignored.
The ring configuration is now inconsistent with what our driver expects,
causing TX DMA to never complete.

---

## Recommended Actions

### Immediate: Verify Firmware DTB Processing

1. **Check if DTB is being loaded**: Add `kernel=kernel8.img` to config.txt
   explicitly. The firmware auto-detects kernel filename but may behave
   differently for bare-metal binaries.

2. **Ensure DTB exists on SD card**: Verify that `bcm2711-rpi-4-b.dtb` is
   present in the boot partition alongside our kernel. If missing, the
   firmware cannot initialize GENET.

3. **Read x0 on entry**: At our kernel entry point, x0 should contain the
   DTB address if the firmware loaded one. If x0 is 0 or invalid, the
   firmware may not be processing the DTB.

### Immediate: Test with PiOS-style config.txt

Try this config.txt to match PiOS more closely:
```
arm_64bit=1
enable_uart=1
dtoverlay=disable-bt
dtparam=audio=off
disable_overscan=1
```

The key is that we are NOT setting `device_tree=` and we ARE letting the
firmware load the default DTB. The audio/overscan lines are cosmetic but
match PiOS patterns.

### Immediate: Verify DTB Files on SD Card

Ensure the boot partition has:
- `start4.elf` (Pi 4 firmware)
- `fixup4.dat` (Pi 4 firmware companion)
- `bcm2711-rpi-4-b.dtb` (device tree blob)
- `overlays/` directory with `disable-bt.dtbo`
- `kernel8.img` (our kernel)
- `config.txt`

If `bcm2711-rpi-4-b.dtb` is missing, the firmware cannot do GENET init.

### Driver Fix: Handle Write-Once Registers

In our GENET driver, do NOT assume DMA ring registers start at 0. Instead:
```
// Read current values from write-once registers
prod_index = readl(RDMA_PROD_INDEX);
writel(prod_index, RDMA_CONS_INDEX);  // Align consumer to producer

tx_cons = readl(TDMA_CONS_INDEX);
writel(tx_cons, TDMA_PROD_INDEX);     // Align producer to consumer
```

### Diagnostic: Dump GENET Registers at Boot

Before our driver touches anything, read and print:
- `SYS_REV_CTRL` (0x7D580000 + 0x00) -- should be GENET v5 identifier
- `SYS_PORT_CTRL` (0x7D580000 + 0x04) -- should be PORT_MODE_EXT_GPHY (3)
- `EXT_RGMII_OOB_CTRL` (0x7D580000 + 0x8C) -- RGMII mode bits
- `EXT_GPHY_CTRL` (0x7D580000 + 0x9C) -- PHY power/reset state
- `EXT_EXT_PWR_MGMT` (0x7D580000 + 0x80) -- power management
- `UMAC_CMD` (0x7D580000 + 0x808) -- MAC command register
- `RDMA_PROD_INDEX` / `TDMA_CONS_INDEX` -- DMA ring state

If `SYS_REV_CTRL` reads as 0 or 0xFFFFFFFF, the GENET block is not
clocked/powered. If `EXT_GPHY_CTRL` shows PHY in reset, the firmware
did not initialize it.

### Long-Term: PHY Power-Up Sequence

If the firmware is NOT initializing the PHY, our driver needs to:
1. Clear `EXT_CFG_IDDQ_BIAS` and `EXT_CFG_PWR_DOWN` in `EXT_GPHY_CTRL`
2. Enable the 25 MHz clock: clear `EXT_CK25_DIS` in `EXT_GPHY_CTRL`
3. De-assert PHY reset: clear `EXT_GPHY_RESET` in `EXT_GPHY_CTRL`
4. Wait for PHY to stabilize (~100ms)
5. Set `SYS_PORT_CTRL` to `PORT_MODE_EXT_GPHY` (value 3)
6. Configure RGMII OOB: set `RGMII_MODE_EN`, `RGMII_LINK`, clear `OOB_DISABLE`
7. If using rgmii-rxid mode: set `ID_MODE_DIS` in `EXT_RGMII_OOB_CTRL`

### Long-Term: RGMII Pinmux

If the firmware is not activating the high-speed RGMII mux for GPIO 46-57,
this may need to be done manually. The mechanism for activating this mux is
undocumented -- it is not the standard GPIO alt-function register. The
firmware binary (start4.elf) contains the code to do this, but it is not
open source.

---

## Key References

- Hardware pitfalls thread (write-once registers):
  https://forums.raspberrypi.com/viewtopic.php?t=349563
- Pi 4 Ethernet Controller info (RGMII pinmux):
  https://forums.raspberrypi.com/viewtopic.php?t=294815
- U-Boot bcmgenet driver:
  https://github.com/u-boot/u-boot/blob/master/drivers/net/bcmgenet.c
- Circle bare-metal BCM54213 driver:
  https://github.com/rsta2/circle/blob/master/lib/bcm54213.cpp
- EDK2 UEFI GENET driver:
  https://github.com/tianocore/edk2-platforms/commit/8f330caf903963aadae92372b3ef0a98335c0931
- Raspberry Pi Linux DTS:
  https://github.com/raspberrypi/linux/blob/rpi-6.6.y/arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts
- Firmware overlay README (dtparam options):
  https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README
- config.txt documentation:
  https://www.raspberrypi.com/documentation/computers/config_txt.html
- Firmware issue #613 (MAC address in DTB):
  https://github.com/raspberrypi/firmware/issues/613
- "Ethernet sometimes fails" (clock issues):
  https://github.com/raspberrypi/linux/issues/3195
- genet rgmii-rxid issue:
  https://github.com/raspberrypi/linux/issues/3417
