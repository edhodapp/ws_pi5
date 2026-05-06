/*
 * http_status.S — Dynamic /status page generator
 *
 * Builds an HTML page with runtime stats: uptime, active
 * connections, total requests served.
 */

.include "net.inc"
.include "tcp.inc"
.include "http.inc"

.global http_status_generate
.global http_request_count

.section .text

/*
 * http_status_generate — Build status page HTML into buffer
 *
 * x0: output buffer
 * w1: max buffer size
 *
 * Returns: w0 = bytes written
 * Clobbers: x0-x7, x19-x24 saved/restored
 */
http_status_generate:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* output buf */
    mov     x20, x0                 /* write cursor */

    /* --- Gather stats --- */

    /* Uptime: timer ticks / freq → seconds */
    bl      timer_now
    mov     x21, x0                 /* raw ticks */
    bl      timer_freq
    udiv    x21, x21, x0            /* x21 = uptime_seconds */

    /* Active connections: count TCONN with state >= ESTABLISHED */
    ldr     x0, =tcp_conn_table
    mov     w22, #0                 /* active count */
    mov     w1, #TCP_MAX_CONNS
.Lsg_scan:
    cbz     w1, .Lsg_scan_done
    sub     w1, w1, #1
    ldrb    w2, [x0, #TCONN_STATE]
    cmp     w2, #TCPS_ESTABLISHED
    b.lo    .Lsg_scan_next
    add     w22, w22, #1
.Lsg_scan_next:
    add     x0, x0, #TCONN_SIZE
    b       .Lsg_scan
.Lsg_scan_done:

    /* Request count from global counter */
    ldr     x0, =http_request_count
    ldr     w23, [x0]

    /* --- Build HTML --- */

    /* Copy prefix */
    ldr     x0, =status_prefix
    ldr     w1, =status_prefix_len
    bl      .Lsg_copy

    /* Uptime value */
    mov     x0, x21
    bl      .Lsg_write_decimal

    /* Mid1: "</td></tr>\n<tr><td>Active connections</td><td>" */
    ldr     x0, =status_mid1
    ldr     w1, =status_mid1_len
    bl      .Lsg_copy

    /* Active connections value */
    mov     x0, x22
    bl      .Lsg_write_decimal

    /* Mid2 */
    ldr     x0, =status_mid2
    ldr     w1, =status_mid2_len
    bl      .Lsg_copy

    /* Request count value */
    mov     x0, x23
    bl      .Lsg_write_decimal

    /* --- Diagnostics block: DHCP handler counters + key mdns ctx
     * fields. Plain key=value lines inside a <pre> so a test can
     * grep via curl. Order matches dhcp_count_block_start..end. */
    ldr     x0, =status_diag_prefix
    ldr     w1, =status_diag_prefix_len
    bl      .Lsg_copy

    ldr     x0, =diag_label_dhcp_send_discover
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_send_discover
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_resend_discover
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_resend_discover
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_record_offer
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_record_offer_send_request
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_resend_req_sel
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_resend_request_selecting
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_commit_lease
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_commit_lease_arm_timers
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_send_renew
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_send_request_renew
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_resend_renew
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_resend_request_renew
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_send_rebind
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_send_request_rebind
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_resend_rebind
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_resend_request_rebind
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_dhcp_panic_d
    bl      .Lsg_copy_asciz
    ldr     x0, =dhcp_count_panic_d
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    /* mDNS state + announced IPs in dotted-quad form. */
    ldr     x0, =diag_label_mdns_state
    bl      .Lsg_copy_asciz
    bl      mdns_get_state
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_mdns_announced
    bl      .Lsg_copy_asciz
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    add     x0, x0, #56                     /* MDNSC_ANNOUNCED_IP */
    bl      .Lsg_write_dotted_w_nl

    ldr     x0, =diag_label_mdns_prior
    bl      .Lsg_copy_asciz
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    add     x0, x0, #60                     /* MDNSC_PRIOR_ANNOUNCED_IP */
    bl      .Lsg_write_dotted_w_nl

    ldr     x0, =diag_label_net_our_ip
    bl      .Lsg_copy_asciz
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    bl      .Lsg_write_dotted_w_nl

    /* mDNS context's timer wiring — pool ptr non-null and current
     * armed slot. If TIMER_POOL is 0, _mdns_try_arm and the cb's
     * re-arm both bail silently — state can stick mid-cycle. If
     * TIMER_SLOT is -1, no timer is currently armed. */
    ldr     x0, =diag_label_mdns_timer_pool
    bl      .Lsg_copy_asciz
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    ldr     x0, [x0, #24]                   /* MDNSC_TIMER_POOL */
    bl      .Lsg_write_decimal_w_nl

    ldr     x0, =diag_label_mdns_timer_slot
    bl      .Lsg_copy_asciz
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    ldrsw   x0, [x0, #52]                   /* MDNSC_TIMER_SLOT (s32) */
    bl      .Lsg_write_signed_decimal_w_nl

    /* mdns_timer_cb invocation count — distinguishes "timer never
     * fires" (stuck) from "cb fires but doesn't advance" (climbing
     * while state stays). */
    ldr     x0, =diag_label_mdns_timer_cb_count
    bl      .Lsg_copy_asciz
    adrp    x0, mdns_count_timer_cb
    add     x0, x0, :lo12:mdns_count_timer_cb
    ldr     w0, [x0]
    bl      .Lsg_write_decimal_w_nl

    /* Live state of the timer slot mdns is supposedly armed in:
     * actual callback pointer (0 = inactive) and expiry vs now. If
     * MDNSC_TIMER_SLOT=N but slot[N].callback==0, the slot was
     * cancelled or fired between arm and sample — pinpoints whether
     * the cb is being called at all. */
    ldr     x0, =diag_label_mdns_slot_cb_ptr
    bl      .Lsg_copy_asciz
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    ldrsw   x1, [x0, #52]                   /* MDNSC_TIMER_SLOT */
    ldr     x0, [x0, #24]                   /* MDNSC_TIMER_POOL */
    /* Compute slot[N] address: pool + TPOOL_SLOTS + N*SLOT_SIZE.
     * Skip the read if pool is null (mdns_start hasn't run yet —
     * BSS leaves both POOL=0 and SLOT=0, and slot=0 is in-range so
     * the slot-bounds check below would not catch it) or the slot
     * index is out of bounds (-1 sentinel or >=16). */
    cbz     x0, .Lsg_slot_skip
    cmp     w1, #0
    b.lt    .Lsg_slot_skip
    cmp     w1, #16
    b.ge    .Lsg_slot_skip
    add     x0, x0, #8                      /* +TPOOL_SLOTS */
    mov     w2, #32                         /* SLOT_SIZE */
    madd    x0, x1, x2, x0
    ldr     x0, [x0, #8]                    /* SLOT_CALLBACK */
    bl      .Lsg_write_decimal_w_nl
    b       .Lsg_slot_done
.Lsg_slot_skip:
    mov     w1, #'-'
    strb    w1, [x20], #1
    mov     w1, #'\n'
    strb    w1, [x20], #1
.Lsg_slot_done:

    ldr     x0, =status_diag_suffix
    ldr     w1, =status_diag_suffix_len
    bl      .Lsg_copy

    /* Suffix */
    ldr     x0, =status_suffix
    ldr     w1, =status_suffix_len
    bl      .Lsg_copy

    /* Return bytes written */
    sub     w0, w20, w19

    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* Helper: copy w1 bytes from x0 to x20, advance x20 */
.Lsg_copy:
    cbz     w1, .Lsg_copy_done
    ldrb    w2, [x0], #1
    strb    w2, [x20], #1
    sub     w1, w1, #1
    b       .Lsg_copy
.Lsg_copy_done:
    ret

/* Helper: write unsigned decimal for x0 into x20, advance x20.
 * Handles up to 10 digits (32-bit max 4294967295). */
.Lsg_write_decimal:
    /* Push digits onto stack in reverse, then pop in order */
    mov     x3, sp
    sub     sp, sp, #16            /* space for digits */
    mov     x4, sp                 /* digit buffer start */
    mov     x5, x4                 /* write ptr */
    mov     w6, #10

    /* Special case: 0 */
    cbnz    x0, .Lsg_dec_loop
    mov     w1, #'0'
    strb    w1, [x20], #1
    add     sp, sp, #16
    ret

.Lsg_dec_loop:
    cbz     x0, .Lsg_dec_reverse
    udiv    x1, x0, x6
    msub    w2, w1, w6, w0         /* digit = x0 % 10 */
    add     w2, w2, #'0'
    strb    w2, [x5], #1
    mov     x0, x1
    b       .Lsg_dec_loop

.Lsg_dec_reverse:
    /* Digits are in reverse order at [x4..x5). Copy to x20 in reverse. */
.Lsg_dec_rev:
    cmp     x5, x4
    b.ls    .Lsg_dec_done
    sub     x5, x5, #1
    ldrb    w2, [x5]
    strb    w2, [x20], #1
    b       .Lsg_dec_rev

.Lsg_dec_done:
    add     sp, sp, #16
    ret

/* Helper: copy a NUL-terminated string from x0 to x20, advance x20.
 * Stops at the NUL (which is not written). */
.Lsg_copy_asciz:
    ldrb    w1, [x0], #1
    cbz     w1, .Lsg_asciz_done
    strb    w1, [x20], #1
    b       .Lsg_copy_asciz
.Lsg_asciz_done:
    ret

/* Helper: write decimal of x0 into x20 followed by '\n'. */
.Lsg_write_decimal_w_nl:
    stp     x29, x30, [sp, #-16]!
    bl      .Lsg_write_decimal
    mov     w1, #'\n'
    strb    w1, [x20], #1
    ldp     x29, x30, [sp], #16
    ret

/* Helper: write x0 as a signed decimal followed by '\n'. Treats x0
 * as 64-bit signed so -1 (sentinel for "no slot armed") prints as
 * "-1\n" rather than as a huge unsigned number. */
.Lsg_write_signed_decimal_w_nl:
    stp     x29, x30, [sp, #-16]!
    cmp     x0, #0
    b.ge    .Lsg_swdwn_pos
    mov     w1, #'-'
    strb    w1, [x20], #1
    neg     x0, x0
.Lsg_swdwn_pos:
    bl      .Lsg_write_decimal
    mov     w1, #'\n'
    strb    w1, [x20], #1
    ldp     x29, x30, [sp], #16
    ret

/* Helper: write the 4-byte wire-order IP at [x0] as "a.b.c.d\n". */
.Lsg_write_dotted_w_nl:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    mov     x19, x0                         /* save IP base */
    /* byte 0 */
    ldrb    w0, [x19, #0]
    bl      .Lsg_write_decimal
    mov     w1, #'.'
    strb    w1, [x20], #1
    ldrb    w0, [x19, #1]
    bl      .Lsg_write_decimal
    mov     w1, #'.'
    strb    w1, [x20], #1
    ldrb    w0, [x19, #2]
    bl      .Lsg_write_decimal
    mov     w1, #'.'
    strb    w1, [x20], #1
    ldrb    w0, [x19, #3]
    bl      .Lsg_write_decimal
    mov     w1, #'\n'
    strb    w1, [x20], #1
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/* ===================================================================
 * Status page HTML fragments
 * =================================================================== */
.section .rodata

status_prefix:
    .ascii  "<!DOCTYPE html>\n<html><head><title>Status</title></head>\n"
    .ascii  "<body>\n<h1>ws_pi5 Status</h1>\n"
    .ascii  "<table>\n<tr><td>Uptime (seconds)</td><td>"
status_prefix_end:
.equ status_prefix_len, status_prefix_end - status_prefix

status_mid1:
    .ascii  "</td></tr>\n<tr><td>Active connections</td><td>"
status_mid1_end:
.equ status_mid1_len, status_mid1_end - status_mid1

status_mid2:
    .ascii  "</td></tr>\n<tr><td>Requests served</td><td>"
status_mid2_end:
.equ status_mid2_len, status_mid2_end - status_mid2

status_diag_prefix:
    .ascii  "</td></tr>\n</table>\n<h2>Diagnostics</h2>\n<pre>\n"
status_diag_prefix_end:
.equ status_diag_prefix_len, status_diag_prefix_end - status_diag_prefix

status_diag_suffix:
    .ascii  "</pre>\n"
status_diag_suffix_end:
.equ status_diag_suffix_len, status_diag_suffix_end - status_diag_suffix

/* NUL-terminated label strings. The trailing "= " (no newline) is
 * what each .Lsg_copy_asciz prints; the value-writer adds the
 * decimal/dotted-quad and the newline. */
diag_label_dhcp_send_discover:        .asciz "dhcp_send_discover= "
diag_label_dhcp_resend_discover:      .asciz "dhcp_resend_discover= "
diag_label_dhcp_record_offer:         .asciz "dhcp_record_offer_send_request= "
diag_label_dhcp_resend_req_sel:       .asciz "dhcp_resend_request_selecting= "
diag_label_dhcp_commit_lease:         .asciz "dhcp_commit_lease_arm_timers= "
diag_label_dhcp_send_renew:           .asciz "dhcp_send_request_renew= "
diag_label_dhcp_resend_renew:         .asciz "dhcp_resend_request_renew= "
diag_label_dhcp_send_rebind:          .asciz "dhcp_send_request_rebind= "
diag_label_dhcp_resend_rebind:        .asciz "dhcp_resend_request_rebind= "
diag_label_dhcp_panic_d:              .asciz "dhcp_panic_d= "
diag_label_mdns_state:                .asciz "mdns_state= "
diag_label_mdns_announced:            .asciz "mdns_announced_ip= "
diag_label_mdns_prior:                .asciz "mdns_prior_announced_ip= "
diag_label_net_our_ip:                .asciz "net_our_ip= "
diag_label_mdns_timer_pool:           .asciz "mdns_timer_pool_ptr= "
diag_label_mdns_timer_slot:           .asciz "mdns_timer_slot= "
diag_label_mdns_timer_cb_count:       .asciz "mdns_timer_cb_count= "
diag_label_mdns_slot_cb_ptr:          .asciz "mdns_slot_callback_ptr= "

status_suffix:
    .ascii  "</body></html>\n"
status_suffix_end:
.equ status_suffix_len, status_suffix_end - status_suffix

/* ===================================================================
 * BSS: request counter
 * =================================================================== */
.section .bss
.balign 4
http_request_count:
    .space  4
