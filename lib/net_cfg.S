/*
 * net_cfg.S — MAC, IP, hostname configuration storage.
 *
 * Per D005, the configurable fields live in .data so the network.conf
 * parser (I4) can populate them at boot. The compile-time values
 * here serve as initial defaults until the parser overwrites them on
 * Pi 4 — and as the permanent values on QEMU, which has no SD card
 * and no network.conf.
 *
 * D005's "Pi 4 defaults are zero" requirement lands in I5, when
 * config_parser is wired into the boot sequence. Until then, Pi 4
 * defaults preserve the working hw_test integration values so the
 * pre-push gate stays green during the redesign's intermediate
 * commits.
 *
 * net_broadcast_mac is universal (FF:FF:FF:FF:FF:FF) and stays in
 * .rodata as a true constant.
 */

.include "net.inc"

.global net_our_mac
.global net_broadcast_mac
.global net_our_ip
.global net_gw_ip
.global net_ntp_ip
.global net_netmask
.global net_hostname
.global net_hostname_len
.global net_gw_mac
.global net_gw_mac_valid
.global net_hw_csum_tx
.global net_dhcp

/* --- Invariant constants (.rodata) --- */
.section .rodata

.balign 4
net_broadcast_mac:
    .byte   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

/* --- Parser-writable storage (.data) --- */
.section .data

/* Locally administered, unicast MAC.
 * Must match the MAC programmed into the network controller.
 * I5 will zero this on Pi 4 once config_parser sets it from either
 * the mailbox factory MAC (D011) or a `mac=` override. */
.balign 4
net_our_mac:
.ifdef PLATFORM_PI4
    .byte   0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE
.else
    .byte   0x02, 0x00, 0x00, 0x00, 0x00, 0x01
.endif

/* IPv4 fields stored as raw wire-format bytes (network byte order).
 * `ldr w` from these labels gives the same value as `ldr w` from a
 * wire buffer, enabling zero-cost comparison without rev.
 *
 * Pi 4 default is 0.0.0.0 so subsystems that read net_our_ip before
 * config_parse / DHCP commits can detect "not yet configured" with
 * a single cbz check (e.g. mdns_start defers its probe arm). config
 * parser sets this for static configs (ip= is required when dhcp=no
 * per D012/D013); DHCP commits set it via h_commit_lease_arm_timers.
 * QEMU has no SD/network.conf, so the 10.0.2.15 default stays. */
.balign 4
net_our_ip:
.ifdef PLATFORM_PI4
    .word   0
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

/* New labels per D005. Netmask is recorded for documentation
 * only — D010 fixed the routing model as always-via-gateway, so
 * the runtime never reads this. Zero default is a reasonable
 * "uninitialized" sentinel; QEMU keeps 255.255.255.0 for symmetry
 * with the dotted-decimal it would receive from a network.conf. */
.balign 4
net_netmask:
.ifdef PLATFORM_PI4
    .word   0
.else
    .byte   0xFF, 0xFF, 0xFF, 0x00     /* 255.255.255.0 (QEMU default) */
.endif

/* Hostname storage: 1..HOSTNAME_MAX_LEN bytes per D006, plus a
 * 4-byte length. The buffer is sized one octet larger than the
 * RFC 1123 max (63) so a future caller that wants C-string
 * semantics has room for a trailing NUL without overrunning. */
.balign 4
net_hostname_len:
    .word   0                           /* 0..63 */

/* 8-byte alignment is load-bearing: lib/config_parser.S's
 * _store_hostname zeroes the buffer with `stp xzr, xzr, [x3, ...]`
 * which requires 8-byte alignment under MMU-on. */
.balign 8
net_hostname:
    .space  64                          /* 63 LDH chars + slack */

/* --- Runtime-managed (existing) --- */

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

/* DHCP-mode flag set by the network.conf parser (dhcp=yes|no, per
 * D017). 0 = static config (use the ip / netmask / gateway fields
 * verbatim, default), 1 = run the DHCP client at boot and let it
 * stamp net_our_ip / net_netmask / net_gw_ip. main.S gates
 * dhcp_start on this flag. */
.balign 4
net_dhcp:
    .word   0
