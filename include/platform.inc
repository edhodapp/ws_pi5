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
.equ DWC2_OFFSET,      0x980000
.equ MBOX_OFFSET,      0x00B880
