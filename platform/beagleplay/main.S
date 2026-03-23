/*
 * main.S — BeaglePlay (AM625) init sequence
 *
 * Brings up UART0, CPSW Ethernet, and enters net_loop.
 * CPSW send/recv are stubbed until PKTDMA is implemented —
 * net_loop runs but recv always fails, so it just checks timers.
 */

.include "platform.inc"
.include "cpsw.inc"
.include "net.inc"
.include "timer.inc"
.include "ntp.inc"
.include "tcp.inc"
.include "http.inc"

.section .text

/*
 * main — Entry point after boot setup
 * Returns: w0 = 0 on success, 1 on failure
 */
.global main
main:
    stp     x29, x30, [sp, #-16]!

    bl      uart_init

    ldr     x0, =msg_hello
    bl      uart_puts

    /* Initialize CPSW Ethernet */
    ldr     x0, =cpsw_state
    ldr     x1, =our_mac_addr
    ldr     x2, =CPSW_BASE
    bl      cpsw_init
    cbnz    w0, .Lcpsw_fail

    ldr     x0, =msg_cpsw_ok
    bl      uart_puts

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

    /* Give TCP a handle to the timer pool */
    ldr     x0, =timer_pool
    bl      tcp_set_timer_pool

    mov     w0, #80
    bl      tcp_listen

    /* Start idle connection reaper */
    bl      tcp_start_reaper

    /* Set up TCP retransmit send context */
    ldr     x0, =CPSW_BASE
    ldr     x1, =cpsw_state
    ldr     x2, =tcp_tx_buf
    ldr     x3, =cpsw_send
    bl      tcp_set_send_ctx

    /* Initialize ICMP error subsystem */
    bl      icmp_init
    ldr     x0, =CPSW_BASE
    ldr     x1, =cpsw_state
    ldr     x2, =icmp_tx_buf
    ldr     x3, =cpsw_send
    bl      icmp_set_send_ctx

    /* Start ARP cache refresh */
    ldr     x0, =CPSW_BASE
    ldr     x1, =cpsw_state
    ldr     x2, =arp_tx_buf
    ldr     x3, =timer_pool
    ldr     x4, =cpsw_send
    bl      arp_start

    /* Initialize NTP */
    bl      ntp_init

    /* Start NTP client */
    ldr     x0, =CPSW_BASE
    ldr     x1, =cpsw_state
    ldr     x2, =ntp_tx_buf
    ldr     x3, =timer_pool
    ldr     x4, =cpsw_send
    bl      ntp_start

    /* Initialize HTTP server */
    bl      http_init
    ldr     x0, =CPSW_BASE
    ldr     x1, =cpsw_state
    ldr     x2, =http_tx_buf
    ldr     x3, =cpsw_send
    bl      http_set_send_ctx

    mov     w0, #0
    b       .Ldone

.Lcpsw_fail:
    ldr     x0, =msg_cpsw_fail
    bl      uart_puts
    mov     w0, #1

.Ldone:
    ldp     x29, x30, [sp], #16
    ret

/*
 * net_loop — Infinite recv/dispatch/send loop
 *
 * Never returns. Called after main succeeds.
 * recv stub always fails, so this just checks timers each iteration.
 */
.global net_loop
net_loop:
    ldr     x0, =CPSW_BASE
    ldr     x1, =cpsw_state
    ldr     x2, =rx_buf
    mov     w3, #ETH_FRAME_MAX
    bl      cpsw_recv
    cbnz    w0, .Lnet_timers        /* recv failed → check timers */

    /* w1 = frame length from cpsw_recv */
    ldr     x0, =rx_buf
    bl      net_recv_one
    cbz     w0, .Lnet_timers

    mov     w3, w0                  /* w3 = reply_len */
    ldr     x0, =CPSW_BASE
    ldr     x1, =cpsw_state
    ldr     x2, =rx_buf
    bl      cpsw_send

.Lnet_timers:
    bl      timer_now
    mov     x1, x0
    ldr     x0, =timer_pool
    bl      timer_check
    bl      http_poll
    b       net_loop

.section .data
.balign 16
cpsw_state:
    .space  CPSW_ST_SIZE

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

.section .rodata
our_mac_addr:   .byte 0x02, 0xBE, 0xEF, 0x00, 0x00, 0x01
msg_hello:      .asciz "Hello from bare-metal BeaglePlay!\r\n"
msg_cpsw_ok:    .asciz "CPSW Ethernet initialized\r\n"
msg_cpsw_fail:  .asciz "CPSW init failed\r\n"
