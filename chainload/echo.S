/*
 * echo.S — Bidirectional UART byte test.
 * Sends 0x00,0x01,...,0xFF,0x00,... while receiving and verifying
 * the same pattern from the host. On RX error, TX switches to
 * 0xDE,0xAD repeating so the host can detect the failure.
 */

.equ UART_BASE,  0xFE201000
.equ DR,         0x000
.equ FR,         0x018
.equ IBRD,       0x024
.equ FBRD,       0x028
.equ LCRH,       0x02C
.equ CR,         0x030
.equ ICR,        0x044
.equ FR_RXFE,    0x10
.equ FR_TXFF,    0x20

.section .text._start
.global _start

_start:
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, park

    /* EL2 → EL1 */
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    1f
    mrs     x0, HCR_EL2
    orr     x0, x0, #(1 << 31)
    msr     HCR_EL2, x0
    mov     x0, #0x3C5
    msr     SPSR_EL2, x0
    adr     x0, 1f
    msr     ELR_EL2, x0
    eret

1:  /* UART0: 115200 8N1, FIFOs enabled */
    ldr     x19, =UART_BASE
    str     wzr, [x19, #CR]
    mov     w0, #0x7FF
    str     w0, [x19, #ICR]
    mov     w0, #26
    str     w0, [x19, #IBRD]
    mov     w0, #3
    str     w0, [x19, #FBRD]
    mov     w0, #0x70
    str     w0, [x19, #LCRH]
    mov     w0, #0x301
    str     w0, [x19, #CR]

    mov     w20, #0             /* TX counter */
    mov     w21, #0xFF          /* RX expected (0xFF = first byte unknown) */
    mov     w22, #0             /* 0 = OK, 1 = error */

loop:
    /* --- TX: send next byte if FIFO not full --- */
    ldr     w0, [x19, #FR]
    tst     w0, #FR_TXFF
    b.ne    try_rx

    cbnz    w22, tx_error
    str     w20, [x19, #DR]
    add     w20, w20, #1
    and     w20, w20, #0xFF
    b       try_rx

tx_error:
    /* RX error detected — send 0xDE, 0xAD alternating */
    mov     w0, #0xDE
    tst     w20, #1
    csel    w0, w0, w24, eq
    str     w0, [x19, #DR]
    add     w20, w20, #1
    /* fall through */

try_rx:
    /* --- RX: read and verify if byte available --- */
    ldr     w0, [x19, #FR]
    tst     w0, #FR_RXFE
    b.ne    loop
    ldr     w0, [x19, #DR]
    and     w0, w0, #0xFF

    /* First byte: accept whatever arrives */
    cmp     w21, #0xFF
    b.eq    accept
    cmp     w0, w21
    b.eq    rx_ok
    /* Mismatch */
    mov     w22, #1
    mov     w24, #0xAD
rx_ok:
accept:
    add     w21, w0, #1
    and     w21, w21, #0xFF
    b       loop

park:
    wfe
    b       park
