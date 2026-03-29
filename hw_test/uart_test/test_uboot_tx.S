/*
 * test_uboot_tx.S — TX test using U-Boot's GENET state
 *
 * Load via U-Boot: loady 0x100000, then go 0x100000
 * Assumes GENET is already initialized and TX works (after U-Boot ping).
 * Does NO GENET init — just builds a frame and sends it.
 */

.equ UART0_BASE, 0xFE201000
.equ GENET_BASE, 0xFD580000
.equ PM_WDOG,    0xFE100024
.equ PM_RSTC,    0xFE10001C

.equ DR,    0x000
.equ FR,    0x018
.equ FR_TXFF, 0x20

.section .text._start
.global _start

_start:
    /* We arrive from U-Boot's "go" command — already at EL1, MMU may be on */
    ldr     x0, =_stack_top
    mov     sp, x0

    /* Zero BSS */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.ge    2f
    str     xzr, [x0], #8
    b       1b
2:

    /* Skip MMU setup — U-Boot already has MMU configured */

    /* UART0 — already configured by U-Boot, just use it */
    ldr     x9, =UART0_BASE

    ldr     x19, =GENET_BASE
    add     x26, x19, #5, lsl #12  /* TDMA ring 16 */

    /* Print current GENET state */
    adr     x10, msg_start
    bl      puts

    /* UMAC_CMD */
    ldr     w0, [x19, #0x808]
    bl      print_hex32
    mov     w0, #' '
    bl      putc

    /* TDMA_DMA_CTRL */
    ldr     w0, [x26, #0x044]
    bl      print_hex32
    mov     w0, #' '
    bl      putc

    /* TDMA PROD/CONS */
    ldr     w0, [x26, #0x00C]
    bl      print_hex32
    mov     w0, #'/'
    bl      putc
    ldr     w0, [x26, #0x008]
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* Re-enable UMAC TX+RX (U-Boot's eth_stop cleared them) */
    ldr     w0, [x19, #0x808]
    orr     w0, w0, #3             /* TX_EN | RX_EN */
    str     w0, [x19, #0x808]

    /* Re-enable DMA (U-Boot's eth_stop cleared DMA_EN) */
    ldr     w0, [x26, #0x044]
    orr     w0, w0, #1             /* DMA_EN */
    str     w0, [x26, #0x044]
    ldr     w0, [x19, #0x3044]     /* RDMA_DMA_CTRL */
    orr     w0, w0, #1
    str     w0, [x19, #0x3044]

    /* Print re-enabled state */
    adr     x10, msg_enabled
    bl      puts
    ldr     w0, [x19, #0x808]
    bl      print_hex32
    mov     w0, #' '
    bl      putc
    ldr     w0, [x26, #0x044]
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* Build ARP frame at 0x300000 */
    ldr     x28, =0x300000
    mov     w0, #-1
    str     w0, [x28, #0]
    strh    w0, [x28, #4]
    ldr     w0, =0xDEADBEEF
    str     w0, [x28, #6]
    mov     w0, #0xCAFE
    strh    w0, [x28, #10]
    mov     w0, #0x0608
    strh    w0, [x28, #12]
    mov     w0, #0x0100
    strh    w0, [x28, #14]
    mov     w0, #0x0008
    strh    w0, [x28, #16]
    mov     w0, #0x0406
    strh    w0, [x28, #18]
    mov     w0, #0x0100
    strh    w0, [x28, #20]
    ldr     w0, =0xDEADBEEF
    str     w0, [x28, #22]
    mov     w0, #0xCAFE
    strh    w0, [x28, #26]
    mov     w0, #0x000A
    strh    w0, [x28, #28]
    mov     w0, #0x0200
    strh    w0, [x28, #30]
    str     wzr, [x28, #32]
    strh    wzr, [x28, #36]
    mov     w0, #0x000A
    strh    w0, [x28, #38]
    mov     w0, #0x0100
    strh    w0, [x28, #40]
    str     xzr, [x28, #48]
    str     xzr, [x28, #56]
    mov     w0, #0x0100
    strh    w0, [x28, #40]

    /* Flush cache (U-Boot has D-cache on) */
    mov     x0, x28
    dc      civac, x0
    add     x0, x0, #64
    dc      civac, x0
    dsb     sy

    /* Write TX descriptor */
    ldr     w22, [x26, #0x00C]     /* PROD_INDEX */
    and     w23, w22, #0xFF
    add     x24, x19, #4, lsl #12
    mov     w0, #12
    mul     w1, w23, w0
    add     x24, x24, x1

    /* Write descriptor using 64-bit stores for atomicity */
    /* Word 0+1: length_status (low) | addr_lo (high) as single str x */
    mov     w0, #(64 << 16)
    ldr     w1, =0x7FC0
    orr     x0, x0, x1             /* x0 low 32 = length_status */
    mov     w1, w28                /* addr_lo = 0x300000 */
    orr     x0, x0, x1, lsl #32   /* x0 high 32 = addr_lo */
    str     x0, [x24, #0]          /* 64-bit write: len_stat + addr_lo */

    /* Word 2: addr_hi */
    str     wzr, [x24, #8]

    /* Flush descriptor */
    dc      civac, x24
    dsb     sy

    /* Print desc readback */
    adr     x10, msg_desc
    bl      puts
    ldr     w0, [x24, #0]
    bl      print_hex32
    mov     w0, #' '
    bl      putc
    ldr     w0, [x24, #4]
    bl      print_hex32
    mov     w0, #' '
    bl      putc
    ldr     w0, [x24, #8]
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* Kick PROD */
    add     w22, w22, #1
    and     w22, w22, #0xFFFF
    str     w22, [x26, #0x00C]

    /* Poll CONS */
    ldr     w24, =1000000
.Ltx_poll:
    ldr     w0, [x26, #0x008]
    and     w0, w0, #0xFFFF
    cmp     w0, w22
    b.eq    .Ltx_ok
    subs    w24, w24, #1
    b.ne    .Ltx_poll
    adr     x10, msg_timeout
    bl      puts
    b       .Ldone
.Ltx_ok:
    adr     x10, msg_tx_ok
    bl      puts

    /* Check key MIB counters */
    adr     x10, msg_mib
    bl      puts
    /* Scan 0xC00-0xCBF for non-zero */
    mov     w21, #0xC00
.Lmib:
    ldr     w0, [x19, x21]
    cbz     w0, .Lmib_skip
    mov     w0, w21
    bl      print_hex32
    mov     w0, #'='
    bl      putc
    ldr     w0, [x19, x21]
    bl      print_hex32
    mov     w0, #' '
    bl      putc
.Lmib_skip:
    add     w21, w21, #4
    cmp     w21, #0xCC0
    b.lt    .Lmib

    /* TXFIFO */
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc
    adr     x10, msg_fifo
    bl      puts
    ldr     w0, [x19, #0xB3C]
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

.Ldone:
    adr     x10, msg_done
    bl      puts

    /* Spin (can't watchdog reset since we came from U-Boot) */
1:  wfe
    b       1b

/* UART helpers */
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
    stp     x21, xzr, [sp, #-16]!
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
    cbz     w21, 3f
    sub     w21, w21, #4
    b       .Lph
3:  ldp     x21, xzr, [sp], #16
    ldp     x30, x20, [sp], #16
    ret

msg_desc:    .asciz "DESC: "
msg_start:   .asciz "UBOOT STATE: CMD="
msg_enabled: .asciz "RE-ENABLED: CMD="
msg_tx_ok:   .asciz "TX OK\r\n"
msg_timeout: .asciz "TX TIMEOUT\r\n"
msg_mib:     .asciz "MIB: "
msg_fifo:    .asciz "TXFIFO="
msg_done:    .asciz "DONE\r\n"
