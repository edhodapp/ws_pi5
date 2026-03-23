/*
 * test_gpio.S — GPIO function select tests
 *
 * 5 tests verifying pin function configuration using fake register blocks:
 *   pin 4 ALT4, pin 5 ALT4, pin 14 OUTPUT, no-clobber, pin 0 INPUT.
 */

.include "gpio.inc"

.section .text

/* Zero the fake GPIO register block */
zero_fake_gpio:
    ldr     x0, =fake_gpio_regs
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    ret

/* =======================================================================
 * Test 1: GPIO 4 set to ALT4 — GPFSEL0 bits [14:12] = 3
 * ======================================================================= */
.global test_gpio_pin4_alt4
test_gpio_pin4_alt4:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_gpio

    ldr     x0, =fake_gpio_regs
    mov     w1, #4
    mov     w2, #GPIO_FSEL_ALT4
    bl      gpio_set_function

    /* Verify GPFSEL0 bits [14:12] = 3 (ALT4) */
    ldr     x0, =fake_gpio_regs
    ldr     w1, [x0]
    ubfx    w1, w1, #12, #3
    cmp     w1, #GPIO_FSEL_ALT4
    b.ne    .Lfail_pin4

    ldr     x0, =name_pin4_alt4
    bl      test_pass
    b       .Ldone_pin4
.Lfail_pin4:
    ldr     x0, =name_pin4_alt4
    bl      test_fail
.Ldone_pin4:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 2: GPIO 5 set to ALT4 — GPFSEL0 bits [17:15] = 3
 * ======================================================================= */
.global test_gpio_pin5_alt4
test_gpio_pin5_alt4:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_gpio

    ldr     x0, =fake_gpio_regs
    mov     w1, #5
    mov     w2, #GPIO_FSEL_ALT4
    bl      gpio_set_function

    /* Verify GPFSEL0 bits [17:15] = 3 */
    ldr     x0, =fake_gpio_regs
    ldr     w1, [x0]
    ubfx    w1, w1, #15, #3
    cmp     w1, #GPIO_FSEL_ALT4
    b.ne    .Lfail_pin5

    ldr     x0, =name_pin5_alt4
    bl      test_pass
    b       .Ldone_pin5
.Lfail_pin5:
    ldr     x0, =name_pin5_alt4
    bl      test_fail
.Ldone_pin5:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 3: GPIO 14 set to OUTPUT — GPFSEL1 bits [14:12] = 1
 * ======================================================================= */
.global test_gpio_pin14_output
test_gpio_pin14_output:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_gpio

    ldr     x0, =fake_gpio_regs
    mov     w1, #14
    mov     w2, #GPIO_FSEL_OUTPUT
    bl      gpio_set_function

    /* GPIO 14: pin/10=1 → GPFSEL1, pin%10=4 → bits [14:12] */
    ldr     x0, =fake_gpio_regs
    ldr     w1, [x0, #4]           /* GPFSEL1 */
    ubfx    w1, w1, #12, #3
    cmp     w1, #GPIO_FSEL_OUTPUT
    b.ne    .Lfail_pin14

    ldr     x0, =name_pin14_output
    bl      test_pass
    b       .Ldone_pin14
.Lfail_pin14:
    ldr     x0, =name_pin14_output
    bl      test_fail
.Ldone_pin14:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 4: No clobber — setting pin 4 doesn't change pin 5 (and vice versa)
 * ======================================================================= */
.global test_gpio_no_clobber
test_gpio_no_clobber:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_gpio

    /* Set pin 5 to ALT4 first */
    ldr     x0, =fake_gpio_regs
    mov     w1, #5
    mov     w2, #GPIO_FSEL_ALT4
    bl      gpio_set_function

    /* Now set pin 4 to ALT4 — pin 5 should be preserved */
    ldr     x0, =fake_gpio_regs
    mov     w1, #4
    mov     w2, #GPIO_FSEL_ALT4
    bl      gpio_set_function

    /* Verify both pins are set correctly */
    ldr     x0, =fake_gpio_regs
    ldr     w1, [x0]

    /* Pin 4: bits [14:12] = 3 */
    ubfx    w2, w1, #12, #3
    cmp     w2, #GPIO_FSEL_ALT4
    b.ne    .Lfail_noclobber

    /* Pin 5: bits [17:15] = 3 (should be preserved) */
    ubfx    w2, w1, #15, #3
    cmp     w2, #GPIO_FSEL_ALT4
    b.ne    .Lfail_noclobber

    ldr     x0, =name_no_clobber
    bl      test_pass
    b       .Ldone_noclobber
.Lfail_noclobber:
    ldr     x0, =name_no_clobber
    bl      test_fail
.Ldone_noclobber:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 5: GPIO 0 set to INPUT — GPFSEL0 bits [2:0] = 0
 * ======================================================================= */
.global test_gpio_pin0_input
test_gpio_pin0_input:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_gpio

    /* Pre-set GPFSEL0 to all 1s so we can verify clearing */
    ldr     x0, =fake_gpio_regs
    mov     w1, #-1
    str     w1, [x0]

    ldr     x0, =fake_gpio_regs
    mov     w1, #0
    mov     w2, #GPIO_FSEL_INPUT
    bl      gpio_set_function

    /* Verify bits [2:0] = 0 (INPUT), rest unchanged */
    ldr     x0, =fake_gpio_regs
    ldr     w1, [x0]
    ubfx    w2, w1, #0, #3
    cbnz    w2, .Lfail_pin0

    /* Verify other bits were NOT cleared (bits [31:3] still all 1s) */
    lsr     w2, w1, #3
    ldr     w3, =0x1FFFFFFF        /* 29 bits of 1s */
    cmp     w2, w3
    b.ne    .Lfail_pin0

    ldr     x0, =name_pin0_input
    bl      test_pass
    b       .Ldone_pin0
.Lfail_pin0:
    ldr     x0, =name_pin0_input
    bl      test_fail
.Ldone_pin0:
    ldp     x29, x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * BSS
 * ----------------------------------------------------------------------- */
.section .bss
.balign 8
fake_gpio_regs:
    .space GPIO_FAKE_SIZE

/* -----------------------------------------------------------------------
 * Test name strings
 * ----------------------------------------------------------------------- */
.section .rodata
name_pin4_alt4:     .asciz "gpio_pin4_alt4"
name_pin5_alt4:     .asciz "gpio_pin5_alt4"
name_pin14_output:  .asciz "gpio_pin14_output"
name_no_clobber:    .asciz "gpio_no_clobber"
name_pin0_input:    .asciz "gpio_pin0_input"
