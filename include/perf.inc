/*
 * perf.inc — GENET hot-path performance instrumentation
 *
 * Compile-time-gated cycle counters for the receive / dispatch / send
 * stages of the network fast path. When PERF_COUNTERS is defined the
 * probe macros expand into CNTVCT_EL0 reads that accumulate per-stage
 * cycle totals into a single cache-line struct in .bss. When
 * PERF_COUNTERS is undefined the macros expand to nothing and there
 * is ZERO overhead in production builds.
 *
 * Enable for a profile build with:
 *
 *     make PLATFORM=pi4 PERF=1
 *
 * The collected counters are surfaced to the test harness over a
 * custom Ethernet frame (ethertype 0x88B6) handled in a later commit.
 *
 * Layout is a single 64-byte struct (one cache line on Cortex-A72)
 * to keep every counter access to one L1 line. Do not let this grow
 * past 64 bytes without bumping the SIZE constant and re-verifying
 * cache placement.
 */

/* --- Struct offsets ------------------------------------------------- */

.equ PERF_RECV_TICKS,      0   /* u64: CNTVCT ticks inside genet_recv */
.equ PERF_RECV_COUNT,      8   /* u32: successful recvs (got a frame) */
.equ PERF_RECV_NONE,      12   /* u32: calls returning "no frame" */

.equ PERF_DISPATCH_TICKS, 16   /* u64: ticks inside net_recv_one */
.equ PERF_DISPATCH_COUNT, 24   /* u32: frames dispatched */
.equ PERF_DROP_COUNT,     28   /* u32: frames dropped (not for us) */

.equ PERF_SEND_TICKS,     32   /* u64: ticks inside genet_send */
.equ PERF_SEND_COUNT,     40   /* u32: sends issued */
.equ PERF_SEND_FAIL,      44   /* u32: TX wait-loop timeouts */

.equ PERF_MAX_BURST,      48   /* u32: longest drain batch between idles */
.equ PERF_CUR_BURST,      52   /* u32: current drain count (reset on idle) */
.equ PERF_RX_DISCARDS,    56   /* u32: RDMA_PROD_INDEX upper-16 snapshot */
.equ PERF_MAGIC,          60   /* u32: 0xDEADBEEF sanity tag */

.equ PERF_COUNTERS_SIZE,  64   /* one A72 cache line, do not exceed */

.equ PERF_MAGIC_VALUE,    0xDEADBEEF

/* --- Readout protocol ----------------------------------------------- */

/* Custom ethertype for the perf query frame. Chosen from the IEEE 802
 * "local experimental 1" range (0x88B5-0x88B6). 0x88B5 is already used
 * by hw_test/wire.py's WireCapture readiness probe; 0x88B6 is unused. */
.equ PERF_ETHERTYPE,      0x88B6

/* Commands carried in payload[0] of a perf query frame. */
.equ PERF_CMD_DUMP,       0    /* read current counters, no mutation */
.equ PERF_CMD_DUMP_RESET, 1    /* read then zero all counters */

/* --- Probe macros --------------------------------------------------- */
/*
 * PROBE_ENTRY tmp_reg
 *     Snapshot CNTVCT_EL0 into tmp_reg at the start of a timed region.
 *     Caller is responsible for ensuring tmp_reg is free.
 *
 * PROBE_EXIT start_reg, offset, scratch1, scratch2
 *     End a timed region started with PROBE_ENTRY. Computes the
 *     elapsed ticks and adds them to perf_counters[offset]. The
 *     caller supplies all scratch registers explicitly — this forces
 *     every probe site to audit register pressure rather than
 *     quietly relying on specific registers being free.
 *
 *     Uses: reads [perf_counters+offset], writes back updated total.
 *     Clobbers: start_reg, scratch1, scratch2.
 *     All four registers must be distinct.
 *
 * PROBE_COUNT_INC offset, scratch1, scratch2
 *     Increment a 32-bit u32 counter at perf_counters[offset].
 *     Used for frame counts independent of tick totals.
 */

.ifdef PERF_COUNTERS

.macro PROBE_ENTRY tmp
    mrs     \tmp, cntvct_el0
.endm

.macro PROBE_EXIT start, offset, scratch1, scratch2
    mrs     \scratch1, cntvct_el0
    sub     \scratch1, \scratch1, \start
    ldr     \scratch2, =perf_counters
    ldr     \start, [\scratch2, \offset]
    add     \start, \start, \scratch1
    str     \start, [\scratch2, \offset]
.endm

.macro PROBE_COUNT_INC offset, scratch1, scratch2
    ldr     \scratch2, =perf_counters
    ldr     \scratch1, [\scratch2, \offset]
    add     \scratch1, \scratch1, #1
    str     \scratch1, [\scratch2, \offset]
.endm

.else

.macro PROBE_ENTRY tmp
.endm

.macro PROBE_EXIT start, offset, scratch1, scratch2
.endm

.macro PROBE_COUNT_INC offset, scratch1, scratch2
.endm

.endif
