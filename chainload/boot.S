/*
 * boot.S — UART chainloader for Pi 4
 *
 * Loaded at 0x4000000 (64 MB) by GPU firmware (via config.txt kernel_address).
 * Must be above the kernel's memory footprint (~34 MB for 128 TCP connections).
 *
 * Waits for a 0xFF sync byte over UART0 (GPIO 14/15), receives a kernel image
 * in Intel HEX format with per-line checksums and ACK/NAK flow control,
 * then optionally arms a PM watchdog and jumps to 0x80000.
 *
 * Protocol:
 *   1. Chainloader waits for 0xFF byte
 *   2. Chainloader prints "READY\r\n"
 *   3. Host sends 1-byte timeout (seconds, 0 = no watchdog)
 *   4. Host sends Intel HEX records (ASCII, \r\n terminated)
 *   5. Chainloader verifies checksum, sends '+' (ACK) or '-' (NAK)
 *   6. On EOF record: arm PM watchdog, print "BOOT\r\n", jump to 0x80000
 *   7. After timeout: PM watchdog reset → reboot → step 1
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

    /* --- Receive Intel HEX records --- */
    ldr     x25, =hex_line_buf             /* line buffer */
    mov     x24, xzr                        /* extended base address */
    mov     w20, wzr                        /* total bytes received */

.Lhex_loop:
    bl      cl_getline                      /* w26 = line length */
    bl      cl_parse_hex_record             /* w0: 0=data, 1=EOF, -1=error */

    tbnz    w0, #31, .Lhex_nak             /* negative = error → NAK */
    cbnz    w0, .Lhex_eof                  /* 1 = EOF */

    /* Data record OK → ACK, continue */
    mov     w0, #'+'
    bl      cl_putc
    b       .Lhex_loop

.Lhex_eof:
    mov     w0, #'+'
    bl      cl_putc
    b       .Lrecv_done

.Lhex_nak:
    mov     w0, #'-'
    bl      cl_putc
    b       .Lhex_loop                      /* host retransmits */

.Lrecv_done:
    /* --- Arm PM watchdog if timeout > 0 --- */
    cbz     w23, .Lskip_wdog

    /* PM watchdog: 20-bit counter at 65536 Hz, max ~16 seconds.
     * Timeout clamped to 16s. sub 1 avoids 20-bit overflow (16*65536=0x100000). */
    cmp     w23, #16
    mov     w0, #16
    csel    w0, w23, w0, lo             /* w0 = min(timeout, 16) */
    lsl     w0, w0, #16                 /* w0 = seconds * 65536 */
    sub     w0, w0, #1                  /* clamp to 20-bit max (0xFFFFF) */
    movz    w1, #0x5A00, lsl #16        /* password high half */
    orr     w0, w0, w1                  /* ticks | password */
    ldr     x1, =PM_BASE
    str     w0, [x1, #0x24]            /* PM_WDOG */
    movz    w0, #0x5A00, lsl #16
    movk    w0, #0x0020                 /* password + full reset */
    str     w0, [x1, #0x1C]            /* PM_RSTC */

.Lskip_wdog:

    /* --- Print "BOOT\r\n" --- */
    ldr     x0, =msg_boot
    bl      cl_puts

    /* Clean D-cache for kernel region (dirty lines → RAM) */
    ldr     x0, =CL_KERNEL_ADDR
    add     x1, x0, x20            /* x20 = total bytes received */
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

/* =======================================================================
 * UART helpers
 * ======================================================================= */

/* -----------------------------------------------------------------------
 * cl_putc — Send one byte on UART0
 * w0: character. Leaf function.
 * ----------------------------------------------------------------------- */
.global cl_putc
cl_putc:
1:  ldr     w1, [x19, #PL011_FR]
    tst     w1, #PL011_FR_TXFF
    b.ne    1b
    str     w0, [x19, #PL011_DR]
    ret

/* -----------------------------------------------------------------------
 * cl_puts — Send null-terminated string on UART0
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
 * cl_getc — Receive one byte from UART0
 * Returns: w0 = byte received. Leaf function.
 * ----------------------------------------------------------------------- */
.global cl_getc
cl_getc:
1:  ldr     w0, [x19, #PL011_FR]
    tst     w0, #PL011_FR_RXFE
    b.ne    1b
    ldr     w0, [x19, #PL011_DR]
    and     w0, w0, #0xFF
    ret

/* -----------------------------------------------------------------------
 * cl_getline — Read one line from UART into buffer at x25
 *
 * Reads until \n. Strips \r and \n. Stops at 78 chars.
 * Requires: x19 = UART base, x25 = line buffer pointer
 * Returns: w26 = number of characters stored
 * Clobbers: w0, w26
 * ----------------------------------------------------------------------- */
cl_getline:
    str     x30, [sp, #-16]!
    mov     w26, #0
.Lgl_loop:
    bl      cl_getc
    cmp     w0, #0x0A                  /* \n = end of line */
    b.eq    .Lgl_done
    cmp     w0, #0x0D                  /* \r = skip */
    b.eq    .Lgl_loop
    cmp     w26, #78                   /* LINE_BUF_SIZE - 2 */
    b.ge    .Lgl_loop                  /* overflow: discard but keep reading */
    strb    w0, [x25, w26, uxtw]
    add     w26, w26, #1
    b       .Lgl_loop
.Lgl_done:
    ldr     x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * Park loop for non-primary cores
 * ----------------------------------------------------------------------- */
.Lpark:
    wfe
    b       .Lpark

/* -----------------------------------------------------------------------
 * Strings
 * ----------------------------------------------------------------------- */
.section .rodata
msg_ready:  .asciz "READY\r\n"
msg_boot:   .asciz "BOOT\r\n"
