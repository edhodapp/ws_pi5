/*
 * sys_watchdog.inc — sys_watchdog_state struct field offsets.
 *
 * Shared between platform/pi/drivers/sys_watchdog.S (allocator and
 * implementation), platform/pi/main.S (initializer and arm site),
 * lib/http_status.S (telemetry display), and tests/test_sys_watchdog.S
 * (test fixture).
 *
 * GNU as `.equ` symbols are file-local — there is no equivalent of
 * a header `extern`. Each consumer .include's this file and gets
 * its own copy of the values. As long as the file stays the single
 * source of truth, layout drift is impossible.
 */

.equ SWD_PM_BASE,       0    /* u64 — PM register block base */
.equ SWD_TIMEOUT_UNITS, 8    /* u32 — value to write to PM_WDOG */
.equ SWD_PET_COUNT,     12   /* u32 — telemetry: pets since arm */
.equ SWD_BOOT_RSTS,     16   /* u32 — captured at init from PM_RSTS */
.equ SWD_PAD,           20   /* u32 — alignment to 8 */
.equ SWD_TIMER_POOL,    24   /* u64 — pool address for periodic re-arm */
.equ SWD_PET_PERIOD,    32   /* u64 — re-arm period in CNTPCT ticks */
.equ SWD_SIZE,          40
