/*
 * test_noinit_tx.S — TX test with NO GENET init (use firmware state)
 *
 * The firmware processes the device tree and may partially initialize
 * GENET. This test does ZERO register writes except:
 *   - DMA descriptors (write one TX descriptor)
 *   - PROD_INDEX (kick DMA)
 *
 * If TX works here, our init is destroying something.
 * If TX fails, the firmware doesn't init GENET enough for TX.
 */

.equ GENET_BASE_PI4, 0xFD580000
.equ MBOX_BASE_PI4,  0xFE00B880
.equ UART0_BASE_PI4, 0xFE201000
.equ PM_WDOG,        0xFE100024
.equ PM_RSTC,        0xFE10001C

.equ MBOX_CH_PROP,   8
.equ DR,     0x000
.equ FR,     0x018
.equ IBRD,   0x024
.equ FBRD,   0x028
.equ LCRH,   0x02C
.equ CR,     0x030
.equ ICR,    0x044
.equ FR_TXFF, 0x20
.equ FR_RXFE, 0x10

.section .text._start
.global _start

_start:
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    ldr     x0, =_stack_top
    mov     sp, x0

    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.ge    2f
    str     xzr, [x0], #8
    b       1b
2:

    /* MMU */
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
3:  orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #480
    b.lt    3b
4:  orr     x5, x1, x3
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #512
    b.lt    4b
    ldr     x0, =__mmu_l1_table
    msr     TTBR0_EL1, x0
    isb
    mrs     x0, SCTLR_EL1
    orr     x0, x0, #(1 << 0)
    orr     x0, x0, #(1 << 2)
    orr     x0, x0, #(1 << 12)
    msr     SCTLR_EL1, x0
    isb

    /* UART0 */
    ldr     x9, =UART0_BASE_PI4
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

    /* Print banner */
    adr     x10, msg_start
    bl      puts

    /* === Dump firmware GENET state (no init, just read) === */
    ldr     x19, =GENET_BASE_PI4

    adr     x10, msg_ver
    bl      puts
    ldr     w0, [x19, #0x000]
    bl      print_hex32

    adr     x10, msg_cmd
    bl      puts
    ldr     w0, [x19, #0x808]
    bl      print_hex32

    adr     x10, msg_ctrl
    bl      puts
    add     x0, x19, #5, lsl #12
    ldr     w0, [x0, #0x044]
    bl      print_hex32

    adr     x10, msg_oob
    bl      puts
    ldr     w0, [x19, #0x08C]
    bl      print_hex32

    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* === Try TX with firmware state — just write descriptor + kick === */

    /* Build ARP frame at 0x200000 */
    ldr     x28, =0x200000
    mov     w0, #-1
    str     w0, [x28, #0]
    strh    w0, [x28, #4]
    ldr     w0, =0xDEADBEEF
    str     w0, [x28, #6]
    mov     w0, #0xCAFE
    strh    w0, [x28, #10]
    mov     w0, #0x0608
    strh    w0, [x28, #12]
    /* Minimal ARP padding to 60 bytes */
    mov     w1, #14
5:  str     wzr, [x28, x1]
    add     w1, w1, #4
    cmp     w1, #60
    b.lt    5b

    /* Flush */
    bic     x0, x28, #63
    dc      civac, x0
    dsb     sy

    /* Read current TDMA CONS/PROD */
    add     x26, x19, #5, lsl #12
    ldr     w22, [x26, #0x008]     /* CONS */
    ldr     w23, [x26, #0x00C]     /* PROD */

    adr     x10, msg_pre
    bl      puts
    mov     w0, w22
    bl      print_hex32
    mov     w0, #'/'
    bl      putc
    mov     w0, w23
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* Write TX descriptor at index (PROD & 0xFF) */
    and     w24, w23, #0xFF
    add     x25, x19, #4, lsl #12  /* TX desc base */
    mov     w0, #12
    mul     w1, w24, w0
    add     x25, x25, x1

    mov     w0, w28                /* addr_lo = 0x200000 */
    str     w0, [x25, #4]
    str     wzr, [x25, #8]
    /* length_status: 60 bytes + SOP|EOP|QTAG|CRC */
    mov     w0, #60
    lsl     w0, w0, #16
    ldr     w1, =0x7FC0
    orr     w0, w0, w1
    str     w0, [x25, #0]

    /* Kick: PROD++ */
    add     w23, w23, #1
    and     w23, w23, #0xFFFF
    str     w23, [x26, #0x00C]

    /* Wait */
    ldr     w0, =100000
6:  subs    w0, w0, #1
    b.ne    6b

    /* Check CONS */
    ldr     w0, [x26, #0x008]
    adr     x10, msg_post
    bl      puts
    mov     w22, w0
    bl      print_hex32

    /* TX_GD_PKTS */
    adr     x10, msg_txpkt
    bl      puts
    ldr     w0, [x19, #0xA2C]
    bl      print_hex32

    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    adr     x10, msg_done
    bl      puts

    /* Watchdog reset */
7:  ldr     w0, [x9, #FR]
    tst     w0, #0x08
    b.ne    7b
8:  ldr     w0, [x9, #FR]
    tst     w0, #FR_RXFE
    b.ne    8b
    ldr     x0, =PM_WDOG
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x000A
    str     w1, [x0]
    ldr     x0, =PM_RSTC
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x0020
    str     w1, [x0]
9:  wfe
    b       9b

putc:
1:  ldr     w1, [x9, #FR]
    tst     w1, #FR_TXFF
    b.ne    1b
    str     w0, [x9, #DR]
    ret

puts:
    stp     x30, xzr, [sp, #-16]!
1:  ldrb    w0, [x10], #1
    cbz     w0, 2f
    bl      putc
    b       1b
2:  ldp     x30, xzr, [sp], #16
    ret

print_hex32:
    stp     x30, x20, [sp, #-16]!
    mov     w20, w0
    mov     w21, #28
1:  lsr     w0, w20, w21
    and     w0, w0, #0xF
    cmp     w0, #10
    b.lt    2f
    add     w0, w0, #('A' - 10)
    b       3f
2:  add     w0, w0, #'0'
3:  bl      putc
    cbz     w21, 4f
    sub     w21, w21, #4
    b       1b
4:  ldp     x30, x20, [sp], #16
    ret

.Lpark:
    wfe
    b       .Lpark

.section .rodata
msg_start: .asciz "NOINIT TX TEST\r\n"
msg_ver:   .asciz "VER="
msg_cmd:   .asciz " CMD="
msg_ctrl:  .asciz " CTRL="
msg_oob:   .asciz " OOB="
msg_pre:   .asciz "PRE C/P="
msg_post:  .asciz "POST C="
msg_txpkt: .asciz " TX="
msg_done:  .asciz "DONE\r\n"
