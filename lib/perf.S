/*
 * perf.S — Performance-counter storage + readout handler
 *
 * `perf_counters` (BSS, one 64-byte cache line) is emitted only under
 * PERF_COUNTERS. `perf_counters2` (L3 line) is emitted only under
 * PERF_L3. Default production builds pay zero storage for both.
 *
 * `perf_handle` is always linked and always compiled. The function
 * body is no longer wrapped in `.ifdef PERF_COUNTERS` — that gate
 * has moved inward to wrap only the cmd 0/1 (perf_counters) branch
 * of the dispatch. net_recv_one dispatches the PERF_ETHERTYPE
 * (0x88B6) query frame to it unconditionally; the handler decodes
 * the command byte and routes to the appropriate branch:
 *
 *   cmd 0/1 (PERF_CMD_DUMP / DUMP_RESET)         → perf_counters
 *                                                  (gated PERF_COUNTERS)
 *   cmd 2   (PERF_CMD_DUMP_REGS)                 → genet_dump_state
 *                                                  (gated PLATFORM_PI4)
 *   cmd 3/4 (PERF_CMD_DUMP_L3 / L3_RESET)        → perf_counters2
 *                                                  (gated PERF_L3)
 *   cmd 5   (PERF_CMD_DUMP_TCP)                  → tcp_state_count_dump
 *                                                  (always compiled)
 *
 * Commands not supported by the current build flavour fall through
 * to .Lperf_drop and reply nothing. Default builds therefore answer
 * the cmd 5 TCP-state query without needing any PERF flag, which is
 * what the wedge-investigation probe relies on.
 *
 * Probe macros and struct offsets live in include/perf.inc. Kernel
 * hot-path probe call sites are wired under PERF=recv / PERF=send /
 * PERF=dispatch (or PERF=all) in genet.S and main.S.
 */

.include "perf.inc"
.include "net.inc"

.section .text

.global perf_handle

/*
 * perf_handle — Handle a PERF_ETHERTYPE (0x88B6) query frame
 *
 * Request frame layout (built by the test driver):
 *   [0..5]   eth_dst   = our MAC
 *   [6..11]  eth_src   = peer MAC
 *   [12..13] etype     = 0x88B6
 *   [14]     cmd       = one of PERF_CMD_DUMP (0),
 *                        PERF_CMD_DUMP_RESET (1),
 *                        PERF_CMD_DUMP_REGS (2),
 *                        PERF_CMD_DUMP_L3 (3),
 *                        PERF_CMD_DUMP_L3_RESET (4),
 *                        PERF_CMD_DUMP_TCP (5)
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
 *   cmd 3/4: copy of perf_counters2 (L3 timing/event counters).
 *            cmd 4 also zeros the source after snapshot (the magic
 *            tag is preserved).
 *   cmd 5:   tcp_conn_table per-state slot counts via
 *            tcp_state_count_dump. See lib/tcp.S for the layout.
 *
 * Build-flag gating per command:
 *   cmd 0/1 — needs PERF_COUNTERS
 *   cmd 2   — needs PLATFORM_PI4
 *   cmd 3/4 — needs PERF_L3
 *   cmd 5   — always available (pure inspection of tcp_conn_table)
 * Commands the build does not support fall through the dispatch
 * tree to .Lperf_drop and reply nothing.
 *
 * x0: frame buffer pointer (same buffer used for reply)
 * w1: frame length
 * Returns:
 *   w0 = 78 on successful reply built in-place (14 + 64)
 *   w0 = 0  on drop (frame too short; unsupported command in this
 *           build flavour; cmd > PERF_CMD_DUMP_TCP)
 * Clobbers: x0-x7, x30. Saves x30 because the dispatch may bl.
 */
perf_handle:
    stp     x29, x30, [sp, #-16]!   /* prologue: save link reg for bl */
    mov     x29, sp

    /* Length check: need at least ETH_HDR_LEN (14) + 1 cmd byte */
    cmp     w1, #15
    b.lt    .Lperf_drop

    /* Read command byte at offset 14. Bound at the highest defined
     * command (PERF_CMD_DUMP_TCP=5). Anything higher → drop.
     * Commands the build does not support fall through the dispatch
     * tree below to .Lperf_drop. */
    ldrb    w2, [x0, #14]
    cmp     w2, #PERF_CMD_DUMP_TCP
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

    /* ---- Dispatch on cmd ---- */

    /* Cmd 5 — TCP slot-state dump. Always compiled. */
    cmp     w2, #PERF_CMD_DUMP_TCP
    b.eq    .Lperf_tcp

.ifdef PLATFORM_PI4
    cmp     w2, #PERF_CMD_DUMP_REGS
    b.eq    .Lperf_regs
.endif
.ifdef PERF_L3
    cmp     w2, #PERF_CMD_DUMP_L3
    b.eq    .Lperf_l3
    cmp     w2, #PERF_CMD_DUMP_L3_RESET
    b.eq    .Lperf_l3
.endif

.ifdef PERF_COUNTERS
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
.else
    /* No PERF_COUNTERS — cmd 0/1 are unsupported in this build. */
    b       .Lperf_drop
.endif

.Lperf_tcp:
    /* tcp_state_count_dump takes x0 = destination buffer (64 bytes)
     * and writes the per-state slot counts. Save frame base across
     * the call so we can return reply length. */
    stp     x0, xzr, [sp, #-16]!
    add     x0, x0, #14
    bl      tcp_state_count_dump
    ldp     x0, xzr, [sp], #16
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
    b       .Lperf_ret
.endif

.ifdef PERF_L3
.Lperf_l3:
    /* Cmd 3/4: L3 counter dump. Before the copy, populate
     * PERF_L3_FRAG_ACTIVE with a live count of reasm slots whose
     * REASM_FLAGS bit 7 (active) is set. Costs one pass over the
     * 4-slot array per query — cheap, and not counted under any
     * probe (the query handler is not in a timed hot path).
     *
     * Scratch: w3 = loop counter, x5 = walking slot pointer,
     * w6 = flags byte, w7 = active count. */
    ldr     x5, =reasm_slots
    mov     w3, #REASM_MAX_SLOTS
    mov     w7, #0
.Lperf_l3_slot_loop:
    ldrb    w6, [x5, #REASM_FLAGS]
    lsr     w6, w6, #7              /* bit 7 → bit 0 */
    and     w6, w6, #1
    add     w7, w7, w6
    add     x5, x5, #REASM_SLOT_SIZE
    subs    w3, w3, #1
    b.ne    .Lperf_l3_slot_loop

    /* Store the computed active count into perf_counters2. */
    ldr     x4, =perf_counters2
    str     w7, [x4, #PERF_L3_FRAG_ACTIVE]

    /* Copy perf_counters2 (64 bytes) into the reply payload. */
    add     x5, x0, #14
    ldp     x6, x7, [x4, #0]
    stp     x6, x7, [x5, #0]
    ldp     x6, x7, [x4, #16]
    stp     x6, x7, [x5, #16]
    ldp     x6, x7, [x4, #32]
    stp     x6, x7, [x5, #32]
    ldp     x6, x7, [x4, #48]
    stp     x6, x7, [x5, #48]

    /* If this was PERF_CMD_DUMP_L3_RESET, zero the L3 counter
     * fields AFTER the copy. The magic tag (offset 60) must be
     * preserved so the next query can still verify the layout,
     * so we restore it after the bulk zero. FRAG_ACTIVE (offset
     * 48) is also zeroed and will be re-populated live on the
     * next query. */
    cmp     w2, #PERF_CMD_DUMP_L3_RESET
    b.ne    .Lperf_ret
    stp     xzr, xzr, [x4, #0]
    stp     xzr, xzr, [x4, #16]
    stp     xzr, xzr, [x4, #32]
    stp     xzr, xzr, [x4, #48]
    ldr     w6, =PERF_L3_MAGIC_VALUE
    str     w6, [x4, #PERF_L3_MAGIC]
    b       .Lperf_ret
.endif

.Lperf_ret:
    mov     w0, #78
    ldp     x29, x30, [sp], #16
    ret

.Lperf_drop:
    mov     w0, #0
    ldp     x29, x30, [sp], #16
    ret


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
