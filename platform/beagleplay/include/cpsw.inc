/*
 * cpsw.inc — CPSW 3G Ethernet MAC constants (TI AM625)
 *
 * CPSW (Common Platform Switch) per SPRUJ87A §13.
 * MDIO register offsets, bit definitions, and MII PHY constants.
 */

/* -----------------------------------------------------------------------
 * CPSW top-level constants
 * ----------------------------------------------------------------------- */
.equ CPSW_NUM_PORTS,        2           /* 2 external ports + 1 host port */
.equ CPSW_MTU,              1518        /* Standard Ethernet MTU + headers */

/* -----------------------------------------------------------------------
 * MDIO register offsets (from MDIO base = CPSW_BASE + 0x0F00)
 * ----------------------------------------------------------------------- */
.equ CPSW_MDIO_OFFSET,      0x0F00

.equ MDIO_VERSION,          0x00
.equ MDIO_CONTROL,          0x04
.equ MDIO_ALIVE,            0x08
.equ MDIO_LINK,             0x0C
.equ MDIO_LINKINTRAW,       0x10
.equ MDIO_LINKINTMASKED,    0x14
.equ MDIO_USERINTRAW,       0x20
.equ MDIO_USERINTMASKED,    0x24
.equ MDIO_USERINTMASKSET,   0x28
.equ MDIO_USERINTMASKCLEAR, 0x2C
.equ MDIO_USERACCESS0,      0x80
.equ MDIO_USERPHYSEL0,      0x84
.equ MDIO_USERACCESS1,      0x88
.equ MDIO_USERPHYSEL1,      0x8C

/* Fake register block size — covers through USERPHYSEL1 + 4 */
.equ MDIO_FAKE_SIZE,        0x90

/* -----------------------------------------------------------------------
 * MDIO_CONTROL bits
 * ----------------------------------------------------------------------- */
.equ MDIO_CTRL_IDLE_BIT,    31          /* bit position for tbz/tbnz */
.equ MDIO_CTRL_ENABLE,      0x40000000  /* bit 30 */
.equ MDIO_CTRL_CLKDIV_MASK, 0xFFFF     /* bits 0-15 */

/* AM625: 250 MHz / (2 * 2.5 MHz) - 1 = 49 */
.equ MDIO_CLKDIV_DEFAULT,   49

/* -----------------------------------------------------------------------
 * MDIO_USERACCESS0 bit fields
 * ----------------------------------------------------------------------- */
.equ MDIO_UA_GO_BIT,        31          /* bit position for tbz/tbnz */
.equ MDIO_UA_GO,            0x80000000  /* bit 31 */
.equ MDIO_UA_WRITE,         0x40000000  /* bit 30 */
.equ MDIO_UA_ACK_BIT,       29          /* bit position for tbz/tbnz */
.equ MDIO_UA_ACK,           0x20000000  /* bit 29 */
.equ MDIO_UA_REGADDR_SHIFT, 21
.equ MDIO_UA_PHYADDR_SHIFT, 16
.equ MDIO_UA_DATA_MASK,     0xFFFF      /* bits 15:0 */

/* MDIO poll loop limit */
.equ MDIO_POLL_LIMIT,       60000

/* -----------------------------------------------------------------------
 * Standard MII PHY registers (IEEE 802.3)
 * ----------------------------------------------------------------------- */
.equ MII_BMCR,              0           /* Basic Mode Control */
.equ MII_BMSR,              1           /* Basic Mode Status */
.equ MII_PHYID1,            2           /* PHY Identifier 1 */
.equ MII_PHYID2,            3           /* PHY Identifier 2 */
.equ MII_ANAR,              4           /* Auto-Negotiation Advertisement */
.equ MII_ANLPAR,            5           /* Auto-Neg Link Partner Ability */

/* MII_BMCR bits (bit positions for tbz/tbnz) */
.equ BMCR_RESET_BIT,        15
.equ BMCR_LOOPBACK_BIT,     14
.equ BMCR_SPEED_100_BIT,    13
.equ BMCR_ANENABLE_BIT,     12
.equ BMCR_ANRESTART_BIT,    9

/* MII_BMSR bits (bit positions for tbz/tbnz) */
.equ BMSR_ANCOMP_BIT,       5           /* Auto-negotiation complete */
.equ BMSR_LINK_BIT,         2           /* Link status */
