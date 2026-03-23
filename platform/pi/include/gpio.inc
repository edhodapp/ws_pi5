/*
 * gpio.inc — BCM2711 GPIO function select constants
 *
 * GPFSEL0-5 each control 10 GPIO pins (3 bits per pin).
 * GPIO_BASE derived from platform.inc.
 */

.include "platform.inc"

.equ GPIO_BASE,         (PERIPH_BASE + GPIO_OFFSET)

/* GPFSEL registers: GPFSEL0 at +0x00, GPFSEL1 at +0x04, ... */
/* Each covers 10 pins, 3 bits per pin */

/* Function select values (3-bit field per pin) */
.equ GPIO_FSEL_INPUT,   0
.equ GPIO_FSEL_OUTPUT,  1
.equ GPIO_FSEL_ALT0,    4
.equ GPIO_FSEL_ALT1,    5
.equ GPIO_FSEL_ALT2,    6
.equ GPIO_FSEL_ALT3,    7
.equ GPIO_FSEL_ALT4,    3
.equ GPIO_FSEL_ALT5,    2

/* Fake register block size for tests (6 GPFSEL regs × 4 bytes + padding) */
.equ GPIO_FAKE_SIZE,    0x20
