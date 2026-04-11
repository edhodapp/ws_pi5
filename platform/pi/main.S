.include "dwc2.inc"
.include "cdc_ecm.inc"
.include "uart.inc"
.include "gpio.inc"
.include "net.inc"
.include "timer.inc"
.include "ntp.inc"
.include "tcp.inc"
.include "http.inc"
.include "perf.inc"
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

.ifdef PLATFORM_PI4
    /* When chainloaded, UART0 is already configured. Wait 50ms for
     * the CP2102 to finish delivering BOOT to the host before we
     * reinitialize the UART and potentially glitch the TX line. */
    mrs     x0, CNTFRQ_EL0
    lsr     x0, x0, #5             /* freq/32 ≈ 50ms worth of ticks */
    mrs     x1, CNTPCT_EL0
    add     x0, x0, x1
1:  mrs     x1, CNTPCT_EL0
    cmp     x1, x0
    b.lo    1b
.endif

    bl      uart_init

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

    /* Enable HW TX checksum offload — software writes 0 in the L4
     * checksum field, GENET fills it from the TSB's tx_csum_info. */
    ldr     x0, =net_hw_csum_tx
    mov     w1, #1
    str     w1, [x0]

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
    cbnz    w0, .Lnet_idle          /* recv returned no frame → idle path */

    /* w1 = actual frame length. On the drop path (no reply) go
     * straight back to recv — batch drain: while frames are
     * available we do nothing but recv/dispatch/send. Background
     * work only runs when the ring empties (.Lnet_idle).
     *
     * PERF=dispatch: probe ticks around the net_recv_one call. The
     * measurement captures dispatch + whatever handler ran (ARP,
     * IP, ICMP, etc.) as a single aggregate — we don't split the
     * inner branches. x23 holds the start tick across the call;
     * net_recv_one and its callees preserve x19-x28 per AAPCS so
     * x23 survives. The PROBE_* macros don't touch w0/w1, so the
     * return value (reply length) is preserved for the cbz and
     * subsequent send path. */
    ldr     x0, =rx_buf
.ifdef PERF_DISPATCH
    PROBE_ENTRY x23
.endif
    bl      net_recv_one
.ifdef PERF_DISPATCH
    PROBE_EXIT x23, PERF_DISPATCH_TICKS, x2, x3
    PROBE_COUNT_INC PERF_DISPATCH_COUNT, w2, x3
.endif
    cbz     w0, net_loop

    mov     w3, w0                  /* w3 = reply_len */
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =rx_buf
.ifdef PLATFORM_PI4
    bl      genet_send
.else
    bl      cdc_ecm_send
.endif
    b       net_loop

.Lnet_idle:
    /* Ring empty — burst (if any) has drained. Run the background
     * work that's too expensive for the recv hot path: PHY speed
     * poll, expired timers, HTTP connection service. Amortizing
     * these across a whole burst (instead of per-frame) cuts
     * per-frame overhead during sustained traffic. PHY first so a
     * link-speed change takes effect on the NEXT recv attempt. */
.ifdef PLATFORM_PI4
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    bl      genet_phy_check
.endif

    bl      timer_now
    mov     x1, x0
    ldr     x0, =timer_pool
    bl      timer_check
    bl      http_poll
    b       net_loop

.section .data

.ifdef PLATFORM_PI4
.balign 16
.global genet_state                 /* referenced by genet_dump_state */
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
msg_entering_loop: .asciz "Entering net_loop\r\n"
