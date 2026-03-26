/*
 * boot.S — UART chainloader for Pi 4
 *
 * Loaded at 0x200000 by GPU firmware (via config.txt kernel_address).
 * Waits for a kernel image over UART3 (GPIO 4/5), writes it to 0x80000,
 * then jumps to it. Stays on the SD card permanently — only the kernel
 * changes per iteration.
 *
 * Protocol:
 *   1. Chainloader prints "READY\r\n"
 *   2. Host sends 4-byte LE kernel size
 *   3. Host sends kernel bytes
 *   4. Chainloader prints "BOOT\r\n", jumps to 0x80000
 */

.include "platform.inc"
.include "uart.inc"
.include "gpio.inc"

/* Pi 4 UART3 base and GPIO base (hardcoded — chainloader is Pi 4 only) */
.equ CL_UART3_BASE,   0xFE201600
.equ CL_GPIO_BASE,    0xFE200000
.equ CL_KERNEL_ADDR,  0x80000

/* PL011 register offsets */
.equ PL011_DR,         0x000
.equ PL011_FR,         0x018
.equ PL011_IBRD,       0x024
.equ PL011_FBRD,       0x028
.equ PL011_LCRH,       0x02C
.equ PL011_CR,         0x030
.equ PL011_ICR,        0x044

.equ PL011_FR_RXFE,    0x10    /* RX FIFO empty (bit 4) */
.equ PL011_FR_TXFF,    0x20    /* TX FIFO full (bit 5) */

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
    /* Stack */
    ldr     x0, =_stack_top
    mov     sp, x0

    /* Zero BSS */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.ge    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    /* --- MMU setup: Pi 4 mapping (4 GB) --- */
    mov     x0, #0xFF
    msr     MAIR_EL1, x0

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
    cmp     w4, #496
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

    /* --- GPIO: pins 4/5 → ALT4 (UART3) --- */
    ldr     x19, =CL_GPIO_BASE
    ldr     w0, [x19]              /* GPFSEL0 */
    /* Pin 4: bits [14:12] = 3 (ALT4) */
    bic     w0, w0, #(7 << 12)
    orr     w0, w0, #(3 << 12)
    /* Pin 5: bits [17:15] = 3 (ALT4) */
    bic     w0, w0, #(7 << 15)
    orr     w0, w0, #(3 << 15)
    str     w0, [x19]

    /* --- UART3 init at 115200 --- */
    ldr     x19, =CL_UART3_BASE
    str     wzr, [x19, #PL011_CR]          /* disable */
    mov     w0, #0x7FF
    str     w0, [x19, #PL011_ICR]          /* clear interrupts */
    mov     w0, #26
    str     w0, [x19, #PL011_IBRD]         /* 48 MHz / (16 × 115200) = 26 */
    mov     w0, #3
    str     w0, [x19, #PL011_FBRD]         /* fractional = 3 */
    mov     w0, #0x70
    str     w0, [x19, #PL011_LCRH]         /* 8N1, FIFOs enabled */
    mov     w0, #0x301
    str     w0, [x19, #PL011_CR]           /* enable UART, TX, RX */

    /* --- Print "READY\r\n" --- */
    ldr     x0, =msg_ready
    bl      cl_puts

    /* --- Receive kernel size (4 bytes LE) --- */
    bl      cl_getc
    mov     w20, w0
    bl      cl_getc
    orr     w20, w20, w0, lsl #8
    bl      cl_getc
    orr     w20, w20, w0, lsl #16
    bl      cl_getc
    orr     w20, w20, w0, lsl #24

    /* w20 = kernel size in bytes */

    /* --- Receive kernel bytes to 0x80000 --- */
    ldr     x21, =CL_KERNEL_ADDR
    mov     w22, w20                        /* remaining bytes */

.Lrecv_loop:
    cbz     w22, .Lrecv_done
    bl      cl_getc
    strb    w0, [x21], #1
    sub     w22, w22, #1
    b       .Lrecv_loop

.Lrecv_done:
    /* --- Print "BOOT\r\n" --- */
    ldr     x0, =msg_boot
    bl      cl_puts

    /* Clean D-cache for kernel region (dirty lines → RAM) */
    ldr     x0, =CL_KERNEL_ADDR
    add     x1, x0, x20            /* x20 = kernel size (w20 zero-extended) */
.Lclean_dc:
    dc      civac, x0              /* Clean + Invalidate by VA to PoC */
    add     x0, x0, #64            /* cache line = 64 bytes */
    cmp     x0, x1
    b.lt    .Lclean_dc
    dsb     sy

    /* Invalidate I-cache */
    ic      iallu
    dsb     sy
    isb

    /* Drain UART TX FIFO before disabling MMU */
.Luart_drain:
    ldr     w0, [x19, #PL011_FR]
    tst     w0, #0x08              /* BUSY bit (bit 3) */
    b.ne    .Luart_drain

    /* --- Disable MMU before jumping (kernel will set up its own) --- */
    mrs     x0, SCTLR_EL1
    bic     x0, x0, #(1 << 0)     /* M: disable MMU */
    bic     x0, x0, #(1 << 2)     /* C: disable D-cache */
    bic     x0, x0, #(1 << 12)    /* I: disable I-cache */
    msr     SCTLR_EL1, x0
    isb

    /* Jump to kernel */
    ldr     x0, =CL_KERNEL_ADDR
    br      x0

/* -----------------------------------------------------------------------
 * cl_putc — Send one byte on UART3
 * w0: character
 * ----------------------------------------------------------------------- */
cl_putc:
1:  ldr     w1, [x19, #PL011_FR]
    tst     w1, #PL011_FR_TXFF
    b.ne    1b
    str     w0, [x19, #PL011_DR]
    ret

/* -----------------------------------------------------------------------
 * cl_puts — Send null-terminated string on UART3
 * x0: string pointer
 * ----------------------------------------------------------------------- */
cl_puts:
    stp     x29, x30, [sp, #-16]!
    mov     x29, x0
.Lps:
    ldrb    w0, [x29], #1
    cbz     w0, .Lpsd
    bl      cl_putc
    b       .Lps
.Lpsd:
    ldp     x29, x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * cl_getc — Receive one byte from UART3
 * Returns: w0 = byte received
 * ----------------------------------------------------------------------- */
cl_getc:
1:  ldr     w0, [x19, #PL011_FR]
    tst     w0, #PL011_FR_RXFE
    b.ne    1b
    ldr     w0, [x19, #PL011_DR]
    and     w0, w0, #0xFF
    ret

.Lpark:
    wfe
    b       .Lpark

/* -----------------------------------------------------------------------
 * Strings
 * ----------------------------------------------------------------------- */
.section .rodata
msg_ready:  .asciz "READY\r\n"
msg_boot:   .asciz "BOOT\r\n"
