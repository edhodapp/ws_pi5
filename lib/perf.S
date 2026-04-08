/*
 * perf.S — Performance-counter storage + readout handler
 *
 * `perf_counters` (BSS, one 64-byte cache line) is emitted only under
 * PERF_COUNTERS. Default production builds pay zero storage.
 *
 * `perf_handle` is always linked — net_recv_one dispatches the
 * PERF_ETHERTYPE (0x88B6) query frame to it unconditionally. Under
 * PERF_COUNTERS the handler builds a reply containing a snapshot of
 * the counter struct; otherwise it drops the frame silently. That
 * way default builds and PERF builds have the same dispatch code in
 * net_recv_one, and the only behavioural difference is whether the
 * 0x88B6 query actually gets a response.
 *
 * Probe macros and struct offsets live in include/perf.inc. Kernel
 * hot-path probe call sites are wired under PERF=recv / PERF=send /
 * PERF=dispatch (or PERF=all) in genet.S and main.S.
 */

.include "perf.inc"

.section .text

.global perf_handle

/*
 * perf_handle — Handle a PERF_ETHERTYPE (0x88B6) query frame
 *
 * Request frame layout (built by the test driver):
 *   [0..5]   eth_dst   = our MAC
 *   [6..11]  eth_src   = peer MAC
 *   [12..13] etype     = 0x88B6
 *   [14]     cmd       = PERF_CMD_DUMP (0) or PERF_CMD_DUMP_RESET (1)
 *   [15..]   pad       (ignored)
 *
 * Reply frame (built in-place in the same rx_buf):
 *   [0..5]   eth_dst   = peer MAC (from request's eth_src)
 *   [6..11]  eth_src   = our MAC  (from net_our_mac)
 *   [12..13] etype     = 0x88B6
 *   [14..77] payload   = 64-byte copy of perf_counters
 *
 * On PERF_CMD_DUMP_RESET the counters are zeroed AFTER being copied
 * into the reply — the reply frame sees the pre-reset values.
 *
 * x0: frame buffer pointer (same buffer used for reply)
 * w1: frame length
 * Returns:
 *   w0 = 78 on successful reply built in-place (14 + 64)
 *   w0 = 0  on drop (PERF build disabled; frame too short;
 *           unknown command)
 * Clobbers: x0-x7. Leaf function — no prologue/epilogue.
 */
perf_handle:
.ifdef PERF_COUNTERS
    /* Length check: need at least ETH_HDR_LEN (14) + 1 cmd byte */
    cmp     w1, #15
    b.lt    .Lperf_drop

    /* Read command byte at offset 14. Reject anything above
     * PERF_CMD_DUMP_RESET (the highest defined command). */
    ldrb    w2, [x0, #14]
    cmp     w2, #PERF_CMD_DUMP_RESET
    b.hi    .Lperf_drop

    /* ---- Build Ethernet header in place ---- */

    /* Step 1: copy request's src MAC (bytes 6..11) into dst MAC
     * position (bytes 0..5). 4 + 2 bytes. */
    ldr     w4, [x0, #6]
    ldrh    w5, [x0, #10]
    str     w4, [x0, #0]
    strh    w5, [x0, #4]

    /* Step 2: write our MAC into src MAC position (bytes 6..11). */
    ldr     x6, =net_our_mac
    ldr     w4, [x6]
    ldrh    w5, [x6, #4]
    str     w4, [x0, #6]
    strh    w5, [x0, #10]

    /* Step 3: write ethertype 0x88B6 in big-endian at [12..13].
     * Load the host-order constant, byte-swap, store 16-bit.
     * Same pattern as eth_build_hdr in lib/eth.S. */
    ldr     w4, =PERF_ETHERTYPE
    rev16   w4, w4
    strh    w4, [x0, #12]

    /* ---- Copy perf_counters (64 bytes) to payload at offset 14 ----
     * Four 16-byte ldp/stp pairs. The counters struct is
     * 16-byte aligned (.balign 64 in the BSS declaration), so
     * ldp is safe. The payload start (x0 + 14) is NOT 16-aligned,
     * but unaligned stp is legal on AArch64 Normal memory. */
    ldr     x4, =perf_counters
    add     x5, x0, #14

    ldp     x6, x7, [x4, #0]
    stp     x6, x7, [x5, #0]
    ldp     x6, x7, [x4, #16]
    stp     x6, x7, [x5, #16]
    ldp     x6, x7, [x4, #32]
    stp     x6, x7, [x5, #32]
    ldp     x6, x7, [x4, #48]
    stp     x6, x7, [x5, #48]

    /* ---- Optionally reset counters AFTER snapshot ----
     * PERF_CMD_DUMP_RESET → zero the whole struct so the next
     * perf_query gets a fresh per-test window. The reply frame
     * already carries the pre-reset values via the copy above. */
    cmp     w2, #PERF_CMD_DUMP_RESET
    b.ne    .Lperf_no_reset
    stp     xzr, xzr, [x4, #0]
    stp     xzr, xzr, [x4, #16]
    stp     xzr, xzr, [x4, #32]
    stp     xzr, xzr, [x4, #48]
.Lperf_no_reset:

    mov     w0, #78
    ret

.Lperf_drop:
    mov     w0, #0
    ret

.else
    /* PERF not compiled — silently drop any 0x88B6 frames. */
    mov     w0, #0
    ret
.endif


.ifdef PERF_COUNTERS

.section .bss
.balign 64
.global perf_counters
perf_counters:
    .space  PERF_COUNTERS_SIZE

.endif
