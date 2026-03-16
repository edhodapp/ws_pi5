/* USB standard constants for enumeration */

/* Standard Request Codes (bRequest) */
.equ USB_REQ_GET_DESCRIPTOR,    6
.equ USB_REQ_SET_ADDRESS,       5
.equ USB_REQ_SET_CONFIGURATION, 9

/* Descriptor Types (high byte of wValue) */
.equ USB_DESC_DEVICE,           1
.equ USB_DESC_CONFIGURATION,    2
.equ USB_DESC_STRING,           3
.equ USB_DESC_INTERFACE,        4
.equ USB_DESC_ENDPOINT,         5

/* bmRequestType direction bit */
.equ USB_DIR_IN,                0x80
.equ USB_DIR_OUT,               0x00

/* Device Descriptor field offsets */
.equ USBDEV_BLENGTH,           0       /* u8  — always 18 */
.equ USBDEV_BDESCTYPE,         1       /* u8  — always 1 */
.equ USBDEV_BCDUSB,            2       /* u16 */
.equ USBDEV_BDEVCLASS,         4       /* u8  */
.equ USBDEV_BDEVSUBCLASS,      5       /* u8  */
.equ USBDEV_BDEVPROTOCOL,      6       /* u8  */
.equ USBDEV_BMAXPACKETSIZE0,   7       /* u8  — EP0 max packet size */
.equ USBDEV_IDVENDOR,          8       /* u16 */
.equ USBDEV_IDPRODUCT,         10      /* u16 */
.equ USBDEV_BCDDEVICE,         12      /* u16 */
.equ USBDEV_BNUMCONFIGURATIONS,17      /* u8  */
.equ USBDEV_SIZE,              18

/* Setup Packet field offsets */
.equ SETUP_BMREQUESTTYPE,      0
.equ SETUP_BREQUEST,            1
.equ SETUP_WVALUE,              2
.equ SETUP_WINDEX,              4
.equ SETUP_WLENGTH,             6
.equ SETUP_SIZE,                8
