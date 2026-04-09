/*
 * test_genet_rx_err.S — Unit tests for the RX error drop path.
 *
 * genet.S::genet_rx_drop_bookkeeping is the pure-software helper
 * called from .Lrx_err in genet_recv when a received descriptor has
 * any DMA_RX_FI_MASK bit set (OV, CRC_ERROR, RXER, NO, LG). The
 * helper advances the software CIDX+RIDX and, when passed a
 * non-NULL pointer, bumps PERF_DROP_COUNT; the caller then
 * publishes the returned CIDX to the RDMA_CONS_INDEX hardware
 * register.
 *
 * These tests drive the helper directly with fake genet_state and
 * perf_counters blocks in .bss. That's the only L2 path we can
 * reasonably unit-test off-hardware: the test bench can't generate
 * deterministic HW RX errors (the r8152 USB NIC has no FCS
 * injection support), so the contract has to be pinned at the
 * function boundary instead. Each test sets up known-state,
 * invokes the helper, and asserts every observable post-condition
 * — matching the project rule that every branch must have a
 * meaningful assertion.
 *
 * Tests:
 *   1. test_rx_err_basic              — fresh state, perf ptr non-null
 *   2. test_rx_err_null_perf          — NULL perf ptr → perf untouched
 *   3. test_rx_err_cidx_wrap          — CIDX 0xFFFF → 0 (16-bit mask)
 *   4. test_rx_err_ridx_wrap          — RIDX 0xFF → 0 (8-bit mask)
 *   5. test_rx_err_preserves_other    — TX_PIDX/TX_RIDX + other perf
 *                                       fields are not touched
 *   6. test_rx_err_fi_mask_covers     — DMA_RX_FI_MASK == OR of the
 *                                       five individual error bits
 */

.include "genet.inc"
.include "perf.inc"

.global test_rx_err_basic
.global test_rx_err_null_perf
.global test_rx_err_cidx_wrap
.global test_rx_err_ridx_wrap
.global test_rx_err_preserves_other
.global test_rx_err_fi_mask_covers

.section .text

/* ========================================================================
 * Helper: zero the fake_state block (32 bytes).
 * Clobbers x0, x1.
 * ======================================================================== */
.Lzero_state:
    ldr     x0, =fake_state
    mov     x1, #0
    str     x1, [x0, #0]
    str     x1, [x0, #8]
    str     x1, [x0, #16]
    str     x1, [x0, #24]
    ret

/* ========================================================================
 * Helper: zero the fake_perf block (64 bytes).
 * Clobbers x0, x1.
 * ======================================================================== */
.Lzero_perf:
    ldr     x0, =fake_perf
    mov     x1, #0
    str     x1, [x0, #0]
    str     x1, [x0, #8]
    str     x1, [x0, #16]
    str     x1, [x0, #24]
    str     x1, [x0, #32]
    str     x1, [x0, #40]
    str     x1, [x0, #48]
    str     x1, [x0, #56]
    ret

/* ========================================================================
 * test_rx_err_basic — fresh state, non-null perf pointer.
 *
 *   Pre:  fake_state = {0}, fake_perf = {0}
 *   Call: genet_rx_drop_bookkeeping(&fake_state, &fake_perf)
 *   Post: RX_CIDX == 1, RX_RIDX == 1, DROP_COUNT == 1, w0 == 1
 * ======================================================================== */
test_rx_err_basic:
    stp     x29, x30, [sp, #-16]!

    bl      .Lzero_state
    bl      .Lzero_perf

    ldr     x0, =fake_state
    ldr     x1, =fake_perf
    bl      genet_rx_drop_bookkeeping

    /* w0 return: new CIDX == 1 */
    cmp     w0, #1
    b.ne    .Lfail_basic

    /* State CIDX advanced to 1 */
    ldr     x2, =fake_state
    ldr     w3, [x2, #GENET_STATE_RX_CIDX]
    cmp     w3, #1
    b.ne    .Lfail_basic

    /* State RIDX advanced to 1 */
    ldr     w3, [x2, #GENET_STATE_RX_RIDX]
    cmp     w3, #1
    b.ne    .Lfail_basic

    /* DROP_COUNT incremented to 1 */
    ldr     x2, =fake_perf
    ldr     w3, [x2, #PERF_DROP_COUNT]
    cmp     w3, #1
    b.ne    .Lfail_basic

    ldr     x0, =name_basic
    bl      test_pass
    b       .Ldone_basic

.Lfail_basic:
    ldr     x0, =name_basic
    bl      test_fail

.Ldone_basic:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_rx_err_null_perf — NULL perf pointer skips the perf bump.
 *
 *   Pre:  fake_state = {0}, fake_perf = {0}
 *   Call: genet_rx_drop_bookkeeping(&fake_state, NULL)
 *   Post: RX_CIDX == 1, RX_RIDX == 1, fake_perf.DROP_COUNT == 0
 *
 * Pins the cbz x1 branch: in default (non-PERF) kernel builds the
 * caller passes xzr and the helper must NOT deref the pointer.
 * ======================================================================== */
test_rx_err_null_perf:
    stp     x29, x30, [sp, #-16]!

    bl      .Lzero_state
    bl      .Lzero_perf

    ldr     x0, =fake_state
    mov     x1, xzr                 /* NULL perf pointer */
    bl      genet_rx_drop_bookkeeping

    /* Return value */
    cmp     w0, #1
    b.ne    .Lfail_null

    /* State advanced */
    ldr     x2, =fake_state
    ldr     w3, [x2, #GENET_STATE_RX_CIDX]
    cmp     w3, #1
    b.ne    .Lfail_null
    ldr     w3, [x2, #GENET_STATE_RX_RIDX]
    cmp     w3, #1
    b.ne    .Lfail_null

    /* Perf block untouched — drop_count still 0 */
    ldr     x2, =fake_perf
    ldr     w3, [x2, #PERF_DROP_COUNT]
    cbnz    w3, .Lfail_null

    ldr     x0, =name_null
    bl      test_pass
    b       .Ldone_null

.Lfail_null:
    ldr     x0, =name_null
    bl      test_fail

.Ldone_null:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_rx_err_cidx_wrap — CIDX = 0xFFFF wraps to 0 on increment.
 *
 *   Pre:  fake_state.CIDX = 0xFFFF, fake_state.RIDX = 0, fake_perf = {0}
 *   Call: genet_rx_drop_bookkeeping(&fake_state, &fake_perf)
 *   Post: CIDX == 0 (16-bit wrap), RIDX == 1, return w0 == 0
 *
 * Pins the 16-bit mask on CIDX. The hardware RDMA_CONS_INDEX is a
 * 16-bit field so CIDX must wrap at 0x10000, not 0x100000000.
 * ======================================================================== */
test_rx_err_cidx_wrap:
    stp     x29, x30, [sp, #-16]!

    bl      .Lzero_state
    bl      .Lzero_perf

    ldr     x0, =fake_state
    mov     w1, #0xFFFF
    str     w1, [x0, #GENET_STATE_RX_CIDX]

    ldr     x0, =fake_state
    ldr     x1, =fake_perf
    bl      genet_rx_drop_bookkeeping

    /* Returned new CIDX == 0 */
    cbnz    w0, .Lfail_cwrap

    /* State CIDX wrapped */
    ldr     x2, =fake_state
    ldr     w3, [x2, #GENET_STATE_RX_CIDX]
    cbnz    w3, .Lfail_cwrap

    /* RIDX advanced normally (0 → 1) */
    ldr     w3, [x2, #GENET_STATE_RX_RIDX]
    cmp     w3, #1
    b.ne    .Lfail_cwrap

    ldr     x0, =name_cwrap
    bl      test_pass
    b       .Ldone_cwrap

.Lfail_cwrap:
    ldr     x0, =name_cwrap
    bl      test_fail

.Ldone_cwrap:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_rx_err_ridx_wrap — RIDX = 0xFF wraps to 0 on increment.
 *
 *   Pre:  fake_state.CIDX = 0, fake_state.RIDX = 0xFF, fake_perf = {0}
 *   Call: genet_rx_drop_bookkeeping(&fake_state, &fake_perf)
 *   Post: CIDX == 1, RIDX == 0 (8-bit wrap)
 *
 * Pins the 8-bit mask on RIDX. The RX ring has 256 entries so
 * RIDX MUST wrap at 0x100, not at 0x10000 or later — a wider mask
 * would let RIDX drift off the end of the ring and corrupt
 * the next slot lookup on the following receive.
 * ======================================================================== */
test_rx_err_ridx_wrap:
    stp     x29, x30, [sp, #-16]!

    bl      .Lzero_state
    bl      .Lzero_perf

    ldr     x0, =fake_state
    mov     w1, #0xFF
    str     w1, [x0, #GENET_STATE_RX_RIDX]

    ldr     x0, =fake_state
    ldr     x1, =fake_perf
    bl      genet_rx_drop_bookkeeping

    /* CIDX advanced from 0 to 1 */
    cmp     w0, #1
    b.ne    .Lfail_rwrap

    ldr     x2, =fake_state
    ldr     w3, [x2, #GENET_STATE_RX_CIDX]
    cmp     w3, #1
    b.ne    .Lfail_rwrap

    /* RIDX wrapped from 0xFF to 0 */
    ldr     w3, [x2, #GENET_STATE_RX_RIDX]
    cbnz    w3, .Lfail_rwrap

    ldr     x0, =name_rwrap
    bl      test_pass
    b       .Ldone_rwrap

.Lfail_rwrap:
    ldr     x0, =name_rwrap
    bl      test_fail

.Ldone_rwrap:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_rx_err_preserves_other — unrelated fields are not clobbered.
 *
 *   Pre:  fake_state.TX_PIDX = 0xAAAA, fake_state.TX_RIDX = 0x55,
 *         fake_state.RX_POOL = 0xDEADBEEFCAFE0000,
 *         fake_state.PHY_SPEED = 0x1000,
 *         fake_perf.RECV_TICKS = 0x1111_2222_3333_4444,
 *         fake_perf.RECV_COUNT = 0x12345678,
 *         fake_perf.DROP_COUNT = 42
 *   Call: genet_rx_drop_bookkeeping(&fake_state, &fake_perf)
 *   Post: DROP_COUNT == 43 (bumped by one),
 *         all other fields unchanged.
 *
 * Pins that the helper touches ONLY the four bytes of RX_CIDX,
 * four bytes of RX_RIDX, and four bytes of PERF_DROP_COUNT — any
 * wider write (e.g. a stray stp into the state struct) would be
 * caught here.
 * ======================================================================== */
test_rx_err_preserves_other:
    stp     x29, x30, [sp, #-16]!

    bl      .Lzero_state
    bl      .Lzero_perf

    /* Seed fake_state's TX + pool + phy fields with a pattern */
    ldr     x0, =fake_state
    mov     w1, #0xAAAA
    str     w1, [x0, #GENET_STATE_TX_PIDX]
    mov     w1, #0x55
    str     w1, [x0, #GENET_STATE_TX_RIDX]
    ldr     x1, =0xDEADBEEFCAFE0000
    str     x1, [x0, #GENET_STATE_RX_POOL]
    mov     w1, #0x1000
    str     w1, [x0, #GENET_STATE_PHY_SPEED]

    /* Seed fake_perf — every field except DROP_COUNT starting at 42 */
    ldr     x0, =fake_perf
    ldr     x1, =0x1111222233334444
    str     x1, [x0, #PERF_RECV_TICKS]
    mov     w1, #0x5678
    movk    w1, #0x1234, lsl #16
    str     w1, [x0, #PERF_RECV_COUNT]
    mov     w1, #42
    str     w1, [x0, #PERF_DROP_COUNT]

    ldr     x0, =fake_state
    ldr     x1, =fake_perf
    bl      genet_rx_drop_bookkeeping

    /* DROP_COUNT bumped 42 → 43 */
    ldr     x2, =fake_perf
    ldr     w3, [x2, #PERF_DROP_COUNT]
    cmp     w3, #43
    b.ne    .Lfail_pres

    /* RECV_TICKS untouched */
    ldr     x3, [x2, #PERF_RECV_TICKS]
    ldr     x4, =0x1111222233334444
    cmp     x3, x4
    b.ne    .Lfail_pres

    /* RECV_COUNT untouched */
    ldr     w3, [x2, #PERF_RECV_COUNT]
    mov     w4, #0x5678
    movk    w4, #0x1234, lsl #16
    cmp     w3, w4
    b.ne    .Lfail_pres

    /* TX_PIDX untouched */
    ldr     x2, =fake_state
    ldr     w3, [x2, #GENET_STATE_TX_PIDX]
    mov     w4, #0xAAAA
    cmp     w3, w4
    b.ne    .Lfail_pres

    /* TX_RIDX untouched */
    ldr     w3, [x2, #GENET_STATE_TX_RIDX]
    cmp     w3, #0x55
    b.ne    .Lfail_pres

    /* RX_POOL untouched */
    ldr     x3, [x2, #GENET_STATE_RX_POOL]
    ldr     x4, =0xDEADBEEFCAFE0000
    cmp     x3, x4
    b.ne    .Lfail_pres

    /* PHY_SPEED untouched */
    ldr     w3, [x2, #GENET_STATE_PHY_SPEED]
    mov     w4, #0x1000
    cmp     w3, w4
    b.ne    .Lfail_pres

    /* RX_CIDX advanced to 1 (sanity — we care about non-touch of
     * everything else, but confirm the helper actually did its job) */
    ldr     w3, [x2, #GENET_STATE_RX_CIDX]
    cmp     w3, #1
    b.ne    .Lfail_pres

    ldr     w3, [x2, #GENET_STATE_RX_RIDX]
    cmp     w3, #1
    b.ne    .Lfail_pres

    ldr     x0, =name_pres
    bl      test_pass
    b       .Ldone_pres

.Lfail_pres:
    ldr     x0, =name_pres
    bl      test_fail

.Ldone_pres:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_rx_err_fi_mask_covers — DMA_RX_FI_MASK matches OR of fields.
 *
 * The inline error-detection in genet_recv is a one-instruction
 * `tst w4, #DMA_RX_FI_MASK`. This test pins the structural
 * invariant the tst relies on: DMA_RX_FI_MASK equals the bitwise
 * OR of all five individual error flag constants. If a future
 * change adds a new error bit to DMA_RX_OV/CRC/RXER/NO/LG but
 * forgets to widen FI_MASK (or vice versa), the two would drift
 * and the tst would silently miss the new bit.
 *
 * GNU as can't OR .equ constants at assemble time, so we compute
 * the OR at runtime and assert equality to FI_MASK.
 * ======================================================================== */
test_rx_err_fi_mask_covers:
    stp     x29, x30, [sp, #-16]!

    mov     w0, #DMA_RX_OV
    mov     w1, #DMA_RX_CRC_ERROR
    orr     w0, w0, w1
    mov     w1, #DMA_RX_RXER
    orr     w0, w0, w1
    mov     w1, #DMA_RX_NO
    orr     w0, w0, w1
    mov     w1, #DMA_RX_LG
    orr     w0, w0, w1

    mov     w1, #DMA_RX_FI_MASK
    cmp     w0, w1
    b.ne    .Lfail_mask

    /* Also assert each individual bit is subset of FI_MASK — catches
     * the other direction of drift (individual bit defined but
     * missing from mask). */
    mov     w2, #DMA_RX_FI_MASK
    mov     w0, #DMA_RX_OV
    and     w0, w0, w2
    cbz     w0, .Lfail_mask
    mov     w0, #DMA_RX_CRC_ERROR
    and     w0, w0, w2
    cbz     w0, .Lfail_mask
    mov     w0, #DMA_RX_RXER
    and     w0, w0, w2
    cbz     w0, .Lfail_mask
    mov     w0, #DMA_RX_NO
    and     w0, w0, w2
    cbz     w0, .Lfail_mask
    mov     w0, #DMA_RX_LG
    and     w0, w0, w2
    cbz     w0, .Lfail_mask

    ldr     x0, =name_mask
    bl      test_pass
    b       .Ldone_mask

.Lfail_mask:
    ldr     x0, =name_mask
    bl      test_fail

.Ldone_mask:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * Test data / bss
 * ======================================================================== */
.section .rodata
name_basic: .asciz "rx_err_basic"
name_null:  .asciz "rx_err_null_perf"
name_cwrap: .asciz "rx_err_cidx_wrap"
name_rwrap: .asciz "rx_err_ridx_wrap"
name_pres:  .asciz "rx_err_preserves_other"
name_mask:  .asciz "rx_err_fi_mask_covers"

.section .bss
.balign 8
fake_state:
    .space  GENET_STATE_SIZE        /* 32 bytes */
.balign 8
fake_perf:
    .space  PERF_COUNTERS_SIZE      /* 64 bytes */
