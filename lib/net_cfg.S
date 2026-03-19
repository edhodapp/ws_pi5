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

.section .rodata

/* Locally administered, unicast MAC */
net_our_mac:
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01

net_broadcast_mac:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

/* IP stored as raw wire-format bytes (network byte order).
 * ldr w from this label gives the same value as ldr w from
 * a wire buffer, enabling zero-cost comparison with no rev. */
.balign 4
net_our_ip:
    .byte   0x0A, 0x00, 0x02, 0x0F     /* 10.0.2.15 */

.balign 4
net_gw_ip:
    .byte   0x0A, 0x00, 0x02, 0x02     /* 10.0.2.2 */

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
