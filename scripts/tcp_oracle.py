#!/usr/bin/env python3
"""
TCP functional test oracle — generates binary test vectors for tcp_handle.

Primary:   pict /o:max < tcp_func.pict | python3 tcp_oracle.py > tcp_vectors.bin
Fallback:  python3 tcp_oracle.py --generate > tcp_vectors.bin
Debug:     python3 tcp_oracle.py --dry-run [--generate]
"""

import struct
import sys
import itertools

# ---------------------------------------------------------------------------
# Constants matching tcp.inc / net.inc
# ---------------------------------------------------------------------------
TCPS_CLOSED      = 0
TCPS_LISTEN      = 1
TCPS_SYN_RCVD    = 2
TCPS_ESTABLISHED = 3
TCPS_CLOSE_WAIT  = 4
TCPS_LAST_ACK    = 5
TCPS_FIN_WAIT_1  = 6
TCPS_FIN_WAIT_2  = 7
TCPS_TIME_WAIT   = 8
TCPS_CLOSING     = 9

ETH_HDR_LEN = 14
IP_HDR_MIN  = 20
TCP_HDR_MIN = 20

# Flag bits
TCP_FIN      = 0x01
TCP_SYN      = 0x02
TCP_RST      = 0x04
TCP_ACK_FLAG = 0x10

# Pre-combined
TCP_RST_ACK  = 0x14
TCP_SYN_ACK  = 0x12

# ISN convention (deterministic for functional tests)
ISN = 0x41424344

# Pre-seeded connection fields for exact-match cases
PRE_SND_UNA = ISN
PRE_SND_NXT = ISN + 1
PRE_RCV_NXT = 2          # client SYN SEQ=1, +1

# Network addresses
OUR_MAC   = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
PEER_MAC  = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
PEER_IP   = bytes([0x0A, 0x00, 0x02, 0x02])  # 10.0.2.2
OUR_IP    = bytes([0x0A, 0x00, 0x02, 0x0F])  # 10.0.2.15

# Ports (network byte order)
LPORT_80_NBO    = 0x0050
RPORT_12345_NBO = 0x3039
DPORT_9999_NBO  = 0x270F

# Binary entry size
ENTRY_SIZE = 192

# ---------------------------------------------------------------------------
# Parameter enumerations
# ---------------------------------------------------------------------------
CONN_STATES = ['CLOSED', 'LISTEN', 'SYN_RCVD', 'ESTABLISHED', 'CLOSE_WAIT',
               'LAST_ACK', 'FIN_WAIT_1', 'FIN_WAIT_2', 'TIME_WAIT', 'CLOSING']
FLAGS       = ['RST', 'SYN', 'SYNACK', 'FIN_ACK', 'ACK', 'NONE']
PORT_MATCH  = ['exact', 'listen_only', 'no_match']
PAYLOAD     = ['none', 'some', 'bad_seq', 'dup_seq']
CHECKSUM    = ['valid', 'invalid']
HEADER      = ['valid', 'short_frame', 'bad_doff', 'doff_overrun']

STATE_MAP = {
    'CLOSED': TCPS_CLOSED,
    'LISTEN': TCPS_LISTEN,
    'SYN_RCVD': TCPS_SYN_RCVD,
    'ESTABLISHED': TCPS_ESTABLISHED,
    'CLOSE_WAIT': TCPS_CLOSE_WAIT,
    'LAST_ACK': TCPS_LAST_ACK,
    'FIN_WAIT_1': TCPS_FIN_WAIT_1,
    'FIN_WAIT_2': TCPS_FIN_WAIT_2,
    'TIME_WAIT': TCPS_TIME_WAIT,
    'CLOSING': TCPS_CLOSING,
}

FLAGS_MAP = {
    'RST': TCP_RST,
    'SYN': TCP_SYN,
    'SYNACK': TCP_SYN | TCP_ACK_FLAG,
    'FIN_ACK': TCP_FIN | TCP_ACK_FLAG,
    'ACK': TCP_ACK_FLAG,
    'NONE': 0x00,
}

PORT_MATCH_CODE = {'exact': 0, 'listen_only': 1, 'no_match': 2}


# ---------------------------------------------------------------------------
# Constraint filtering (matches PICT model constraints)
# ---------------------------------------------------------------------------
def is_valid_combo(conn_state, flags, port_match, payload, checksum, header):
    # Invalid header → pin other params to canonical values
    if header != 'valid':
        if conn_state != 'CLOSED' or flags != 'ACK' or port_match != 'no_match':
            return False
        if payload != 'none' or checksum != 'valid':
            return False
        return True

    # Invalid checksum → pin other params to canonical values
    if checksum == 'invalid':
        if conn_state != 'CLOSED' or flags != 'ACK' or port_match != 'no_match':
            return False
        if payload != 'none':
            return False
        return True

    # port_match constraints
    if port_match == 'exact' and conn_state not in (
            'SYN_RCVD', 'ESTABLISHED', 'CLOSE_WAIT',
            'LAST_ACK', 'FIN_WAIT_1', 'FIN_WAIT_2', 'TIME_WAIT', 'CLOSING'):
        return False
    if port_match == 'listen_only' and conn_state not in ('LISTEN', 'CLOSED'):
        return False
    if port_match == 'no_match' and conn_state != 'CLOSED':
        return False

    # payload constraints
    if payload == 'bad_seq':
        if not (conn_state == 'ESTABLISHED' and flags == 'ACK' and port_match == 'exact'):
            return False
    if payload == 'dup_seq':
        if not (conn_state == 'ESTABLISHED' and flags == 'ACK' and port_match == 'exact'):
            return False
    if payload in ('some', 'bad_seq', 'dup_seq'):
        if header != 'valid' or checksum != 'valid':
            return False

    return True


def generate_all_combos():
    """Generate full constrained cross-product (fallback for PICT)."""
    combos = []
    for combo in itertools.product(CONN_STATES, FLAGS, PORT_MATCH, PAYLOAD, CHECKSUM, HEADER):
        if is_valid_combo(*combo):
            combos.append(combo)
    return combos


# ---------------------------------------------------------------------------
# IP checksum (RFC 791)
# ---------------------------------------------------------------------------
def ip_checksum(header_bytes):
    if len(header_bytes) % 2:
        header_bytes = header_bytes + b'\x00'
    s = 0
    for i in range(0, len(header_bytes), 2):
        s += (header_bytes[i] << 8) | header_bytes[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


# ---------------------------------------------------------------------------
# TCP checksum (RFC 793) — LE halfword sum with pseudo-header
# ---------------------------------------------------------------------------
def tcp_checksum_calc(frame):
    """Calculate TCP checksum matching the assembly implementation.

    The assembly loads LE halfwords via ldrh, so we sum 16-bit LE values.
    """
    ip_src = frame[ETH_HDR_LEN + 12 : ETH_HDR_LEN + 16]
    ip_dst = frame[ETH_HDR_LEN + 16 : ETH_HDR_LEN + 20]
    tcp_start = ETH_HDR_LEN + IP_HDR_MIN
    tcp_data = frame[tcp_start:]
    tcp_len = len(tcp_data)

    acc = 0

    # Pseudo-header: IP src (2 LE halfwords)
    acc += struct.unpack_from('<H', ip_src, 0)[0]
    acc += struct.unpack_from('<H', ip_src, 2)[0]
    # Pseudo-header: IP dst (2 LE halfwords)
    acc += struct.unpack_from('<H', ip_dst, 0)[0]
    acc += struct.unpack_from('<H', ip_dst, 2)[0]
    # Pseudo-header: zero + protocol (TCP=6, LE halfword of 00 06 = 0x0600)
    acc += 0x0600
    # Pseudo-header: TCP length (rev16 of native)
    tcp_len_nbo = ((tcp_len & 0xFF) << 8) | ((tcp_len >> 8) & 0xFF)
    acc += tcp_len_nbo

    # TCP segment as LE halfwords
    i = 0
    while i + 1 < tcp_len:
        acc += struct.unpack_from('<H', tcp_data, i)[0]
        i += 2
    if i < tcp_len:
        acc += tcp_data[i]

    # Fold carries
    while acc >> 16:
        acc = (acc & 0xFFFF) + (acc >> 16)
    return (~acc) & 0xFFFF


# ---------------------------------------------------------------------------
# Oracle: compute expected behavior
# ---------------------------------------------------------------------------
def classify_event(tcp_flags):
    """Map TCP flags to FSA event code, matching tcp_classify_event."""
    if tcp_flags & TCP_RST:
        return 0   # TCP_EVT_RST
    if tcp_flags & TCP_SYN:
        if tcp_flags & TCP_ACK_FLAG:
            return 2  # TCP_EVT_SYNACK
        return 1      # TCP_EVT_SYN
    if tcp_flags & TCP_FIN:
        return 3      # TCP_EVT_FIN
    if tcp_flags & TCP_ACK_FLAG:
        return 4      # TCP_EVT_ACK
    return -1         # unclassifiable


# FSA table: [state][event] -> (next_state, handler_name)
# None handler = no transition -> RST
FSA_TABLE = {
    TCPS_CLOSED: {0: None, 1: None, 2: None, 3: None, 4: None},
    TCPS_LISTEN: {
        0: None,  # RST -> no handler (RST reply)
        1: ('listen_syn',),
        2: None,  # SYNACK -> RST
        3: None,  # FIN -> RST
        4: None,  # ACK -> RST
    },
    TCPS_SYN_RCVD: {
        0: (TCPS_CLOSED, 'conn_close'),
        1: None,
        2: None,
        3: None,
        4: (TCPS_ESTABLISHED, 'synrcvd_ack'),
    },
    TCPS_ESTABLISHED: {
        0: (TCPS_CLOSED, 'conn_close'),
        1: None,
        2: None,
        3: (TCPS_CLOSE_WAIT, 'estab_fin'),
        4: (TCPS_ESTABLISHED, 'estab_ack'),
    },
    TCPS_CLOSE_WAIT: {
        0: (TCPS_CLOSED, 'conn_close'),
        1: None,
        2: None,
        3: None,
        4: (TCPS_CLOSE_WAIT, 'drop'),
    },
    TCPS_LAST_ACK: {
        0: (TCPS_CLOSED, 'conn_close'),
        1: None,
        2: None,
        3: None,
        4: (TCPS_CLOSED, 'lastack_ack'),
    },
    TCPS_FIN_WAIT_1: {
        0: (TCPS_CLOSED, 'conn_close'),
        1: None,
        2: None,
        3: (TCPS_CLOSING, 'finwait1_fin'),
        4: (TCPS_FIN_WAIT_2, 'finwait1_ack'),
    },
    TCPS_FIN_WAIT_2: {
        0: (TCPS_CLOSED, 'conn_close'),
        1: None,
        2: None,
        3: (TCPS_TIME_WAIT, 'finwait2_fin'),
        4: (TCPS_FIN_WAIT_2, 'drop'),
    },
    TCPS_TIME_WAIT: {
        0: (TCPS_CLOSED, 'conn_close'),
        1: None,
        2: None,
        3: (TCPS_TIME_WAIT, 'drop'),
        4: (TCPS_TIME_WAIT, 'drop'),
    },
    TCPS_CLOSING: {
        0: (TCPS_CLOSED, 'conn_close'),
        1: None,
        2: None,
        3: None,
        4: (TCPS_TIME_WAIT, 'closing_ack'),
    },
}


def oracle(conn_state, flags, port_match, payload, checksum, header):
    """Compute expected behavior for a test vector.

    Returns 8-tuple:
      (ret, post_state, reply_flags, reply_seq, reply_ack,
       post_rcv_nxt, post_rxlen, post_snd_una)

    ret: 0 = drop/no-reply, 54 = reply frame built
    post_state: TCPS_* value after tcp_handle returns
    reply_flags: TCP flags byte in reply (only meaningful when ret=54)
    reply_seq/reply_ack: value ldr reads from reply frame (NBO as LE u32)
    post_rcv_nxt/post_rxlen/post_snd_una: exact-match only, else 0
    """
    state_code = STATE_MAP[conn_state]
    tcp_flags = FLAGS_MAP[flags]

    # Compute incoming frame fields (matching build_frame_v2)
    if payload == 'some':
        tcp_seq_host = PRE_RCV_NXT
    elif payload == 'bad_seq':
        tcp_seq_host = 999
    elif payload == 'dup_seq':
        tcp_seq_host = 0
    else:
        tcp_seq_host = 1

    if port_match == 'exact' and (tcp_flags & TCP_ACK_FLAG):
        tcp_ack_host = PRE_SND_NXT
    else:
        tcp_ack_host = 0

    data_bytes = 5 if payload in ('some', 'bad_seq', 'dup_seq') else 0

    # 1. Header invalid -> drop (no conn state change)
    if header != 'valid':
        return (0, state_code, 0, 0, 0, 0, 0, 0)

    # 2. Checksum invalid -> drop (no conn state change)
    if checksum == 'invalid':
        return (0, state_code, 0, 0, 0, 0, 0, 0)

    # 3. No connection match -> RST (no conn to modify)
    if port_match == 'no_match':
        return rst_result(tcp_flags, state_code,
                          tcp_seq_host, tcp_ack_host, data_bytes)

    # 4. Determine lookup state and the slot's actual state
    if port_match == 'listen_only':
        lookup_state = TCPS_LISTEN
        slot_state = TCPS_LISTEN
    else:  # exact
        lookup_state = state_code
        slot_state = state_code

    # 5. Classify event
    evt = classify_event(tcp_flags)
    if evt == -1:
        r = rst_result(tcp_flags, slot_state,
                       tcp_seq_host, tcp_ack_host, data_bytes)
        if port_match == 'exact':
            return r[:5] + (PRE_RCV_NXT, 0, PRE_SND_UNA)
        return r

    # 6. FSA table lookup
    entry = FSA_TABLE.get(lookup_state, {}).get(evt)
    if entry is None:
        r = rst_result(tcp_flags, slot_state,
                       tcp_seq_host, tcp_ack_host, data_bytes)
        if port_match == 'exact':
            return r[:5] + (PRE_RCV_NXT, 0, PRE_SND_UNA)
        return r

    # 7. Handler-specific logic (handler is non-NULL, FSA wrote next_state)
    handler = entry[-1]

    if handler == 'listen_syn':
        reply_seq = to_nbo_ldr(ISN)
        reply_ack = to_nbo_ldr(tcp_seq_host + 1)
        return (58, TCPS_SYN_RCVD, TCP_SYN_ACK, reply_seq, reply_ack,
                0, 0, 0)

    if handler == 'conn_close':
        next_state = entry[0]
        if port_match == 'exact':
            return (0, next_state, 0, 0, 0, PRE_RCV_NXT, 0, PRE_SND_UNA)
        return (0, next_state, 0, 0, 0, 0, 0, 0)

    if handler == 'synrcvd_ack':
        next_state = entry[0]
        return (0, next_state, 0, 0, 0, PRE_RCV_NXT, 0, PRE_SND_NXT)

    if handler == 'estab_ack':
        next_state = entry[0]
        if payload == 'none':
            return (0, next_state, 0, 0, 0, PRE_RCV_NXT, 0, PRE_SND_NXT)
        elif payload == 'some':
            reply_seq = to_nbo_ldr(PRE_SND_NXT)
            reply_ack = to_nbo_ldr(PRE_RCV_NXT + 5)
            return (54, next_state, TCP_ACK_FLAG, reply_seq, reply_ack,
                    PRE_RCV_NXT + 5, 5, PRE_SND_NXT)
        elif payload == 'bad_seq':
            # OOO buffering: segment buffered, dup ACK sent
            reply_seq = to_nbo_ldr(PRE_SND_NXT)
            reply_ack = to_nbo_ldr(PRE_RCV_NXT)
            return (54, next_state, TCP_ACK_FLAG, reply_seq, reply_ack,
                    PRE_RCV_NXT, 0, PRE_SND_NXT)
        elif payload == 'dup_seq':
            reply_seq = to_nbo_ldr(PRE_SND_NXT)
            reply_ack = to_nbo_ldr(PRE_RCV_NXT)
            return (54, next_state, TCP_ACK_FLAG, reply_seq, reply_ack,
                    PRE_RCV_NXT, 0, PRE_SND_NXT)
        return (0, next_state, 0, 0, 0, PRE_RCV_NXT, 0, PRE_SND_NXT)

    if handler == 'estab_fin':
        next_state = entry[0]
        reply_seq = to_nbo_ldr(PRE_SND_NXT)
        reply_ack = to_nbo_ldr(PRE_RCV_NXT + 1)
        return (54, next_state, TCP_ACK_FLAG, reply_seq, reply_ack,
                PRE_RCV_NXT + 1, 0, PRE_SND_UNA)

    if handler == 'drop':
        next_state = entry[0]
        if port_match == 'exact':
            return (0, next_state, 0, 0, 0, PRE_RCV_NXT, 0, PRE_SND_UNA)
        return (0, next_state, 0, 0, 0, 0, 0, 0)

    if handler == 'lastack_ack':
        next_state = entry[0]
        return (0, next_state, 0, 0, 0, PRE_RCV_NXT, 0, PRE_SND_UNA)

    if handler == 'finwait1_ack':
        next_state = entry[0]
        return (0, next_state, 0, 0, 0, PRE_RCV_NXT, 0, PRE_SND_UNA)

    if handler == 'finwait1_fin':
        next_state = entry[0]
        reply_seq = to_nbo_ldr(PRE_SND_NXT)
        reply_ack = to_nbo_ldr(PRE_RCV_NXT + 1)
        return (54, next_state, TCP_ACK_FLAG, reply_seq, reply_ack,
                PRE_RCV_NXT + 1, 0, PRE_SND_UNA)

    if handler == 'finwait2_fin':
        next_state = entry[0]
        reply_seq = to_nbo_ldr(PRE_SND_NXT)
        reply_ack = to_nbo_ldr(PRE_RCV_NXT + 1)
        return (54, next_state, TCP_ACK_FLAG, reply_seq, reply_ack,
                PRE_RCV_NXT + 1, 0, PRE_SND_UNA)

    if handler == 'closing_ack':
        next_state = entry[0]
        return (0, next_state, 0, 0, 0, PRE_RCV_NXT, 0, PRE_SND_UNA)

    # Should not reach here
    r = rst_result(tcp_flags, slot_state,
                   tcp_seq_host, tcp_ack_host, data_bytes)
    if port_match == 'exact':
        return r[:5] + (PRE_RCV_NXT, 0, PRE_SND_UNA)
    return r


def to_nbo_ldr(h):
    """Convert host-order u32 to the value ldr reads from NBO frame bytes."""
    return struct.unpack('<I', struct.pack('>I', h & 0xFFFFFFFF))[0]


def rst_result(tcp_flags, post_state, tcp_seq_host, tcp_ack_host, data_bytes):
    """Compute RST reply details matching tcp_handle .Ltcp_no_conn.

    post_state: the connection slot's state (unchanged by RST path).
    Returns 8-tuple: (ret, post_state, reply_flags, reply_seq, reply_ack,
                       post_rcv_nxt, post_rxlen, post_snd_una)
    post_rcv_nxt/rxlen/snd_una are 0 here — caller overrides for exact-match.
    """
    # RFC 793 §3.4: never send RST in response to RST
    if tcp_flags & TCP_RST:
        return (0, post_state, 0, 0, 0, 0, 0, 0)

    if tcp_flags & TCP_ACK_FLAG:
        reply_seq = to_nbo_ldr(tcp_ack_host)
        return (54, post_state, TCP_RST, reply_seq, 0, 0, 0, 0)
    else:
        seg_len = data_bytes
        if tcp_flags & TCP_SYN:
            seg_len += 1
        if tcp_flags & TCP_FIN:
            seg_len += 1
        reply_ack = to_nbo_ldr(tcp_seq_host + seg_len)
        return (54, post_state, TCP_RST_ACK, 0, reply_ack, 0, 0, 0)


# ---------------------------------------------------------------------------
# Frame construction (revised — SEQ depends on payload type)
# ---------------------------------------------------------------------------
def build_frame_v2(conn_state, flags, port_match, payload, checksum, header):
    """Build an Ethernet + IP + TCP frame for the given parameters."""
    tcp_flags = FLAGS_MAP[flags]

    # Determine ports
    if port_match == 'no_match':
        sport_nbo = RPORT_12345_NBO
        dport_nbo = DPORT_9999_NBO
    else:
        sport_nbo = RPORT_12345_NBO
        dport_nbo = LPORT_80_NBO

    # TCP SEQ (host-order value, will be packed as big-endian)
    if payload == 'some':
        # Good SEQ: must match RCV_NXT of pre-seeded connection
        tcp_seq_host = PRE_RCV_NXT  # 2
    elif payload == 'bad_seq':
        tcp_seq_host = 999  # wrong SEQ (future: > RCV_NXT)
    elif payload == 'dup_seq':
        tcp_seq_host = 0    # duplicate: < RCV_NXT (which is 2)
    else:
        tcp_seq_host = 1

    # TCP ACK: for exact-match with ACK flag, use SND_NXT
    if port_match == 'exact' and (tcp_flags & TCP_ACK_FLAG):
        tcp_ack_host = PRE_SND_NXT
    else:
        tcp_ack_host = 0

    # Data offset byte
    if header == 'bad_doff':
        data_off_byte = 0x30  # 3 words = 12 bytes < 20 min
    elif header == 'doff_overrun':
        data_off_byte = 0x60  # 6 words = 24 bytes > 20 TCP section
    else:
        data_off_byte = 0x50  # 5 words = 20 bytes (normal)

    # Payload data
    if payload in ('some', 'bad_seq', 'dup_seq'):
        payload_data = bytes([0x48, 0x65, 0x6C, 0x6C, 0x6F])  # "Hello"
    else:
        payload_data = b''

    # Build TCP header (20 bytes)
    tcp_hdr = bytearray(20)
    struct.pack_into('>H', tcp_hdr, 0, sport_nbo)
    struct.pack_into('>H', tcp_hdr, 2, dport_nbo)
    struct.pack_into('>I', tcp_hdr, 4, tcp_seq_host)
    struct.pack_into('>I', tcp_hdr, 8, tcp_ack_host)
    tcp_hdr[12] = data_off_byte
    tcp_hdr[13] = tcp_flags
    struct.pack_into('>H', tcp_hdr, 14, 0xFFFF)  # window
    # checksum [16:18] and urgent [18:20] stay zero
    tcp_segment = bytes(tcp_hdr) + payload_data

    # IP total length
    ip_total_len = IP_HDR_MIN + len(tcp_segment)

    # Build IP header (20 bytes)
    ip_hdr = bytearray(20)
    ip_hdr[0] = 0x45
    ip_hdr[1] = 0x00
    struct.pack_into('>H', ip_hdr, 2, ip_total_len)
    struct.pack_into('>H', ip_hdr, 4, 0x1234)
    ip_hdr[8] = 64
    ip_hdr[9] = 6
    ip_hdr[12:16] = PEER_IP
    ip_hdr[16:20] = OUR_IP
    cksum = ip_checksum(bytes(ip_hdr))
    struct.pack_into('>H', ip_hdr, 10, cksum)

    # Ethernet header
    eth_hdr = OUR_MAC + PEER_MAC + struct.pack('>H', 0x0800)

    frame = bytearray(eth_hdr + bytes(ip_hdr) + tcp_segment)

    # Compute and store valid TCP checksum
    tcp_cksum = tcp_checksum_calc(frame)
    tcp_cksum_offset = ETH_HDR_LEN + IP_HDR_MIN + 16
    struct.pack_into('<H', frame, tcp_cksum_offset, tcp_cksum)

    # Corrupt checksum if requested
    if checksum == 'invalid':
        frame[tcp_cksum_offset] ^= 0xFF

    # Frame length
    if header == 'short_frame':
        frame_len = 53  # 1 byte short of full TCP header
    else:
        frame_len = len(frame)

    return bytes(frame[:frame_len]), frame_len


# ---------------------------------------------------------------------------
# Binary emission
# ---------------------------------------------------------------------------
def make_entry(conn_state, flags, port_match, payload, checksum, header):
    """Build one 192-byte binary entry."""
    frame_data, frame_len = build_frame_v2(
        conn_state, flags, port_match, payload, checksum, header)
    (ret, post_state, reply_flags, reply_seq, reply_ack,
     post_rcv_nxt, post_rxlen, post_snd_una) = oracle(
        conn_state, flags, port_match, payload, checksum, header)

    state_code = STATE_MAP[conn_state]
    pm_code = PORT_MATCH_CODE[port_match]

    # Expected ret: actual return value (0 or 54)
    expected_ret = ret

    # Pre-seed fields (only relevant for exact match)
    # Port/IP values must be stored as LE-loaded representations of NBO bytes,
    # because the assembly uses ldrh/ldr (LE loads) to compare them.
    if pm_code == 0:  # exact
        pre_snd_nxt = PRE_SND_NXT
        pre_rcv_nxt = PRE_RCV_NXT
        pre_lport = struct.unpack('<H', struct.pack('>H', 80))[0]      # 0x5000
        pre_rport = struct.unpack('<H', struct.pack('>H', 12345))[0]   # 0x3930
        pre_rip = struct.unpack('<I', PEER_IP)[0]                       # 0x0202000A
        pre_snd_una = PRE_SND_UNA
    else:
        pre_snd_nxt = 0
        pre_rcv_nxt = 0
        pre_lport = 0
        pre_rport = 0
        pre_rip = 0
        pre_snd_una = 0

    # Pack entry header (32 bytes)
    entry_hdr = struct.pack('<HBBBBBxIIHHIIxxxx',
        frame_len,          # [0..1]  u16 LE frame_len
        expected_ret,       # [2]     u8 expected_ret
        post_state,         # [3]     u8 expected_post_state
        reply_flags,        # [4]     u8 expected_reply_flags
        state_code,         # [5]     u8 conn_state_code
        pm_code,            # [6]     u8 port_match_code
                            # [7]     pad
        pre_snd_nxt,        # [8..11] u32 LE
        pre_rcv_nxt,        # [12..15] u32 LE
        pre_lport,          # [16..17] u16 LE (NBO value)
        pre_rport,          # [18..19] u16 LE (NBO value)
        pre_rip,            # [20..23] u32 LE (NBO value)
        pre_snd_una,        # [24..27] u32 LE
                            # [28..31] padding
    )
    assert len(entry_hdr) == 32, f"entry_hdr is {len(entry_hdr)}, expected 32"

    # Frame data (128 bytes, zero-padded)
    frame_padded = frame_data[:128].ljust(128, b'\x00')

    # Trailing fields (32 bytes): new expected values + padding
    trailing = struct.pack('<IIIHxxI',
        reply_seq,          # [160..163] u32 LE
        reply_ack,          # [164..167] u32 LE
        post_rcv_nxt,       # [168..171] u32 LE
        post_rxlen,         # [172..173] u16 LE
                            # [174..175] pad
        post_snd_una,       # [176..179] u32 LE
    )
    trailing += b'\x00' * 12   # [180..191] pad

    # Entry = header(32) + frame(128) + trailing(32) = 192
    entry = entry_hdr + frame_padded + trailing
    assert len(entry) == ENTRY_SIZE
    return entry


def dry_run_entry(idx, conn_state, flags, port_match, payload, checksum, header):
    """Return human-readable description of one test vector."""
    (ret, post_state, reply_flags, reply_seq, reply_ack,
     post_rcv_nxt, post_rxlen, post_snd_una) = oracle(
        conn_state, flags, port_match, payload, checksum, header)
    state_names = {v: k for k, v in STATE_MAP.items()}
    post_name = state_names.get(post_state, f'?{post_state}')
    ret_str = f'reply({reply_flags:#04x})' if ret == 54 else 'drop'
    return (f'{idx:4d}  {conn_state:13s} {flags:8s} {port_match:12s} '
            f'{payload:7s} {checksum:8s} {header:12s} '
            f'-> {ret_str:16s} post={post_name}')


# ---------------------------------------------------------------------------
# TSV parsing (PICT output)
# ---------------------------------------------------------------------------
def parse_tsv(lines):
    """Parse PICT TSV output into list of tuples."""
    combos = []
    header = None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        fields = line.split('\t')
        if header is None:
            header = fields
            continue
        if len(fields) != 6:
            print(f'WARNING: skipping line with {len(fields)} fields: {line}',
                  file=sys.stderr)
            continue
        combos.append(tuple(fields))
    return combos


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    import argparse
    parser = argparse.ArgumentParser(description='TCP functional test oracle')
    parser.add_argument('--generate', action='store_true',
                        help='Generate cross-product internally (no PICT needed)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print human-readable output instead of binary')
    args = parser.parse_args()

    if args.generate:
        combos = generate_all_combos()
    else:
        combos = parse_tsv(sys.stdin.readlines())

    if args.dry_run:
        print(f'# {len(combos)} test vectors')
        print(f'# {"idx":>4s}  {"conn_state":13s} {"flags":8s} {"port_match":12s} '
              f'{"payload":7s} {"checksum":8s} {"header":12s} '
              f'   {"result":16s} post_state')
        for i, combo in enumerate(combos):
            print(dry_run_entry(i, *combo))
        return

    # Binary output
    entries = []
    for combo in combos:
        entries.append(make_entry(*combo))

    # Header: 16 bytes
    n = len(entries)
    hdr = struct.pack('<I', n) + b'\x00' * 12

    out = sys.stdout.buffer
    out.write(hdr)
    for e in entries:
        out.write(e)

    print(f'Wrote {n} entries ({16 + n * ENTRY_SIZE} bytes)',
          file=sys.stderr)


if __name__ == '__main__':
    main()
