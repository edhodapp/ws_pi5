.include "dwc2.inc"
.include "cdc_ecm.inc"

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
 *
 * Brings up UART, DWC2 USB host, and CDC-ECM Ethernet device.
 */
.global main
main:
    stp     x29, x30, [sp, #-16]!

    bl      uart_init

    ldr     x0, =msg_hello
    bl      uart_puts

    /* Initialize DWC2 USB host controller */
    ldr     x0, =DWC2_BASE
    bl      dwc2_init
    cbnz    w0, .Lusb_fail

    ldr     x0, =msg_dwc2_ok
    bl      uart_puts

    /* Enumerate and configure CDC-ECM device */
    ldr     x0, =DWC2_BASE
    ldr     x1, =ecm_state
    bl      cdc_ecm_init
    cbnz    w0, .Lusb_fail

    ldr     x0, =msg_ecm_init_ok
    bl      uart_puts

    /* Activate data interface (SET_INTERFACE alt=1) */
    ldr     x0, =DWC2_BASE
    ldr     x1, =ecm_state
    bl      cdc_ecm_activate
    cbnz    w0, .Lusb_fail

    ldr     x0, =msg_ecm_active
    bl      uart_puts

    b       .Ldone

.Lusb_fail:
    ldr     x0, =msg_usb_fail
    bl      uart_puts

.Ldone:
    ldp     x29, x30, [sp], #16
    b       .Lpark

.section .data
.balign 16
ecm_state:
    .space  ECM_SIZE

.section .rodata
msg_hello:      .asciz "Hello from bare-metal Pi 3!\r\n"
msg_dwc2_ok:    .asciz "DWC2 USB host initialized\r\n"
msg_ecm_init_ok: .asciz "CDC-ECM device configured\r\n"
msg_ecm_active: .asciz "CDC-ECM data interface active\r\n"
msg_usb_fail:   .asciz "USB bring-up failed\r\n"
