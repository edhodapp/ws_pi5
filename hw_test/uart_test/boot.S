/*
 * uart_test/boot.S — Minimal UART3 test kernel for Pi 4
 *
 * Loads at 0x80000 (default kernel address).
 * Configures GPIO 4/5 for ALT4 (UART3), inits UART3 at 115200 8N1,
 * then loops printing "UART3 OK\r\n" forever.
 *
 * No MMU, no stack, no BSS — absolute minimum to prove the serial link.
 */

.equ GPIO_BASE,    0xFE200000
.equ UART3_BASE,   0xFE201600

/* PL011 register offsets */
.equ DR,           0x000
.equ FR,           0x018
.equ IBRD,         0x024
.equ FBRD,         0x028
.equ LCRH,         0x02C
.equ CR,           0x030
.equ ICR,          0x044

.equ FR_TXFF,      0x20    /* TX FIFO full (bit 5) */

.section .text._start

.global _start

_start:
    /* Park cores 1-3 */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    /* EL2 → EL1 drop (Pi 4 boots at EL2) */
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    .Lel1_ready

    mrs     x0, HCR_EL2
    orr     x0, x0, #(1 << 31)     /* RW: EL1 is AArch64 */
    msr     HCR_EL2, x0
    mov     x0, #3
    msr     CNTHCTL_EL2, x0        /* enable EL1 physical timer */
    msr     CNTVOFF_EL2, xzr
    mov     x0, #0x33FF
    msr     CPTR_EL2, x0           /* no trapping */
    mov     x0, #0x3C5
    msr     SPSR_EL2, x0           /* EL1h, DAIF masked */
    adr     x0, .Lel1_ready
    msr     ELR_EL2, x0
    eret

.Lel1_ready:
    /* --- GPIO: pins 4/5 → ALT4 (UART3) --- */
    ldr     x9, =GPIO_BASE
    ldr     w0, [x9]               /* GPFSEL0 */
    /* Pin 4: bits [14:12] = 3 (ALT4) */
    bic     w0, w0, #(7 << 12)
    orr     w0, w0, #(3 << 12)
    /* Pin 5: bits [17:15] = 3 (ALT4) */
    bic     w0, w0, #(7 << 15)
    orr     w0, w0, #(3 << 15)
    str     w0, [x9]

    /* --- UART3 init at 115200 (48 MHz clock) --- */
    ldr     x9, =UART3_BASE
    str     wzr, [x9, #CR]         /* disable */
    mov     w0, #0x7FF
    str     w0, [x9, #ICR]         /* clear interrupts */
    mov     w0, #26
    str     w0, [x9, #IBRD]        /* integer divisor */
    mov     w0, #3
    str     w0, [x9, #FBRD]        /* fractional divisor */
    mov     w0, #0x70
    str     w0, [x9, #LCRH]        /* 8N1, FIFOs enabled */
    mov     w0, #0x301
    str     w0, [x9, #CR]          /* enable UART, TX, RX */

    /* --- Loop: print "UART3 OK\r\n" forever --- */
.Lprint_loop:
    adr     x10, msg
.Lchar:
    ldrb    w0, [x10], #1
    cbz     w0, .Ldelay
    /* wait for TX FIFO not full */
1:  ldr     w1, [x9, #FR]
    tst     w1, #FR_TXFF
    b.ne    1b
    str     w0, [x9, #DR]
    b       .Lchar

.Ldelay:
    /* Simple delay between prints (~0.5s at ~1 GHz) */
    mov     x0, #0x4000000
1:  sub     x0, x0, #1
    cbnz    x0, 1b
    b       .Lprint_loop

.Lpark:
    wfe
    b       .Lpark

msg:    .asciz "UART3 OK\r\n"
