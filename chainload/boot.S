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
 * Receives a kernel image in Intel HEX format over UART0 (GPIO 14/15)
 * with per-line checksums and ACK/NAK flow control, then jumps to 0x200000.
 * Uses CTS/RTS hardware flow control (GPIO 16/17).
 *
 * Protocol:
 *   1. Chainloader prints "READY\r\n" when initialized
 *   2. Host sends Intel HEX records (ASCII, \r\n terminated)
 *   3. Chainloader sends 2-byte ACK (line_len + checksum) or NAK (len + cksum^0xFF)
 *   4. On EOF record: ACK, print "BOOT:NNNN\r\n", jump to 0x200000
 *   5. Host resets Pi via DTR (GLOBAL_EN) when needed
 */

/* Pi 4 UART0 (PL011) — firmware configures GPIO 14/15 via enable_uart=1 */
.equ CL_UART_BASE,    0xFE201000
.equ CL_KERNEL_ADDR,  0x200000    /* firmware VC agent owns 0x80000 */

/* PL011 register offsets */
.equ PL011_DR,         0x000
.equ PL011_FR,         0x018
.equ PL011_IBRD,       0x024
.equ PL011_FBRD,       0x028
.equ PL011_LCRH,       0x02C
.equ PL011_CR,         0x030
.equ PL011_ICR,        0x044

/* PL011 flag register bits */
.equ PL011_FR_BUSY,    0x08    /* UART busy transmitting (bit 3) */
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

    /* --- Reset DMA left active by GPU firmware --- */
    /* The firmware leaves DMA channels pointing at 0x80000 for UART I/O.
     * Writing kernel data there triggers phantom DMA-to-UART transfers. */
    mov     w1, #(1 << 31)                /* RESET bit */
    ldr     x0, =0xFE007000               /* DMA channel 0 CS */
    mov     w2, #0
.Ldma_reset:
    str     w1, [x0]
    add     x0, x0, #0x100
    add     w2, w2, #1
    cmp     w2, #11                        /* channels 0-10 */
    b.lt    .Ldma_reset

    /* --- UART0 init: 115200 8N1, FIFOs enabled --- */
    ldr     x19, =CL_UART_BASE
    str     wzr, [x19, #PL011_CR]          /* disable UART */
    str     wzr, [x19, #0x48]              /* DMACR = 0: disable PL011 DMA */
    mov     w0, #0x7FF
    str     w0, [x19, #PL011_ICR]          /* clear all interrupts */
    mov     w0, #26
    str     w0, [x19, #PL011_IBRD]         /* 48 MHz / (16 × 115200) = 26 */
    mov     w0, #3
    str     w0, [x19, #PL011_FBRD]         /* fractional = 3 */
    mov     w0, #0x70
    str     w0, [x19, #PL011_LCRH]         /* 8N1, FIFOs enabled */

    mov     w0, #0x301
    str     w0, [x19, #PL011_CR]           /* enable UART, TX, RX (no flow control) */

    /* Drain any garbage from RX FIFO after UART init */
.Lrx_drain:
    ldr     w0, [x19, #PL011_FR]
    tst     w0, #PL011_FR_RXFE
    b.ne    .Lrx_clean
    ldr     w0, [x19, #PL011_DR]          /* discard */
    b       .Lrx_drain
.Lrx_clean:

    /* --- Signal ready for Intel HEX transfer --- */
    ldr     x0, =msg_ready
    bl      cl_puts

    /* --- Receive Intel HEX records --- */
    ldr     x25, =hex_line_buf
    mov     x24, xzr                        /* extended base address */
    mov     w20, wzr                        /* total data bytes received */
    mov     w21, wzr                        /* record counter */

.Lhex_loop:
    bl      cl_getline                      /* w26 = line length */
    cmp     w26, #11                        /* minimum: :LLAAAATTCC */
    b.lt    .Lhex_eof                       /* short/empty → treat as EOF */
    bl      cl_parse_hex_record             /* w0: 0=data, 1=EOF, -1=err */

    tbnz    w0, #31, .Lhex_nak             /* negative = checksum error */
    cbnz    w0, .Lhex_eof                  /* 1 = EOF record */

    /* ACK: send line length + checksum byte */
    mov     w0, w26
    bl      cl_putc
    mov     w0, w27
    bl      cl_putc
    add     w21, w21, #1
    b       .Lhex_loop

.Lhex_eof:
    mov     w0, w26
    bl      cl_putc
    mov     w0, w27
    bl      cl_putc
    add     w21, w21, #1
    b       .Lrecv_done

.Lhex_nak:
    /* NAK: send line length + checksum XOR 0xFF */
    mov     w0, w26
    bl      cl_putc
    eor     w0, w27, #0xFF
    bl      cl_putc
    b       .Lhex_loop

.Lrecv_done:
    /* Print "BOOT:NNNN\r\n" */
    ldr     x0, =msg_boot
    bl      cl_puts
    mov     w0, w21
    bl      cl_print_hex16
    mov     w0, #0x0D
    bl      cl_putc
    mov     w0, #0x0A
    bl      cl_putc

    /* Drain UART TX — ensure BOOT message is fully on the wire */
.Luart_drain:
    ldr     w0, [x19, #PL011_FR]
    tst     w0, #PL011_FR_BUSY
    b.ne    .Luart_drain

    /* Jump to kernel (loaded directly at 0x200000, no staging needed) */
    mov     x0, #CL_KERNEL_ADDR
    br      x0

/* =======================================================================
 * UART helpers — all expect x19 = UART base
 * ======================================================================= */

.global cl_putc
cl_putc:
    /* Wait for TX FIFO not full, write byte, wait for transmit */
1:  ldr     w1, [x19, #PL011_FR]
    tst     w1, #PL011_FR_TXFF
    b.ne    1b
    str     w0, [x19, #PL011_DR]
2:  ldr     w1, [x19, #PL011_FR]
    tst     w1, #PL011_FR_BUSY
    b.ne    2b
    ret

cl_puts:
    stp     x29, x30, [sp, #-16]!
    mov     x29, x0
1:  ldrb    w0, [x29], #1
    cbz     w0, 2f
    bl      cl_putc
    b       1b
2:  ldp     x29, x30, [sp], #16
    ret

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
1:  bl      cl_getc
    cmp     w0, #0x0A
    b.eq    2f
    cmp     w0, #0x0D
    b.eq    1b
    cmp     w26, #78
    b.ge    1b
    strb    w0, [x25, w26, uxtw]
    add     w26, w26, #1
    b       1b
2:  ldr     x30, [sp], #16
    ret

.Lpark:
    wfe
    b       .Lpark

/* -----------------------------------------------------------------------
 * Strings
 * ----------------------------------------------------------------------- */
.section .rodata
msg_ready:  .asciz "READY\r\n"
msg_boot:   .asciz "BOOT:"
