/*
 * boot.S — UART chainloader for Pi 4
 *
 * Loaded at 0x4000000 (64 MB) by GPU firmware (via config.txt kernel_address).
 * Must be above the kernel's memory footprint (~34 MB for 128 TCP connections).
 *
 * Waits for a 0xFF sync byte over UART0 (GPIO 14/15), receives a kernel image,
 * writes it to 0x80000, optionally arms a watchdog timer, then jumps to it.
 * After timeout, a GIC-routed timer interrupt triggers PM watchdog reset,
 * rebooting the Pi back into this chainloader.
 *
 * Protocol:
 *   1. Chainloader waits for 0xFF byte
 *   2. Chainloader prints "READY\r\n"
 *   3. Host sends 1-byte timeout (seconds, 0 = no watchdog)
 *   4. Host sends 4-byte LE kernel size
 *   5. Host sends kernel bytes
 *   6. Chainloader prints "BOOT\r\n", arms timer, jumps to 0x80000
 *   7. After timeout: timer IRQ → PM watchdog reset → reboot → step 1
 */

.include "platform.inc"
.include "uart.inc"
.include "gpio.inc"

/* Pi 4 UART0 — firmware configures GPIO 14/15 via enable_uart=1 + disable-bt */
.equ CL_UART_BASE,    0xFE201000
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

/* GIC-400 on BCM2711 */
.equ GICD_BASE,        0xFF841000
.equ GICC_BASE,        0xFF842000
.equ TIMER_PPI,        30      /* CNTPNSIRQ — non-secure physical timer */

/* PM watchdog */
.equ PM_BASE,          0xFE100000

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

    /* L2 for GB 3: 0-479 Normal, 480-511 Device (peripherals at 0xFC000000+) */
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

    /* --- UART0 init at 115200 (GPIO 14/15 already configured by firmware) --- */
    ldr     x19, =CL_UART_BASE
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

    /* --- Wait for 0xFF sync byte (discards stale FIFO data) --- */
.Lwait_sync:
    bl      cl_getc
    cmp     w0, #0xFF
    b.ne    .Lwait_sync

    /* --- Print "READY\r\n" --- */
    ldr     x0, =msg_ready
    bl      cl_puts

    /* --- Read timeout (1 byte, 0-255 seconds) --- */
    bl      cl_getc
    mov     w23, w0                         /* w23 = timeout */

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

    /* --- Set up watchdog timer if timeout > 0 --- */
    cbz     w23, .Lskip_timer

    /* Install exception vector table (in chainloader memory, safe from kernel) */
    ldr     x0, =cl_vectors
    msr     VBAR_EL1, x0
    isb

    /* Configure GIC distributor */
    ldr     x0, =GICD_BASE
    mov     w1, #1
    str     w1, [x0]                        /* GICD_CTLR: enable forwarding */

    ldr     w1, [x0, #0x80]                /* GICD_IGROUPR0 */
    orr     w1, w1, #(1 << TIMER_PPI)
    str     w1, [x0, #0x80]                /* PPI 30 → Group 1 (non-secure) */

    mov     w1, #(1 << TIMER_PPI)
    str     w1, [x0, #0x100]               /* GICD_ISENABLER0: enable PPI 30 */

    /* Priority for PPI 30 = 0 (highest) */
    add     x1, x0, #0x400                 /* GICD_IPRIORITYR base */
    strb    wzr, [x1, #TIMER_PPI]

    /* Configure GIC CPU interface */
    ldr     x0, =GICC_BASE
    mov     w1, #1
    str     w1, [x0]                        /* GICC_CTLR: enable */
    mov     w1, #0xFF
    str     w1, [x0, #0x4]                 /* GICC_PMR: allow all priorities */

    /* Program timer: CVAL = now + (timeout * frequency) */
    mrs     x0, CNTPCT_EL0                 /* current count */
    mrs     x1, CNTFRQ_EL0                 /* frequency (54 MHz on Pi 4) */
    mov     x2, x23                        /* timeout seconds (zero-extended) */
    mul     x1, x1, x2
    add     x0, x0, x1
    msr     CNTP_CVAL_EL0, x0             /* set comparator */
    mov     x0, #1
    msr     CNTP_CTL_EL0, x0              /* enable timer, unmask output */

.Lskip_timer:

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

    /* Unmask IRQ if timer was armed (after MMU disable so we don't take
     * the interrupt during chainloader cleanup — the kernel re-enables
     * MMU in boot.S within microseconds) */
    cbz     w23, .Lskip_unmask
    msr     DAIFClr, #2
.Lskip_unmask:

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

/* =======================================================================
 * Exception Vector Table
 *
 * 16 entries × 0x80 bytes = 2 KB, must be 0x800-aligned.
 * Only the IRQ EL1h entry (offset 0x280) is used — timer interrupt.
 * All others hang (should never fire).
 * ======================================================================= */
.balign 0x800
cl_vectors:
    /* 0x000: Synchronous, current EL with SP_EL0 */
    b       .Lhang
    .balign 0x80

    /* 0x080: IRQ, current EL with SP_EL0 */
    b       .Lhang
    .balign 0x80

    /* 0x100: FIQ, current EL with SP_EL0 */
    b       .Lhang
    .balign 0x80

    /* 0x180: SError, current EL with SP_EL0 */
    b       .Lhang
    .balign 0x80

    /* 0x200: Synchronous, current EL with SP_ELx */
    b       .Lhang
    .balign 0x80

    /* 0x280: IRQ, current EL with SP_ELx — TIMER WATCHDOG
     *
     * When the ARM generic timer fires after the configured timeout,
     * this handler disables the timer, acknowledges the GIC interrupt,
     * and arms the PM hardware watchdog for immediate reset (~150 µs).
     * The Pi reboots from SD card, bringing up the chainloader again.
     *
     * Uses movz/movk for all addresses — no literal pool references,
     * so this is position-independent within the 0x80-byte entry.
     * 14 instructions = 56 bytes (fits in 128-byte slot).
     */
    msr     CNTP_CTL_EL0, xzr              /* disable timer */
    movz    x0, #0xFF84, lsl #16
    movk    x0, #0x2000                     /* x0 = GICC_BASE */
    ldr     w1, [x0, #0xC]                 /* read GICC_IAR */
    str     w1, [x0, #0x10]                /* write GICC_EOIR */
    movz    x0, #0xFE10, lsl #16           /* x0 = PM_BASE */
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x000A                     /* password + ~150 µs */
    str     w1, [x0, #0x24]                /* PM_WDOG */
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x0020                     /* password + full reset */
    str     w1, [x0, #0x1C]                /* PM_RSTC */
1:  wfe
    b       1b
    .balign 0x80

    /* 0x300: FIQ, current EL with SP_ELx */
    b       .Lhang
    .balign 0x80

    /* 0x380: SError, current EL with SP_ELx */
    b       .Lhang
    .balign 0x80

    /* 0x400: Synchronous, lower EL using AArch64 */
    b       .Lhang
    .balign 0x80

    /* 0x480: IRQ, lower EL using AArch64 */
    b       .Lhang
    .balign 0x80

    /* 0x500: FIQ, lower EL using AArch64 */
    b       .Lhang
    .balign 0x80

    /* 0x580: SError, lower EL using AArch64 */
    b       .Lhang
    .balign 0x80

    /* 0x600: Synchronous, lower EL using AArch32 */
    b       .Lhang
    .balign 0x80

    /* 0x680: IRQ, lower EL using AArch32 */
    b       .Lhang
    .balign 0x80

    /* 0x700: FIQ, lower EL using AArch32 */
    b       .Lhang
    .balign 0x80

    /* 0x780: SError, lower EL using AArch32 */
    b       .Lhang

.Lhang:
    wfe
    b       .Lhang

/* -----------------------------------------------------------------------
 * Strings
 * ----------------------------------------------------------------------- */
.section .rodata
msg_ready:  .asciz "READY\r\n"
msg_boot:   .asciz "BOOT\r\n"
