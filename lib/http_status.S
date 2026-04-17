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

status_suffix:
    .ascii  "</td></tr>\n</table>\n</body></html>\n"
status_suffix_end:
.equ status_suffix_len, status_suffix_end - status_suffix

/* ===================================================================
 * BSS: request counter
 * =================================================================== */
.section .bss
.balign 4
http_request_count:
    .space  4
