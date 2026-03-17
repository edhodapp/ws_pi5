/*
 * arp.S — ARP request handler
 *
 * Validates incoming ARP requests for our IP and builds
 * a reply in-place in the frame buffer.
 */

.include "net.inc"

.global arp_handle

.section .text

/*
 * arp_handle — Process an ARP frame, build reply in-place if it's for us
 *
 * x0: frame buffer pointer (Ethernet header + ARP payload)
 * w1: frame length
 * Returns: w0 = 42 (reply built in-place) or 0 (ignored)
 * Clobbers: x0-x9
 */
arp_handle:
    /* Check length >= ARP_FRAME_LEN (42) */
    cmp     w1, #ARP_FRAME_LEN
    b.lt    .Larp_ignore

    mov     x8, x0                 /* x8 = frame base */

    /* x9 = pointer to ARP payload */
    add     x9, x8, #ETH_PAYLOAD

    /* Validate ARP header fields (all big-endian on wire):
     * HTYPE=0x0001, PTYPE=0x0800, HLEN=6, PLEN=4, OPER=0x0001
     * Bytes 0-7: 00 01 08 00 06 04 00 01
     * Load as a single 64-bit value (big-endian) */
    ldr     x0, [x9, #ARP_HTYPE]
    ldr     x1, =0x0001080006040001
    rev     x1, x1                 /* convert to little-endian for comparison */
    cmp     x0, x1
    b.ne    .Larp_ignore

    /* Check TPA == our IP.
     * net_our_ip is stored as wire-format bytes, so ldr w from both
     * gives the same LE representation — direct compare, no rev. */
    ldr     w0, [x9, #ARP_TPA]
    ldr     x1, =net_our_ip
    ldr     w1, [x1]
    cmp     w0, w1
    b.ne    .Larp_ignore

    /* === Build reply in-place === */

    /* Step 1: Copy sender's MAC to Ethernet dst and ARP THA
     * (must happen before we overwrite ARP SHA with our MAC) */
    /* ETH dst ← ARP SHA (sender's MAC): 4 + 2 bytes */
    ldr     w2, [x9, #ARP_SHA]
    str     w2, [x8, #ETH_DST]
    ldrh    w3, [x9, #ARP_SHA + 4]
    strh    w3, [x8, #ETH_DST + 4]

    /* ARP THA ← ARP SHA (sender's MAC): 4 + 2 bytes */
    str     w2, [x9, #ARP_THA]
    strh    w3, [x9, #ARP_THA + 4]

    /* Step 2: Copy sender's IP to ARP TPA
     * (must happen before we overwrite ARP SPA with our IP) */
    ldr     w2, [x9, #ARP_SPA]
    str     w2, [x9, #ARP_TPA]

    /* Step 3: Write our MAC into ETH src and ARP SHA */
    ldr     x4, =net_our_mac
    ldr     w2, [x4]
    ldrh    w3, [x4, #4]

    str     w2, [x8, #ETH_SRC]
    strh    w3, [x8, #ETH_SRC + 4]

    str     w2, [x9, #ARP_SHA]
    strh    w3, [x9, #ARP_SHA + 4]

    /* Step 4: Write our IP into ARP SPA */
    ldr     x4, =net_our_ip
    ldr     w2, [x4]
    str     w2, [x9, #ARP_SPA]

    /* Step 5: Set OPER = reply (0x0002 big-endian) */
    mov     w2, #0x0200            /* 0x0002 byte-swapped to big-endian */
    strh    w2, [x9, #ARP_OPER]

    /* Return frame length */
    mov     w0, #ARP_FRAME_LEN
    ret

.Larp_ignore:
    mov     w0, #0
    ret
