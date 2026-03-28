/*
 * step5_jump.S — Receive and jump to a kernel
 *
 * Builds on step4. After receiving, adds:
 *   - D-cache clean for received region
 *   - I-cache invalidate
 *   - UART TX drain
 *   - MMU disable
 *   - Jump to received code
 *
 * Receives to 0x100000 (not 0x80000, since we're running there).
 * Prints BOOT before jumping so send_kernel.py is happy.
 */

.equ UART0_BASE,   0xFE201000
.equ RECV_ADDR,    0x100000

.equ DR,           0x000
.equ FR,           0x018
.equ IBRD,         0x024
.equ FBRD,         0x028
.equ LCRH,         0x02C
.equ CR,           0x030
.equ ICR,          0x044

.equ FR_TXFF,      0x20
.equ FR_RXFE,      0x10

.section .text._start

.global _start

_start:
    /* Park cores 1-3 */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    /* EL2 → EL1 drop */
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
    /* --- UART0 init at 115200 (GPIO 14/15 default pin mux, no config needed) --- */
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

    /* --- Stack --- */
    ldr     x0, =_stack_top
    mov     sp, x0

    /* --- Zero BSS --- */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.ge    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    /* --- MMU setup: 4 GB identity map --- */
    mov     x0, #0xFF
    msr     MAIR_EL1, x0

    ldr     x0, =0x80803520
    msr     TCR_EL1, x0

    ldr     x0, =__mmu_l1_table
    ldr     x1, =__mmu_l2_table
    mov     x2, #0x701

    str     x2, [x0, #0]
    mov     x3, #0x40000000
    orr     x3, x3, x2
    str     x3, [x0, #8]
    mov     x3, #0x80000000
    orr     x3, x3, x2
    str     x3, [x0, #16]
    orr     x1, x1, #0x3
    str     x1, [x0, #24]

    ldr     x0, =__mmu_l2_table
    mov     x1, #0xC0000000
    mov     x2, #0x701
    mov     x3, #0x405
    mov     w4, #0

.Lfill_normal:
    orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #480
    b.lt    .Lfill_normal

.Lfill_device:
    orr     x5, x1, x3
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #512
    b.lt    .Lfill_device

    ldr     x0, =__mmu_l1_table
    msr     TTBR0_EL1, x0
    isb

    mrs     x0, SCTLR_EL1
    orr     x0, x0, #(1 << 0)
    orr     x0, x0, #(1 << 2)
    orr     x0, x0, #(1 << 12)
    msr     SCTLR_EL1, x0
    isb

    /* === Protocol: READY → receive → BOOT → jump === */

    /* Print READY */
    adr     x10, msg_ready
    bl      puts_inline

    /* Receive 4-byte LE size */
    bl      getc_inline
    mov     w20, w0
    bl      getc_inline
    orr     w20, w20, w0, lsl #8
    bl      getc_inline
    orr     w20, w20, w0, lsl #16
    bl      getc_inline
    orr     w20, w20, w0, lsl #24

    /* Receive data bytes to RECV_ADDR */
    ldr     x21, =RECV_ADDR
    mov     w22, w20

.Lrecv_loop:
    cbz     w22, .Lrecv_done
    bl      getc_inline
    strb    w0, [x21], #1
    sub     w22, w22, #1
    b       .Lrecv_loop

.Lrecv_done:
    /* Print BOOT */
    adr     x10, msg_boot
    bl      puts_inline

    /* --- D-cache clean for received region --- */
    ldr     x0, =RECV_ADDR
    add     x1, x0, x20            /* x20 = size */
.Lclean_dc:
    dc      civac, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lt    .Lclean_dc
    dsb     sy

    /* --- I-cache invalidate --- */
    ic      iallu
    dsb     sy
    isb

    /* --- Drain UART TX FIFO --- */
.Luart_drain:
    ldr     w0, [x9, #FR]
    tst     w0, #0x08              /* BUSY bit */
    b.ne    .Luart_drain

    /* --- Disable MMU + caches --- */
    mrs     x0, SCTLR_EL1
    bic     x0, x0, #(1 << 0)     /* M */
    bic     x0, x0, #(1 << 2)     /* C */
    bic     x0, x0, #(1 << 12)    /* I */
    msr     SCTLR_EL1, x0
    isb

    /* --- Jump to received code --- */
    ldr     x0, =RECV_ADDR
    br      x0

/* --- UART helpers --- */

putc_inline:
1:  ldr     w1, [x9, #FR]
    tst     w1, #FR_TXFF
    b.ne    1b
    str     w0, [x9, #DR]
    ret

getc_inline:
1:  ldr     w0, [x9, #FR]
    tst     w0, #FR_RXFE
    b.ne    1b
    ldr     w0, [x9, #DR]
    and     w0, w0, #0xFF
    ret

puts_inline:
    stp     x30, xzr, [sp, #-16]!
.Lpi:
    ldrb    w0, [x10], #1
    cbz     w0, .Lpid
    bl      putc_inline
    b       .Lpi
.Lpid:
    ldp     x30, xzr, [sp], #16
    ret

.Lpark:
    wfe
    b       .Lpark

msg_ready:  .asciz "READY\r\n"
msg_boot:   .asciz "BOOT\r\n"
