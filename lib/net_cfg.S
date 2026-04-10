/*
 * net_cfg.S — MAC address and IP address labeled data
 *
 * DHCP migration: move net_our_ip from .rodata to .data,
 * have DHCP client write to it. Rest of stack loads from
 * same label — no API change.
 */

.include "net.inc"

.global net_our_mac
.global net_broadcast_mac
.global net_our_ip
.global net_gw_ip
.global net_ntp_ip
.global net_gw_mac
.global net_gw_mac_valid
.global net_hw_csum_tx

.section .rodata

/* Locally administered, unicast MAC
 * Must match the MAC programmed into the network controller */
net_our_mac:
.ifdef PLATFORM_PI4
    .byte   0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE
.else
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
.endif

net_broadcast_mac:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

/* IP stored as raw wire-format bytes (network byte order).
 * ldr w from this label gives the same value as ldr w from
 * a wire buffer, enabling zero-cost comparison with no rev. */
.balign 4
net_our_ip:
.ifdef PLATFORM_PI4
    .byte   0x0A, 0x00, 0x00, 0x02     /* 10.0.0.2 */
.else
    .byte   0x0A, 0x00, 0x02, 0x0F     /* 10.0.2.15 (QEMU default) */
.endif

.balign 4
net_gw_ip:
.ifdef PLATFORM_PI4
    .byte   0x0A, 0x00, 0x00, 0x01     /* 10.0.0.1 (Chromebook) */
.else
    .byte   0x0A, 0x00, 0x02, 0x02     /* 10.0.2.2 (QEMU default) */
.endif

.balign 4
net_ntp_ip:
    .byte   0xD8, 0xEF, 0x23, 0x00     /* 216.239.35.0 */

.section .data

.balign 4
net_gw_mac:
    .space  6                           /* filled by ARP passive learning */
    .balign 4
net_gw_mac_valid:
    .word   0

/* Hardware TX checksum offload flag.
 *
 * 0 (default) = software L4 checksum in lib/icmp.S, lib/udp.S, lib/tcp.S
 * 1           = hardware L4 checksum insertion by the NIC
 *
 * When set to 1, protocol handlers skip the L4 checksum computation
 * and write 0 (or the pseudo-header sum for TCP/UDP) into the
 * checksum field. The platform driver (e.g. genet_send) fills in
 * the correct value via DMA-time checksum offload.
 *
 * IP header checksum (20 bytes) is always computed in software
 * regardless of this flag — it's ~50 ns and no NIC we target
 * offloads it on the TX side.
 *
 * Set by platform init code (e.g. main.S after genet_init succeeds
 * and TBUF_64B_EN is enabled). QEMU builds leave this at 0. */
.balign 4
net_hw_csum_tx:
    .word   0
