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
.equ PERF_DROP_COUNT,     28   /* u32: frames dropped in genet_recv
                                  due to hardware descriptor error
                                  bits (DMA_RX_FI_MASK). Distinct
                                  from PERF_RX_DISCARDS which counts
                                  frames the HW dropped BEFORE they
                                  reached a descriptor. */

.equ PERF_SEND_TICKS,     32   /* u64: ticks inside genet_send */
.equ PERF_SEND_COUNT,     40   /* u32: sends issued */
.equ PERF_SEND_FAIL,      44   /* u32: TX wait-loop timeouts */

.equ PERF_MAX_BURST,      48   /* u32: longest drain batch between idles */
.equ PERF_CUR_BURST,      52   /* u32: current drain count (reset on idle) */
.equ PERF_RX_DISCARDS,    56   /* u32: RDMA_PROD_INDEX upper-16 snapshot */
.equ PERF_MAGIC,          60   /* u32: 0xDEADBEEF sanity tag */

.equ PERF_COUNTERS_SIZE,  64   /* one A72 cache line, do not exceed */

.equ PERF_MAGIC_VALUE,    0xDEADBEEF

/* --- PERF_L3 struct (second cache line) ----------------------------- */
/*
 * A separate 64-byte struct `perf_counters2` holds L3-stage
 * instrumentation (IP, ICMP, fragment reassembly). Kept distinct
 * from the L2 struct so:
 *   (a) PERF=l3 builds can be mixed with or without PERF=recv/send
 *       without aliasing counter fields, and
 *   (b) the 0x88B6 query protocol can target one line at a time,
 *       keeping each response to the 64-byte frame the L2 protocol
 *       already uses.
 *
 * Layout mirrors the L2 struct's discipline: every u64 on an 8-byte
 * boundary, every u32 on a 4-byte boundary, magic tag at offset 60.
 */

.equ PERF_L3_IP_TICKS,          0   /* u64: ticks in ip_handle */
.equ PERF_L3_IP_COUNT,          8   /* u32: dispatched to L4 protocol */
.equ PERF_L3_IP_DROPS,         12   /* u32: ip_handle validation drops */

.equ PERF_L3_ICMP_TICKS,       16   /* u64: ticks in icmp_handle */
.equ PERF_L3_ICMP_COUNT,       24   /* u32: echo requests handled */
.equ PERF_L3_ICMP_ERR_GEN,     28   /* u32: icmp errors generated */

.equ PERF_L3_FRAG_TICKS,       32   /* u64: ticks in ip_reasm_input */
.equ PERF_L3_FRAG_REASSEMBLED, 40   /* u32: full reassemblies */
.equ PERF_L3_FRAG_DROPS,       44   /* u32: fragment drops */

.equ PERF_L3_FRAG_ACTIVE,      48   /* u32: live slot count (populated
                                     * on demand by the 0x88B6 dump
                                     * handler, not by probes) */
.equ PERF_L3_RSVD1,            52   /* u32: reserved */
.equ PERF_L3_RSVD2,            56   /* u32: reserved */
.equ PERF_L3_MAGIC,            60   /* u32: 0xDEADBEE1 sanity tag */

.equ PERF_L3_COUNTERS_SIZE,    64   /* second A72 cache line */

.equ PERF_L3_MAGIC_VALUE,      0xDEADBEE1

/* --- Readout protocol ----------------------------------------------- */

/* Custom ethertype for the perf query frame. Chosen from the IEEE 802
 * "local experimental 1" range (0x88B5-0x88B6). 0x88B5 is already used
 * by hw_test/wire.py's WireCapture readiness probe; 0x88B6 is unused. */
.equ PERF_ETHERTYPE,      0x88B6

/* Commands carried in payload[0] of a perf query frame. */
.equ PERF_CMD_DUMP,          0   /* read L2 counters, no mutation */
.equ PERF_CMD_DUMP_RESET,    1   /* read then zero L2 counters */
.equ PERF_CMD_DUMP_REGS,     2   /* dump GENET register + driver state
                                  * snapshot (64 bytes, different shape
                                  * from perf_counters — see
                                  * hw_test/wire.py _parse_genet_regs) */
.equ PERF_CMD_DUMP_L3,       3   /* read perf_counters2 (64 bytes) */
.equ PERF_CMD_DUMP_L3_RESET, 4   /* read then zero L3 counters
                                  * (magic tag preserved) */

/* --- Probe macros --------------------------------------------------- */
/*
 * PROBE_ENTRY tmp_x
 *     Snapshot CNTVCT_EL0 into an x-register at the start of a
 *     timed region. Caller ensures tmp_x is free across the region.
 *
 * PROBE_EXIT start_x, offset, scratch_x, base_x
 *     End a timed region started with PROBE_ENTRY. Computes the
 *     elapsed ticks and adds them to a u64 field at
 *     perf_counters[offset]. All four registers MUST be x-registers
 *     (64-bit) and MUST be distinct. Offset MUST correspond to a
 *     u64 field (8-byte aligned) in the struct. Clobbers start_x,
 *     scratch_x, base_x. The counter field is updated atomically
 *     with respect to single-core execution; there is no barrier.
 *
 * PROBE_COUNT_INC offset, scratch_w, base_x
 *     Increment a u32 counter at perf_counters[offset] by 1.
 *     `scratch_w` MUST be a w-register (32-bit) so the load/store
 *     emits a 4-byte access — using an x-register here would do an
 *     8-byte access that overlaps the adjacent struct field. `base_x`
 *     MUST be an x-register (64-bit) for the perf_counters address.
 *     Clobbers scratch_w and base_x.
 *
 *     The caller supplies every scratch register explicitly; there
 *     is no hidden global reservation. This forces each probe site
 *     to audit live-register pressure rather than implicitly trusting
 *     a specific register to be free.
 */

.ifdef PERF_COUNTERS

.macro PROBE_ENTRY tmp_x
    mrs     \tmp_x, cntvct_el0
.endm

.macro PROBE_EXIT start_x, offset, scratch_x, base_x
    mrs     \scratch_x, cntvct_el0
    sub     \scratch_x, \scratch_x, \start_x
    ldr     \base_x, =perf_counters
    ldr     \start_x, [\base_x, \offset]
    add     \start_x, \start_x, \scratch_x
    str     \start_x, [\base_x, \offset]
.endm

.macro PROBE_COUNT_INC offset, scratch_w, base_x
    ldr     \base_x, =perf_counters
    ldr     \scratch_w, [\base_x, \offset]
    add     \scratch_w, \scratch_w, #1
    str     \scratch_w, [\base_x, \offset]
.endm

.else

.macro PROBE_ENTRY tmp_x
.endm

.macro PROBE_EXIT start_x, offset, scratch_x, base_x
.endm

.macro PROBE_COUNT_INC offset, scratch_w, base_x
.endm

.endif

/* --- L3 probe macros ----------------------------------------------- */
/*
 * Same shape as the L2 probes but target `perf_counters2` instead of
 * `perf_counters`. Gated on PERF_L3 so PERF_L3 can be enabled
 * independently of PERF_RECV / PERF_SEND / PERF_DISPATCH.
 *
 * The PERF_L3 flag implies PERF_COUNTERS at the build layer (the
 * Makefile sets both together) so perf_handle is compiled, but a
 * PERF_L3-only build with no PERF_RECV/SEND/DISPATCH will have the
 * L2 perf_counters line sitting idle — that's fine, the readout
 * code just reports zeros for the L2 fields.
 */

.ifdef PERF_L3

.macro PROBE_L3_ENTRY tmp_x
    mrs     \tmp_x, cntvct_el0
.endm

.macro PROBE_L3_EXIT start_x, offset, scratch_x, base_x
    mrs     \scratch_x, cntvct_el0
    sub     \scratch_x, \scratch_x, \start_x
    ldr     \base_x, =perf_counters2
    ldr     \start_x, [\base_x, \offset]
    add     \start_x, \start_x, \scratch_x
    str     \start_x, [\base_x, \offset]
.endm

.macro PROBE_L3_COUNT_INC offset, scratch_w, base_x
    ldr     \base_x, =perf_counters2
    ldr     \scratch_w, [\base_x, \offset]
    add     \scratch_w, \scratch_w, #1
    str     \scratch_w, [\base_x, \offset]
.endm

.else

.macro PROBE_L3_ENTRY tmp_x
.endm

.macro PROBE_L3_EXIT start_x, offset, scratch_x, base_x
.endm

.macro PROBE_L3_COUNT_INC offset, scratch_w, base_x
.endm

.endif
