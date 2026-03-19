/*
 * ntp.S — SNTP client
 *
 * Builds NTP request frames, parses responses, maintains wall-clock time.
 * Timer-driven: ntp_timer_cb fires periodically to send requests.
 */

.include "net.inc"
.include "ntp.inc"
.include "timer.inc"

.global ntp_init
.global ntp_build_request
.global ntp_handle
.global ntp_time
.global ntp_start
.global ntp_timer_cb
.global ntp_state
.global ntp_send_ctx

.section .text

/*
 * ntp_init — Cache timer frequency in ntp_state
 * Clobbers: x0-x1
 */
ntp_init:
    stp     x29, x30, [sp, #-16]!

    bl      timer_freq
    ldr     x1, =ntp_state
    str     x0, [x1, #NTPS_TIMER_FREQ]

    ldp     x29, x30, [sp], #16
    ret

/*
 * ntp_build_request — Build complete 90-byte NTP request frame
 *
 * x0: buffer pointer (>= 90 bytes)
 * x1: gateway MAC pointer (6 bytes)
 * Returns: w0 = 90 (frame length)
 * Clobbers: x0-x9, x19-x22, x30
 */
ntp_build_request:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* x19 = buf */
    mov     x20, x1                 /* x20 = gw_mac */

    /* 1. Ethernet header via eth_build_hdr(buf, dst_mac, ethertype) */
    mov     x0, x19
    mov     x1, x20
    mov     w2, #ETHERTYPE_IPV4
    bl      eth_build_hdr

    /* 2. IP header (20 bytes at buf+14) */
    add     x21, x19, #ETH_PAYLOAD

    mov     w0, #0x45               /* VER=4, IHL=5 */
    strb    w0, [x21, #IP_VER_IHL]
    strb    wzr, [x21, #IP_DSCP_ECN]

    /* Total length = IP(20) + UDP(8) + NTP(48) = 76 = 0x004C */
    mov     w0, #0x4C00             /* 0x004C big-endian */
    strh    w0, [x21, #IP_TOTLEN]

    strh    wzr, [x21, #IP_ID]
    strh    wzr, [x21, #IP_FLAGS_FRAG]

    mov     w0, #IP_DEFAULT_TTL
    strb    w0, [x21, #IP_TTL]
    mov     w0, #IP_PROTO_UDP
    strb    w0, [x21, #IP_PROTO]
    strh    wzr, [x21, #IP_CHECKSUM]    /* zero before computing */

    /* IP src = net_our_ip */
    ldr     x0, =net_our_ip
    ldr     w1, [x0]
    str     w1, [x21, #IP_SRC]

    /* IP dst = net_ntp_ip */
    ldr     x0, =net_ntp_ip
    ldr     w1, [x0]
    str     w1, [x21, #IP_DST]

    /* IP checksum */
    mov     x0, x21
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x21, #IP_CHECKSUM]

    /* 3. UDP header (8 bytes at buf+34) */
    add     x22, x21, #IP_HDR_MIN

    /* sport = 12345 big-endian = 0x3039 → store 0x3930 LE */
    mov     w0, #NTP_SPORT
    rev16   w0, w0
    strh    w0, [x22, #UDP_SPORT]

    /* dport = 123 big-endian = 0x007B → store 0x7B00 LE */
    mov     w0, #NTP_PORT
    rev16   w0, w0
    strh    w0, [x22, #UDP_DPORT]

    /* UDP length = 8 + 48 = 56 = 0x0038 → store 0x3800 LE */
    mov     w0, #56
    rev16   w0, w0
    strh    w0, [x22, #UDP_LENGTH]

    strh    wzr, [x22, #UDP_CHECKSUM]   /* zero before computing */

    /* 4. NTP payload (48 bytes at buf+42) — zero first, then set flags */
    add     x0, x22, #UDP_HDR_LEN
    /* Zero 48 bytes = 6 doublewords */
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]

    /* Byte 0 = NTP_CLIENT_FLAGS (0x23) */
    mov     w1, #NTP_CLIENT_FLAGS
    strb    w1, [x0, #NTP_FLAGS]

    /* 5. UDP checksum */
    mov     x0, x19
    mov     w1, #56                     /* UDP segment length */
    bl      udp_checksum
    /* RFC 768: if computed == 0, store 0xFFFF */
    cmp     w0, #0
    csinv   w0, w0, wzr, ne
    uxth    w0, w0
    strh    w0, [x22, #UDP_CHECKSUM]

    mov     w0, #NTP_FRAME_LEN

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #48
    ret

/*
 * ntp_handle — Process an NTP response
 *
 * x0: pointer to NTP payload (48 bytes, past UDP header)
 * w1: payload length (UDP payload, i.e. UDP len - 8)
 * x2: current_ticks (CNTPCT_EL0 value)
 * Returns: w0 = 1 (synced) or 0 (ignored)
 * Clobbers: x0-x5
 */
ntp_handle:
    /* Validate length >= 48 */
    cmp     w1, #NTP_PKT_LEN
    b.lt    .Lntp_ignore

    /* Validate mode == 4 (server): flags & 0x07 */
    ldrb    w3, [x0, #NTP_FLAGS]
    and     w3, w3, #0x07
    cmp     w3, #NTP_SERVER_MODE
    b.ne    .Lntp_ignore

    /* Reject Kiss of Death: stratum == 0 */
    ldrb    w3, [x0, #NTP_STRATUM]
    cbz     w3, .Lntp_ignore

    /* Extract TX timestamp seconds (offset 40, 4 bytes big-endian) */
    ldr     w3, [x0, #NTP_TX_TS]
    rev     w3, w3                  /* big-endian → host order */

    /* Convert NTP epoch → Unix epoch: subtract 0x83AA7E80 */
    mov     w4, #NTP_UNIX_OFFSET_LO
    movk    w4, #NTP_UNIX_OFFSET_HI, lsl #16
    sub     w3, w3, w4

    /* Store in ntp_state */
    ldr     x4, =ntp_state
    /* Zero-extend w3 to x3 for 64-bit store */
    mov     x5, x3
    str     x5, [x4, #NTPS_SYNC_SECS]
    str     x2, [x4, #NTPS_SYNC_TICKS]
    mov     w5, #1
    str     w5, [x4, #NTPS_SYNCED]

    mov     w0, #1
    ret

.Lntp_ignore:
    mov     w0, #0
    ret

/*
 * ntp_time — Get current Unix time
 *
 * x0: current_ticks (CNTPCT_EL0 value)
 * Returns: x0 = Unix seconds, or 0 if not synced
 * Clobbers: x0-x4
 */
ntp_time:
    ldr     x1, =ntp_state
    ldr     w2, [x1, #NTPS_SYNCED]
    cbz     w2, .Lntp_time_nosync

    /* elapsed_ticks = current_ticks - sync_ticks */
    ldr     x2, [x1, #NTPS_SYNC_TICKS]
    sub     x0, x0, x2

    /* elapsed_secs = elapsed_ticks / timer_freq */
    ldr     x3, [x1, #NTPS_TIMER_FREQ]
    udiv    x0, x0, x3

    /* wall_time = sync_secs + elapsed_secs */
    ldr     x4, [x1, #NTPS_SYNC_SECS]
    add     x0, x0, x4
    ret

.Lntp_time_nosync:
    mov     x0, #0
    ret

/*
 * ntp_start — Initialize send context and arm first timer
 *
 * x0: dwc2_base
 * x1: ecm_state pointer
 * x2: tx_buf pointer
 * x3: timer_pool pointer
 * Clobbers: x0-x6, x30
 */
ntp_start:
    stp     x29, x30, [sp, #-16]!

    /* Store send context */
    ldr     x4, =ntp_send_ctx
    str     x0, [x4, #NTPC_DWC2_BASE]
    str     x1, [x4, #NTPC_ECM_STATE]
    str     x2, [x4, #NTPC_TX_BUF]
    str     x3, [x4, #NTPC_TIMER_POOL]

    /* Arm first timer: expiry = now (fire immediately on first check) */
    mov     x0, x3                      /* pool */
    bl      timer_now
    mov     x1, x0                      /* expiry = now */
    ldr     x0, [x4, #NTPC_TIMER_POOL]
    ldr     x2, =ntp_timer_cb           /* callback */
    ldr     x3, =ntp_send_ctx           /* context */
    bl      timer_set

    ldp     x29, x30, [sp], #16
    ret

/*
 * ntp_timer_cb — Timer callback: build and send NTP request, re-arm
 *
 * x0: pointer to ntp_send_ctx
 * Clobbers: x0-x9, x19-x24, x30
 */
ntp_timer_cb:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                     /* x19 = &ntp_send_ctx */

    /* Check if gateway MAC is known */
    ldr     x0, =net_gw_mac_valid
    ldr     w0, [x0]
    cbz     w0, .Lntp_rearm             /* no gateway MAC yet, skip send */

    /* Build NTP request */
    ldr     x0, [x19, #NTPC_TX_BUF]
    ldr     x1, =net_gw_mac
    bl      ntp_build_request
    mov     w20, w0                     /* w20 = frame length (90) */

    /* Send: cdc_ecm_send(dwc2_base, ecm_state, tx_buf, frame_len) */
    ldr     x0, [x19, #NTPC_DWC2_BASE]
    ldr     x1, [x19, #NTPC_ECM_STATE]
    ldr     x2, [x19, #NTPC_TX_BUF]
    mov     w3, w20
    bl      cdc_ecm_send

.Lntp_rearm:
    /* Re-arm timer: expiry = now + NTP_POLL_SECS * freq */
    bl      timer_now
    mov     x21, x0                     /* x21 = now */

    ldr     x0, =ntp_state
    ldr     x22, [x0, #NTPS_TIMER_FREQ]  /* x22 = freq */
    mov     x0, #NTP_POLL_SECS
    mul     x0, x0, x22                /* poll_ticks = 64 * freq */
    add     x1, x21, x0               /* expiry = now + poll_ticks */

    ldr     x0, [x19, #NTPC_TIMER_POOL]
    ldr     x2, =ntp_timer_cb
    ldr     x3, =ntp_send_ctx
    bl      timer_set

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #48
    ret

.section .data
.balign 8
ntp_state:
    .space  NTPS_SIZE

.balign 8
ntp_send_ctx:
    .space  NTPC_SIZE
