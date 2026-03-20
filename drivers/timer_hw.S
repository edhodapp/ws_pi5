/*
 * timer_hw.S — Hardware timer counter access
 *
 * Reads ARMv8 system counters. Separated from timer pool
 * logic so lib/ contains only pure computation.
 */

.global timer_now
.global timer_freq

.section .text

/*
 * timer_now - Read monotonic counter
 * Returns: x0 = CNTPCT_EL0 value
 */
timer_now:
    mrs     x0, cntpct_el0
    ret

/*
 * timer_freq - Read counter frequency
 * Returns: x0 = CNTFRQ_EL0 value (Hz)
 */
timer_freq:
    mrs     x0, cntfrq_el0
    ret
