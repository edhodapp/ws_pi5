/*
 * uart0_test.S — Minimal UART0 test kernel for Pi 4
 *
 * Loads at 0x80000 (default). No GPIO pin mux needed — UART0
 * on GPIO 14/15 is the default after firmware init.
 * Prints "UART0 OK\r\n" forever.
 */

.equ UART0_BASE,   0xFE201000

.equ DR,           0x000
.equ FR,           0x018
.equ IBRD,         0x024
.equ FBRD,         0x028
.equ LCRH,         0x02C
.equ CR,           0x030
.equ ICR,          0x044

.equ FR_TXFF,      0x20

.section .text._start

.global _start

_start:
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    .Lel1_ready

    mrs     x0, HCR_EL2
    orr     x0, x0, #(1 << 31)
    msr     HCR_EL2, x0
    mov     x0, #3
    msr     CNTHCTL_EL2, x0
    msr     CNTVOFF_EL2, xzr
    mov     x0, #0x33FF
    msr     CPTR_EL2, x0
    mov     x0, #0x3C5
    msr     SPSR_EL2, x0
    adr     x0, .Lel1_ready
    msr     ELR_EL2, x0
    eret

.Lel1_ready:
    /* UART0 init at 115200 (48 MHz clock) */
    ldr     x9, =UART0_BASE
    str     wzr, [x9, #CR]
    mov     w0, #0x7FF
    str     w0, [x9, #ICR]
    mov     w0, #26
    str     w0, [x9, #IBRD]
    mov     w0, #3
    str     w0, [x9, #FBRD]
    mov     w0, #0x70
    str     w0, [x9, #LCRH]
    mov     w0, #0x301
    str     w0, [x9, #CR]

    /* Print forever */
.Lprint_loop:
    adr     x10, msg
.Lchar:
    ldrb    w0, [x10], #1
    cbz     w0, .Ldelay
1:  ldr     w1, [x9, #FR]
    tst     w1, #FR_TXFF
    b.ne    1b
    str     w0, [x9, #DR]
    b       .Lchar

.Ldelay:
    mov     x0, #0x4000000
1:  sub     x0, x0, #1
    cbnz    x0, 1b
    b       .Lprint_loop

.Lpark:
    wfe
    b       .Lpark

msg:    .asciz "UART0 OK\r\n"
