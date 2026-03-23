/* PL011 UART register addresses — derived from platform.inc */

.include "platform.inc"

.equ UART_BASE,    (PERIPH_BASE + UART_OFFSET)
.equ UART3_BASE,   (PERIPH_BASE + UART3_OFFSET)
.equ GPIO_BASE,    (PERIPH_BASE + GPIO_OFFSET)

/* PL011 register offsets (from any UART base) */
.equ UART_DR_OFS,    0x000    /* Data Register */
.equ UART_FR_OFS,    0x018    /* Flag Register */
.equ UART_IBRD_OFS,  0x024    /* Integer Baud Rate Divisor */
.equ UART_FBRD_OFS,  0x028    /* Fractional Baud Rate Divisor */
.equ UART_LCRH_OFS,  0x02C    /* Line Control Register */
.equ UART_CR_OFS,    0x030    /* Control Register */
.equ UART_ICR_OFS,   0x044    /* Interrupt Clear Register */

/* Absolute addresses (backward compatibility) */
.equ UART_DR,      (UART_BASE + 0x000)
.equ UART_FR,      (UART_BASE + 0x018)
.equ UART_IBRD,    (UART_BASE + 0x024)
.equ UART_FBRD,    (UART_BASE + 0x028)
.equ UART_LCRH,    (UART_BASE + 0x02C)
.equ UART_CR,      (UART_BASE + 0x030)
.equ UART_ICR,     (UART_BASE + 0x044)

/* Flag Register bits */
.equ UART_FR_TXFF, 0x20                 /* Transmit FIFO full (bit 5) */

/* Line Control Register: 8-bit word + FIFOs enabled */
.equ UART_LCRH_WLEN8_FEN, 0x70         /* (3<<5) | (1<<4) */

/* Control Register: UART + TX + RX enable */
.equ UART_CR_EN_TXRX, 0x301            /* (1<<0) | (1<<8) | (1<<9) */
