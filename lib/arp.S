/*
 * arp.S — ARP request/reply handler with proactive cache refresh
 *
 * Handles incoming ARP requests (build reply) and replies (learn MAC).
 * Provides arp_build_request for proactive gateway resolution and
 * timer-driven cache refresh.
 */

.include "net.inc"
.include "timer.inc"

.global arp_handle
.global arp_build_request
.global arp_start
.global arp_timer_cb
.global arp_send_ctx

.section .text

/*
 * arp_handle — Process an ARP frame (request or reply)
 *
 * Requests for our IP: cache gateway MAC, build reply in-place.
 * Replies to our IP from gateway: cache gateway MAC.
 *
 * SPA validation (RFC 826 + security hardening):
 *   - Reject SPA = 0.0.0.0 (RFC 5227 probe)
 *   - Reject SPA = 255.255.255.255 (broadcast)
 *   - Reject SPA in 224.0.0.0/4 (multicast)
 *
 * x0: frame buffer pointer (Ethernet header + ARP payload)
 * w1: frame length
 * Returns: w0 = 42 (reply built in-place) or 0 (ignored/learned)
 * Clobbers: x0-x9
 */
arp_handle:
    /* Check length >= ARP_FRAME_LEN (42) */
    cmp     w1, #ARP_FRAME_LEN
    b.lt    .Larp_ignore

    mov     x8, x0                 /* x8 = frame base */
    add     x9, x8, #ETH_PAYLOAD  /* x9 = ARP payload */

    /* Validate HTYPE(00 01) + PTYPE(08 00) — bytes 0-3 on wire.
     * ldr w on LE reads [00,01,08,00] as 0x00080100. */
    ldr     w0, [x9, #ARP_HTYPE]
    ldr     w1, =0x00080100
    cmp     w0, w1
    b.ne    .Larp_ignore

    /* Validate HLEN(06) + PLEN(04) — bytes 4-5 on wire.
     * ldrh on LE reads [06,04] as 0x0406. */
    ldrh    w0, [x9, #ARP_HLEN]
    cmp     w0, #0x0406
    b.ne    .Larp_ignore

    /* SPA validation: reject invalid source addresses */
    ldr     w0, [x9, #ARP_SPA]
    cbz     w0, .Larp_ignore             /* 0.0.0.0 */
    cmn     w0, #1
    b.eq    .Larp_ignore                 /* 255.255.255.255 */
    ldrb    w1, [x9, #ARP_SPA]
    and     w1, w1, #0xF0
    cmp     w1, #0xE0
    b.eq    .Larp_ignore                 /* 224.0.0.0/4 multicast */

    /* Branch on OPER: [00,01] on wire → LE 0x0100, [00,02] → LE 0x0200 */
    ldrh    w0, [x9, #ARP_OPER]
    cmp     w0, #0x0100
    b.eq    .Larp_request
    cmp     w0, #0x0200
    b.eq    .Larp_reply
    b       .Larp_ignore

/* -------------------------------------------------------------------
 * ARP REQUEST handling: TPA must be our IP → cache, then build reply
 * ------------------------------------------------------------------- */
.Larp_request:
    /* Check TPA == our IP */
    ldr     w0, [x9, #ARP_TPA]
    ldr     x1, =net_our_ip
    ldr     w1, [x1]
    cmp     w0, w1
    b.ne    .Larp_ignore

    /* Cache gateway MAC from SPA/SHA BEFORE reply build overwrites them */
    ldr     x4, =net_gw_ip
    ldr     w2, [x4]
    ldr     w3, [x9, #ARP_SPA]
    cmp     w2, w3
    b.ne    .Larp_req_no_cache

    ldr     x4, =net_gw_mac
    ldr     w2, [x9, #ARP_SHA]
    str     w2, [x4]
    ldrh    w2, [x9, #ARP_SHA + 4]
    strh    w2, [x4, #4]
    ldr     x4, =net_gw_mac_valid
    mov     w2, #1
    str     w2, [x4]

.Larp_req_no_cache:
    /* === Build reply in-place === */

    /* Step 1: Copy sender's MAC to Ethernet dst and ARP THA */
    ldr     w2, [x9, #ARP_SHA]
    str     w2, [x8, #ETH_DST]
    ldrh    w3, [x9, #ARP_SHA + 4]
    strh    w3, [x8, #ETH_DST + 4]

    str     w2, [x9, #ARP_THA]
    strh    w3, [x9, #ARP_THA + 4]

    /* Step 2: Copy sender's IP to ARP TPA */
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

    /* Step 5: Set OPER = reply (0x0002 on wire → LE 0x0200) */
    mov     w2, #0x0200
    strh    w2, [x9, #ARP_OPER]

    mov     w0, #ARP_FRAME_LEN
    ret

/* -------------------------------------------------------------------
 * ARP REPLY handling: learn gateway MAC from sender
 * ------------------------------------------------------------------- */
.Larp_reply:
    /* Only process replies addressed to us */
    ldr     w0, [x9, #ARP_TPA]
    ldr     x1, =net_our_ip
    ldr     w1, [x1]
    cmp     w0, w1
    b.ne    .Larp_ignore

    /* Cache gateway MAC if SPA == gateway IP */
    ldr     x4, =net_gw_ip
    ldr     w2, [x4]
    ldr     w3, [x9, #ARP_SPA]
    cmp     w2, w3
    b.ne    .Larp_ignore

    ldr     x4, =net_gw_mac
    ldr     w2, [x9, #ARP_SHA]
    str     w2, [x4]
    ldrh    w2, [x9, #ARP_SHA + 4]
    strh    w2, [x4, #4]
    ldr     x4, =net_gw_mac_valid
    mov     w2, #1
    str     w2, [x4]

    /* Replies don't generate a response frame */
    mov     w0, #0
    ret

.Larp_ignore:
    mov     w0, #0
    ret

/* ===================================================================
 * arp_build_request — Build a 42-byte ARP request frame
 *
 * Sends unicast if gateway MAC is known (refresh), broadcast otherwise.
 *
 * x0: frame buffer pointer (>= 42 bytes)
 * Returns: w0 = 42 (frame length)
 * Clobbers: x0-x5, x19-x20, x30
 * =================================================================== */
arp_build_request:
    stp     x19, x30, [sp, #-32]!
    str     x20, [sp, #16]

    mov     x19, x0                 /* x19 = buf */

    /* Ethernet header: unicast if MAC known, broadcast otherwise */
    ldr     x1, =net_gw_mac_valid
    ldr     w0, [x1]
    cbz     w0, .Labr_broadcast

    ldr     x1, =net_gw_mac
    b       .Labr_eth_hdr

.Labr_broadcast:
    ldr     x1, =net_broadcast_mac

.Labr_eth_hdr:
    mov     x0, x19
    mov     w2, #ETHERTYPE_ARP
    bl      eth_build_hdr

    /* ARP payload at buf + ETH_PAYLOAD */
    add     x20, x19, #ETH_PAYLOAD

    /* HTYPE=1, PTYPE=0x0800 — wire [00,01,08,00] → LE 0x00080100 */
    ldr     w0, =0x00080100
    str     w0, [x20, #ARP_HTYPE]

    /* HLEN=6, PLEN=4 — wire [06,04] → LE 0x0406 */
    mov     w0, #0x0406
    strh    w0, [x20, #ARP_HLEN]

    /* OPER=request — wire [00,01] → LE 0x0100 */
    mov     w0, #0x0100
    strh    w0, [x20, #ARP_OPER]

    /* SHA = our MAC */
    ldr     x1, =net_our_mac
    ldr     w0, [x1]
    str     w0, [x20, #ARP_SHA]
    ldrh    w0, [x1, #4]
    strh    w0, [x20, #ARP_SHA + 4]

    /* SPA = our IP */
    ldr     x1, =net_our_ip
    ldr     w0, [x1]
    str     w0, [x20, #ARP_SPA]

    /* THA = zeroes (unknown) */
    str     wzr, [x20, #ARP_THA]
    strh    wzr, [x20, #ARP_THA + 4]

    /* TPA = gateway IP */
    ldr     x1, =net_gw_ip
    ldr     w0, [x1]
    str     w0, [x20, #ARP_TPA]

    mov     w0, #ARP_FRAME_LEN

    ldr     x20, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* ===================================================================
 * arp_start — Initialize ARP send context and arm refresh timer
 *
 * Arms timer to fire immediately so gateway MAC is resolved on boot.
 *
 * x0: DWC2 base address
 * x1: ECM state pointer
 * x2: TX buffer pointer (>= 42 bytes)
 * x3: timer pool pointer
 * x4: send function pointer (cdc_ecm_send)
 * Clobbers: x0-x5, x19, x30
 * =================================================================== */
arp_start:
    stp     x19, x30, [sp, #-16]!

    mov     x5, x4                      /* save send_fn */

    ldr     x19, =arp_send_ctx
    str     x0, [x19, #ARPC_DWC2_BASE]
    str     x1, [x19, #ARPC_ECM_STATE]
    str     x2, [x19, #ARPC_TX_BUF]
    str     x3, [x19, #ARPC_TIMER_POOL]
    str     x5, [x19, #ARPC_SEND_FN]

    /* Cache timer frequency */
    bl      timer_freq
    str     x0, [x19, #ARPC_TIMER_FREQ]

    /* Arm first timer: fire immediately */
    ldr     x0, [x19, #ARPC_TIMER_POOL]
    bl      timer_now
    mov     x1, x0                      /* expiry = now */
    ldr     x0, [x19, #ARPC_TIMER_POOL]
    ldr     x2, =arp_timer_cb
    ldr     x3, =arp_send_ctx
    bl      timer_set

    ldp     x19, x30, [sp], #16
    ret

/* ===================================================================
 * arp_timer_cb — Timer callback: send ARP request, re-arm
 *
 * x0: pointer to arp_send_ctx
 * Clobbers: x0-x5, x19-x21, x30
 * =================================================================== */
arp_timer_cb:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]
    mov     x29, sp

    mov     x19, x0                     /* x19 = &arp_send_ctx */

    /* Build ARP request in tx_buf */
    ldr     x0, [x19, #ARPC_TX_BUF]
    bl      arp_build_request
    mov     w21, w0                     /* w21 = frame_len (42) */

    /* Send: send_fn(dwc2_base, ecm_state, tx_buf, frame_len) */
    ldr     x5, [x19, #ARPC_SEND_FN]
    cbz     x5, .Latcb_rearm           /* no send function → skip */
    ldr     x0, [x19, #ARPC_DWC2_BASE]
    ldr     x1, [x19, #ARPC_ECM_STATE]
    ldr     x2, [x19, #ARPC_TX_BUF]
    mov     w3, w21
    blr     x5

.Latcb_rearm:
    /* Re-arm: expiry = now + ARP_REFRESH_SECS * freq */
    bl      timer_now
    mov     x20, x0
    ldr     x1, [x19, #ARPC_TIMER_FREQ]
    mov     x0, #ARP_REFRESH_SECS
    mul     x0, x0, x1
    add     x1, x20, x0                /* expiry */

    ldr     x0, [x19, #ARPC_TIMER_POOL]
    cbz     x0, .Latcb_done            /* no pool → skip */
    ldr     x2, =arp_timer_cb
    ldr     x3, =arp_send_ctx
    bl      timer_set

.Latcb_done:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===================================================================
 * Data
 * =================================================================== */
.section .data
.balign 8
arp_send_ctx:
    .space  ARPC_SIZE
