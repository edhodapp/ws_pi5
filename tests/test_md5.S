/*
 * test_md5.S — MD5 known-answer tests (RFC 1321 test vectors)
 *
 * Tests:
 *   1. test_md5_abc    — MD5("abc") = 900150983cd24fb0d6963f7d28e17f72
 *   2. test_md5_empty  — MD5("") = d41d8cd98f00b204e9800998ecf8427e
 */

.global test_md5

.section .text

test_md5:
    stp     x29, x30, [sp, #-16]!
    bl      test_md5_abc
    bl      test_md5_empty
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_md5_abc — MD5("abc")
 * ======================================================================== */
test_md5_abc:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =md5_input_abc
    mov     w1, #3
    ldr     x2, =md5_result_buf
    bl      md5_hash

    /* Compare 16 bytes */
    ldr     x0, =md5_result_buf
    ldr     x1, =md5_expected_abc
    ldp     x2, x3, [x0]
    ldp     x4, x5, [x1]
    cmp     x2, x4
    b.ne    .Lfail_md5_abc
    cmp     x3, x5
    b.ne    .Lfail_md5_abc

    ldr     x0, =name_md5_abc
    bl      test_pass
    b       .Ldone_md5_abc
.Lfail_md5_abc:
    ldr     x0, =name_md5_abc
    bl      test_fail
.Ldone_md5_abc:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_md5_empty — MD5("")
 * ======================================================================== */
test_md5_empty:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =md5_result_buf      /* dummy input ptr, length=0 */
    mov     w1, #0
    ldr     x2, =md5_result_buf
    bl      md5_hash

    ldr     x0, =md5_result_buf
    ldr     x1, =md5_expected_empty
    ldp     x2, x3, [x0]
    ldp     x4, x5, [x1]
    cmp     x2, x4
    b.ne    .Lfail_md5_empty
    cmp     x3, x5
    b.ne    .Lfail_md5_empty

    ldr     x0, =name_md5_empty
    bl      test_pass
    b       .Ldone_md5_empty
.Lfail_md5_empty:
    ldr     x0, =name_md5_empty
    bl      test_fail
.Ldone_md5_empty:
    ldp     x29, x30, [sp], #16
    ret

/* ---- Test data ---- */
.section .rodata
.balign 4
md5_input_abc:
    .byte   0x61, 0x62, 0x63        /* "abc" */

/* MD5("abc") = 900150983cd24fb0d6963f7d28e17f72 */
.balign 4
md5_expected_abc:
    .byte   0x90, 0x01, 0x50, 0x98, 0x3c, 0xd2, 0x4f, 0xb0
    .byte   0xd6, 0x96, 0x3f, 0x7d, 0x28, 0xe1, 0x7f, 0x72

/* MD5("") = d41d8cd98f00b204e9800998ecf8427e */
.balign 4
md5_expected_empty:
    .byte   0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04
    .byte   0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e

name_md5_abc:   .asciz "md5_abc"
name_md5_empty: .asciz "md5_empty"

.section .data
.balign 8
md5_result_buf:
    .space  16
