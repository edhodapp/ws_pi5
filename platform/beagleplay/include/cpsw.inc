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

/* -----------------------------------------------------------------------
 * CPSW NU Core registers (offsets from NU base = CPSW_BASE + 0x20000)
 * ----------------------------------------------------------------------- */
.equ CPSW_NU_OFFSET,        0x20000

.equ NU_CTL_REG,            0x04
.equ NU_STAT_PORT_EN,       0x14
.equ NU_PTYPE_REG,          0x18

/* NU_CTL_REG: P0_ENABLE(2) | P0_TX_CRC_REMOVE(13) | P0_RX_PAD(14) */
.equ NU_CTL_INIT_VAL,       0x6004
.equ NU_STAT_PORT_EN_ALL,   0x07

/* -----------------------------------------------------------------------
 * Port registers (offsets from NU base; Port N at NU + (N+1)*0x1000)
 * ----------------------------------------------------------------------- */
.equ NU_PORT0_OFFSET,       0x1000      /* Host port */
.equ NU_PORT1_OFFSET,       0x2000      /* External port 1 */
.equ NU_PORT2_OFFSET,       0x3000      /* External port 2 */

.equ PN_FLOW_ID_REG,        0x08        /* Host port only: RX DMA flow_id_base */
.equ PN_RX_MAXLEN,          0x24        /* Max receive frame length */
.equ PN_REG_SA_L,           0x308       /* MAC source address low 32 bits */
.equ PN_REG_SA_H,           0x30C       /* MAC source address high 16 bits */

/* MTU(1500) + ETH_HDR(14) + CRC(4) + VLAN(4) */
.equ PN_MAXLEN_DEFAULT,     1522

/* -----------------------------------------------------------------------
 * MAC Sublayer (MACSL) — at port base + 0x330
 * ----------------------------------------------------------------------- */
.equ PN_MACSL_OFFSET,       0x330

.equ MACSL_CTL,             0x00
.equ MACSL_STATUS,          0x04
.equ MACSL_RESET,           0x08

.equ MACSL_RESET_BIT,       0           /* bit position for tbz/tbnz */
.equ MACSL_POLL_LIMIT,      60000

/* Pre-computed speed/duplex values (no .equ ORing needed) */
.equ MACSL_CTL_1000,        0xA1        /* GMII_EN | GIG | FULL_DUPLEX */
.equ MACSL_CTL_100,         0x8021      /* GMII_EN | IFCTL_A | FULL_DUPLEX */
.equ MACSL_CTL_10,          0x21        /* GMII_EN | FULL_DUPLEX */

/* Speed codes (passed as w1 to cpsw_macsl_config) */
.equ SPEED_10,              10
.equ SPEED_100,             100
.equ SPEED_1000,            1000

/* -----------------------------------------------------------------------
 * ALE registers (offsets from ALE base = NU base + 0x1E000)
 * ----------------------------------------------------------------------- */
.equ NU_ALE_OFFSET,         0x1E000

.equ ALE_CTL,               0x08
.equ ALE_PN_CTL_BASE,       0x40        /* ALE_PN_CTL(N) = 0x40 + N*4 */
.equ ALE_PN_CTL_STRIDE,     4
.equ ALE_THREADMAPDEF,      0x134

/* ALE bypass mode: ENABLE(31) | RESET_TBL(30) | BYPASS(4) = 0xC0000010 */
.equ ALE_CTL_BYPASS_VAL,    0xC0000010
.equ ALE_PN_FORWARD,        3

/* -----------------------------------------------------------------------
 * Fake register block sizes (for tests)
 * ----------------------------------------------------------------------- */
/* NU: covers through Port 1 MACSL_RESET at 0x2000 + 0x330 + 0x08 = 0x2338 */
.equ NU_FAKE_SIZE,          0x2400
/* ALE: covers through THREADMAPDEF at 0x134 + 4 */
.equ ALE_FAKE_SIZE,         0x140
