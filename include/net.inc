/* Network protocol constants: Ethernet, ARP, static IP config */

/* Ethernet header offsets and sizes */
.equ ETH_DST,          0
.equ ETH_SRC,          6
.equ ETH_TYPE,         12
.equ ETH_PAYLOAD,      14
.equ ETH_HDR_LEN,      14
.equ ETH_ADDR_LEN,     6
.equ ETH_MTU,          1500
.equ ETH_FRAME_MAX,    1514

/* EtherType values (host order) */
.equ ETHERTYPE_ARP,    0x0806
.equ ETHERTYPE_IPV4,   0x0800

/* ARP packet offsets (relative to ETH_PAYLOAD) */
.equ ARP_HTYPE,        0
.equ ARP_PTYPE,        2
.equ ARP_HLEN,         4
.equ ARP_PLEN,         5
.equ ARP_OPER,         6
.equ ARP_SHA,          8
.equ ARP_SPA,          14
.equ ARP_THA,          18
.equ ARP_TPA,          24
.equ ARP_PKT_LEN,      28
.equ ARP_FRAME_LEN,    42

/* ARP operation codes (big-endian on wire) */
.equ ARP_OP_REQUEST,   1
.equ ARP_OP_REPLY,     2

/* Static IP configuration (network byte order for zero-cost wire comparison) */
.equ NET_IP_NBO,       0x0A00020F      /* 10.0.2.15 */
.equ NET_GW_NBO,       0x0A000202      /* 10.0.2.2 */
.equ NET_MASK_NBO,     0xFFFFFF00      /* 255.255.255.0 */
