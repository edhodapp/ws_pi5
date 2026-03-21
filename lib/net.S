/*
 * net.S — Network receive dispatch
 *
 * net_recv_one: dispatch a single Ethernet frame by EtherType
 */

.include "net.inc"

.global net_recv_one

.section .text

/*
 * net_recv_one — Dispatch one Ethernet frame
 *
 * x0: frame buffer pointer
 * w1: frame length
 * Returns: w0 = reply length or 0 (dropped)
 * Clobbers: x0-x5, x19-x20, x30
 */
net_recv_one:
    stp     x19, x30, [sp, #-32]!
    str     x20, [sp, #16]

    mov     x19, x0                 /* x19 = frame */
    mov     w20, w1                 /* w20 = frame_len */

    /* Need at least ETH_HDR_LEN to read destination MAC */
    cmp     w20, #ETH_HDR_LEN
    b.lt    .Lnr_drop

    /* Filter: destination MAC must be ours or broadcast */
    /* x0 = frame pointer (ETH_DST at offset 0) */
    ldr     x1, =net_our_mac
    bl      eth_mac_eq
    cbnz    w0, .Lnr_mac_ok

    mov     x0, x19
    ldr     x1, =net_broadcast_mac
    bl      eth_mac_eq
    cbz     w0, .Lnr_drop

.Lnr_mac_ok:
    /* Get EtherType (returns -1 if invalid) */
    mov     x0, x19
    mov     w1, w20
    bl      eth_type
    /* w0 = EtherType or -1 */

    cmp     w0, #ETHERTYPE_ARP
    b.eq    .Lnr_arp

    cmp     w0, #ETHERTYPE_IPV4
    b.eq    .Lnr_ipv4

.Lnr_drop:
    mov     w0, #0
    b       .Lnr_done

.Lnr_arp:
    mov     x0, x19
    mov     w1, w20
    bl      arp_handle
    b       .Lnr_done

.Lnr_ipv4:
    mov     x0, x19
    mov     w1, w20
    bl      ip_handle

.Lnr_done:
    ldr     x20, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret
