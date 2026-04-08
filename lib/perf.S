/*
 * perf.S — Performance-counter storage
 *
 * Only provides the `perf_counters` symbol (one 64-byte cache line in
 * .bss) when PERF_COUNTERS is defined. Without PERF_COUNTERS the file
 * produces no symbols at all, so default production builds pay zero
 * bytes and zero cycles for profiling.
 *
 * Probe macros and struct offsets live in include/perf.inc. Handler
 * and init live in later commits.
 */

.include "perf.inc"

.ifdef PERF_COUNTERS

.section .bss
.balign 64
.global perf_counters
perf_counters:
    .space  PERF_COUNTERS_SIZE

.endif
