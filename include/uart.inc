/* PL011 UART register addresses for BCM2711 (Raspberry Pi 4)
 * Peripheral base: 0xFE000000 (was 0x3F000000 on BCM2837/Pi 3) */

.equ UART_BASE,    0xFE201000

.equ UART_DR,      0xFE201000           /* Data Register */
.equ UART_FR,      0xFE201018           /* Flag Register */
.equ UART_IBRD,    0xFE201024           /* Integer Baud Rate Divisor */
.equ UART_FBRD,    0xFE201028           /* Fractional Baud Rate Divisor */
.equ UART_LCRH,    0xFE20102C           /* Line Control Register */
.equ UART_CR,      0xFE201030           /* Control Register */
.equ UART_ICR,     0xFE201044           /* Interrupt Clear Register */

/* Flag Register bits */
.equ UART_FR_TXFF, 0x20                 /* Transmit FIFO full (bit 5) */

/* Line Control Register: 8-bit word + FIFOs enabled */
.equ UART_LCRH_WLEN8_FEN, 0x70         /* (3<<5) | (1<<4) */

/* Control Register: UART + TX + RX enable */
.equ UART_CR_EN_TXRX, 0x301            /* (1<<0) | (1<<8) | (1<<9) */
