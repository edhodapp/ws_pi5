/*
 * test_mailbox - Test VideoCore mailbox round-trip using "get board revision"
 *
 * Sends a property tag request (TAG_GET_BOARD_REV = 0x00010002) through the
 * mailbox. This is a read-only query with no side effects. We verify:
 *   1. mbox_call returns 0 (success)
 *   2. The tag response bit (bit 31) is set in the tag's value-length field
 */

.include "mailbox.inc"

.global test_mailbox
.global test_mbox_response_fail

.section .text

test_mailbox:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    /* Prepare the property tag buffer in .data (already 16-byte aligned) */
    ldr     x0, =mbox_buf

    /* Buffer header */
    mov     w1, #32                /* Total buffer size: 32 bytes */
    str     w1, [x0, #0]          /* buf[0] = size */
    mov     w1, #MBOX_REQUEST
    str     w1, [x0, #4]          /* buf[1] = request code */

    /* Tag: get board revision */
    ldr     w1, =TAG_GET_BOARD_REV
    str     w1, [x0, #8]          /* buf[2] = tag id */
    mov     w1, #4
    str     w1, [x0, #12]         /* buf[3] = value buffer size (4 bytes) */
    str     wzr, [x0, #16]        /* buf[4] = request/response code (0 = request) */
    str     wzr, [x0, #20]        /* buf[5] = value (0, filled by VC on response) */

    /* End tag */
    str     wzr, [x0, #24]        /* buf[6] = MBOX_TAG_LAST */

    /* Call mailbox on property channel */
    mov     w1, #MBOX_CH_PROP
    ldr     x2, =MBOX_BASE
    bl      mbox_call

    /* Test 1: mbox_call returned success (w0 == 0) */
    cbnz    w0, .Lfail_call

    /* Test 2: Tag response bit set in value-length word (offset 16) */
    ldr     x1, =mbox_buf
    ldr     w1, [x1, #16]         /* tag value-length field */
    tbz     w1, #31, .Lfail_response

    ldr     x0, =name_mbox_call
    bl      test_pass
    b       .Ldone

.Lfail_call:
    ldr     x0, =name_mbox_call_fail
    bl      test_fail
    b       .Ldone

.Lfail_response:
    ldr     x0, =name_mbox_resp_fail
    bl      test_fail

.Ldone:
    ldp     x29, x30, [sp], #16
    ret

/*
 * test_mbox_response_fail - Verify mbox_call returns 1 when response lacks bit 31
 *
 * Uses a fake mailbox register block in RAM:
 *   - STATUS (offset 0x18) = 0 (not full, not empty)
 *   - READ (offset 0x00) = buf_addr | channel
 * The tag buffer's response code at [buf+4] is left as 0 (no success bit).
 * Expects mbox_call to return 1 (failure).
 */
test_mbox_response_fail:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    /* Zero the fake mbox register block (0x24 bytes covers READ..WRITE) */
    ldr     x0, =fake_mbox_regs
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    str     xzr, [x0, #32]

    /* Set up tag buffer: leave [buf+4] = 0 (no response bit) */
    ldr     x3, =mbox_fail_buf
    mov     w1, #32
    str     w1, [x3]                /* buffer size */
    str     wzr, [x3, #4]          /* response code = 0 (no bit 31) */

    /* Pre-store READ value: buf_addr | channel */
    mov     w1, #MBOX_CH_PROP
    orr     x1, x3, x1
    ldr     x0, =fake_mbox_regs
    str     w1, [x0, #MBOX_READ]

    /* Call mbox_call(buf, channel, fake_mbox_base) */
    mov     x0, x3
    mov     w1, #MBOX_CH_PROP
    ldr     x2, =fake_mbox_regs
    bl      mbox_call

    /* Expect w0 == 1 (failure) */
    cmp     w0, #1
    b.ne    .Lfail_resp

    ldr     x0, =name_mbox_resp_fail_test
    bl      test_pass
    b       .Ldone_resp

.Lfail_resp:
    ldr     x0, =name_mbox_resp_fail_bad
    bl      test_fail

.Ldone_resp:
    ldp     x29, x30, [sp], #16
    ret

/* 16-byte aligned mailbox buffer in .data */
.section .data
.balign 16
mbox_buf:
    .space 32

.balign 16
mbox_fail_buf:
    .space 32

/* Fake mailbox register block — needs 0x24 bytes (READ at 0x00, STATUS at 0x18, WRITE at 0x20) */
.section .bss
.balign 8
fake_mbox_regs:
    .space 0x28

.section .rodata
name_mbox_call:            .asciz "mbox_get_board_rev"
name_mbox_call_fail:       .asciz "mbox_call_returned_error"
name_mbox_resp_fail:       .asciz "mbox_tag_response_bit_not_set"
name_mbox_resp_fail_test:  .asciz "mbox_response_fail"
name_mbox_resp_fail_bad:   .asciz "mbox_response_fail_expected_error"
