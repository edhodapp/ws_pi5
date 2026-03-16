/* VideoCore Mailbox interface for BCM2837 (Raspberry Pi 3) */

.equ MBOX_BASE,        0x3F00B880

/* Register offsets from MBOX_BASE */
.equ MBOX_READ,        0x00
.equ MBOX_STATUS,      0x18
.equ MBOX_WRITE,       0x20

/* Status register bits */
.equ MBOX_FULL,        0x80000000
.equ MBOX_EMPTY,       0x40000000

/* Channels */
.equ MBOX_CH_PROP,     8        /* Property tags (ARM → VC) */

/* Property tag request/response codes */
.equ MBOX_REQUEST,     0x00000000
.equ MBOX_RESPONSE_OK, 0x80000000
.equ MBOX_TAG_LAST,    0x00000000

/* Property tags */
.equ TAG_GET_BOARD_REV, 0x00010002
.equ TAG_SET_POWER,     0x00028001

/* Tag response bit — set in tag's status word on success */
.equ TAG_RESPONSE_BIT, 0x80000000
