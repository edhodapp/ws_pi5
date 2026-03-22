.include "uart.inc"

.global uart_init
.global uart_putc
.global uart_puts

.section .text

/*
 * uart_init - Initialize PL011 UART
 * Clobbers: x0, x1
 */
uart_init:
    ldr     x1, =UART_CR
    str     wzr, [x1]              /* Disable UART */

    ldr     x1, =UART_ICR
    mov     w0, #0x7FF
    str     w0, [x1]               /* Clear all interrupts */

    /* Set baud rate: 115200 at 48MHz clock
     * Divider = 48000000 / (16 * 115200) = 26.0416...
     * IBRD = 26, FBRD = round(0.0416 * 64) = 3 */
    ldr     x1, =UART_IBRD
    mov     w0, #26
    str     w0, [x1]

    ldr     x1, =UART_FBRD
    mov     w0, #3
    str     w0, [x1]

    /* 8 bits, FIFOs enabled, no parity */
    ldr     x1, =UART_LCRH
    mov     w0, #UART_LCRH_WLEN8_FEN
    str     w0, [x1]

    /* Enable UART, TX and RX */
    ldr     x1, =UART_CR
    mov     w0, #UART_CR_EN_TXRX
    str     w0, [x1]

    ret

/*
 * uart_putc - Send a single character
 * x0: character to send
 * Clobbers: x1, x2
 */
uart_putc:
    ldr     x1, =UART_FR
1:  ldr     w2, [x1]
    tst     w2, #UART_FR_TXFF
    b.ne    1b                     /* Wait while TX FIFO is full */

    ldr     x1, =UART_DR
    str     w0, [x1]
    ret

/*
 * uart_puts - Send a null-terminated string
 * x0: pointer to string
 * Clobbers: x0, x1, x2, x19, x30
 */
uart_puts:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0                /* Save string pointer */

.Lputs_loop:
    ldrb    w0, [x19], #1
    cbz     w0, .Lputs_done
    bl      uart_putc
    b       .Lputs_loop

.Lputs_done:
    ldp     x19, x30, [sp], #16
    ret
