/*
 * platform.inc — TI AM625 (BeaglePlay) peripheral base addresses
 *
 * AM625 memory map per SPRUJ87A (AM62x TRM).
 * All peripheral addresses derived from module base addresses.
 */

/* UART0 (Main domain, 16550-compatible) */
.equ UART0_BASE,       0x02800000

/* CPSW 3G Ethernet (Main domain) */
.equ CPSW_BASE,        0x08000000
.equ CPSW_NUSS_BASE,   0x08000000
.equ CPSW_ALE_BASE,    0x0803E000
.equ CPSW_PORT1_BASE,  0x08001000
.equ CPSW_PORT2_BASE,  0x08002000
.equ CPSW_CPDMA_BASE,  0x0800A000
.equ CPSW_STATS_BASE,  0x08001A00

/* DMTIMER (General-purpose timers, Main domain) */
.equ DMTIMER0_BASE,    0x02400000

/* GTC (Global Timebase Counter — feeds CNTPCT_EL0) */
.equ GTC_BASE,         0x00A90000

/* GPIO (Main domain) */
.equ GPIO0_BASE,       0x00600000
.equ GPIO1_BASE,       0x00601000

/* I2C (Main domain) */
.equ I2C0_BASE,        0x20000000

/* Kernel load address (standard AArch64) */
.equ KERNEL_BASE,      0x80000
