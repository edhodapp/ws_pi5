/*
 * uart.inc — 16550-compatible UART register offsets (TI AM625)
 *
 * AM625 UARTs are 16550-compatible per SPRUJ87A §12.
 * Register offsets are 4-byte spaced (32-bit access).
 */

.equ UART_RHR,         0x00    /* Receive Holding Register (read) */
.equ UART_THR,         0x00    /* Transmit Holding Register (write) */
.equ UART_IER,         0x04    /* Interrupt Enable Register */
.equ UART_IIR,         0x08    /* Interrupt Identification Register (read) */
.equ UART_FCR,         0x08    /* FIFO Control Register (write) */
.equ UART_LCR,         0x0C    /* Line Control Register */
.equ UART_MCR,         0x10    /* Modem Control Register */
.equ UART_LSR,         0x14    /* Line Status Register */
.equ UART_MSR,         0x18    /* Modem Status Register */
.equ UART_SCR,         0x1C    /* Scratch Register */
.equ UART_DLL,         0x00    /* Divisor Latch Low (LCR.DLAB=1) */
.equ UART_DLH,         0x04    /* Divisor Latch High (LCR.DLAB=1) */
.equ UART_MDR1,        0x20    /* Mode Definition Register 1 (TI extension) */

/* LSR bit masks */
.equ UART_LSR_DR,      0x01    /* Data Ready */
.equ UART_LSR_THRE,    0x20    /* Transmit Holding Register Empty */

/* LCR bit masks */
.equ UART_LCR_DLAB,    0x80    /* Divisor Latch Access Bit */
.equ UART_LCR_8N1,     0x03    /* 8 data bits, no parity, 1 stop bit */

/* FCR bit masks */
.equ UART_FCR_ENABLE,  0x07    /* Enable + reset TX/RX FIFOs */

/* MDR1 modes */
.equ UART_MDR1_16X,    0x00    /* 16x mode (standard UART) */
.equ UART_MDR1_DISABLE, 0x07  /* Disable UART */
