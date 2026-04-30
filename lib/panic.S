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
 * use `bl` to subroutines. Each panic_* function uses x9..x14 as
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
.equ _ACT_FSEL_SHIFT,   6
.equ _ACT_FSEL_MASK,    (7 << 6)        /* 0x1C0 — clear all 3 fsel bits */
.equ _ACT_FSEL_OUT,     (1 << 6)        /* 0x040 — fsel=001 = output */

/* Element timing per docs/PANIC_PATTERNS.md. */
.equ _DIT_MS,           200
.equ _DAH_MS,           600
.equ _GAP_MS,           200
.equ _CYCLE_GAP_MS,     3000

/* PANIC_SETUP: configure GPIO 42 as output (RMW so we don't disturb
 * other pins controlled by GPFSEL4). Idempotent — re-running on a
 * pin already configured as output is a no-op store-back. */
.macro PANIC_SETUP
    ldr     x9, =_GPFSEL4
    ldr     w10, [x9]
    /* Clear pin 42's three fsel bits, then set them to OUT. */
    mov     w11, #_ACT_FSEL_MASK
    bic     w10, w10, w11
    mov     w11, #_ACT_FSEL_OUT
    orr     w10, w10, w11
    str     w10, [x9]
.endm

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
 * writing 1 sets/clears the corresponding pin, writing 0 is no-op). */
.macro LED_ON
    ldr     x9, =_GPSET1
    mov     w10, #_ACT_BIT
    str     w10, [x9]
.endm

.macro LED_OFF
    ldr     x9, =_GPCLR1
    mov     w10, #_ACT_BIT
    str     w10, [x9]
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
    DAH
    DIT
    CYCLE_GAP
    b       .Lpan_n

panic_g:                            /* ——· (Gateway unreachable) */
    PANIC_SETUP
.Lpan_g:
    DAH
    DAH
    DIT
    CYCLE_GAP
    b       .Lpan_g

panic_i:                            /* ·· (Init failed) */
    PANIC_SETUP
.Lpan_i:
    DIT
    DIT
    CYCLE_GAP
    b       .Lpan_i

panic_m:                            /* —— (MAC unreadable) */
    PANIC_SETUP
.Lpan_m:
    DAH
    DAH
    CYCLE_GAP
    b       .Lpan_m

panic_k:                            /* —·— (Kernel panic) */
    PANIC_SETUP
.Lpan_k:
    DAH
    DIT
    DAH
    CYCLE_GAP
    b       .Lpan_k

panic_u:                            /* ··— (Unknown / catch-all) */
    PANIC_SETUP
.Lpan_u:
    DIT
    DIT
    DAH
    CYCLE_GAP
    b       .Lpan_u
