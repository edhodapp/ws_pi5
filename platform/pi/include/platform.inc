/*
 * platform.inc — Platform-specific peripheral base addresses
 *
 * Two targets:
 *   BCM2837 (Pi 3) — for QEMU raspi3b testing
 *   BCM2711 (Pi 4) — for production hardware
 *
 * Default: Pi 3 (QEMU testing). Define PLATFORM_PI4 to switch.
 */

.ifdef PLATFORM_PI4
    /* BCM2711 (Raspberry Pi 4) */
    .equ PERIPH_BASE,  0xFE000000
.else
    /* BCM2837 (Raspberry Pi 3) — QEMU raspi3b */
    .equ PERIPH_BASE,  0x3F000000
.endif

/* All peripheral addresses derived from PERIPH_BASE */
.equ UART_OFFSET,      0x201000
.equ UART3_OFFSET,     0x201600    /* Pi 4 only: PL011 UART3 */
.equ GPIO_OFFSET,      0x200000
.equ DWC2_OFFSET,      0x980000
.equ MBOX_OFFSET,      0x00B880
.equ PM_OFFSET,        0x100000    /* PM (Power Manager) — system watchdog lives here */

/* PM peripheral register offsets (relative to PERIPH_BASE + PM_OFFSET).
 * Documented in BCM2835 ARM Peripherals §13 and BCM2711 Peripheral
 * Spec §10. Layout is identical between BCM2835/2837 (Pi 3) and
 * BCM2711 (Pi 4), so the same constants serve both, but the watchdog
 * is only armed on Pi 4 in production — QEMU raspi3b doesn't model
 * the PM block. Every write must be OR'd with PM_PASSWORD; writes
 * without the password are silently ignored. */
.equ PM_RSTC,          0x1c        /* reset control */
.equ PM_RSTS,          0x20        /* reset status (last-reset reason) */
.equ PM_WDOG,          0x24        /* 24-bit timeout in 1/65536-s units */
.equ PM_PASSWORD,      0x5A000000  /* must OR'd with all PM writes */
.equ PM_RSTC_WRCFG_FULL_RESET, 0x20  /* trigger full SoC reset on expiry */
.equ PM_RSTC_WRCFG_CLR,        0x10  /* disable / clear the watchdog */
.equ PM_RSTC_WRCFG_MASK,       0x30  /* mask covering both WRCFG bits */
