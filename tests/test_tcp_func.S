/*
 * test_tcp_func.S — Functional test harness for TCP state machine
 *
 * Loads binary test vectors (.incbin), loops over them, calls tcp_handle,
 * verifies return value, reply flags, and post-state.
 *
 * Strong tcp_isn override ensures deterministic ISN = 0x41424344.
 */

.include "net.inc"
.include "tcp.inc"
.include "timer.inc"

.global test_tcp_functional

.section .text

/* ---------------------------------------------------------------------------
 * tcp_isn — Strong override of weak symbol in tcp.o
 * Returns: w0 = 0x41424344 (deterministic ISN for functional tests)
 * --------------------------------------------------------------------------- */
.global tcp_isn
tcp_isn:
    mov     w0, #0x4344
    movk    w0, #0x4142, lsl #16
    ret

/* ---------------------------------------------------------------------------
 * uart_puthex4 — Print a single hex nibble (0-F)
 * w0: value (low 4 bits used)
 * Clobbers: x0-x1, x30
 * --------------------------------------------------------------------------- */
uart_puthex4:
    and     w0, w0, #0xF
    cmp     w0, #10
    b.lt    .Lph4_digit
    add     w0, w0, #('A' - 10)
    b       uart_putc
.Lph4_digit:
    add     w0, w0, #'0'
    b       uart_putc

/* ---------------------------------------------------------------------------
 * uart_puthex16 — Print 4-digit hex (e.g., "004B")
 * w0: 16-bit value
 * Clobbers: x0-x1, x19, x30
 * --------------------------------------------------------------------------- */
uart_puthex16:
    stp     x19, x30, [sp, #-16]!
    mov     w19, w0

    lsr     w0, w19, #12
    bl      uart_puthex4
    lsr     w0, w19, #8
    bl      uart_puthex4
    lsr     w0, w19, #4
    bl      uart_puthex4
    mov     w0, w19
    bl      uart_puthex4

    ldp     x19, x30, [sp], #16
    ret

/* ---------------------------------------------------------------------------
 * uart_puthex8 — Print 2-digit hex (e.g., "0A")
 * w0: 8-bit value
 * Clobbers: x0-x1, x19, x30
 * --------------------------------------------------------------------------- */
uart_puthex8:
    stp     x19, x30, [sp, #-16]!
    mov     w19, w0

    lsr     w0, w19, #4
    bl      uart_puthex4
    mov     w0, w19
    bl      uart_puthex4

    ldp     x19, x30, [sp], #16
    ret

/* ---------------------------------------------------------------------------
 * Binary entry layout (192 bytes):
 *   [0..1]     u16 LE  frame_len
 *   [2]        u8      expected_ret (0 or 54)
 *   [3]        u8      expected_post_state (TCPS_*)
 *   [4]        u8      expected_reply_flags
 *   [5]        u8      conn_state_code (TCPS_* to pre-seed)
 *   [6]        u8      port_match_code (0=exact, 1=listen_only, 2=no_match)
 *   [7]        pad
 *   [8..11]    u32 LE  pre_snd_nxt
 *   [12..15]   u32 LE  pre_rcv_nxt
 *   [16..17]   u16 LE  pre_lport (NBO value)
 *   [18..19]   u16 LE  pre_rport (NBO value)
 *   [20..23]   u32 LE  pre_rip (NBO value)
 *   [24..27]   u32 LE  pre_snd_una
 *   [28..31]   padding
 *   [32..159]  frame_data (128 bytes)
 *   [160..163] u32 LE  expected_reply_seq
 *   [164..167] u32 LE  expected_reply_ack
 *   [168..171] u32 LE  expected_post_rcv_nxt
 *   [172..173] u16 LE  expected_post_rxlen
 *   [174..175] pad
 *   [176..179] u32 LE  expected_post_snd_una
 *   [180..191] pad (12 bytes)
 * --------------------------------------------------------------------------- */
.equ ENT_FRAME_LEN,       0
.equ ENT_EXPECTED_RET,     2
.equ ENT_EXPECTED_STATE,   3
.equ ENT_EXPECTED_FLAGS,   4
.equ ENT_CONN_STATE,       5
.equ ENT_PORT_MATCH,       6
.equ ENT_PRE_SND_NXT,      8
.equ ENT_PRE_RCV_NXT,      12
.equ ENT_PRE_LPORT,        16
.equ ENT_PRE_RPORT,        18
.equ ENT_PRE_RIP,          20
.equ ENT_PRE_SND_UNA,      24
.equ ENT_FRAME_DATA,       32
.equ ENT_REPLY_SEQ,        160
.equ ENT_REPLY_ACK,        164
.equ ENT_POST_RCV_NXT,     168
.equ ENT_POST_RXLEN,       172
.equ ENT_POST_SND_UNA,     176
.equ ENT_SIZE,             192

/* ---------------------------------------------------------------------------
 * test_tcp_functional — Main functional test loop
 *
 * Register allocation:
 *   x19: table base (after 16-byte header)
 *   w20: entry count (N)
 *   w21: loop index (i)
 *   x22: current entry pointer
 *   x23: scratch buffer address
 * --------------------------------------------------------------------------- */
test_tcp_functional:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    /* Load table header */
    ldr     x19, =tcp_func_table
    ldr     w20, [x19]              /* entry count */
    add     x19, x19, #16          /* skip header, point to first entry */
    mov     w21, #0                 /* i = 0 */
    ldr     x23, =tcp_func_scratch

.Lfunc_loop:
    cmp     w21, w20
    b.ge    .Lfunc_done

    /* x22 = &table[i] */
    mov     w0, #ENT_SIZE
    umull   x22, w21, w0
    add     x22, x22, x19

    /* --- 1. tcp_init() + timer pool setup --- */
    bl      tcp_init
    mov     w0, #80
    bl      tcp_listen
    ldr     x0, =func_timer_pool
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init
    ldr     x0, =func_timer_pool
    bl      tcp_set_timer_pool

    /* --- 2. Pre-seed slot 1 if port_match == exact (code 0) --- */
    ldrb    w0, [x22, #ENT_PORT_MATCH]
    cbnz    w0, .Lfunc_no_preseed

    /* Pre-seed slot 1 */
    ldr     x0, =tcp_conn_table
    add     x0, x0, #TCONN_SIZE    /* slot 1 */

    ldrb    w1, [x22, #ENT_CONN_STATE]
    strb    w1, [x0, #TCONN_STATE]

    ldrh    w1, [x22, #ENT_PRE_LPORT]
    strh    w1, [x0, #TCONN_LPORT]

    ldrh    w1, [x22, #ENT_PRE_RPORT]
    strh    w1, [x0, #TCONN_RPORT]

    ldr     w1, [x22, #ENT_PRE_RIP]
    str     w1, [x0, #TCONN_RIP]

    ldr     w1, [x22, #ENT_PRE_SND_UNA]
    str     w1, [x0, #TCONN_SND_UNA]

    ldr     w1, [x22, #ENT_PRE_SND_NXT]
    str     w1, [x0, #TCONN_SND_NXT]

    ldr     w1, [x22, #ENT_PRE_RCV_NXT]
    str     w1, [x0, #TCONN_RCV_NXT]

    /* Initialize retransmit state (no pending retransmit) */
    mov     w1, #-1
    str     w1, [x0, #TCONN_TIMER_SLOT]

.Lfunc_no_preseed:

    /* --- 3. Copy frame data to scratch buffer --- */
    add     x0, x22, #ENT_FRAME_DATA   /* src */
    mov     x1, x23                     /* dst = scratch */
    mov     w2, #128
.Lfunc_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    w2, w2, #1
    b.ne    .Lfunc_copy

    /* --- 4. Call tcp_handle(scratch, frame_len) --- */
    mov     x0, x23
    ldrh    w1, [x22, #ENT_FRAME_LEN]
    bl      tcp_handle
    /* w0 = return value (0, 54, or 58 for SYN-ACK with MSS) */

    /* --- 5. Verify return value (direct comparison: 0 or 54) --- */
    ldrb    w1, [x22, #ENT_EXPECTED_RET]
    cmp     w0, w1
    b.ne    .Lfunc_fail
    cbz     w0, .Lfunc_check_state      /* drop → skip reply checks */

    /* --- 5a. Verify reply flags --- */
    ldrb    w2, [x23, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_FLAGS)]
    ldrb    w3, [x22, #ENT_EXPECTED_FLAGS]
    cmp     w2, w3
    b.ne    .Lfunc_fail

    /* --- 5b. Verify reply SEQ and ACK --- */
    ldr     w2, [x23, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_SEQ)]
    ldr     w3, [x22, #ENT_REPLY_SEQ]
    cmp     w2, w3
    b.ne    .Lfunc_fail
    ldr     w2, [x23, #(ETH_PAYLOAD + IP_HDR_MIN + TCP_ACK)]
    ldr     w3, [x22, #ENT_REPLY_ACK]
    cmp     w2, w3
    b.ne    .Lfunc_fail

.Lfunc_check_state:
    /* --- 6. Verify post-state --- */
    ldrb    w0, [x22, #ENT_PORT_MATCH]
    cmp     w0, #2
    b.eq    .Lfunc_pass                 /* no_match: skip state+data */
    cmp     w0, #1
    b.eq    .Lfunc_check_listen_state   /* listen_only */

    /* --- exact: check slot 1 state --- */
    ldr     x0, =tcp_conn_table
    add     x0, x0, #TCONN_SIZE        /* slot 1 */
    ldrb    w1, [x0, #TCONN_STATE]
    ldrb    w2, [x22, #ENT_EXPECTED_STATE]
    cmp     w1, w2
    b.ne    .Lfunc_fail

    /* --- 7. Data-path assertions (exact-match only) --- */
    ldr     x0, =tcp_conn_table
    add     x0, x0, #TCONN_SIZE        /* slot 1 */
    ldr     w1, [x0, #TCONN_RCV_NXT]
    ldr     w2, [x22, #ENT_POST_RCV_NXT]
    cmp     w1, w2
    b.ne    .Lfunc_fail
    ldrh    w1, [x0, #TCONN_RXLEN]
    ldrh    w2, [x22, #ENT_POST_RXLEN]
    cmp     w1, w2
    b.ne    .Lfunc_fail
    ldr     w1, [x0, #TCONN_SND_UNA]
    ldr     w2, [x22, #ENT_POST_SND_UNA]
    cmp     w1, w2
    b.ne    .Lfunc_fail
    b       .Lfunc_pass

.Lfunc_check_listen_state:
    ldrb    w1, [x22, #ENT_EXPECTED_STATE]
    cmp     w1, #TCPS_SYN_RCVD
    b.ne    .Lfunc_check_listen_simple

    /* SYN_RCVD: verify slot 0 preserved as LISTEN */
    ldr     x0, =tcp_conn_table
    ldrb    w1, [x0, #TCONN_STATE]
    cmp     w1, #TCPS_LISTEN
    b.ne    .Lfunc_fail

    /* Scan table for any SYN_RCVD slot */
    ldr     x0, =tcp_conn_table
    mov     w2, #TCP_MAX_CONNS
.Lfunc_scan_synrcvd:
    cbz     w2, .Lfunc_fail             /* no SYN_RCVD found */
    sub     w2, w2, #1
    ldrb    w3, [x0, #TCONN_STATE]
    cmp     w3, #TCPS_SYN_RCVD
    b.eq    .Lfunc_pass
    add     x0, x0, #TCONN_SIZE
    b       .Lfunc_scan_synrcvd

.Lfunc_check_listen_simple:
    /* Non-SYN_RCVD: check slot 0 state == expected (always LISTEN) */
    ldr     x0, =tcp_conn_table
    ldrb    w1, [x0, #TCONN_STATE]
    ldrb    w2, [x22, #ENT_EXPECTED_STATE]
    cmp     w1, w2
    b.ne    .Lfunc_fail

.Lfunc_pass:
    /* Print "PASS: func_XXXX" */
    ldr     x0, =msg_func_pass
    bl      uart_puts
    mov     w0, w21
    bl      uart_puthex16
    ldr     x0, =msg_newline_f
    bl      uart_puts

    /* Increment test_count */
    ldr     x0, =test_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    b       .Lfunc_next

.Lfunc_fail:
    /* Print "FAIL: func_XXXX" */
    ldr     x0, =msg_func_fail
    bl      uart_puts
    mov     w0, w21
    bl      uart_puthex16
    ldr     x0, =msg_newline_f
    bl      uart_puts

    /* Increment test_count and fail_count */
    ldr     x0, =test_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    ldr     x0, =fail_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

.Lfunc_next:
    add     w21, w21, #1
    b       .Lfunc_loop

.Lfunc_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/* --- Data sections --- */

.section .rodata
.balign 4
tcp_func_table:
    .incbin "build/tcp_vectors.bin"

msg_func_pass:   .asciz "PASS: func_"
msg_func_fail:   .asciz "FAIL: func_"
msg_newline_f:   .asciz "\r\n"

.section .data
.balign 8
func_timer_pool:
    .space  TPOOL_DEFAULT_SIZE

.section .bss
.balign 16
tcp_func_scratch:
    .space  256
