/*
 * test_example - A trivial test to validate the test framework
 */

.global test_example

.section .text

test_example:
    stp     x29, x30, [sp, #-16]!

    /* Test: 1 + 1 == 2 */
    mov     w0, #1
    add     w0, w0, #1
    cmp     w0, #2
    b.ne    .Lfail_add

    ldr     x0, =name_add
    bl      test_pass
    b       .Ldone

.Lfail_add:
    ldr     x0, =name_add
    bl      test_fail

.Ldone:
    ldp     x29, x30, [sp], #16
    ret

.section .rodata
name_add:   .asciz "1+1==2"
