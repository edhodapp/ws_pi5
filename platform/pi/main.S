.include "dwc2.inc"
.include "cdc_ecm.inc"
.include "uart.inc"
.include "gpio.inc"
.include "net.inc"
.include "timer.inc"
.include "ntp.inc"
.include "tcp.inc"
.include "http.inc"
.ifdef PLATFORM_PI4
.include "genet.inc"
.endif

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

.ifdef PLATFORM_PI4
    /* Switch to UART3 on GPIO 4/5 for Pi 4 serial debug */
    ldr     x0, =GPIO_BASE
    mov     w1, #4
    mov     w2, #GPIO_FSEL_ALT4
    bl      gpio_set_function

    ldr     x0, =GPIO_BASE
    mov     w1, #5
    mov     w2, #GPIO_FSEL_ALT4
    bl      gpio_set_function

    ldr     x0, =UART3_BASE
    bl      uart_set_base
    bl      uart_init
.endif

.ifdef PLATFORM_PI4
    ldr     x0, =msg_hello_pi4
    bl      uart_puts

    /* Initialize GENET Ethernet */
    ldr     x0, =GENET_BASE
    ldr     x1, =genet_state
    ldr     x2, =genet_rx_pool
    bl      genet_init
    cbnz    w0, .Lnet_fail

    /* Set MAC address from mailbox */
    ldr     x0, =GENET_BASE
    ldr     x1, =genet_mac
    bl      genet_set_mac

    ldr     x0, =msg_genet_ok
    bl      uart_puts
.else
    ldr     x0, =msg_hello
    bl      uart_puts

    /* Initialize DWC2 USB host controller */
    ldr     x0, =DWC2_BASE
    bl      dwc2_init
    cbnz    w0, .Lnet_fail

    ldr     x0, =msg_dwc2_ok
    bl      uart_puts

    /* Enumerate and configure CDC-ECM device */
    ldr     x0, =DWC2_BASE
    ldr     x1, =ecm_state
    bl      cdc_ecm_init
    cbnz    w0, .Lnet_fail

    ldr     x0, =msg_ecm_init_ok
    bl      uart_puts

    /* Activate data interface (SET_INTERFACE alt=1) */
    ldr     x0, =DWC2_BASE
    ldr     x1, =ecm_state
    bl      cdc_ecm_activate
    cbnz    w0, .Lnet_fail

    ldr     x0, =msg_ecm_active
    bl      uart_puts
.endif

    /* Initialize timer pool */
    ldr     x0, =timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init

    /* Initialize IP fragment reassembly */
    bl      ip_reasm_init
    ldr     x0, =timer_pool
    bl      ip_reasm_set_timer_pool

    /* Initialize TCP connection table */
    bl      tcp_init

    /* Give TCP a handle to the timer pool — must precede tcp_listen */
    ldr     x0, =timer_pool
    bl      tcp_set_timer_pool

    mov     w0, #80
    bl      tcp_listen

    /* Start idle connection reaper */
    bl      tcp_start_reaper

.ifdef PLATFORM_PI4
    .equ NET_BASE_SYM, GENET_BASE
    .equ NET_STATE_SYM, genet_state
    .equ NET_SEND_SYM, genet_send
.else
    .equ NET_BASE_SYM, DWC2_BASE
    .equ NET_STATE_SYM, ecm_state
    .equ NET_SEND_SYM, cdc_ecm_send
.endif

    /* Set up TCP retransmit send context */
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =tcp_tx_buf
    ldr     x3, =NET_SEND_SYM
    bl      tcp_set_send_ctx

    /* Initialize ICMP error subsystem */
    bl      icmp_init
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =icmp_tx_buf
    ldr     x3, =NET_SEND_SYM
    bl      icmp_set_send_ctx

    /* Start ARP cache refresh (arm timer to resolve gateway MAC on boot) */
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =arp_tx_buf
    ldr     x3, =timer_pool
    ldr     x4, =NET_SEND_SYM
    bl      arp_start

    /* Initialize NTP (cache timer frequency) */
    bl      ntp_init

    /* Start NTP client (arm first timer) */
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =ntp_tx_buf
    ldr     x3, =timer_pool
    ldr     x4, =NET_SEND_SYM
    bl      ntp_start

    /* Initialize HTTP server */
    bl      http_init
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =http_tx_buf
    ldr     x3, =NET_SEND_SYM
    bl      http_set_send_ctx

    mov     w0, #0
    b       .Ldone

.Lnet_fail:
    ldr     x0, =msg_net_fail
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
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =rx_buf
    mov     w3, #ETH_FRAME_MAX
.ifdef PLATFORM_PI4
    bl      genet_recv
.else
    bl      cdc_ecm_recv
.endif
    cbnz    w0, .Lnet_timers        /* recv failed / no frame → check timers */

.ifdef PLATFORM_PI4
    /* Debug: print '.' for each received frame */
    stp     x0, x1, [sp, #-16]!
    mov     w0, #'.'
    bl      uart_putc
    ldp     x0, x1, [sp], #16
.endif

    /* w1 = actual frame length */
    ldr     x0, =rx_buf
    bl      net_recv_one
    cbz     w0, .Lnet_timers

    mov     w3, w0                  /* w3 = reply_len */
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =rx_buf
.ifdef PLATFORM_PI4
    bl      genet_send
.else
    bl      cdc_ecm_send
.endif

.Lnet_timers:
    bl      timer_now
    mov     x1, x0
    ldr     x0, =timer_pool
    bl      timer_check
    bl      http_poll
    b       net_loop

.section .data

.ifdef PLATFORM_PI4
.balign 16
genet_state:
    .space  GENET_STATE_SIZE

/* Hardcoded MAC — replace with mailbox tag later */
genet_mac:
    .byte   0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE
    .balign 4

.endif

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
http_tx_buf:
    .space  ETH_FRAME_MAX

.balign 16
icmp_tx_buf:
    .space  ICMP_ERROR_FRAME_LEN

.balign 16
arp_tx_buf:
    .space  ARP_FRAME_LEN

.balign 16
ntp_tx_buf:
    .space  NTP_FRAME_LEN

.balign 16
tcp_tx_buf:
    .space  ETH_FRAME_MAX

.ifdef PLATFORM_PI4
/* RX buffer pool in BSS: 256 * 2048 = 512 KB, zeroed by boot.S */
.section .bss
.balign 64
genet_rx_pool:
    .space  (DMA_DESC_COUNT * RX_BUF_LENGTH)
.endif

.section .rodata
msg_hello:      .asciz "Hello from bare-metal Pi 3!\r\n"
msg_dwc2_ok:    .asciz "DWC2 USB host initialized\r\n"
msg_ecm_init_ok: .asciz "CDC-ECM device configured\r\n"
msg_ecm_active: .asciz "CDC-ECM data interface active\r\n"
.ifdef PLATFORM_PI4
msg_hello_pi4:  .asciz "Hello from bare-metal Pi 4!\r\n"
msg_genet_ok:   .asciz "GENET Gigabit Ethernet initialized\r\n"
.endif
msg_net_fail:   .asciz "Network bring-up failed\r\n"
