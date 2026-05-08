/*
 * lib/panic.S — Panic blink driver per D013 (six-pattern catalog).
 *
 * Six entry points: panic_n / panic_g / panic_i / panic_m / panic_k /
 * panic_u. Each enters an infinite loop blinking the corresponding
 * Morse pattern on the Pi 4 ACT LED (GPIO 42), waiting 3 s between
 * cycles. UART is the primary diagnostic channel; the LED is the
 * backup for users without a serial cable.
 *
 * Visual specification (timing, pulse counts) lives in
 * docs/PANIC_PATTERNS.md. The code letters and meanings are
 * normative in DECISIONS.md D013.
 *
 * Stack-free by design: every primitive is a GAS macro expanded
 * inline. After a fatal error the stack may be corrupt, so we don't
 * use `bl` to subroutines. Each panic_* function uses x9..x13 as
 * scratch and never returns. Running on QEMU (Pi 3) executes the
 * same instruction sequence — there's no visible LED in QEMU's
 * raspi3b model but the GPIO writes are harmless.
 *
 * Timing comes from CNTPCT_EL0 (the architectural cycle counter,
 * enabled for EL1 in boot.S via CNTHCTL_EL2). CNTFRQ_EL0 reports
 * the counter's tick rate (~19.2 MHz on Pi 3/4); we convert ms
 * to ticks at runtime so the same code is correct on either
 * platform without recalibration.
 */

.include "platform.inc"

.global panic_n
.global panic_g
.global panic_i
.global panic_m
.global panic_k
.global panic_u

/* GPIO peripheral layout — see BCM2711 ARM Peripherals §5.2.
 * GPFSEL4 controls pins 40-49 (3 fsel bits per pin); pin 42 is at
 * bits [8:6]. GPSET1/GPCLR1 control pins 32-53 (one bit per pin);
 * pin 42 is bit 10 (= 42 - 32). */
.equ _GPIO_BASE,        PERIPH_BASE + 0x200000
.equ _GPFSEL4,          _GPIO_BASE + 0x10
.equ _GPSET1,           _GPIO_BASE + 0x20
.equ _GPCLR1,           _GPIO_BASE + 0x2C
.equ _ACT_BIT,          (1 << 10)
.equ _ACT_FSEL_MASK,    (7 << 6)        /* 0x1C0 — clear all 3 fsel bits */
.equ _ACT_FSEL_OUT,     (1 << 6)        /* 0x040 — fsel=001 = output */

/* Element timing per docs/PANIC_PATTERNS.md. */
.equ _DIT_MS,           200
.equ _DAH_MS,           600
.equ _GAP_MS,           200
.equ _CYCLE_GAP_MS,     3000

/* PANIC_SETUP: configure GPIO 42 as output (RMW so we don't disturb
 * other pins controlled by GPFSEL4). Idempotent — re-running on a
 * pin already configured as output is a no-op store-back. The
 * trailing `dsb sy` ensures the fsel write is observable before
 * any subsequent GPIO operation; on AArch64 Device-memory writes
 * are not ordered with later instructions otherwise. */
.macro PANIC_SETUP
    ldr     x9, =_GPFSEL4
    ldr     w10, [x9]
    /* Clear pin 42's three fsel bits, then set them to OUT. */
    mov     w11, #_ACT_FSEL_MASK
    bic     w10, w10, w11
    mov     w11, #_ACT_FSEL_OUT
    orr     w10, w10, w11
    str     w10, [x9]
    dsb     sy
.endm

/* PANIC_PET_WATCHDOG: refresh PM_WDOG inside the panic blink loop
 * so the watchdog never expires while the LED is still telling
 * the user what's wrong. Called once per blink cycle (right after
 * the loop label). Without this, a panic that fires after
 * sys_watchdog_arm has run in main() would only blink for ~10 s
 * before the SoC resets, defeating the purpose of the diagnostic
 * LED.
 *
 * Feed-in-loop, not one-shot disarm: if the panic-blink loop
 * itself wedges — corrupt page table that crashes the LED writes,
 * exception in DELAY_MS, etc. — the watchdog still gets to do its
 * job. PM_WDOG stops being refreshed and the SoC resets within
 * the pet timeout. A once-and-done disarm would forfeit that
 * safety net.
 *
 * Pet timeout: 10 s. Each blink cycle is at most ~5 s (3 elements
 * × 800 ms + 3 s CYCLE_GAP), so 10 s gives ~2× margin for normal
 * progress and detects a wedged loop within one cycle.
 *
 * Pre-arm safe: if a panic fires before sys_watchdog_arm runs,
 * PM_RSTC's WRCFG_FULL_RESET isn't set, so writing PM_WDOG just
 * sets the countdown without enabling reset — harmless.
 *
 * Macro form, NOT a bl to sys_watchdog_pet_cb — panic.S is
 * stack-free by design (the stack may be corrupt by the time we
 * panic). All work uses x9..x10 only.
 *
 * Pi 4 only — QEMU/raspi3b doesn't model the PM block. The
 * .ifdef guard expands to an empty macro on QEMU builds so the
 * panic path stays platform-independent at the source level. */
.ifdef PLATFORM_PI4
.macro PANIC_PET_WATCHDOG
    ldr     x9, =(PERIPH_BASE + PM_OFFSET)
    /* 10 s timeout (0x000A0000) | PM_PASSWORD (0x5A000000) =
     * 0x5A0A0000. Literal-OR-equ resolves at assembly time and
     * lands in the literal pool; only the .equ-OR-.equ form is
     * forbidden by GAS (see CLAUDE.md gotcha). */
    ldr     w10, =(0x000A0000 | PM_PASSWORD)
    str     w10, [x9, #PM_WDOG]
    dsb     sy
.endm
.else
.macro PANIC_PET_WATCHDOG
.endm
.endif

/* DELAY_MS \ms — busy-wait \ms milliseconds using CNTPCT_EL0.
 * Computes target ticks = (CNTFRQ_EL0 * ms) / 1000 at runtime,
 * adds to current counter, spins until current >= deadline. */
.macro DELAY_MS ms
    mrs     x12, CNTFRQ_EL0
    mov     x13, #(\ms)
    mul     x12, x12, x13
    mov     x13, #1000
    udiv    x12, x12, x13           /* x12 = ticks for \ms */
    mrs     x13, CNTPCT_EL0
    add     x12, x12, x13           /* x12 = deadline */
1099:
    mrs     x13, CNTPCT_EL0
    cmp     x13, x12
    b.lo    1099b
.endm

/* LED_ON / LED_OFF — single-write (GPSET1/GPCLR1 are write-only;
 * writing 1 sets/clears the corresponding pin, writing 0 is no-op).
 * `dsb sy` after the write ensures the LED transition is observable
 * before the timing loop begins, so each blink's perceived width
 * matches the spec'd ms count rather than starting some Device-write
 * latency in the past. */
.macro LED_ON
    ldr     x9, =_GPSET1
    mov     w10, #_ACT_BIT
    str     w10, [x9]
    dsb     sy
.endm

.macro LED_OFF
    ldr     x9, =_GPCLR1
    mov     w10, #_ACT_BIT
    str     w10, [x9]
    dsb     sy
.endm

.macro DIT
    LED_ON
    DELAY_MS _DIT_MS
    LED_OFF
    DELAY_MS _GAP_MS
.endm

.macro DAH
    LED_ON
    DELAY_MS _DAH_MS
    LED_OFF
    DELAY_MS _GAP_MS
.endm

/* CYCLE_GAP — 3-second pause between repeats. The trailing
 * intra-letter GAP_MS from the last DIT/DAH plus this pause give
 * a clear "letter ended" boundary the eye can register. */
.macro CYCLE_GAP
    DELAY_MS _CYCLE_GAP_MS
.endm

/* --- Entry points: one per code letter. Each loops forever. --- */

.section .text

panic_n:                            /* —· (Network conf invalid) */
    PANIC_SETUP
.Lpan_n:
    PANIC_PET_WATCHDOG
    DAH
    DIT
    CYCLE_GAP
    b       .Lpan_n

panic_g:                            /* ——· (Gateway unreachable) */
    PANIC_SETUP
.Lpan_g:
    PANIC_PET_WATCHDOG
    DAH
    DAH
    DIT
    CYCLE_GAP
    b       .Lpan_g

panic_i:                            /* ·· (Init failed) */
    PANIC_SETUP
.Lpan_i:
    PANIC_PET_WATCHDOG
    DIT
    DIT
    CYCLE_GAP
    b       .Lpan_i

panic_m:                            /* —— (MAC unreadable) */
    PANIC_SETUP
.Lpan_m:
    PANIC_PET_WATCHDOG
    DAH
    DAH
    CYCLE_GAP
    b       .Lpan_m

panic_k:                            /* —·— (Kernel panic) */
    PANIC_SETUP
.Lpan_k:
    PANIC_PET_WATCHDOG
    DAH
    DIT
    DAH
    CYCLE_GAP
    b       .Lpan_k

panic_u:                            /* ··— (Unknown / catch-all) */
    PANIC_SETUP
.Lpan_u:
    PANIC_PET_WATCHDOG
    DIT
    DIT
    DAH
    CYCLE_GAP
    b       .Lpan_u
