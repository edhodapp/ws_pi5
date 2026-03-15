.section .text._start

.global _start

_start:
    /* Only let core 0 proceed, park other cores */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    /* Set up stack */
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

    bl      main

.Lpark:
    wfe
    b       .Lpark

/*
 * main - Entry point after boot setup
 */
.global main
main:
    stp     x29, x30, [sp, #-16]!

    bl      uart_init

    ldr     x0, =msg_hello
    bl      uart_puts

    ldp     x29, x30, [sp], #16
    b       .Lpark

.section .rodata
msg_hello:
    .asciz "Hello from bare-metal Pi 3!\r\n"
