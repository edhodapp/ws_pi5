/*
 * ip_reasm.S — IP fragment reassembly engine (RFC 791)
 *
 * 4 reassembly slots, each with a 32-byte header, 32-byte bitmap,
 * and 2048-byte data buffer.  Fragments are identified by
 * {src_ip, dst_ip, ip_id, proto}.  A 30-second timer frees stale slots.
 *
 * ip_reasm_input:  accept a fragment, return reassembled frame or 0
 * ip_reasm_init:   zero all slots
 * ip_reasm_set_timer_pool: store timer pool pointer for timeout arming
 * ip_reasm_timeout_cb: timer callback — free a slot
 */

.include "net.inc"
.include "timer.inc"

.global ip_reasm_init
.global ip_reasm_input
.global ip_reasm_set_timer_pool
.global ip_reasm_timeout_cb
.global reasm_slots

.section .text

/*
 * ip_reasm_init — Zero all reassembly slots
 * Clobbers: x0-x2
 */
ip_reasm_init:
    ldr     x0, =reasm_slots
    mov     x1, #(REASM_SLOT_SIZE * REASM_MAX_SLOTS / 8)
.Lri_init_loop:
    cbz     x1, .Lri_init_done
    str     xzr, [x0], #8
    sub     x1, x1, #1
    b       .Lri_init_loop
.Lri_init_done:
    ret

/*
 * ip_reasm_set_timer_pool — Store timer pool pointer
 * x0: timer pool pointer
 * Clobbers: x1
 */
ip_reasm_set_timer_pool:
    ldr     x1, =reasm_timer_pool
    str     x0, [x1]
    ret

/*
 * ip_reasm_timeout_cb — Timer callback: free a reassembly slot
 * x0: pointer to reasm slot
 * Clobbers: x0
 */
ip_reasm_timeout_cb:
    strb    wzr, [x0, #REASM_FLAGS]
    ret

/*
 * ip_reasm_input — Process an IP fragment
 *
 * x0: frame buffer pointer (Ethernet header + IP + fragment payload)
 * w1: frame length
 * Returns: x0 = pointer to reassembled frame (built in-place) or 0
 * Clobbers: x0-x9, x19-x24, x30
 *
 * On completion, overwrites the input frame buffer with the full
 * reassembled datagram (ETH + IP + payload).  The caller must ensure
 * the buffer is at least ETH_FRAME_MAX bytes.
 */
ip_reasm_input:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* x19 = frame */
    mov     w20, w1                 /* w20 = frame_len */

    /* ---- Parse fragment info from IP header ---- */
    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_FLAGS_FRAG)]
    rev16   w0, w0
    uxth    w0, w0
    /* w0 = flags_frag (host order): bit 13 = MF, bits 12-0 = offset */
    ubfx    w21, w0, #13, #1       /* w21 = MF flag */
    and     w22, w0, #0x1FFF
    lsl     w22, w22, #3           /* w22 = frag_off (bytes) */

    ldrh    w0, [x19, #(ETH_PAYLOAD + IP_TOTLEN)]
    rev16   w0, w0
    uxth    w0, w0
    sub     w23, w0, #IP_HDR_MIN   /* w23 = payload_len */

    /* Sanity: payload_len > 0 */
    cmp     w23, #1
    b.lt    .Lri_drop

    /* Bounds: frag_off + payload_len <= REASM_BUF_SIZE */
    add     w0, w22, w23
    mov     w1, #REASM_BUF_SIZE
    cmp     w0, w1
    b.hi    .Lri_drop

    /* ---- Find matching slot or first free slot ---- */
    ldr     w3, [x19, #(ETH_PAYLOAD + IP_SRC)]
    ldr     w4, [x19, #(ETH_PAYLOAD + IP_DST)]
    ldrh    w5, [x19, #(ETH_PAYLOAD + IP_ID)]
    ldrb    w6, [x19, #(ETH_PAYLOAD + IP_PROTO)]

    ldr     x24, =reasm_slots
    mov     w7, #0                  /* slot index */
    mov     x8, #-1                 /* first free slot (-1 = none) */

.Lri_search:
    cmp     w7, #REASM_MAX_SLOTS
    b.hs    .Lri_search_done

    ldrb    w0, [x24, #REASM_FLAGS]
    tbz     w0, #7, .Lri_not_active

    /* Active slot — check key {src_ip, dst_ip, ip_id, proto} */
    ldr     w1, [x24, #REASM_SRC_IP]
    cmp     w1, w3
    b.ne    .Lri_next
    ldr     w1, [x24, #REASM_DST_IP]
    cmp     w1, w4
    b.ne    .Lri_next
    ldrh    w1, [x24, #REASM_IP_ID]
    cmp     w1, w5
    b.ne    .Lri_next
    ldrb    w1, [x24, #REASM_PROTO]
    cmp     w1, w6
    b.ne    .Lri_next

    /* Match found */
    b       .Lri_have_slot

.Lri_not_active:
    /* Remember first free slot */
    cmn     x8, #1
    b.ne    .Lri_next
    mov     x8, x24

.Lri_next:
    add     x24, x24, #REASM_SLOT_SIZE
    add     w7, w7, #1
    b       .Lri_search

.Lri_search_done:
    /* No match — allocate free slot */
    cmn     x8, #1
    b.eq    .Lri_drop               /* no free slots */

    mov     x24, x8

    /* Initialize header */
    str     w3, [x24, #REASM_SRC_IP]
    str     w4, [x24, #REASM_DST_IP]
    strh    w5, [x24, #REASM_IP_ID]
    strb    w6, [x24, #REASM_PROTO]
    mov     w0, #0x80               /* active */
    strb    w0, [x24, #REASM_FLAGS]
    strh    wzr, [x24, #REASM_TOTAL_LEN]
    mov     w0, #0xFF
    strb    w0, [x24, #REASM_TIMER_SLOT]

    /* Zero bitmap (4 doublewords) */
    add     x0, x24, #REASM_BITMAP
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]

    /* Arm timeout timer if pool is available */
    ldr     x0, =reasm_timer_pool
    ldr     x0, [x0]
    cbz     x0, .Lri_have_slot

    /* timer_set(pool, expiry, callback, context) */
    /* expiry = now + REASM_TIMEOUT_SECS * freq */
    stp     x3, x4, [sp, #-32]!    /* save key regs across calls */
    stp     x5, x6, [sp, #16]

    bl      timer_now
    mov     x9, x0                  /* x9 = now */
    bl      timer_freq
    mov     x1, #REASM_TIMEOUT_SECS
    mul     x1, x1, x0             /* timeout_ticks */
    add     x1, x9, x1             /* expiry = now + timeout */

    ldr     x0, =reasm_timer_pool
    ldr     x0, [x0]               /* pool */
    ldr     x2, =ip_reasm_timeout_cb
    mov     x3, x24                 /* context = slot ptr */
    bl      timer_set
    strb    w0, [x24, #REASM_TIMER_SLOT]

    ldp     x5, x6, [sp, #16]
    ldp     x3, x4, [sp], #32

.Lri_have_slot:
    /* x24 = slot, w22 = frag_off, w23 = payload_len, w21 = MF */

    /* ---- Copy payload to slot->data[frag_off] ---- */
    add     x0, x24, #REASM_DATA
    add     x0, x0, w22, uxtw      /* dst = data + frag_off */
    add     x1, x19, #(ETH_PAYLOAD + IP_HDR_MIN)   /* src */
    mov     w2, w23
    cbz     w2, .Lri_copy_done
.Lri_copy:
    sub     w2, w2, #1
    ldrb    w9, [x1, x2]
    strb    w9, [x0, x2]
    cbnz    w2, .Lri_copy
.Lri_copy_done:

    /* ---- Set bitmap bits ---- */
    /* start_bit = frag_off / 8 */
    lsr     w0, w22, #3
    /* end_bit = (frag_off + payload_len - 1) / 8 */
    add     w1, w22, w23
    sub     w1, w1, #1
    lsr     w1, w1, #3
    add     x2, x24, #REASM_BITMAP

.Lri_setbit:
    cmp     w0, w1
    b.hi    .Lri_bits_done
    lsr     w9, w0, #3             /* byte index */
    and     w3, w0, #7             /* bit within byte */
    mov     w4, #1
    lsl     w4, w4, w3
    ldrb    w5, [x2, w9, uxtw]
    orr     w5, w5, w4
    strb    w5, [x2, w9, uxtw]
    add     w0, w0, #1
    b       .Lri_setbit
.Lri_bits_done:

    /* ---- If last fragment (MF==0), record total length ---- */
    cbnz    w21, .Lri_check_complete
    ldrb    w0, [x24, #REASM_FLAGS]
    orr     w0, w0, #1             /* set have_last */
    strb    w0, [x24, #REASM_FLAGS]
    add     w0, w22, w23           /* total_len = frag_off + payload_len */
    strh    w0, [x24, #REASM_TOTAL_LEN]

.Lri_check_complete:
    /* Must have seen last fragment */
    ldrb    w0, [x24, #REASM_FLAGS]
    tbz     w0, #0, .Lri_incomplete

    /* ---- Check bitmap for contiguous coverage ---- */
    ldrh    w0, [x24, #REASM_TOTAL_LEN]
    add     w0, w0, #7
    lsr     w0, w0, #3             /* total_bits = ceil(total_len / 8) */
    add     x2, x24, #REASM_BITMAP

    /* Full bytes: total_bits / 8 */
    lsr     w1, w0, #3
    mov     w3, #0

.Lri_chk_full:
    cmp     w3, w1
    b.hs    .Lri_chk_partial
    ldrb    w4, [x2, w3, uxtw]
    cmp     w4, #0xFF
    b.ne    .Lri_incomplete
    add     w3, w3, #1
    b       .Lri_chk_full

.Lri_chk_partial:
    and     w5, w0, #7
    cbz     w5, .Lri_complete
    ldrb    w4, [x2, w3, uxtw]
    mov     w6, #1
    lsl     w6, w6, w5
    sub     w6, w6, #1             /* mask = (1 << remaining) - 1 */
    and     w4, w4, w6
    cmp     w4, w6
    b.ne    .Lri_incomplete

.Lri_complete:
    /* ---- Reassembled datagram fits in frame buffer? ---- */
    ldrh    w0, [x24, #REASM_TOTAL_LEN]
    add     w0, w0, #(ETH_HDR_LEN + IP_HDR_MIN)
    cmp     w0, #ETH_FRAME_MAX
    b.hi    .Lri_free_drop          /* too large for frame buffer */

    /* ---- Build reassembled frame in-place at x19 ---- */
    /* ETH header is already present from the arriving fragment */

    add     x1, x19, #ETH_PAYLOAD
    mov     w2, #0x45
    strb    w2, [x1, #IP_VER_IHL]
    strb    wzr, [x1, #IP_DSCP_ECN]

    ldrh    w2, [x24, #REASM_TOTAL_LEN]
    add     w2, w2, #IP_HDR_MIN
    rev16   w2, w2
    strh    w2, [x1, #IP_TOTLEN]

    ldrh    w2, [x24, #REASM_IP_ID]
    strh    w2, [x1, #IP_ID]
    strh    wzr, [x1, #IP_FLAGS_FRAG]

    mov     w2, #IP_DEFAULT_TTL
    strb    w2, [x1, #IP_TTL]
    ldrb    w2, [x24, #REASM_PROTO]
    strb    w2, [x1, #IP_PROTO]
    strh    wzr, [x1, #IP_CHECKSUM]

    ldr     w2, [x24, #REASM_SRC_IP]
    str     w2, [x1, #IP_SRC]
    ldr     w2, [x24, #REASM_DST_IP]
    str     w2, [x1, #IP_DST]

    /* Compute IP checksum */
    mov     x0, x1
    mov     w1, #IP_HDR_MIN
    bl      ip_checksum
    strh    w0, [x19, #(ETH_PAYLOAD + IP_CHECKSUM)]

    /* Copy payload from slot buffer to frame */
    ldrh    w2, [x24, #REASM_TOTAL_LEN]
    add     x0, x19, #(ETH_PAYLOAD + IP_HDR_MIN)
    add     x3, x24, #REASM_DATA
    mov     w4, #0
.Lri_outcopy:
    cmp     w4, w2
    b.hs    .Lri_outcopy_done
    ldrb    w5, [x3, w4, uxtw]
    strb    w5, [x0, w4, uxtw]
    add     w4, w4, #1
    b       .Lri_outcopy
.Lri_outcopy_done:

    /* Cancel timer */
    ldrb    w0, [x24, #REASM_TIMER_SLOT]
    cmp     w0, #0xFF
    b.eq    .Lri_no_cancel
    ldr     x1, =reasm_timer_pool
    ldr     x1, [x1]
    cbz     x1, .Lri_no_cancel
    mov     w2, w0                  /* slot index */
    mov     x0, x1                  /* pool */
    mov     w1, w2
    bl      timer_cancel
.Lri_no_cancel:

    /* Free slot */
    strb    wzr, [x24, #REASM_FLAGS]

    /* Return pointer to reassembled frame */
    mov     x0, x19
    b       .Lri_done

.Lri_free_drop:
    strb    wzr, [x24, #REASM_FLAGS]

.Lri_drop:
.Lri_incomplete:
    mov     x0, #0

.Lri_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

.section .bss
.balign 8
reasm_slots:
    .space  REASM_SLOT_SIZE * REASM_MAX_SLOTS

.section .data
.balign 8
reasm_timer_pool:
    .space  8
