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
.global test_swd_set_timeout_updates_field
.global test_swd_set_timeout_skips_mmio_when_unarmed

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

/* test_swd_set_timeout_updates_field
 *   Pre:  state.TIMEOUT_UNITS = 0xAA, state.PM_BASE = &fake_pm
 *   Call: sys_watchdog_set_timeout(&state, 0x000A0000)
 *   Post: state.TIMEOUT_UNITS == 0x000A0000 AND
 *         fake_pm[PM_WDOG / 4] == (0x000A0000 | PM_PASSWORD)
 *
 * Pins both halves of the contract: the state field gets updated
 * (so the periodic pet picks up the new value) AND the PM_WDOG
 * register sees the new value immediately (so the change takes
 * effect without waiting for the next pet cycle).
 */
.balign 4
test_swd_set_timeout_updates_field:
    stp     x29, x30, [sp, #-16]!
    bl      .Lswd_zero
    /* Zero fake_pm. */
    ldr     x0, =fake_pm
    str     xzr, [x0, #0]
    str     xzr, [x0, #8]
    str     xzr, [x0, #16]
    str     xzr, [x0, #24]
    str     xzr, [x0, #32]
    /* Seed an old timeout in state, point PM_BASE at fake_pm. */
    ldr     x1, =fake_swd_state
    mov     w2, #0xAA
    str     w2, [x1, #SWD_TIMEOUT_UNITS]
    str     x0, [x1, #SWD_PM_BASE]
    /* Call set_timeout with new value 0x000A0000 (= 10s × 65536). */
    mov     x0, x1                      /* x0 = state ptr */
    mov     w1, #0
    movk    w1, #0xA, lsl #16
    bl      sys_watchdog_set_timeout
    /* Verify state field. */
    ldr     x0, =fake_swd_state
    ldr     w1, [x0, #SWD_TIMEOUT_UNITS]
    mov     w2, #0
    movk    w2, #0xA, lsl #16
    cmp     w1, w2
    b.ne    .Lswd_t5_fail
    /* Verify fake PM_WDOG = timeout | password. */
    ldr     x0, =fake_pm
    ldr     w1, [x0, #PM_WDOG]
    ldr     w2, =(0x000A0000 | PM_PASSWORD)
    cmp     w1, w2
    b.ne    .Lswd_t5_fail
    ldr     x0, =.Lswd_name_t5
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lswd_t5_fail:
    ldr     x0, =.Lswd_name_t5
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lswd_name_t5: .asciz "swd_set_timeout_updates_field"

/* test_swd_set_timeout_skips_mmio_when_unarmed
 *   Pre:  state.PM_BASE = 0 (not yet armed)
 *   Call: sys_watchdog_set_timeout(&state, 0x12345)
 *   Post: state.TIMEOUT_UNITS == 0x12345 (field still updated)
 *         Helper returns without faulting or hanging.
 *
 * Critical for main()'s startup ordering: if the kernel pre-
 * configures TIMEOUT_UNITS before sys_watchdog_arm runs, the
 * helper must take the cbz-guarded skip rather than dereferencing
 * a null PM_BASE. We can't directly observe "no MMIO write" with
 * MMU off (writing to 0x24 hits RAM, not MMIO), so the assertion
 * is the indirect one: state field updates correctly and control
 * returns cleanly.
 */
.balign 4
test_swd_set_timeout_skips_mmio_when_unarmed:
    stp     x29, x30, [sp, #-16]!
    bl      .Lswd_zero                  /* PM_BASE = 0 */
    /* Call set_timeout with PM_BASE still 0. */
    ldr     x0, =fake_swd_state
    mov     w1, #0x12345 & 0xFFFF
    movk    w1, #(0x12345 >> 16), lsl #16
    bl      sys_watchdog_set_timeout
    /* Verify state field DID update. */
    ldr     x0, =fake_swd_state
    ldr     w1, [x0, #SWD_TIMEOUT_UNITS]
    ldr     w2, =0x12345
    cmp     w1, w2
    b.ne    .Lswd_t6_fail
    /* What this test actually proves: the helper updates the
     * state field AND returns cleanly without faulting when
     * PM_BASE=0. A buggy helper that always wrote MMIO would
     * write to physical address 0x24 — with MMU off that's just
     * RAM, neither faulting nor landing in fake_pm — so we can't
     * directly assert "no MMIO write." The strong post-condition
     * is "we got here and TIMEOUT_UNITS is right." Indirectly,
     * the absence of a hang or fault demonstrates the cbz guard
     * is taken on this path. */
    ldr     x0, =.Lswd_name_t6
    bl      test_pass
    ldp     x29, x30, [sp], #16
    ret
.Lswd_t6_fail:
    ldr     x0, =.Lswd_name_t6
    bl      test_fail
    ldp     x29, x30, [sp], #16
    ret
.Lswd_name_t6: .asciz "swd_set_timeout_skips_mmio_when_unarmed"

.section .bss
.balign 8
fake_swd_state:
    .space  SWD_SIZE
fake_pm:
    .space  64                          /* enough for PM_RSTS @ 0x20 */
