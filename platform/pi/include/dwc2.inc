/* DWC2 USB Host Controller registers — derived from platform.inc */

.include "platform.inc"

.equ DWC2_BASE,        (PERIPH_BASE + DWC2_OFFSET)

/* Global registers (offsets from DWC2_BASE) */
.equ DWC2_GOTGCTL,     0x000       /* OTG Control */
.equ DWC2_GOTGINT,     0x004       /* OTG Interrupt */
.equ DWC2_GAHBCFG,     0x008       /* AHB Configuration */
.equ DWC2_GUSBCFG,     0x00C       /* USB Configuration */
.equ DWC2_GRSTCTL,     0x010       /* Reset Control */
.equ DWC2_GINTSTS,     0x014       /* Interrupt Status */
.equ DWC2_GINTMSK,     0x018       /* Interrupt Mask */
.equ DWC2_GRXFSIZ,     0x024       /* RX FIFO Size */
.equ DWC2_GNPTXFSIZ,   0x028       /* Non-periodic TX FIFO Size */
.equ DWC2_HPTXFSIZ,    0x100       /* Periodic TX FIFO Size */

/* Host registers */
.equ DWC2_HCFG,        0x400       /* Host Configuration */
.equ DWC2_HPRT,        0x440       /* Host Port Control/Status */

/* Power/clock gating */
.equ DWC2_PCGCCTL,     0xE00       /* Power and Clock Gating Control */

/* Host channel registers: base 0x500, stride 0x20, 8 channels */
.equ DWC2_HC_BASE,     0x500
.equ DWC2_HC_STRIDE,   0x20

/* Channel register offsets (from channel base) */
.equ HC_CHAR,           0x00       /* Channel Characteristics */
.equ HC_SPLT,           0x04       /* Split Transaction Control */
.equ HC_INT,            0x08       /* Channel Interrupt */
.equ HC_INTMSK,         0x0C       /* Channel Interrupt Mask */
.equ HC_TSIZ,           0x10       /* Transfer Size */
.equ HC_DMA,            0x14       /* DMA Address */

/* GRSTCTL bits */
.equ GRSTCTL_CSFTRST,          0x01            /* Core Soft Reset */
.equ GRSTCTL_RXFFLSH,          0x10            /* RX FIFO Flush */
.equ GRSTCTL_TXFFLSH,          0x20            /* TX FIFO Flush */
.equ GRSTCTL_TXFFLSH_ALL,      0x420           /* TX FIFO Flush + TXFNUM=0x10 (all) */
.equ GRSTCTL_AHBIDLE_BIT,      31              /* AHB Master Idle (bit position) */

/* GUSBCFG bits */
.equ GUSBCFG_FHMOD,            0x20000000      /* Force Host Mode (bit 29) */

/* GINTSTS bits */
.equ GINTSTS_CURMOD_BIT,       0               /* Current Mode: 1=host (bit position) */

/* HPRT bits and masks */
.equ HPRT_PRTCONNSTS,          0x01            /* Port Connect Status (RO, bit 0) */
.equ HPRT_PRTCONNDET,          0x02            /* Port Connect Detected (W1C, bit 1) */
.equ HPRT_PRTENA,              0x04            /* Port Enable (W1C, bit 2 — write 1 disables!) */
.equ HPRT_PRTENCHNG,           0x08            /* Port Enable Changed (W1C, bit 3) */
.equ HPRT_PRTRST,              0x100           /* Port Reset (R/W, bit 8) */
.equ HPRT_PRTPWR,              0x1000          /* Port Power (R/W, bit 12) */
.equ HPRT_W1C_MASK,            0x2E            /* W1C bits: 1,2,3,5 — mask off when modifying */

/* FIFO sizes (in 32-bit words) */
.equ DWC2_RXFSIZ,              0x100           /* 256 words = 1KB */
.equ DWC2_NPTXFSIZ,            0x01000100      /* depth=256, start=256 */
.equ DWC2_PTXFSIZ,             0x01000200      /* depth=256, start=512 */

/* GAHBCFG bits */
.equ GAHBCFG_DMAEN,            0x20            /* DMA Enable (bit 5) */

/* HCCHAR bits */
.equ HCCHAR_EPDIR_IN,          0x8000          /* EP Direction IN (bit 15) */
.equ HCCHAR_EPNUM_SHIFT,       11
.equ HCCHAR_EPTYPE_BULK,       0x00080000      /* 2 << 18 */
.equ HCCHAR_CHEN,              0x80000000      /* Channel Enable (bit 31) */

/* HCTSIZ PID values (bits 30:29) */
.equ HCTSIZ_PID_DATA0,         0x00000000      /* 0 << 29 */
.equ HCTSIZ_PID_DATA1,         0x40000000      /* 2 << 29 */
.equ HCTSIZ_PID_SETUP,         0x60000000      /* 3 << 29 */
.equ HCTSIZ_PKTCNT_1,          0x00080000      /* 1 << 19 */

/* HCINT bits */
.equ HCINT_XFERCOMP,           0x01            /* Transfer Complete (bit 0) */
.equ HCINT_CHHLTD,             0x02            /* Channel Halted (bit 1) */
.equ HCINT_STALL,              0x08            /* STALL (bit 3) */
.equ HCINT_NAK,                0x10            /* NAK (bit 4) */
.equ HCINT_ACK,                0x20            /* ACK (bit 5) */
.equ HCINT_XACTERR,            0x80            /* Transaction Error (bit 7) */

/* USB power device ID for mailbox */
.equ MBOX_USB_DEVICE_ID,       3
