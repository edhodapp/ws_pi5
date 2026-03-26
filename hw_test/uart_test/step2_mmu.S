/*
 * step2_mmu.S — UART3 test + stack + BSS zero + MMU
 *
 * Builds on the proven UART test kernel. Adds:
 *   - Stack setup
 *   - BSS zeroing
 *   - MMU with 4 GB identity map (Normal RAM + Device peripherals)
 *
 * Loads at 0x80000. Prints "MMU OK\r\n" in a loop if everything works.
 */

.equ GPIO_BASE,    0xFE200000
.equ UART3_BASE,   0xFE201600

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
    /* --- GPIO: pins 4/5 → ALT4 (UART3) --- */
    ldr     x9, =GPIO_BASE
    ldr     w0, [x9]
    bic     w0, w0, #(7 << 12)
    orr     w0, w0, #(3 << 12)
    bic     w0, w0, #(7 << 15)
    orr     w0, w0, #(3 << 15)
    str     w0, [x9]

    /* --- UART3 init at 115200 --- */
    ldr     x9, =UART3_BASE
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

    /* x9 = UART3 base from here on */

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

    /* MAIR: attr0 = Normal WB (0xFF), attr1 = Device-nGnRnE (0x00) */
    mov     x0, #0xFF
    msr     MAIR_EL1, x0

    /* TCR: T0SZ=32 (4 GB), 4KB granule, inner shareable, WB cache */
    ldr     x0, =0x80803520
    msr     TCR_EL1, x0

    /* L1: entries 0-2 = 1 GB Normal blocks, entry 3 → L2 */
    ldr     x0, =__mmu_l1_table
    ldr     x1, =__mmu_l2_table
    mov     x2, #0x701             /* Normal block */

    str     x2, [x0, #0]          /* 0x00000000 */
    mov     x3, #0x40000000
    orr     x3, x3, x2
    str     x3, [x0, #8]          /* 0x40000000 */
    mov     x3, #0x80000000
    orr     x3, x3, x2
    str     x3, [x0, #16]         /* 0x80000000 */
    orr     x1, x1, #0x3          /* table descriptor */
    str     x1, [x0, #24]         /* 0xC0000000 → L2 */

    /* L2 for GB 3: 0-495 Normal, 496-511 Device */
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
    orr     x0, x0, #(1 << 0)     /* M: MMU */
    orr     x0, x0, #(1 << 2)     /* C: D-cache */
    orr     x0, x0, #(1 << 12)    /* I: I-cache */
    msr     SCTLR_EL1, x0
    isb

    /* --- If we get here, MMU is on. Print forever. --- */
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

msg:    .asciz "MMU OK\r\n"
