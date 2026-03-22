/* USB descriptor field offsets and constants for parsing */

/* Configuration descriptor field offsets */
.equ USB_CFG_BLENGTH,          0       /* u8  */
.equ USB_CFG_BDESCTYPE,        1       /* u8  — always 2 */
.equ USB_CFG_WTOTALLENGTH,     2       /* u16 LE */
.equ USB_CFG_BNUMINTERFACES,   4       /* u8  */
.equ USB_CFG_BCFGVALUE,        5       /* u8  */
.equ USB_CFG_SIZE,             9

/* Endpoint descriptor field offsets */
.equ USB_EP_BLENGTH,           0       /* u8  */
.equ USB_EP_BDESCTYPE,         1       /* u8  — always 5 */
.equ USB_EP_BEPADDRESS,        2       /* u8  */
.equ USB_EP_BMATTRIBUTES,      3       /* u8  */
.equ USB_EP_WMAXPACKETSIZE,    4       /* u16 LE */
.equ USB_EP_SIZE,              7

/* bmAttributes transfer type mask and values */
.equ USB_EP_XFER_MASK,        0x03
.equ USB_EP_XFER_BULK,        2

/* bEndpointAddress direction bit */
.equ USB_EP_DIR_IN,            0x80

/* Result struct offsets from usb_parse_bulk_eps */
.equ BULKEP_IN_ADDR,          0       /* u8: e.g. 0x83 */
.equ BULKEP_OUT_ADDR,         1       /* u8: e.g. 0x02 */
.equ BULKEP_IN_MPS,           2       /* u16 LE */
.equ BULKEP_OUT_MPS,          4       /* u16 LE */
.equ BULKEP_SIZE,             6
