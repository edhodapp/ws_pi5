/*
 * boot.S — UART chainloader for Pi 4
 *
 * Boot model: the chainloader IMAGE is loaded by GPU firmware at the
 * default kernel address 0x80000 (no kernel_address= override in
 * config.txt). The first thing _start does is copy itself from
 * 0x80000 to 0x4000000 (its link address) and jump into the relocated
 * copy — see the relocate stub below for the rationale and mechanics.
 *
 * Why this dance: an earlier design loaded the chainloader directly at
 * 0x4000000 via kernel_address=0x4000000. That worked for the chain-
 * loader itself, but when the chainloader later wrote the kernel HEX
 * records to 0x80000, those writes raced firmware activity (framebuffer,
 * VC agent scratch) that was still touching 0x80000 in the background.
 * Symptom: writes corrupted at deterministic-but-arbitrary record
 * offsets, ACK checksum mismatch, host-side bail. SD-direct boot avoids
 * this because firmware FINISHES its 0x80000 work before releasing the
 * ARM cores. Loading the chainloader at 0x80000 imports the same
 * quiescence guarantee: by the time we're running, firmware has handed
 * off and stopped touching 0x80000 — exactly what we need so the
 * chainloader can write the kernel there cleanly.
 *
 * Runs WITHOUT MMU or caches. All RAM writes go directly to physical
 * memory, eliminating D-cache coherency issues. At 115200 baud the CPU
 * is idle >99% of the time, so caching adds complexity for no benefit.
 *
 * Receives a kernel image in Intel HEX format over UART0 (GPIO 14/15)
 * with per-line checksums and ACK/NAK flow control, then jumps to 0x80000.
 * Uses CTS/RTS hardware flow control (GPIO 16/17).
 *
 * Protocol:
 *   1. Chainloader prints "READY\r\n" when initialized
 *   2. Host sends Intel HEX records (ASCII, \r\n terminated)
 *   3. Chainloader sends 2-byte ACK (line_len + checksum) or NAK (len + cksum^0xFF)
 *   4. On EOF record: ACK, print "BOOT:NNNN\r\n", jump to 0x80000
 *   5. Host resets Pi via DTR (GLOBAL_EN) when needed
 *
 * Kernel link address (LINK_ADDR=0x80000) matches both the chainloader's
 * jump target and the SD-direct firmware default — one binary, one
 * address, no per-path asymmetry.
 */

/* Pi 4 UART0 (PL011) — firmware configures GPIO 14/15 via enable_uart=1 */
.equ CL_UART_BASE,    0xFE201000
.equ CL_KERNEL_ADDR,  0x80000     /* HEX target + jump address; matches
                                     SD-direct firmware default + the
                                     kernel's LINK_ADDR. */

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
    /* Diagnostic: print 'A' raw to PL011 the very first thing, before
     * even the parking check or relocate. The PL011 was configured by
     * firmware (enable_uart=1 in config.txt), so writing PL011_DR
     * directly works without any setup. Three breadcrumbs in this
     * stub bracket the boot:
     *   'A' = entry — chainload.img reached _start at 0x80000
     *   'B' = relocate copy loop done, about to ic iallu + br
     *   'C' = inside the relocated copy at 0x4000000+offset
     * After 'C' the code falls into the existing chainloader body
     * which prints "READY\r\n" once UART is re-initialized. If we see
     * no characters, firmware isn't placing chainload.img at 0x80000
     * (or 0x80000 is otherwise being clobbered before we run). */
    movz    x9, #0xFE20, lsl #16
    movk    x9, #0x1000
    mov     w10, #'A'
1:  ldr     w11, [x9, #0x18]
    tst     w11, #0x20
    b.ne    1b
    str     w10, [x9]

    /* Park cores 1-3 immediately, while we're still at 0x80000.
     * Doing this before the self-relocate avoids a four-way race on
     * 0x4000000 during the copy and a four-way UART contention on
     * the "READY" message later. Cores 1-3 wfe forever in the live
     * copy at 0x80000 — they don't follow us to 0x4000000. */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    /* === Self-relocate from 0x80000 (firmware load addr) to 0x4000000
     * (link addr) ===
     *
     * The chainloader is linked at 0x4000000 so its literal-pool
     * absolute references resolve there. Firmware loaded the IMAGE at
     * 0x80000 (default kernel address), so we currently execute at
     * 0x80000 with the live binary at 0x80000+offset. Copy the loaded
     * image to 0x4000000, then branch into the copy and continue.
     *
     * Why use literal-pool reads in the stub when we haven't relocated
     * yet: PC-relative ldr `=sym` reads from the literal pool, and the
     * literal pool is part of the .text image — so it's at 0x80000+pool
     * in the LIVE copy. The VALUES it returns are linked addresses
     * (0x4000000, _chainload_size) — what we need for the copy.
     *
     * After the copy we read .Lpost_reloc's linked address and br to
     * it; that lands us at 0x4000000+offset, where every subsequent
     * literal-pool reference is correct. */
    adr     x0, _start                /* source base = current PC = 0x80000 */
    ldr     x1, =_chainload_dest       /* dest base = 0x4000000 */
    ldr     x2, =_chainload_size       /* size in bytes (16-aligned) */
.Lreloc_loop:
    ldp     x3, x4, [x0], #16
    stp     x3, x4, [x1], #16
    subs    x2, x2, #16
    b.gt    .Lreloc_loop

    /* Breadcrumb 'B': copy done, about to ic iallu + br into the copy. */
    movz    x9, #0xFE20, lsl #16
    movk    x9, #0x1000
    mov     w10, #'B'
2:  ldr     w11, [x9, #0x18]
    tst     w11, #0x20
    b.ne    2b
    str     w10, [x9]

    /* I-cache hygiene before branching into the copied bytes. With
     * MMU off the stp went straight to RAM (Device-nGnRnE), so no
     * dc cvau is needed; but I-cache could have stale lines for the
     * 0x4000000 region from any prior boot stage, and Cortex-A72
     * speculatively prefetches. Standard self-modifying-code recipe:
     *   dsb sy   — drain prior stores
     *   ic iallu — invalidate I-cache to PoU
     *   dsb sy   — wait for invalidate
     *   isb      — pipeline flush so next fetch is from RAM */
    dsb     sy
    ic      iallu
    dsb     sy
    isb

    /* Branch into the relocated copy. From here on, literal-pool
     * absolute references resolve correctly because we're running at
     * 0x4000000+offset, where the linker placed everything. */
    ldr     x0, =.Lpost_reloc
    br      x0

.Lpost_reloc:
    /* Breadcrumb 'C': we're now executing in the relocated copy at
     * 0x4000000+offset. From here on, literal-pool refs resolve correctly. */
    movz    x9, #0xFE20, lsl #16
    movk    x9, #0x1000
    mov     w10, #'C'
3:  ldr     w11, [x9, #0x18]
    tst     w11, #0x20
    b.ne    3b
    str     w10, [x9]


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

    /* I-cache hygiene before the jump.
     *
     * The chainloader wrote the kernel's bytes to 0x80000 via D-side
     * stores. With MMU off those writes are Device-nGnRnE — they hit
     * RAM directly, bypassing the D-cache, so no `dc cvau` is needed.
     *
     * BUT: any I-cache lines that exist for the 0x80000 region from
     * an earlier boot stage (firmware splash, prior boot blob, or a
     * previous chainloader run that the host chained twice without a
     * power cycle) would shadow the freshly-written instructions when
     * the CPU branches there. Cortex-A72 also speculatively prefetches
     * along recent branch-predictor entries; without an isb, the core
     * may fetch from a predicted target derived from the chainloader's
     * own code at 0x4000000.
     *
     * The fix is the standard ARM self-modifying-code recipe minus the
     * D-cache clean (already handled by Device-nGnRnE writes):
     *   dsb sy   — drain prior stores and ack-pending barriers
     *   ic iallu — invalidate the entire I-cache to PoU
     *   dsb sy   — wait for the invalidate to complete
     *   isb      — flush the pipeline so the next fetch comes from RAM
     */
    dsb     sy
    ic      iallu
    dsb     sy
    isb

    /* Jump to kernel (loaded directly at 0x80000, no staging needed) */
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
