/*
 * eth.S — Ethernet frame utilities
 *
 * All leaf functions — no bl, no callee-save overhead.
 */

.include "net.inc"

.global eth_type
.global eth_build_hdr
.global eth_mac_eq

.section .text

/*
 * eth_type — Extract EtherType from frame buffer
 *
 * x0: frame buffer pointer
 * w1: frame length
 * Returns: w0 = EtherType (host order), or -1 if len < 14
 * Clobbers: x0, x1
 */
eth_type:
    cmp     w1, #ETH_HDR_LEN
    b.lt    .Ltype_short

    ldrh    w0, [x0, #ETH_TYPE]     /* big-endian on wire */
    rev16   w0, w0                  /* byte-swap to host order */
    uxth    w0, w0                  /* zero-extend to 32 bits */
    ret

.Ltype_short:
    mov     w0, #-1
    ret

/*
 * eth_build_hdr — Write 14-byte Ethernet header
 *
 * x0: frame buffer pointer
 * x1: destination MAC pointer (6 bytes)
 * w2: EtherType (host order)
 * Clobbers: x0-x5
 */
eth_build_hdr:
    /* Copy 6-byte dst MAC: 4 + 2 */
    ldr     w3, [x1]
    str     w3, [x0, #ETH_DST]
    ldrh    w3, [x1, #4]
    strh    w3, [x0, #ETH_DST + 4]

    /* Copy 6-byte src MAC from net_our_mac: 4 + 2 */
    ldr     x4, =net_our_mac
    ldr     w3, [x4]
    str     w3, [x0, #ETH_SRC]
    ldrh    w3, [x4, #4]
    strh    w3, [x0, #ETH_SRC + 4]

    /* Write EtherType in big-endian */
    rev16   w2, w2
    strh    w2, [x0, #ETH_TYPE]

    ret

/*
 * eth_mac_eq — Compare two 6-byte MAC addresses
 *
 * x0: pointer to MAC A
 * x1: pointer to MAC B
 * Returns: w0 = 1 if equal, 0 if not
 * Clobbers: x0-x4
 */
eth_mac_eq:
    /* Compare first 4 bytes */
    ldr     w2, [x0]
    ldr     w3, [x1]
    cmp     w2, w3
    b.ne    .Lmac_ne

    /* Compare last 2 bytes */
    ldrh    w2, [x0, #4]
    ldrh    w3, [x1, #4]
    cmp     w2, w3
    b.ne    .Lmac_ne

    mov     w0, #1
    ret

.Lmac_ne:
    mov     w0, #0
    ret
