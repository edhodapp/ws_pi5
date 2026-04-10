/*
 * test_func_main.S — Boot stub for functional test kernel
 *
 * Same pattern as test_main.S: core 0 only, stack, BSS zero, uart_init.
 * Runs functional tests and prints summary.
 */

.section .text._start

.global _start
.global test_count
.global fail_count

_start:
    /* Only let core 0 proceed */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    /* Drop from EL2 to EL1 if needed */
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    .Lel1_ready

    mrs     x0, HCR_EL2
    orr     x0, x0, #(1 << 31)
    msr     HCR_EL2, x0
    mov     x0, #3
    msr     CNTHCTL_EL2, x0
    msr     CNTVOFF_EL2, xzr
    mov     x0, #0x33FF
    msr     CPTR_EL2, x0
    mov     x0, #0x3C5
    msr     SPSR_EL2, x0
    adr     x0, .Lel1_ready
    msr     ELR_EL2, x0
    eret

.Lel1_ready:
    /* Set up stack */
    ldr     x0, =_stack_top
    mov     sp, x0

    /* Zero BSS */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.ge    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    /* --- MMU setup: identity map, Normal RAM + Device peripherals --- */
    mov     x0, #0xFF
    msr     MAIR_EL1, x0

    ldr     x0, =0x80803520
    msr     TCR_EL1, x0

    ldr     x0, =__mmu_l1_table
    ldr     x1, =__mmu_l2_table
    orr     x1, x1, #0x3
    str     x1, [x0]

    ldr     x0, =__mmu_l2_table
    mov     x1, #0
    mov     x2, #0x701
    mov     x3, #0x405
    mov     w4, #0

.Lfill_normal:
    orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #504
    b.lt    .Lfill_normal

.Lfill_device:
    orr     x5, x1, x3
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #512
    b.lt    .Lfill_device

    ldr     x0, =__mmu_l1_table
    msr     TTBR0_EL1, x0
    isb

    mrs     x0, SCTLR_EL1
    orr     x0, x0, #(1 << 0)
    orr     x0, x0, #(1 << 2)
    orr     x0, x0, #(1 << 12)
    msr     SCTLR_EL1, x0
    isb

    bl      uart_init

    ldr     x0, =msg_func_start
    bl      uart_puts

    bl      test_tcp_functional
    bl      test_tcp_func_handcrafted
    bl      test_reasm_functional

    /* Print summary */
    ldr     x0, =fail_count
    ldr     w0, [x0]
    cbnz    w0, .Ltests_failed

    ldr     x0, =msg_all_passed
    bl      uart_puts
    b       .Ldone

.Ltests_failed:
    ldr     x0, =msg_tests_failed
    bl      uart_puts

.Ldone:
.Lpark:
    wfe
    b       .Lpark

/*
 * test_pass - Record a passing test and print result
 * x0: pointer to test name string
 */
.global test_pass
test_pass:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0

    ldr     x0, =test_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    ldr     x0, =msg_pass
    bl      uart_puts
    mov     x0, x19
    bl      uart_puts
    ldr     x0, =msg_newline
    bl      uart_puts

    ldp     x19, x30, [sp], #16
    ret

/*
 * test_fail - Record a failing test and print result
 * x0: pointer to test name string
 */
.global test_fail
test_fail:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0

    ldr     x0, =test_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    ldr     x0, =fail_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    ldr     x0, =msg_fail
    bl      uart_puts
    mov     x0, x19
    bl      uart_puts
    ldr     x0, =msg_newline
    bl      uart_puts

    ldp     x19, x30, [sp], #16
    ret

.section .data
test_count:     .word 0
fail_count:     .word 0

.section .rodata
msg_func_start:  .asciz "=== Running functional tests ===\r\n"
msg_pass:        .asciz "PASS: "
msg_fail:        .asciz "FAIL: "
msg_newline:     .asciz "\r\n"
msg_all_passed:  .asciz "ALL TESTS PASSED\r\n"
msg_tests_failed: .asciz "TESTS FAILED\r\n"
