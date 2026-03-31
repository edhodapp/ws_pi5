/*
 * diag.S — UART diagnostic for Pi 4 (v2: no echo)
 *
 * Receives bytes, checks PL011 error flags, reports errors.
 * Does NOT echo — avoids protocol confusion with control characters.
 *
 * Output:
 *   DIAG\r\n             — banner on boot
 *   READY\r\n            — after 0xFF sync received
 *   =NNNN\r\n            — every 256 bytes: total count in hex
 *   !F:DD@NNNN\r\n       — on error: F=flag nibble, DD=data, NNNN=count
 *                          F bits: 8=OE 4=BE 2=PE 1=FE
 *   DONE:NNNN:EEEE\r\n   — after 2s idle: total, error count
 *
 * Loaded at 0x4000000 via config.txt.
 */

.equ CL_UART_BASE,    0xFE201000

.equ PL011_DR,         0x000
.equ PL011_RSR,        0x004
.equ PL011_FR,         0x018
.equ PL011_IBRD,       0x024
.equ PL011_FBRD,       0x028
.equ PL011_LCRH,       0x02C
.equ PL011_CR,         0x030
.equ PL011_ICR,        0x044

.equ PL011_FR_RXFE,    0x10
.equ PL011_FR_TXFF,    0x20

.equ DR_ERR_MASK,      0xF00

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
    ldr     x0, =_stack_top
    mov     sp, x0

    /* UART0 init */
    ldr     x19, =CL_UART_BASE
    str     wzr, [x19, #PL011_CR]
    mov     w0, #0x7FF
    str     w0, [x19, #PL011_ICR]
    mov     w0, #26
    str     w0, [x19, #PL011_IBRD]
    mov     w0, #3
    str     w0, [x19, #PL011_FBRD]
    mov     w0, #0x70
    str     w0, [x19, #PL011_LCRH]
    mov     w0, #0x301
    str     w0, [x19, #PL011_CR]

    /* Print DIAG\r\n */
    mov     w0, #'D'
    bl      putc
    mov     w0, #'I'
    bl      putc
    mov     w0, #'A'
    bl      putc
    mov     w0, #'G'
    bl      putc
    mov     w0, #0x0D
    bl      putc
    mov     w0, #0x0A
    bl      putc

    /* Wait for 0xFF sync */
.Lwait_sync:
    ldr     w0, [x19, #PL011_FR]
    tst     w0, #PL011_FR_RXFE
    b.ne    .Lwait_sync
    ldr     w0, [x19, #PL011_DR]
    and     w1, w0, #0xFF
    cmp     w1, #0xFF
    b.ne    .Lwait_sync

    /* Print READY\r\n */
    mov     w0, #'R'
    bl      putc
    mov     w0, #'E'
    bl      putc
    mov     w0, #'A'
    bl      putc
    mov     w0, #'D'
    bl      putc
    mov     w0, #'Y'
    bl      putc
    mov     w0, #0x0D
    bl      putc
    mov     w0, #0x0A
    bl      putc

    /* --- Receive loop: no echo, count + error check --- */
    mov     w20, #0               /* total byte counter */
    mov     w21, #0               /* error counter */
    mov     w22, #0               /* clean-since-last-milestone */

    /* Get timer frequency for idle timeout */
    mrs     x23, CNTFRQ_EL0

.Lrecv_loop:
    /* Poll with timeout: check RXFE, if empty check timer */
    mrs     x24, CNTPCT_EL0       /* snapshot time */

    /* Calculate deadline: now + 2 seconds */
    lsl     x25, x23, #1          /* x25 = freq * 2 */
    add     x25, x24, x25         /* x25 = deadline */

.Lpoll:
    ldr     w0, [x19, #PL011_FR]
    tst     w0, #PL011_FR_RXFE
    b.eq    .Lgot_byte

    /* FIFO empty — check timeout */
    mrs     x0, CNTPCT_EL0
    cmp     x0, x25
    b.lo    .Lpoll

    /* Timeout: print DONE:NNNN:EEEE\r\n */
    mov     w0, #'D'
    bl      putc
    mov     w0, #'O'
    bl      putc
    mov     w0, #'N'
    bl      putc
    mov     w0, #'E'
    bl      putc
    mov     w0, #':'
    bl      putc
    mov     w0, w20
    bl      print_hex16
    mov     w0, #':'
    bl      putc
    mov     w0, w21
    bl      print_hex16
    mov     w0, #0x0D
    bl      putc
    mov     w0, #0x0A
    bl      putc

    /* Wait for more data (restart loop) */
    b       .Lrecv_loop

.Lgot_byte:
    ldr     w0, [x19, #PL011_DR]
    mov     w10, w0               /* save full DR */
    and     w11, w0, #0xFF        /* data byte */
    lsr     w12, w0, #8
    and     w12, w12, #0xF        /* error nibble */

    add     w20, w20, #1          /* total++ */

    cbnz    w12, .Lerror

    /* Clean byte */
    add     w22, w22, #1
    cmp     w22, #256
    b.lo    .Lrecv_loop

    /* Milestone: =NNNN\r\n */
    mov     w0, #'='
    bl      putc
    mov     w0, w20
    bl      print_hex16
    mov     w0, #0x0D
    bl      putc
    mov     w0, #0x0A
    bl      putc
    mov     w22, #0
    b       .Lrecv_loop

.Lerror:
    /* !F:DD@NNNN\r\n */
    mov     w0, #'!'
    bl      putc
    mov     w0, w12
    bl      print_hex8
    mov     w0, #':'
    bl      putc
    mov     w0, w11
    bl      print_hex8
    mov     w0, #'@'
    bl      putc
    mov     w0, w20
    bl      print_hex16
    mov     w0, #0x0D
    bl      putc
    mov     w0, #0x0A
    bl      putc

    str     wzr, [x19, #PL011_RSR]    /* clear error flags */
    add     w21, w21, #1
    mov     w22, #0
    b       .Lrecv_loop

/* =======================================================================
 * UART helpers
 * ======================================================================= */

putc:
1:  ldr     w1, [x19, #PL011_FR]
    tst     w1, #PL011_FR_TXFF
    b.ne    1b
    str     w0, [x19, #PL011_DR]
    ret

print_hex8:
    str     x30, [sp, #-16]!
    mov     w9, w0
    lsr     w0, w9, #4
    and     w0, w0, #0xF
    bl      print_nibble
    and     w0, w9, #0xF
    bl      print_nibble
    ldr     x30, [sp], #16
    ret

print_hex16:
    str     x30, [sp, #-16]!
    mov     w9, w0
    lsr     w0, w9, #12
    and     w0, w0, #0xF
    bl      print_nibble
    lsr     w0, w9, #8
    and     w0, w0, #0xF
    bl      print_nibble
    lsr     w0, w9, #4
    and     w0, w0, #0xF
    bl      print_nibble
    and     w0, w9, #0xF
    bl      print_nibble
    ldr     x30, [sp], #16
    ret

print_nibble:
    cmp     w0, #10
    b.hs    1f
    add     w0, w0, #'0'
    b       putc
1:  add     w0, w0, #('A' - 10)
    b       putc

.Lpark:
    wfe
    b       .Lpark
