/*
 * test_kern.S — Hardware integration test kernel
 *
 * Loaded at 0x100000 by step5 loader. Runs at EL1.
 *
 * Current tests:
 *   - Production MMU (4 GB identity map)
 *   - UART3 output
 *   - Mailbox: TAG_GET_BOARD_REV
 *   - Watchdog reset
 */

.equ GPIO_BASE,    0xFE200000
.equ UART3_BASE,   0xFE201600
.equ MBOX_BASE_PI4, 0xFE00B880
.equ PM_WDOG,      0xFE100024
.equ PM_RSTC,      0xFE10001C

/* Mailbox constants */
.equ MBOX_READ,        0x00
.equ MBOX_STATUS,      0x18
.equ MBOX_WRITE,       0x20
.equ MBOX_CH_PROP,     8
.equ MBOX_REQUEST,     0x00000000
.equ TAG_GET_BOARD_REV, 0x00010002

/* PL011 */
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
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

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
.Lfn:
    orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #496
    b.lt    .Lfn
.Lfd:
    orr     x5, x1, x3
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #512
    b.lt    .Lfd

    ldr     x0, =__mmu_l1_table
    msr     TTBR0_EL1, x0
    isb
    mrs     x0, SCTLR_EL1
    orr     x0, x0, #(1 << 0)
    orr     x0, x0, #(1 << 2)
    orr     x0, x0, #(1 << 12)
    msr     SCTLR_EL1, x0
    isb

    /* --- GPIO + UART3 --- */
    ldr     x9, =GPIO_BASE
    ldr     w0, [x9]
    bic     w0, w0, #(7 << 12)
    orr     w0, w0, #(3 << 12)
    bic     w0, w0, #(7 << 15)
    orr     w0, w0, #(3 << 15)
    str     w0, [x9]

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

    /* ===== TEST: Mailbox — get board revision ===== */

    /* Build tag buffer */
    ldr     x19, =mbox_buf
    mov     w0, #32
    str     w0, [x19, #0]          /* buffer size */
    mov     w0, #MBOX_REQUEST
    str     w0, [x19, #4]          /* request code */
    ldr     w0, =TAG_GET_BOARD_REV
    str     w0, [x19, #8]          /* tag id */
    mov     w0, #4
    str     w0, [x19, #12]         /* value buffer size */
    str     wzr, [x19, #16]        /* request/response code */
    str     wzr, [x19, #20]        /* value (filled by VC) */
    str     wzr, [x19, #24]        /* end tag */

    /* Flush buffer from D-cache to RAM (VC reads RAM directly) */
    dc      civac, x19
    dsb     sy

    /* Call mbox_call(buf, channel, base) */
    mov     x0, x19
    mov     w1, #MBOX_CH_PROP
    ldr     x2, =MBOX_BASE_PI4
    bl      mbox_call

    /* Invalidate buffer cache line so we read VC's response from RAM */
    dc      civac, x19
    dsb     sy

    /* Check result */
    cbnz    w0, .Lmbox_fail

    /* Print "MBOX OK rev=" */
    adr     x10, msg_mbox_ok
    bl      puts

    /* Print the board revision (32-bit hex) */
    ldr     w20, [x19, #20]        /* revision value from VC */
    mov     w0, w20
    bl      print_hex32

    /* Print newline */
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc
    b       .Ltests_done

.Lmbox_fail:
    adr     x10, msg_mbox_fail
    bl      puts

.Ltests_done:
    /* --- DONE --- */
    adr     x10, msg_done
    bl      puts

    /* Drain TX */
.Ldrain:
    ldr     w0, [x9, #FR]
    tst     w0, #0x08
    b.ne    .Ldrain

    /* Wait for reset byte */
.Lwait_cmd:
    ldr     w0, [x9, #FR]
    tst     w0, #FR_RXFE
    b.ne    .Lwait_cmd

    /* Watchdog reset */
    ldr     x0, =PM_WDOG
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x000A
    str     w1, [x0]
    ldr     x0, =PM_RSTC
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x0020
    str     w1, [x0]
.Lwait_reset:
    wfe
    b       .Lwait_reset

/* ===== Mailbox driver (inlined from platform/pi/drivers/mailbox.S) ===== */

/*
 * mbox_call - Send property tag buffer to VideoCore mailbox
 * x0: 16-byte-aligned tag buffer
 * w1: channel (8 = property)
 * x2: mailbox base address
 * Returns: w0 = 0 success, 1 failure
 */
mbox_call:
    mov     x3, x2
    and     w2, w1, #0xF
    orr     x2, x0, x2
.Lmw:
    ldr     w4, [x3, #MBOX_STATUS]
    tbnz    w4, #31, .Lmw
    str     w2, [x3, #MBOX_WRITE]
.Lmr:
    ldr     w4, [x3, #MBOX_STATUS]
    tbnz    w4, #30, .Lmr
    ldr     w4, [x3, #MBOX_READ]
    and     w5, w4, #0xF
    cmp     w5, w1
    b.ne    .Lmr
    /* Invalidate buffer cache line — VC wrote response to RAM, not our cache */
    dc      civac, x0
    dsb     sy
    ldr     w0, [x0, #4]
    and     w0, w0, #0x80000000
    cmp     w0, #0
    cset    w0, eq
    ret

/* ===== UART helpers ===== */

putc:
1:  ldr     w1, [x9, #FR]
    tst     w1, #FR_TXFF
    b.ne    1b
    str     w0, [x9, #DR]
    ret

puts:
    stp     x30, xzr, [sp, #-16]!
.Lps:
    ldrb    w0, [x10], #1
    cbz     w0, .Lpsd
    bl      putc
    b       .Lps
.Lpsd:
    ldp     x30, xzr, [sp], #16
    ret

/* print_hex32: print w0 as 8-digit hex */
print_hex32:
    stp     x30, x20, [sp, #-16]!
    mov     w20, w0
    mov     w21, #28
.Lph:
    lsr     w0, w20, w21
    and     w0, w0, #0xF
    cmp     w0, #10
    b.lt    1f
    add     w0, w0, #('A' - 10)
    b       2f
1:  add     w0, w0, #'0'
2:  bl      putc
    cbz     w21, .Lphd
    sub     w21, w21, #4
    b       .Lph
.Lphd:
    ldp     x30, x20, [sp], #16
    ret

.Lpark:
    wfe
    b       .Lpark

/* ===== Data ===== */

.section .rodata
msg_mbox_ok:    .asciz "MBOX OK rev="
msg_mbox_fail:  .asciz "MBOX FAIL\r\n"
msg_done:       .asciz "DONE\r\n"

.section .data
.balign 16
mbox_buf:
    .space 32
