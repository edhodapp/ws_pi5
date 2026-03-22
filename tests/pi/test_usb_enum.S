/*
 * test_usb_enum - Test USB device enumeration via DWC2
 *
 * Calls dwc2_init then usb_enumerate, verifies:
 *   1. usb_enumerate returns 0 (success)
 *   2. Device descriptor bLength == 18
 *   3. Device descriptor bDescriptorType == 1 (DEVICE)
 */

.include "dwc2.inc"
.include "usb.inc"

.global test_usb_enum

.section .text

test_usb_enum:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    /* Initialize DWC2 (already tested, but needed for USB state) */
    ldr     x0, =DWC2_BASE
    bl      dwc2_init
    cbnz    w0, .Lfail_init

    /* Enumerate the USB device */
    ldr     x0, =DWC2_BASE
    ldr     x1, =enum_desc_buf
    bl      usb_enumerate
    cbnz    w0, .Lfail_enum

    /* Check bLength == 18 */
    ldr     x0, =enum_desc_buf
    ldrb    w1, [x0, #USBDEV_BLENGTH]
    cmp     w1, #USBDEV_SIZE
    b.ne    .Lfail_blength

    /* Check bDescriptorType == 1 */
    ldrb    w1, [x0, #USBDEV_BDESCTYPE]
    cmp     w1, #USB_DESC_DEVICE
    b.ne    .Lfail_bdesctype

    ldr     x0, =name_usb_enum
    bl      test_pass
    b       .Ldone

.Lfail_init:
    ldr     x0, =name_usb_enum_init
    bl      test_fail
    b       .Ldone

.Lfail_enum:
    ldr     x0, =name_usb_enum_fail
    bl      test_fail
    b       .Ldone

.Lfail_blength:
    ldr     x0, =name_usb_enum_blen
    bl      test_fail
    b       .Ldone

.Lfail_bdesctype:
    ldr     x0, =name_usb_enum_btype
    bl      test_fail

.Ldone:
    ldp     x29, x30, [sp], #16
    ret

/* Buffer for device descriptor (DMA writes here) */
.section .data
.balign 4
enum_desc_buf:
    .space  USBDEV_SIZE

.section .rodata
name_usb_enum:       .asciz "usb_enumerate"
name_usb_enum_init:  .asciz "usb_enum_dwc2_init_fail"
name_usb_enum_fail:  .asciz "usb_enum_returned_error"
name_usb_enum_blen:  .asciz "usb_enum_blength_not_18"
name_usb_enum_btype: .asciz "usb_enum_bdesctype_not_1"
