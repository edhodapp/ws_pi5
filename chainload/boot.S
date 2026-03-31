/*
 * boot.S — UART chainloader for Pi 4
 *
 * Loaded at 0x4000000 (64 MB) by GPU firmware (via config.txt kernel_address).
 * Must be above the kernel's memory footprint (~34 MB for 128 TCP connections).
 *
 * Runs WITHOUT MMU or caches. All RAM writes go directly to physical memory,
 * eliminating cache coherency issues. At 115200 baud the CPU is idle >99%
 * of the time, so caching adds complexity for no benefit.
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
 *   6. On EOF record: print "BOOT\r\n", arm PM watchdog, jump to 0x80000
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
    /* Stack — no MMU, so use physical address directly */
    ldr     x0, =_stack_top
    mov     sp, x0

    /* Zero BSS — no MMU, writes go directly to RAM */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.ge    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    /* No MMU setup — run entirely without caches.
     * All loads/stores go directly to RAM/peripherals. */

    /* --- UART0 init at 115200 (GPIO 14/15 already configured by firmware) --- */
    ldr     x19, =CL_UART_BASE
    str     wzr, [x19, #PL011_CR]          /* disable */
    mov     w0, #0x7FF
    str     w0, [x19, #PL011_ICR]          /* clear interrupts */
    mov     w0, #26
    str     w0, [x19, #PL011_IBRD]         /* 48 MHz / (16 × 115200) = 26 */
    mov     w0, #3
    str     w0, [x19, #PL011_FBRD]         /* fractional = 3 */
    mov     w0, #0x60
    str     w0, [x19, #PL011_LCRH]         /* 8N1, FIFOs disabled (1-byte mode) */
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
    mov     w21, wzr                        /* record counter */

.Lhex_loop:
    bl      cl_getline                      /* w26 = line length */
    add     w21, w21, #1                    /* count every loop iteration */
    /* Debug: output /XX NNNN/ (XX=w26, NNNN=iteration count) */
    mov     w0, #'/'
    bl      cl_putc
    lsr     w0, w26, #4
    and     w0, w0, #0xF
    bl      cl_print_nibble
    and     w0, w26, #0xF
    bl      cl_print_nibble
    mov     w0, #' '
    bl      cl_putc
    mov     w0, w21
    bl      cl_print_hex16
    mov     w0, #'/'
    bl      cl_putc
    cmp     w26, #11                        /* minimum: :LLAAAATTCC = 11 chars */
    b.lt    .Lhex_eof                       /* short/empty line → treat as EOF */
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
    /* Debug: print "?XX:LL line_echo\r\n" before NAK */
    /* XX=checksum, LL=line length (w26) */
    mov     w0, #'?'
    bl      cl_putc
    lsr     w0, w27, #4
    and     w0, w0, #0xF
    bl      cl_print_nibble
    and     w0, w27, #0xF
    bl      cl_print_nibble
    mov     w0, #':'
    bl      cl_putc
    lsr     w0, w26, #4
    and     w0, w0, #0xF
    bl      cl_print_nibble
    and     w0, w26, #0xF
    bl      cl_print_nibble
    mov     w0, #' '
    bl      cl_putc
    /* Echo received line buffer */
    mov     w9, #0
.Lnak_echo:
    cmp     w9, w26
    b.ge    .Lnak_echo_done
    ldrb    w0, [x25, w9, uxtw]
    bl      cl_putc
    add     w9, w9, #1
    b       .Lnak_echo
.Lnak_echo_done:
    mov     w0, #0x0D
    bl      cl_putc
    mov     w0, #0x0A
    bl      cl_putc
    mov     w0, #'-'
    bl      cl_putc
    b       .Lhex_loop                      /* host retransmits */

.Lrecv_done:
    /* --- 1) Print "BOOT:NNNN\r\n" (NNNN = record count hex) --- */
    mov     w0, #'B'
    bl      cl_putc
    mov     w0, #'O'
    bl      cl_putc
    mov     w0, #'O'
    bl      cl_putc
    mov     w0, #'T'
    bl      cl_putc
    mov     w0, #':'
    bl      cl_putc
    mov     w0, w21
    bl      cl_print_hex16
    mov     w0, #0x0D
    bl      cl_putc
    mov     w0, #0x0A
    bl      cl_putc

    /* --- 2) Delay ~100ms for CP2102 to deliver BOOT to host --- */
    mrs     x0, CNTFRQ_EL0
    mov     x1, #100
    mul     x0, x0, x1
    mov     x1, #1000
    udiv    x0, x0, x1             /* ticks = freq * 100 / 1000 */
    mrs     x1, CNTPCT_EL0
    add     x0, x0, x1
.Lboot_delay:
    mrs     x1, CNTPCT_EL0
    cmp     x1, x0
    b.lo    .Lboot_delay

    /* --- 3) Arm PM watchdog if timeout > 0 --- */
    cbz     w23, .Lskip_wdog

    cmp     w23, #16
    mov     w0, #16
    csel    w0, w23, w0, lo
    lsl     w0, w0, #16
    sub     w0, w0, #1
    movz    w1, #0x5A00, lsl #16
    orr     w0, w0, w1
    movz    x1, #0xFE10, lsl #16
    str     w0, [x1, #0x24]            /* PM_WDOG */
    movz    w0, #0x5A00, lsl #16
    movk    w0, #0x0020
    str     w0, [x1, #0x1C]            /* PM_RSTC */

.Lskip_wdog:

    /* --- 4) Drain UART and jump to kernel --- */
    /* No cache clean needed — we never enabled caches.
     * All HEX data writes went directly to RAM. */

    /* Drain UART TX FIFO */
.Luart_drain:
    ldr     w0, [x19, #PL011_FR]
    tst     w0, #0x08              /* BUSY bit (bit 3) */
    b.ne    .Luart_drain

    /* Jump to kernel */
    mov     x0, #CL_KERNEL_ADDR
    br      x0

/* =======================================================================
 * UART helpers
 * ======================================================================= */

.equ PL011_FR_BUSY,    0x08    /* UART busy (bit 3) */

.global cl_putc
cl_putc:
    /* Wait for TX holding register empty */
1:  ldr     w1, [x19, #PL011_FR]
    tst     w1, #PL011_FR_TXFF
    b.ne    1b
    /* Write byte */
    str     w0, [x19, #PL011_DR]
    /* Wait for byte fully transmitted */
2:  ldr     w1, [x19, #PL011_FR]
    tst     w1, #PL011_FR_BUSY
    b.ne    2b
    ret

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

/* Print w0 low 16 bits as 4 hex chars */
cl_print_hex16:
    str     x30, [sp, #-16]!
    mov     w9, w0
    lsr     w0, w9, #12
    and     w0, w0, #0xF
    bl      cl_print_nibble
    lsr     w0, w9, #8
    and     w0, w0, #0xF
    bl      cl_print_nibble
    lsr     w0, w9, #4
    and     w0, w0, #0xF
    bl      cl_print_nibble
    and     w0, w9, #0xF
    bl      cl_print_nibble
    ldr     x30, [sp], #16
    ret

cl_print_nibble:
    cmp     w0, #10
    b.hs    1f
    add     w0, w0, #'0'
    b       cl_putc
1:  add     w0, w0, #('A' - 10)
    b       cl_putc

.global cl_getc
cl_getc:
1:  ldr     w0, [x19, #PL011_FR]
    tst     w0, #PL011_FR_RXFE
    b.ne    1b
    ldr     w0, [x19, #PL011_DR]
    and     w0, w0, #0xFF
    ret

cl_getline:
    str     x30, [sp, #-16]!
    mov     w26, #0
.Lgl_loop:
    bl      cl_getc
    cmp     w0, #0x0A
    b.eq    .Lgl_done
    cmp     w0, #0x0D
    b.eq    .Lgl_loop
    cmp     w26, #78
    b.ge    .Lgl_loop
    strb    w0, [x25, w26, uxtw]
    add     w26, w26, #1
    b       .Lgl_loop
.Lgl_done:
    ldr     x30, [sp], #16
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
