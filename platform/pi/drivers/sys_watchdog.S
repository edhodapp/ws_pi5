/*
 * sys_watchdog.S — BCM2711 PM (Power Manager) watchdog driver.
 *
 * Layered above the GENET TX-wedge watchdog as a last-resort
 * recovery: when the kernel itself hangs (tight loop, exception,
 * timer-pool wedge, memory corruption — any failure that prevents
 * the main loop from making progress), the PM watchdog times out
 * and triggers a full SoC hardware reset.
 *
 * Design (per session 2026-05-06):
 *   - Timeout: 10 s. Must be longer than the longest legitimate
 *     kernel-blocking operation. genet_init worst case is ~5 s
 *     (PHY autoneg dominates), so 10 s gives ~2× margin.
 *   - Pet cadence: every 2 s from a periodic timer in the timer
 *     pool. A tick starvation window ≥10 s → reset.
 *   - Arm late: only after main() has reached steady state. A
 *     bug that prevents reaching steady state would otherwise
 *     burn the device into a reset loop.
 *   - On boot, capture the raw PM_RSTS value before petting; this
 *     records why the SoC last reset (cold boot vs. watchdog vs.
 *     soft reset). Exposed via /status as `last_reset_rsts`.
 *
 * Layered with the GENET watchdog the recovery model is:
 *   1. GENET TX wedge → genet_watchdog (bumps reset_count, calls
 *      genet_init; ~5 s recovery).
 *   2. Anything else → PM watchdog → SoC hardware reset (full
 *      cold boot ~10-30 s).
 *
 * Implementation split:
 *   - Pure-software bookkeeping (sys_watchdog_record_pet) — unit-
 *     tested off-hardware in tests/test_sys_watchdog.S.
 *   - MMIO-bearing primitives (read_rsts, write_wdog, arm,
 *     disarm, pet_cb) — exercised at the hardware integration
 *     tier and by an /status sanity check at bringup.
 */

.include "platform.inc"
.include "timer.inc"
.include "sys_watchdog.inc"

.global sys_watchdog_record_pet
.global sys_watchdog_capture_rsts
.global sys_watchdog_arm
.global sys_watchdog_disarm
.global sys_watchdog_pet_cb
.global sys_watchdog_set_timeout
.global sys_watchdog_state

.section .text

/*
 * sys_watchdog_record_pet — pure-software pet counter bump.
 *
 * Pulled out of sys_watchdog_pet_cb so the bookkeeping can be
 * unit-tested without faking the PM register surface. The actual
 * PM_WDOG MMIO write stays in the cb where it belongs.
 *
 * x0: state pointer
 * Clobbers: x0, x1.
 */
sys_watchdog_record_pet:
    ldr     w1, [x0, #SWD_PET_COUNT]
    add     w1, w1, #1
    str     w1, [x0, #SWD_PET_COUNT]
    ret

/*
 * sys_watchdog_capture_rsts — read PM_RSTS at boot, save to state.
 *
 * Must run before any other PM_RSTS-modifying operation. The raw
 * value contains the "why did the SoC last reset" bits — knowing
 * whether a reboot was watchdog-induced vs. cold power-on is the
 * primary in-field telemetry signal that the watchdog is doing
 * its job.
 *
 * x0: state pointer (SWD_PM_BASE must already be populated)
 * Clobbers: x0, x1, x2.
 */
sys_watchdog_capture_rsts:
    ldr     x1, [x0, #SWD_PM_BASE]
    ldr     w2, [x1, #PM_RSTS]
    str     w2, [x0, #SWD_BOOT_RSTS]
    ret

/*
 * sys_watchdog_arm — start the PM watchdog and arm the periodic
 * pet timer.
 *
 * Caller must have populated state: PM_BASE, TIMEOUT_UNITS,
 * TIMER_POOL, PET_PERIOD. This function performs the first pet
 * (writes PM_WDOG with the configured timeout), enables PM_RSTC
 * with the full-reset config, then arms a one-shot timer that
 * will pet again at now+PET_PERIOD. The pet callback re-arms
 * itself, so subsequent pets follow automatically as long as
 * timer_check keeps running.
 *
 * From this point forward, if PM_WDOG is not refreshed within
 * TIMEOUT_UNITS / 65536 seconds, the SoC hardware-resets.
 *
 * x0: state pointer
 * Clobbers: x0-x6, x30.
 */
sys_watchdog_arm:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    mov     x29, sp

    mov     x19, x0                     /* x19 = state ptr (preserve) */

    /* First pet: write timeout to PM_WDOG with password OR'd in.
     * Without the password the write is silently ignored, so the
     * subsequent PM_RSTC enable would arm against an undefined
     * timeout — possibly the residual default, possibly zero.
     * Doing the WDOG write first guarantees a known timeout when
     * RSTC's WRCFG_FULL_RESET takes effect.
     *
     * Use ldr/orr rather than movk for the password merge: movk
     * overwrites a full 16-bit slot, which would clobber bits
     * [23:16] of the timeout (the 0x0A in 0x000A0000). Loading
     * the password whole and OR'ing preserves every timeout bit. */
    ldr     x1, [x19, #SWD_PM_BASE]
    ldr     w2, [x19, #SWD_TIMEOUT_UNITS]
    ldr     w4, =PM_PASSWORD
    orr     w2, w2, w4
    str     w2, [x1, #PM_WDOG]
    /* Memory barrier: the PM_RSTC enable below must observe the
     * PM_WDOG write first, otherwise the watchdog could arm with
     * the residual timeout for a brief window. dsb sy is the
     * cheapest barrier that guarantees both Device-nGnRnE store
     * ordering and visibility to the PM block. */
    dsb     sy

    /* Enable PM_RSTC with WRCFG_FULL_RESET. Mask off the existing
     * WRCFG bits before OR'ing in our config — preserves any
     * unrelated bits (e.g. partition fields the firmware may have
     * left set) without trashing them. */
    ldr     w3, [x1, #PM_RSTC]
    mov     w5, #PM_RSTC_WRCFG_MASK
    bic     w3, w3, w5                  /* clear existing WRCFG */
    mov     w5, #PM_RSTC_WRCFG_FULL_RESET
    orr     w3, w3, w5
    orr     w3, w3, w4                  /* OR in the password */
    str     w3, [x1, #PM_RSTC]
    dsb     sy

    /* Arm the first pet timer: expiry = now + PET_PERIOD. */
    bl      timer_now                   /* x0 = current tick */
    ldr     x6, [x19, #SWD_PET_PERIOD]
    add     x1, x0, x6                  /* x1 = expiry */

    ldr     x0, [x19, #SWD_TIMER_POOL]
    ldr     x2, =sys_watchdog_pet_cb
    mov     x3, x19                     /* x3 = ctx (state ptr) */
    bl      timer_set
    /* timer_set returns the slot index, or -1 if the pool is full.
     * A pool-full at first arm is unrecoverable: the PM watchdog
     * is now enabled with WRCFG_FULL_RESET and needs periodic
     * pets, but timer_set just declined to install the pet timer
     * — guaranteed reset in 10 s. Surface this loudly via UART so
     * the failure mode is "console explains the impending reset"
     * rather than "device mysteriously reboots." Subsequent pets
     * from inside the cb's re-arm path can fail silently — that's
     * the correct behavior for a degraded steady state. */
    cmn     w0, #1                      /* sets flags as if cmp w0, #-1 */
    b.ne    .Larm_done
    ldr     x0, =swd_arm_fail_msg
    bl      uart_puts
.Larm_done:

    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

/*
 * sys_watchdog_disarm — disable the PM watchdog.
 *
 * For test scaffolding and emergency recovery paths. Production
 * runtime code should not call this — the watchdog is supposed
 * to stay armed for the life of the kernel. Panic paths feed the
 * watchdog from inside their blink loop (see PANIC_PET_WATCHDOG
 * in lib/panic.S) rather than disarming, which preserves the
 * watchdog as a backstop against a wedged panic handler itself.
 *
 * Tolerates not-yet-initialized state (PM_BASE = 0): treats it
 * as "nothing to disarm" and returns without touching MMIO.
 *
 * x0: state pointer
 * Clobbers: x0-x3.
 */
sys_watchdog_disarm:
    ldr     x1, [x0, #SWD_PM_BASE]
    cbz     x1, .Lswd_disarm_skip
    mov     w2, #PM_RSTC_WRCFG_CLR
    ldr     w3, =PM_PASSWORD
    orr     w2, w2, w3
    str     w2, [x1, #PM_RSTC]
    dsb     sy
.Lswd_disarm_skip:
    ret

/*
 * sys_watchdog_set_timeout — change the PM watchdog timeout.
 *
 * Updates state.TIMEOUT_UNITS to the new value AND writes the
 * new value to PM_WDOG immediately, so the new timeout is in
 * effect from the next instruction onward. Subsequent periodic
 * pets read TIMEOUT_UNITS from state, so they pick up the new
 * value automatically.
 *
 * Used by main() to transition from the boot-grace timeout
 * (60 s — long enough that slow init operations like PHY
 * autoneg don't false-trip) down to the runtime timeout
 * (10 s — fast detection of post-boot wedges).
 *
 * Tolerates not-yet-armed state (PM_BASE = 0): updates
 * TIMEOUT_UNITS but skips the MMIO write. The next sys_watchdog_arm
 * will pick up the value.
 *
 * x0: state pointer
 * w1: new timeout in PM_WDOG units (1/65536 s per tick, 24-bit)
 * Clobbers: x0-x4.
 */
sys_watchdog_set_timeout:
    str     w1, [x0, #SWD_TIMEOUT_UNITS]
    ldr     x2, [x0, #SWD_PM_BASE]
    cbz     x2, .Lswd_set_to_skip
    ldr     w3, =PM_PASSWORD
    orr     w4, w1, w3
    str     w4, [x2, #PM_WDOG]
    dsb     sy
.Lswd_set_to_skip:
    ret

/*
 * sys_watchdog_pet_cb — periodic timer callback.
 *
 * Invoked by timer_check from the kernel main loop's idle path.
 * Each invocation:
 *   1. Refreshes PM_WDOG with the configured timeout (resets the
 *      SoC reset countdown).
 *   2. Bumps SWD_PET_COUNT for /status telemetry.
 *   3. Re-arms itself for now+PET_PERIOD.
 *
 * If timer_check stops running for any reason — main loop hung,
 * timer pool corrupted, exception loop — this callback won't
 * fire, PM_WDOG won't refresh, and the SoC resets within
 * TIMEOUT_UNITS / 65536 seconds. That's the design intent.
 *
 * x0: context = state pointer (set when timer_set was called)
 * Clobbers: x0-x6, x19, x30.
 */
sys_watchdog_pet_cb:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    mov     x29, sp
    mov     x19, x0                     /* x19 = state ptr */

    /* Pet PM_WDOG — refresh the countdown. Use ldr/orr for the
     * password merge (see sys_watchdog_arm for why movk is wrong
     * with this timeout encoding). */
    ldr     x1, [x19, #SWD_PM_BASE]
    ldr     w2, [x19, #SWD_TIMEOUT_UNITS]
    ldr     w4, =PM_PASSWORD
    orr     w2, w2, w4
    str     w2, [x1, #PM_WDOG]
    dsb     sy

    /* Bookkeeping (testable helper). */
    mov     x0, x19
    bl      sys_watchdog_record_pet

    /* Re-arm self for next tick. */
    bl      timer_now
    ldr     x6, [x19, #SWD_PET_PERIOD]
    add     x1, x0, x6                  /* x1 = expiry */
    ldr     x0, [x19, #SWD_TIMER_POOL]
    ldr     x2, =sys_watchdog_pet_cb
    mov     x3, x19                     /* x3 = ctx */
    bl      timer_set
    /* If timer_set returns -1 (pool full), we lose periodic pets
     * and the watchdog will fire on this iteration. That's the
     * correct behavior under pool exhaustion — degraded state
     * should reboot rather than mask the underlying problem. */

    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

.section .rodata
swd_arm_fail_msg:
    .asciz "swd: arm failed — timer pool full, watchdog will fire\n"

.section .bss
.balign 8
sys_watchdog_state:
    .space  SWD_SIZE
