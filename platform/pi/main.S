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
.include "platform.inc"
.include "sys_watchdog.inc"
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

    /* Dump first 16 bytes at INITRAMFS_ADDR so we can see whether
     * the firmware (or hw_send.py --network-conf in chainloader mode)
     * actually loaded network.conf. If we see "# WSPI5CFG" the bytes
     * arrived; if zeros or 0xff garbage, the SD's initramfs directive
     * isn't taking or the UART push didn't include --network-conf.
     * Permanent infrastructure: this readout was load-bearing during
     * dual-config rig debugging (D019) and stays as a first-line
     * diagnostic for any "kernel boots but config seems wrong" report. */
    ldr     x0, =msg_initramfs_probe
    bl      uart_puts
    ldr     x19, =INITRAMFS_ADDR
    mov     w20, #16
.Lprobe_loop:
    cbz     w20, .Lprobe_done
    ldrb    w0, [x19], #1
    bl      uart_puthex_byte
    mov     w0, #' '
    bl      uart_putc
    sub     w20, w20, #1
    b       .Lprobe_loop
.Lprobe_done:
    mov     w0, #'\r'
    bl      uart_putc
    mov     w0, #'\n'
    bl      uart_putc

    /* Parse user-editable network.conf from initramfs (D004).
     * The firmware loads the file to INITRAMFS_ADDR per config.txt's
     * `initramfs network.conf $INITRAMFS_ADDR` directive (mk_sd.sh
     * keeps the kernel and the SD bundle in sync via the Makefile's
     * print-INITRAMFS_ADDR target).
     *
     * Length: hardcoded at 4 KB. network.conf is < 1 KB in practice,
     * and config_parse handles EOF mid-stream cleanly per the I12
     * regression-guard tests. A follow-up commit will replace this
     * with a DTB walker that reads /chosen/linux,initrd-{start,end}
     * for the exact blob size.
     *
     * Failure → panic_n (Tier-1 user-fixable "Network conf invalid",
     * Morse "N" `─·`) per docs/PANIC_PATTERNS.md. The user pulls
     * the SD, fixes network.conf, reflashes. */
    ldr     x0, =INITRAMFS_ADDR
    mov     w1, #4096
    bl      config_parse
    cbnz    w0, .Lcfg_fail

    ldr     x0, =msg_cfg_ok
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

.ifdef PLATFORM_PI4
    /* Arm the BCM2711 PM watchdog with a generous boot-grace
     * timeout (60 s). At the end of main() — once HTTP is up and
     * the kernel has demonstrated steady state — sys_watchdog_set_timeout
     * tightens this down to 10 s for fast runtime detection.
     *
     * Arming early (here, right after timer_pool_init) lets the
     * watchdog catch boot-time wedges that would otherwise sit
     * silent forever: PHY autoneg without timeout, USB enum hang,
     * DHCP DISCOVER spin, exception-loop on a corrupted page table.
     * 60 s is long enough that legitimate slow-boot operations
     * (PHY ~5 s, DHCP ~5 s, even worst-case stacking) don't false-
     * trip; a kernel/hardware wedge produces a 60 s reset cycle
     * which is loud and observable rather than silent and opaque.
     *
     * panic_X functions (lib/panic.S) feed the watchdog from
     * inside their blink loop via PANIC_PET_WATCHDOG, so user-
     * fixable halts (network.conf invalid, gateway unreachable,
     * etc.) keep their LED Morse pattern visible indefinitely
     * while the watchdog stays armed as a backstop against the
     * blink loop itself wedging. */
    ldr     x0, =sys_watchdog_state
    ldr     x1, =(PERIPH_BASE + PM_OFFSET)
    str     x1, [x0, #SWD_PM_BASE]

    /* SWD_BOOT_TIMEOUT_UNITS = 60 s × 65536 = 0x3C0000. */
    mov     w1, #0
    movk    w1, #0x3C, lsl #16          /* 0x003C0000 */
    str     w1, [x0, #SWD_TIMEOUT_UNITS]

    ldr     x1, =timer_pool
    str     x1, [x0, #SWD_TIMER_POOL]

    /* PET_PERIOD = 2 × timer_freq ticks. */
    bl      timer_freq
    lsl     x1, x0, #1
    ldr     x0, =sys_watchdog_state
    str     x1, [x0, #SWD_PET_PERIOD]

    /* Capture PM_RSTS BEFORE arming so the boot rsts reflects the
     * previous reset's reason, not anything we did this boot. */
    bl      sys_watchdog_capture_rsts

    ldr     x0, =sys_watchdog_state
    bl      sys_watchdog_arm
.endif

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

    /* Per D017: if network.conf set dhcp=yes, run the DHCP client.
     * dhcp_start fires E_START into the FSA, which sends DISCOVER
     * via NET_SEND_SYM and arms a retransmit timer. ARP for the
     * gateway runs in parallel via arp_start above; net_gw_ip will
     * be stamped by h_commit_lease_arm_timers on ACK, so the
     * already-armed gateway ARP is harmless until then. */
    ldr     x0, =net_dhcp
    ldr     w0, [x0]
    cbz     w0, .Lskip_dhcp
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =dhcp_tx_buf
    ldr     x3, =timer_pool
    ldr     x4, =NET_SEND_SYM
    bl      dhcp_start
.Lskip_dhcp:

    /* Initialize NTP (cache timer frequency) */
    bl      ntp_init

    /* Start NTP client (arm first timer) */
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =ntp_tx_buf
    ldr     x3, =timer_pool
    ldr     x4, =NET_SEND_SYM
    bl      ntp_start

    /* Start mDNS responder (per D008). Probes for hostname.local
     * conflicts then announces ownership. mdns_start refuses to
     * arm if net_hostname_len == 0 (which is the default until a
     * future config-parse wiring populates it from network.conf),
     * so this call is safe in builds that ship without a hostname. */
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =mdns_tx_buf
    ldr     x3, =timer_pool
    ldr     x4, =NET_SEND_SYM
    bl      mdns_start

    /* Initialize HTTP server */
    bl      http_init
    ldr     x0, =NET_BASE_SYM
    ldr     x1, =NET_STATE_SYM
    ldr     x2, =http_tx_buf
    ldr     x3, =NET_SEND_SYM
    bl      http_set_send_ctx

.ifdef PLATFORM_PI4
    /* Tighten the PM watchdog timeout from the boot-grace value
     * (60 s, set when the watchdog was armed early in main) down
     * to the runtime value (10 s). The kernel has reached steady
     * state — DHCP/static IP up, timers running, TCP listening,
     * HTTP responding — so post-boot wedges should be detected
     * fast (~10 s) rather than tolerating the boot-grace budget
     * for the rest of the device's life.
     *
     * DEPENDS ON the early-arm block earlier in main() (look for
     * the matching .ifdef PLATFORM_PI4 right after timer_pool_init
     * around line ~153). If that block is removed or moved after
     * this one, sys_watchdog_set_timeout's cbz-PM_BASE guard will
     * silently no-op the MMIO write here and the watchdog will
     * stay at 60 s for the device's entire lifetime — a partial
     * functional regression with zero crash signal. The cbz guard
     * exists for pre-arm panic safety, not for skipping the
     * tighten. Keep the early-arm block before this one. */
    ldr     x0, =sys_watchdog_state
    mov     w1, #0
    movk    w1, #0xA, lsl #16           /* 10 s × 65536 = 0xA0000 */
    bl      sys_watchdog_set_timeout
.endif

    mov     w0, #0
    b       .Ldone

.Lnet_fail:
    ldr     x0, =msg_net_fail
    bl      uart_puts
    mov     w0, #1
    b       .Ldone

.ifdef PLATFORM_PI4
.Lcfg_fail:
    /* w0 from config_parse holds the error code (1..8 per D012).
     * Print "rc=NN\r\n" then halt with panic_n — Tier-1 user-fixable
     * "Network conf invalid" per docs/PANIC_PATTERNS.md. The earlier
     * panic_k call was a misclassification: K is "kernel panic /
     * exception vector / assert," but a config-parse rc!=0 is
     * legitimately a user-edit failure, which is exactly what
     * pattern N exists for. Saves the user from guessing whether
     * it was magic / line / IP / hostname. */
    mov     w19, w0                /* save rc */
    ldr     x0, =msg_cfg_fail
    bl      uart_puts
    ldr     x0, =msg_cfg_rc
    bl      uart_puts
    mov     w0, w19
    bl      uart_puthex_byte
    mov     w0, #'\r'
    bl      uart_putc
    mov     w0, #'\n'
    bl      uart_putc
    bl      panic_n                /* never returns */
.endif

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
    bl      http_update_date
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

/* mDNS frame max: ETH(14) + IP(20) + UDP(8) + payload. Worst-case
 * announce payload at hostname_len=63 is 34 + 63 = 97; total = 139.
 * Round up to 256 for alignment / future TXT/SRV growth. */
.balign 16
mdns_tx_buf:
    .space  256

/* DHCP frame max: ETH(14) + IP(20) + UDP(8) + payload(261 for
 * REQUEST-SELECTING) = 303. Round to 384 for alignment. */
.balign 16
dhcp_tx_buf:
    .space  384

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
msg_cfg_ok:     .asciz "network.conf parsed\r\n"
msg_cfg_fail:   .asciz "network.conf parse failed — check SD\r\n"
msg_cfg_rc:     .asciz "config_parse rc=0x"
msg_initramfs_probe: .asciz "INITRAMFS[0..16]: "
.endif
msg_net_fail:   .asciz "Network bring-up failed\r\n"
msg_entering_loop: .asciz "Entering net_loop\r\n"
