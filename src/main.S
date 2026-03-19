.include "dwc2.inc"
.include "cdc_ecm.inc"
.include "net.inc"
.include "timer.inc"
.include "ntp.inc"

.section .text

/*
 * main - Entry point after boot setup
 *
 * Brings up UART, DWC2 USB host, and CDC-ECM Ethernet device.
 * Returns: w0 = 0 on success, 1 on failure
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

    /* Initialize timer pool */
    ldr     x0, =timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init

    /* Initialize TCP connection table */
    bl      tcp_init

    /* Initialize NTP (cache timer frequency) */
    bl      ntp_init

    /* Start NTP client (arm first timer) */
    ldr     x0, =DWC2_BASE
    ldr     x1, =ecm_state
    ldr     x2, =ntp_tx_buf
    ldr     x3, =timer_pool
    ldr     x4, =cdc_ecm_send
    bl      ntp_start

    mov     w0, #0
    b       .Ldone

.Lusb_fail:
    ldr     x0, =msg_usb_fail
    bl      uart_puts
    mov     w0, #1

.Ldone:
    ldp     x29, x30, [sp], #16
    ret

/*
 * net_loop — Infinite recv/dispatch/send loop
 *
 * Never returns. Called after main succeeds.
 * Accesses ecm_state directly (file-local).
 */
.global net_loop
net_loop:
    ldr     x0, =DWC2_BASE
    ldr     x1, =ecm_state
    ldr     x2, =rx_buf
    mov     w3, #ETH_FRAME_MAX
    bl      cdc_ecm_recv
    cbnz    w0, net_loop            /* recv failed → retry */

    ldr     x0, =rx_buf
    mov     w1, #ETH_FRAME_MAX
    bl      net_recv_one
    cbz     w0, .Lnet_timers        /* no reply → check timers → loop */

    mov     w3, w0                  /* w3 = reply_len */
    ldr     x0, =DWC2_BASE
    ldr     x1, =ecm_state
    ldr     x2, =rx_buf
    bl      cdc_ecm_send

.Lnet_timers:
    bl      timer_now
    mov     x1, x0
    ldr     x0, =timer_pool
    bl      timer_check
    b       net_loop

.section .data
.balign 16
ecm_state:
    .space  ECM_SIZE

.balign 16
rx_buf:
    .space  ETH_FRAME_MAX

.balign 16
timer_pool:
    .space  TPOOL_DEFAULT_SIZE

.balign 16
ntp_tx_buf:
    .space  NTP_FRAME_LEN

.section .rodata
msg_hello:      .asciz "Hello from bare-metal Pi 3!\r\n"
msg_dwc2_ok:    .asciz "DWC2 USB host initialized\r\n"
msg_ecm_init_ok: .asciz "CDC-ECM device configured\r\n"
msg_ecm_active: .asciz "CDC-ECM data interface active\r\n"
msg_usb_fail:   .asciz "USB bring-up failed\r\n"
