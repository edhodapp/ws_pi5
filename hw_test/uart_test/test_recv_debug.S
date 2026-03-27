/*
 * test_recv_debug.S — Debug genet_recv with production driver
 *
 * Calls production genet_init, then polls genet_recv in a loop,
 * printing PROD_INDEX and CIDX each iteration.
 */

.equ GPIO_BASE_PI4,  0xFE200000
.equ UART3_BASE_PI4, 0xFE201600
.equ GENET_BASE_PI4, 0xFD580000
.equ MBOX_BASE_PI4,  0xFE00B880
.equ PM_WDOG,        0xFE100024
.equ PM_RSTC,        0xFE10001C

.equ MBOX_CH_PROP,     8
.equ MBOX_REQUEST,     0
.equ TAG_GET_BOARD_REV, 0x00010002

.equ RDMA_PROD_INDEX,  0x3008
.equ GENET_STATE_RX_CIDX, 0

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

    /* MMU: 4 GB identity map, Device from 0xFC000000 */
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

    /* UART3 */
    ldr     x9, =GPIO_BASE_PI4
    ldr     w0, [x9]
    bic     w0, w0, #(7 << 12)
    orr     w0, w0, #(3 << 12)
    bic     w0, w0, #(7 << 15)
    orr     w0, w0, #(3 << 15)
    str     w0, [x9]

    ldr     x9, =UART3_BASE_PI4
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

    /* Call production genet_init */
    ldr     x0, =GENET_BASE_PI4
    ldr     x1, =gstate
    ldr     x2, =rxpool
    bl      genet_init
    cbnz    w0, .Lfail

    adr     x10, msg_ok
    bl      puts

    /* Print initial PROD_INDEX and CIDX */
    ldr     x19, =GENET_BASE_PI4
    ldr     x20, =gstate

    adr     x10, msg_prod
    bl      puts
    ldr     w0, [x19, #RDMA_PROD_INDEX]
    bl      print_hex32
    adr     x10, msg_cidx
    bl      puts
    ldr     w0, [x20, #GENET_STATE_RX_CIDX]
    bl      print_hex32
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    /* Poll genet_recv 20 times, 1 second apart */
    mov     w27, #0
.Lrecv_loop:
    /* Delay ~1 second */
    ldr     x0, =50000000
5:  subs    x0, x0, #1
    b.ne    5b

    /* Print current PROD_INDEX */
    adr     x10, msg_prod
    bl      puts
    ldr     w0, [x19, #RDMA_PROD_INDEX]
    bl      print_hex32

    /* Print CIDX from state */
    adr     x10, msg_cidx
    bl      puts
    ldr     w0, [x20, #GENET_STATE_RX_CIDX]
    bl      print_hex32

    /* Call genet_recv */
    ldr     x0, =GENET_BASE_PI4
    ldr     x1, =gstate
    ldr     x2, =rxbuf
    mov     w3, #1536
    bl      genet_recv

    /* Print result */
    cbnz    w0, .Lno_frame
    mov     w0, #' '
    bl      putc
    mov     w0, #'F'
    bl      putc
    mov     w0, #'!'
    bl      putc
    b       .Lrecv_next
.Lno_frame:
    mov     w0, #' '
    bl      putc
    mov     w0, #'-'
    bl      putc
.Lrecv_next:
    mov     w0, #'\r'
    bl      putc
    mov     w0, #'\n'
    bl      putc

    add     w27, w27, #1
    cmp     w27, #20
    b.lt    .Lrecv_loop

    adr     x10, msg_done
    bl      puts
    b       .Lwait_reset

.Lfail:
    adr     x10, msg_fail
    bl      puts

.Lwait_reset:
    /* Drain + wait for byte + watchdog */
6:  ldr     w0, [x9, #FR]
    tst     w0, #0x08
    b.ne    6b
7:  ldr     w0, [x9, #FR]
    tst     w0, #FR_RXFE
    b.ne    7b
    ldr     x0, =PM_WDOG
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x000A
    str     w1, [x0]
    ldr     x0, =PM_RSTC
    movz    w1, #0x5A00, lsl #16
    movk    w1, #0x0020
    str     w1, [x0]
8:  wfe
    b       8b

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

print_hex8:
    stp     x30, x20, [sp, #-16]!
    and     w20, w0, #0xFF
    lsr     w0, w20, #4
    and     w0, w0, #0xF
    cmp     w0, #10
    b.lt    1f
    add     w0, w0, #('A' - 10)
    b       2f
1:  add     w0, w0, #'0'
2:  bl      putc
    and     w0, w20, #0xF
    cmp     w0, #10
    b.lt    3f
    add     w0, w0, #('A' - 10)
    b       4f
3:  add     w0, w0, #'0'
4:  bl      putc
    ldp     x30, x20, [sp], #16
    ret

.Lpark:
    wfe
    b       .Lpark

.section .rodata
msg_ok:   .asciz "GENET OK\r\n"
msg_fail: .asciz "GENET FAIL\r\n"
msg_prod: .asciz "P="
msg_cidx: .asciz " C="
msg_done: .asciz "DONE\r\n"

.section .data
.balign 16
gstate: .space 24
.balign 64
rxbuf:  .space 1536

.section .bss
.balign 64
rxpool: .space (256 * 2048)
