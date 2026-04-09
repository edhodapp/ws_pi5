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
 *   [14]     cmd       = PERF_CMD_DUMP (0), PERF_CMD_DUMP_RESET (1),
 *                        or PERF_CMD_DUMP_REGS (2)
 *   [15..]   pad       (ignored)
 *
 * Reply frame (built in-place in the same rx_buf):
 *   [0..5]   eth_dst   = peer MAC (from request's eth_src)
 *   [6..11]  eth_src   = our MAC  (from net_our_mac)
 *   [12..13] etype     = 0x88B6
 *   [14..77] payload   = 64-byte snapshot (see below)
 *
 * Payload shape depends on cmd:
 *   cmd 0/1: copy of perf_counters (cycle counters + event counts)
 *            cmd 1 also zeros the source after snapshot.
 *   cmd 2:   GENET register + driver-state snapshot via
 *            genet_dump_state. See platform/pi/drivers/genet.S
 *            for the exact layout — it is NOT the same shape as
 *            the perf_counters struct.
 *
 * Under PERF_COUNTERS undef, cmd 0/1 drop silently (no counter
 * struct to read). cmd 2 still works because genet_dump_state is
 * platform code, not instrumentation. We keep the whole handler
 * behind PERF_COUNTERS for now so default builds have zero
 * overhead on the 0x88B6 dispatch path.
 *
 * x0: frame buffer pointer (same buffer used for reply)
 * w1: frame length
 * Returns:
 *   w0 = 78 on successful reply built in-place (14 + 64)
 *   w0 = 0  on drop (PERF build disabled; frame too short;
 *           unknown command)
 * Clobbers: x0-x7, x30. Saves x30 because cmd 2 does a bl.
 */
perf_handle:
.ifdef PERF_COUNTERS
    stp     x29, x30, [sp, #-16]!   /* prologue: save link reg for bl */
    mov     x29, sp

    /* Length check: need at least ETH_HDR_LEN (14) + 1 cmd byte */
    cmp     w1, #15
    b.lt    .Lperf_drop

    /* Read command byte at offset 14. Reject anything above the
     * highest defined command for this platform. PERF_CMD_DUMP_REGS
     * is only available on Pi 4 because the register dump it maps
     * to touches GENET hardware; non-Pi-4 builds cap at
     * PERF_CMD_DUMP_RESET and silently drop cmd 2. */
    ldrb    w2, [x0, #14]
.ifdef PLATFORM_PI4
    cmp     w2, #PERF_CMD_DUMP_REGS
.else
    cmp     w2, #PERF_CMD_DUMP_RESET
.endif
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

    /* ---- Branch on cmd to fill the 64-byte payload ---- */
.ifdef PLATFORM_PI4
    cmp     w2, #PERF_CMD_DUMP_REGS
    b.eq    .Lperf_regs
.endif

    /* Cmd 0 or 1: copy perf_counters (64 bytes) to payload at
     * offset 14. Four 16-byte ldp/stp pairs. */
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

    /* PERF_CMD_DUMP_RESET → zero the source struct AFTER the
     * copy so the next perf_query(reset=True) gets a fresh
     * per-test window. Reply frame already has the pre-reset
     * values from the copy above. */
    cmp     w2, #PERF_CMD_DUMP_RESET
    b.ne    .Lperf_ret
    stp     xzr, xzr, [x4, #0]
    stp     xzr, xzr, [x4, #16]
    stp     xzr, xzr, [x4, #32]
    stp     xzr, xzr, [x4, #48]
    b       .Lperf_ret

.ifdef PLATFORM_PI4
.Lperf_regs:
    /* Cmd 2: GENET register + driver-state snapshot.
     * genet_dump_state takes x0 = destination buffer and writes
     * 64 bytes. We need to point it at the reply payload
     * (frame + 14) and then restore x0 to the frame base afterwards
     * because the return value needs to be the reply length.
     *
     * Save frame base on the stack across the call. */
    stp     x0, xzr, [sp, #-16]!
    add     x0, x0, #14
    bl      genet_dump_state
    ldp     x0, xzr, [sp], #16
.endif

.Lperf_ret:
    mov     w0, #78
    ldp     x29, x30, [sp], #16
    ret

.Lperf_drop:
    mov     w0, #0
    ldp     x29, x30, [sp], #16
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

/* ---------------------------------------------------------------------
 * perf_counters2 — second cache line, L3 (IP / ICMP / reassembly).
 * Emitted in .data (not .bss) so the PERF_L3_MAGIC tag can be
 * pre-initialized at link time without a boot-time write; this lets
 * the 0x88B6 L3 dump verify the layout on the very first query,
 * before any counter has been incremented.
 *
 * Only emitted under PERF_L3, so default and PERF=recv/send/dispatch
 * builds pay zero storage.
 * --------------------------------------------------------------------- */
.ifdef PERF_L3

.section .data
.balign 64
.global perf_counters2
perf_counters2:
    .quad   0                           /* PERF_L3_IP_TICKS */
    .word   0                           /* PERF_L3_IP_COUNT */
    .word   0                           /* PERF_L3_IP_DROPS */
    .quad   0                           /* PERF_L3_ICMP_TICKS */
    .word   0                           /* PERF_L3_ICMP_COUNT */
    .word   0                           /* PERF_L3_ICMP_ERR_GEN */
    .quad   0                           /* PERF_L3_FRAG_TICKS */
    .word   0                           /* PERF_L3_FRAG_REASSEMBLED */
    .word   0                           /* PERF_L3_FRAG_DROPS */
    .word   0                           /* PERF_L3_FRAG_ACTIVE */
    .word   0                           /* PERF_L3_RSVD1 */
    .word   0                           /* PERF_L3_RSVD2 */
    .word   PERF_L3_MAGIC_VALUE         /* PERF_L3_MAGIC = 0xDEADBEE1 */

.endif
