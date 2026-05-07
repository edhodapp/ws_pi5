/*
 * test_sys_watchdog.S — Unit tests for the PM watchdog driver's
 * pure-software bookkeeping.
 *
 * The PM watchdog itself is BCM2711-specific MMIO and not unit-
 * testable off-hardware. The pet-counter increment helper IS pure
 * software and was extracted into sys_watchdog_record_pet
 * specifically to be testable here.
 *
 * Tests:
 *   1. test_swd_record_pet_first_increment
 *   2. test_swd_record_pet_accumulates
 *   3. test_swd_record_pet_preserves_other_state
 */

.include "sys_watchdog.inc"
.include "platform.inc"

.global test_swd_record_pet_first_increment
.global test_swd_record_pet_accumulates
.global test_swd_record_pet_preserves_other_state
.global test_swd_capture_rsts_reads_at_offset

.section .text

/* Helper: zero the fake_swd_state block. Clobbers x0, x1. */
.Lswd_zero:
    ldr     x0, =fake_swd_state
    str     xzr, [x0, #0]
    str     xzr, [x0, #8]
    str     xzr, [x0, #16]
    str     xzr, [x0, #24]
    str     xzr, [x0, #32]
    ret

/* test_swd_record_pet_first_increment
 *   Pre:  PET_COUNT = 0
 *   Call: sys_watchdog_record_pet(&state)
 *   Post: PET_COUNT = 1
 */
.balign 4
test_swd_record_pet_first_increment:
    stp     x29, x30, [sp, #-16]!
    bl      .Lswd_zero
    ldr     x0, =fake_swd_state
    bl      sys_watchdog_record_pet
    ldr     x0, =fake_swd_state
    ldr     w0, [x0, #SWD_PET_COUNT]
    cmp     w0, #1
    b.ne    .Lswd_t1_fail
    ldr     x0, =.Lswd_name_t1
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lswd_t1_fail:
    ldr     x0, =.Lswd_name_t1
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lswd_name_t1: .asciz "swd_record_pet_first_increment"

/* test_swd_record_pet_accumulates
 *   Three pets back to back must leave PET_COUNT at 3, pinning
 *   that the counter is monotonic-since-boot rather than reset on
 *   each call.
 */
.balign 4
test_swd_record_pet_accumulates:
    stp     x29, x30, [sp, #-16]!
    bl      .Lswd_zero
    ldr     x0, =fake_swd_state
    bl      sys_watchdog_record_pet
    ldr     x0, =fake_swd_state
    bl      sys_watchdog_record_pet
    ldr     x0, =fake_swd_state
    bl      sys_watchdog_record_pet
    ldr     x0, =fake_swd_state
    ldr     w0, [x0, #SWD_PET_COUNT]
    cmp     w0, #3
    b.ne    .Lswd_t2_fail
    ldr     x0, =.Lswd_name_t2
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lswd_t2_fail:
    ldr     x0, =.Lswd_name_t2
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lswd_name_t2: .asciz "swd_record_pet_accumulates"

/* test_swd_record_pet_preserves_other_state
 *   Pre:  Sentinels in every non-PET_COUNT field
 *   Call: sys_watchdog_record_pet(&state)
 *   Post: Only PET_COUNT changed.
 *
 * Pins locality: a buggy helper that overwrote the PM_BASE pointer
 * with the new pet count, or that bumped a different field, would
 * be caught here.
 */
.balign 4
test_swd_record_pet_preserves_other_state:
    stp     x29, x30, [sp, #-16]!
    bl      .Lswd_zero
    ldr     x0, =fake_swd_state
    ldr     x1, =0x1122334455667788
    str     x1, [x0, #SWD_PM_BASE]
    mov     w1, #0xAA
    str     w1, [x0, #SWD_TIMEOUT_UNITS]
    mov     w1, #0xBB
    str     w1, [x0, #SWD_BOOT_RSTS]
    ldr     x1, =0x99AABBCCDDEEFF00
    str     x1, [x0, #SWD_TIMER_POOL]
    ldr     x1, =0xDEADBEEFCAFEBABE
    str     x1, [x0, #SWD_PET_PERIOD]
    bl      sys_watchdog_record_pet
    ldr     x0, =fake_swd_state
    /* Verify the helper actually moved PET_COUNT. */
    ldr     w1, [x0, #SWD_PET_COUNT]
    cmp     w1, #1
    b.ne    .Lswd_t3_fail
    /* Verify all other fields untouched. */
    ldr     x1, [x0, #SWD_PM_BASE]
    ldr     x2, =0x1122334455667788
    cmp     x1, x2
    b.ne    .Lswd_t3_fail
    ldr     w1, [x0, #SWD_TIMEOUT_UNITS]
    cmp     w1, #0xAA
    b.ne    .Lswd_t3_fail
    ldr     w1, [x0, #SWD_BOOT_RSTS]
    cmp     w1, #0xBB
    b.ne    .Lswd_t3_fail
    ldr     x1, [x0, #SWD_TIMER_POOL]
    ldr     x2, =0x99AABBCCDDEEFF00
    cmp     x1, x2
    b.ne    .Lswd_t3_fail
    ldr     x1, [x0, #SWD_PET_PERIOD]
    ldr     x2, =0xDEADBEEFCAFEBABE
    cmp     x1, x2
    b.ne    .Lswd_t3_fail
    ldr     x0, =.Lswd_name_t3
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lswd_t3_fail:
    ldr     x0, =.Lswd_name_t3
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lswd_name_t3: .asciz "swd_record_pet_preserves_other_state"

/* test_swd_capture_rsts_reads_at_offset
 *   Pre:  fake_pm[PM_RSTS / 4] = sentinel; state.PM_BASE = &fake_pm
 *   Call: sys_watchdog_capture_rsts(&state)
 *   Post: state.BOOT_RSTS == sentinel
 *
 * Pins the PM_BASE+PM_RSTS dependency injection: the helper reads
 * from the parameterized base address rather than a hardcoded
 * MMIO constant, which is what makes it unit-testable per the
 * project's "MMIO base addresses as parameters" rule.
 */
.balign 4
test_swd_capture_rsts_reads_at_offset:
    stp     x29, x30, [sp, #-16]!
    bl      .Lswd_zero
    /* Zero the fake_pm region too. */
    ldr     x0, =fake_pm
    str     xzr, [x0, #0]
    str     xzr, [x0, #8]
    str     xzr, [x0, #16]
    str     xzr, [x0, #24]
    str     xzr, [x0, #32]
    /* Plant a known sentinel at PM_RSTS offset (0x20). */
    mov     w1, #0xCAFE
    movk    w1, #0xBABE, lsl #16        /* w1 = 0xBABECAFE */
    str     w1, [x0, #PM_RSTS]
    /* Point fake state at fake_pm. */
    ldr     x1, =fake_swd_state
    str     x0, [x1, #SWD_PM_BASE]
    /* Run the helper. */
    mov     x0, x1                      /* x0 = state ptr */
    bl      sys_watchdog_capture_rsts
    /* Verify capture. */
    ldr     x0, =fake_swd_state
    ldr     w1, [x0, #SWD_BOOT_RSTS]
    mov     w2, #0xCAFE
    movk    w2, #0xBABE, lsl #16
    cmp     w1, w2
    b.ne    .Lswd_t4_fail
    ldr     x0, =.Lswd_name_t4
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lswd_t4_fail:
    ldr     x0, =.Lswd_name_t4
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lswd_name_t4: .asciz "swd_capture_rsts_reads_at_offset"

.section .bss
.balign 8
fake_swd_state:
    .space  SWD_SIZE
fake_pm:
    .space  64                          /* enough for PM_RSTS @ 0x20 */
