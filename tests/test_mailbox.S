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

/* 16-byte aligned mailbox buffer in .data */
.section .data
.balign 16
mbox_buf:
    .space 32

.section .rodata
name_mbox_call:       .asciz "mbox_get_board_rev"
name_mbox_call_fail:  .asciz "mbox_call_returned_error"
name_mbox_resp_fail:  .asciz "mbox_tag_response_bit_not_set"
