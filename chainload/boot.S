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

/* Line buffer size (max Intel HEX line ~43 chars + margin) */
.equ LINE_BUF_SIZE,    80

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
cl_getc:
1:  ldr     w0, [x19, #PL011_FR]
    tst     w0, #PL011_FR_RXFE
    b.ne    1b
    ldr     w0, [x19, #PL011_DR]
    and     w0, w0, #0xFF
    ret

/* =======================================================================
 * Intel HEX parser
 * ======================================================================= */

/* -----------------------------------------------------------------------
 * cl_getline — Read one line from UART into hex_line_buf
 *
 * Reads until \n. Strips \r and \n. Stops at LINE_BUF_SIZE-2 chars.
 * Uses x25 (line buffer pointer, set by caller).
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
    cmp     w26, #(LINE_BUF_SIZE - 2)
    b.ge    .Lgl_loop                  /* overflow: discard but keep reading */
    strb    w0, [x25, w26, uxtw]
    add     w26, w26, #1
    b       .Lgl_loop
.Lgl_done:
    ldr     x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * cl_hex_nibble — Convert ASCII hex character to 0-15
 *
 * Input:  w0 = ASCII char ('0'-'9', 'A'-'F', 'a'-'f')
 * Output: w0 = 0-15 value
 * Leaf function. Clobbers w0 only.
 * ----------------------------------------------------------------------- */
cl_hex_nibble:
    cmp     w0, #'9'
    b.hi    1f
    sub     w0, w0, #'0'              /* '0'-'9' → 0-9 */
    ret
1:  orr     w0, w0, #0x20             /* tolower: 'A'-'F' → 'a'-'f' */
    sub     w0, w0, #('a' - 10)       /* 'a'-'f' → 10-15 */
    ret

/* -----------------------------------------------------------------------
 * cl_hex_byte — Parse two ASCII hex chars from line buffer into one byte
 *
 * Input:  x25 = buffer base, w22 = current index (advanced by 2)
 * Output: w0 = byte value (0-255)
 * Clobbers: w0, w1, w22
 * ----------------------------------------------------------------------- */
cl_hex_byte:
    str     x30, [sp, #-16]!
    ldrb    w0, [x25, w22, uxtw]
    add     w22, w22, #1
    bl      cl_hex_nibble
    mov     w1, w0                     /* w1 = high nibble */
    ldrb    w0, [x25, w22, uxtw]
    add     w22, w22, #1
    bl      cl_hex_nibble
    orr     w0, w0, w1, lsl #4        /* w0 = (high << 4) | low */
    ldr     x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * cl_parse_hex_record — Parse and process one Intel HEX record
 *
 * Input:
 *   x25 = line buffer (contains record without CR/LF)
 *   w26 = line length
 *   x24 = current extended base address (upper 16 bits << 16)
 *
 * Output:
 *   w0: 0 = data record OK, 1 = EOF, -1 = error
 *   x24 updated for Type 04 (extended linear address)
 *   w20 += data bytes written for Type 00
 *
 * Clobbers: w0-w9, w22, w27
 * Preserves: x19, x23, x25
 * ----------------------------------------------------------------------- */
cl_parse_hex_record:
    stp     x29, x30, [sp, #-48]!     /* frame: 16 saved + 16 staging + 16 pad */

    /* Validate start code */
    ldrb    w0, [x25]
    cmp     w0, #':'
    b.ne    .Lparse_err

    mov     w22, #1                    /* buffer index, skip ':' */

    /* Parse header: LL, AAAA, TT */
    bl      cl_hex_byte
    mov     w2, w0                     /* w2 = byte count (LL) */

    bl      cl_hex_byte
    mov     w3, w0                     /* w3 = address high byte */

    bl      cl_hex_byte
    orr     w3, w0, w3, lsl #8        /* w3 = 16-bit address */

    bl      cl_hex_byte
    mov     w5, w0                     /* w5 = record type (TT) */

    /* Initialize checksum: LL + addr_hi + addr_lo + TT */
    ubfx    w0, w3, #8, #8            /* addr high byte */
    and     w1, w3, #0xFF             /* addr low byte */
    add     w27, w2, w0
    add     w27, w27, w1
    add     w27, w27, w5

    /* Parse data bytes into staging area on stack */
    add     x8, sp, #16               /* x8 = staging buffer */
    mov     w6, #0                     /* staging index */
    mov     w7, w2                     /* loop counter = byte count */
.Lparse_data:
    cbz     w7, .Lparse_data_done
    bl      cl_hex_byte
    add     w27, w27, w0              /* accumulate checksum */
    strb    w0, [x8, w6, uxtw]
    add     w6, w6, #1
    sub     w7, w7, #1
    b       .Lparse_data
.Lparse_data_done:

    /* Parse and verify checksum */
    bl      cl_hex_byte               /* w0 = checksum byte */
    add     w27, w27, w0
    and     w27, w27, #0xFF
    cbnz    w27, .Lparse_err          /* sum must be 0 */

    /* Dispatch on record type */
    cbz     w5, .Ltype_data           /* Type 00: data */
    cmp     w5, #0x01
    b.eq    .Ltype_eof                /* Type 01: EOF */
    cmp     w5, #0x04
    b.eq    .Ltype_ext_addr           /* Type 04: extended linear address */
    b       .Lparse_err               /* unknown type */

.Ltype_data:
    /* Write staged data to RAM at (extended_base + 16-bit offset) */
    add     x9, x24, w3, uxtw        /* x9 = absolute target address */
    mov     w7, #0
.Lcopy_data:
    cmp     w7, w6
    b.ge    .Lcopy_done
    ldrb    w0, [x8, w7, uxtw]
    strb    w0, [x9, w7, uxtw]
    add     w7, w7, #1
    b       .Lcopy_data
.Lcopy_done:
    add     w20, w20, w6              /* total bytes received */
    mov     w0, #0                     /* return 0: data OK */
    b       .Lparse_ret

.Ltype_eof:
    mov     w0, #1                     /* return 1: EOF */
    b       .Lparse_ret

.Ltype_ext_addr:
    /* Two data bytes form the upper 16 bits of the base address */
    ldrb    w0, [x8]                  /* high byte */
    ldrb    w1, [x8, #1]             /* low byte */
    orr     w0, w1, w0, lsl #8       /* 16-bit value */
    lsl     x24, x0, #16             /* x24 = upper address << 16 */
    mov     w0, #0                     /* return 0: OK */
    b       .Lparse_ret

.Lparse_err:
    mov     w0, #-1
    /* fall through */

.Lparse_ret:
    ldp     x29, x30, [sp], #48
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

/* -----------------------------------------------------------------------
 * BSS: line buffer (zeroed by .Lbss_loop at boot)
 * ----------------------------------------------------------------------- */
.section .bss
.balign 8
hex_line_buf:
    .skip   LINE_BUF_SIZE
