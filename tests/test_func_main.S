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

    bl      uart_init

    ldr     x0, =msg_func_start
    bl      uart_puts

    bl      test_tcp_functional

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
