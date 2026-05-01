.include "uart.inc"

.global uart_init
.global uart_set_base
.global uart_putc
.global uart_puts

.section .text

/*
 * uart_set_base - Override the UART base address
 * x0: new UART base address
 * Call before uart_init to switch from UART0 to UART3.
 * Leaf function.
 */
uart_set_base:
    ldr     x1, =uart_hw_base
    str     x0, [x1]
    ret

/*
 * uart_init - Initialize PL011 UART at the stored base address
 * Clobbers: x0, x1, x2
 */
uart_init:
    ldr     x2, =uart_hw_base
    ldr     x2, [x2]               /* x2 = UART base */

    str     wzr, [x2, #UART_CR_OFS]    /* Disable UART */

    mov     w0, #0x7FF
    str     w0, [x2, #UART_ICR_OFS]    /* Clear all interrupts */

    /* Set baud rate: 115200 at 48MHz clock
     * Divider = 48000000 / (16 * 115200) = 26.0416...
     * IBRD = 26, FBRD = round(0.0416 * 64) = 3 */
    mov     w0, #26
    str     w0, [x2, #UART_IBRD_OFS]

    mov     w0, #3
    str     w0, [x2, #UART_FBRD_OFS]

    /* 8 bits, FIFOs enabled, no parity */
    mov     w0, #UART_LCRH_WLEN8_FEN
    str     w0, [x2, #UART_LCRH_OFS]

    /* Enable UART, TX and RX */
    mov     w0, #UART_CR_EN_TXRX
    str     w0, [x2, #UART_CR_OFS]

    ret

/*
 * uart_putc - Send a single character
 * x0: character to send
 * Clobbers: x1, x2
 */
uart_putc:
    ldr     x1, =uart_hw_base
    ldr     x1, [x1]               /* x1 = UART base */
1:  ldr     w2, [x1, #UART_FR_OFS]
    tst     w2, #UART_FR_TXFF
    b.ne    1b                     /* Wait while TX FIFO is full */

    str     w0, [x1, #UART_DR_OFS]
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

/*
 * uart_puthex_byte - Print w0's low byte as two ASCII hex chars
 * x0: byte to print (low 8 bits)
 * Clobbers: x0..x3, x19, x30
 */
.global uart_puthex_byte
uart_puthex_byte:
    stp     x19, x30, [sp, #-16]!
    mov     w19, w0                /* save byte */
    /* high nibble */
    lsr     w0, w19, #4
    and     w0, w0, #0xF
    cmp     w0, #10
    b.lt    1f
    add     w0, w0, #('a' - 10)
    b       2f
1:  add     w0, w0, #'0'
2:  bl      uart_putc
    /* low nibble */
    and     w0, w19, #0xF
    cmp     w0, #10
    b.lt    3f
    add     w0, w0, #('a' - 10)
    b       4f
3:  add     w0, w0, #'0'
4:  bl      uart_putc
    ldp     x19, x30, [sp], #16
    ret

/* Default UART base address (UART0) — overridable via uart_set_base */
.section .data
.balign 8
uart_hw_base: .quad UART_BASE
