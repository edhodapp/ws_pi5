/*
 * main.S — BeaglePlay (AM625) init sequence
 *
 * Brings up UART0, CPSW Ethernet, and enters net_loop.
 * Stub — to be completed during BeaglePlay bringup.
 */

.include "cpsw.inc"
.include "net.inc"
.include "timer.inc"
.include "ntp.inc"
.include "tcp.inc"
.include "http.inc"

.section .text

.global main
main:
    stp     x29, x30, [sp, #-16]!

    bl      uart_init

    ldr     x0, =msg_hello
    bl      uart_puts

    /* TODO: CPSW Ethernet init */
    /* TODO: Timer pool, TCP, HTTP init (same as Pi) */

    mov     w0, #1              /* Stub: fail until implemented */
    ldp     x29, x30, [sp], #16
    ret

.global net_loop
net_loop:
    /* TODO: CPSW recv/send loop */
    wfe
    b       net_loop

.section .rodata
msg_hello:  .asciz "Hello from bare-metal BeaglePlay!\r\n"
