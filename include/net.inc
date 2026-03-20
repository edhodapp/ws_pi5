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

/* IPv4 header offsets (relative to ETH_PAYLOAD) */
.equ IP_VER_IHL,       0
.equ IP_DSCP_ECN,      1
.equ IP_TOTLEN,        2
.equ IP_ID,            4
.equ IP_FLAGS_FRAG,    6
.equ IP_TTL,           8
.equ IP_PROTO,         9
.equ IP_CHECKSUM,      10
.equ IP_SRC,           12
.equ IP_DST,           16
.equ IP_HDR_MIN,       20
.equ IP_DEFAULT_TTL,   64

/* IP protocol numbers */
.equ IP_PROTO_ICMP,    1
.equ IP_PROTO_TCP,     6
.equ IP_PROTO_UDP,     17

/* ICMP offsets (relative to IP payload, i.e., ETH_PAYLOAD + IP_HDR_MIN) */
.equ ICMP_TYPE,        0
.equ ICMP_CODE,        1
.equ ICMP_CHECKSUM,    2
.equ ICMP_ID,          4
.equ ICMP_SEQ,         6
.equ ICMP_HDR_LEN,     8
.equ ICMP_ECHO_REQUEST, 8
.equ ICMP_ECHO_REPLY,  0
.equ ICMP_DEST_UNREACHABLE, 3

/* UDP offsets (relative to IP payload, i.e., ETH_PAYLOAD + IP_HDR_MIN) */
.equ UDP_SPORT,        0
.equ UDP_DPORT,        2
.equ UDP_LENGTH,       4
.equ UDP_CHECKSUM,     6
.equ UDP_HDR_LEN,      8
.equ UDP_ECHO_PORT,    7

/* Static IP configuration (network byte order for zero-cost wire comparison) */
.equ NET_IP_NBO,       0x0A00020F      /* 10.0.2.15 */
.equ NET_GW_NBO,       0x0A000202      /* 10.0.2.2 */
.equ NET_MASK_NBO,     0xFFFFFF00      /* 255.255.255.0 */
