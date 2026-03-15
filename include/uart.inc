/* PL011 UART register addresses for BCM2837 (Raspberry Pi 3) */

.equ UART_BASE,    0x3F201000

.equ UART_DR,      0x3F201000           /* Data Register */
.equ UART_FR,      0x3F201018           /* Flag Register */
.equ UART_IBRD,    0x3F201024           /* Integer Baud Rate Divisor */
.equ UART_FBRD,    0x3F201028           /* Fractional Baud Rate Divisor */
.equ UART_LCRH,    0x3F20102C           /* Line Control Register */
.equ UART_CR,      0x3F201030           /* Control Register */
.equ UART_ICR,     0x3F201044           /* Interrupt Clear Register */

/* Flag Register bits */
.equ UART_FR_TXFF, 0x20                 /* Transmit FIFO full (bit 5) */

/* Line Control Register: 8-bit word + FIFOs enabled */
.equ UART_LCRH_WLEN8_FEN, 0x70         /* (3<<5) | (1<<4) */

/* Control Register: UART + TX + RX enable */
.equ UART_CR_EN_TXRX, 0x301            /* (1<<0) | (1<<8) | (1<<9) */
