#!/usr/bin/env python3
"""
IP fragment reassembly oracle — generates binary test vectors
for ip_reasm_input.

Primary:   pict /o:max < reasm_func.pict | python3 reasm_oracle.py > reasm_vectors.bin
Debug:     python3 reasm_oracle.py --dry-run

Each PICT row describes a fragment arriving at ip_reasm_input when
the matching reassembly slot is in a specific pre-seeded state.
The oracle predicts the expected outcome: drop (with reason),
accept-incomplete, or accept-complete. It also predicts the
post-slot state (active/inactive, bitmap contents, have_last,
total_len).

Binary blob layout:

  Header (16 bytes):
    [0..3]   u32 LE  entry count
    [4..15]  pad

  Entry (256 bytes):
    # Pre-seed
    [0]      u8      slot_state_code (0=empty, 1=first_half,
                     2=second_half, 3=near_complete)
    [1]      u8      pool_free (1=yes, 0=no)
    [2]      u8      pre_flags (REASM_FLAGS: bit7=active, bit0=have_last)
    [3]      u8      pre_min_ttl
    [4..5]   u16 LE  pre_total_len
    [6..7]   pad
    [8..39]  32B     pre_bitmap

    # Fragment input
    [40..41] u16 LE  frame_len
    [42..43] u16 LE  frag_offset (byte offset, multiple of 8)
    [44..45] u16 LE  payload_len
    [46]     u8      mf_flag (0 or 1)
    [47]     pad
    [48..207] 160B   frame_data (ETH+IP+payload, zero-padded)

    # Expected output
    [208]    u8      expected_ret_nonzero (1 = reassembled frame
                     returned; 0 = drop or incomplete)
    [209]    u8      expected_reason (0=ok_complete, 1=ok_incomplete,
                     2=drop_nonaligned, 3=drop_no_slot,
                     4=drop_overlap, 5=drop_bounds, 6=drop_oversized)
    [210]    u8      expected_post_active (1=slot still active)
    [211]    u8      expected_post_have_last
    [212..213] u16 LE expected_post_total_len
    [214..215] pad
    [216..247] 32B   expected_post_bitmap
    [248..255] pad

All multi-byte fields are little-endian (matching ARM64 ldr/str).
"""

import socket
import struct
import sys

# ---------------------------------------------------------------------------
# Constants matching include/net.inc
# ---------------------------------------------------------------------------
ETH_HDR_LEN = 14
IP_HDR_MIN  = 20
IP_PROTO_ICMP = 1
IP_DEFAULT_TTL = 64

IP_FLAG_MF = 0x2000
IP_FRAG_OFFSET_MASK = 0x1FFF

REASM_BUF_SIZE = 2048

ETH_FRAME_MAX = 1514

# Canonical addresses for every test vector (same as test_ip.S templates).
OUR_MAC  = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
PEER_MAC = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
PEER_IP  = "10.0.2.2"
OUR_IP   = "10.0.2.15"
IP_ID    = 0xABCD

# Entry size: 40 (pre-seed) + 8 (frag header) + 256 (frame) + 48 (expected) = 352
# Round to 384 with 32 bytes of trailing pad for alignment.
ENTRY_SIZE = 384

# Slot states
SS_EMPTY         = 0
SS_FIRST_HALF    = 1
SS_SECOND_HALF   = 2
SS_NEAR_COMPLETE = 3

# Expected reason codes
REASON_OK_COMPLETE     = 0
REASON_OK_INCOMPLETE   = 1
REASON_DROP_NONALIGNED = 2
REASON_DROP_NO_SLOT    = 3
REASON_DROP_OVERLAP    = 4
REASON_DROP_BOUNDS     = 5
REASON_DROP_OVERSIZED  = 6


# ---------------------------------------------------------------------------
# Bitmap helpers
# ---------------------------------------------------------------------------

def make_bitmap(*ranges):
    """Build a 32-byte (256-bit) bitmap with the given byte-ranges set.

    Each range is (start_byte, end_byte) — the bits covering
    [start_byte, end_byte) are set (one bit per 8-byte unit).
    """
    bm = bytearray(32)
    for start, end in ranges:
        start_bit = start // 8
        end_bit = (end - 1) // 8
        for b in range(start_bit, end_bit + 1):
            byte_idx = b // 8
            bit_idx = b % 8
            bm[byte_idx] |= (1 << bit_idx)
    return bytes(bm)


def bitmap_has_bit(bm: bytes, bit: int) -> bool:
    """Check if a specific bit is set in the bitmap."""
    byte_idx = bit // 8
    bit_idx = bit % 8
    return bool(bm[byte_idx] & (1 << bit_idx))


def bitmap_or(a: bytes, b: bytes) -> bytes:
    """OR two 32-byte bitmaps."""
    return bytes(x | y for x, y in zip(a, b))


def bitmap_all_set(bm: bytes, total_bits: int) -> bool:
    """Check if bits 0..total_bits-1 are all set."""
    full_bytes = total_bits // 8
    for i in range(full_bytes):
        if bm[i] != 0xFF:
            return False
    remaining = total_bits % 8
    if remaining:
        mask = (1 << remaining) - 1
        if (bm[full_bytes] & mask) != mask:
            return False
    return True


EMPTY_BITMAP = bytes(32)

# Pre-seeded bitmap patterns (matching the PICT model comments)
BM_FIRST_HALF    = make_bitmap((0, 400))        # bits 0..49
BM_SECOND_HALF   = make_bitmap((400, 800))      # bits 50..99
BM_NEAR_COMPLETE = make_bitmap((0, 400), (600, 800))  # bits 0..49 + 75..99


# ---------------------------------------------------------------------------
# IP checksum (RFC 1071)
# ---------------------------------------------------------------------------

def ip_checksum(data: bytes) -> int:
    if len(data) & 1:
        data = data + b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


# ---------------------------------------------------------------------------
# Frame builder
# ---------------------------------------------------------------------------

def build_fragment_frame(frag_offset: int, payload_len: int,
                         mf_flag: int) -> bytes:
    """Build an Ethernet + IPv4 fragment frame."""
    # Ethernet header
    eth = PEER_MAC + OUR_MAC + b"\x08\x00"  # note: dst=OUR_MAC, src=PEER

    # IP header
    total_length = IP_HDR_MIN + payload_len
    flags_frag = (frag_offset >> 3) & IP_FRAG_OFFSET_MASK
    if mf_flag:
        flags_frag |= (IP_FLAG_MF >> 0)  # MF is bit 13 in the 16-bit field

    ip_hdr = struct.pack("!BBHHHBBH4s4s",
        0x45,               # ver/ihl
        0x00,               # tos
        total_length,
        IP_ID,
        flags_frag,
        IP_DEFAULT_TTL,
        IP_PROTO_ICMP,
        0,                  # checksum placeholder
        socket.inet_aton(PEER_IP),
        socket.inet_aton(OUR_IP),
    )
    cksum = ip_checksum(ip_hdr)
    ip_hdr = ip_hdr[:10] + struct.pack("!H", cksum) + ip_hdr[12:]

    # Payload: deterministic pattern so the harness can verify
    # reassembled content (each byte = (offset + i) & 0xFF).
    payload = bytes(((frag_offset + i) & 0xFF) for i in range(payload_len))

    return eth + ip_hdr + payload


# ---------------------------------------------------------------------------
# Oracle
# ---------------------------------------------------------------------------

def slot_pre_state(slot_state_name: str):
    """Return (code, flags, total_len, bitmap) for a slot state name."""
    if slot_state_name == "empty":
        return (SS_EMPTY, 0x00, 0, EMPTY_BITMAP)
    elif slot_state_name == "first_half":
        return (SS_FIRST_HALF, 0x80, 0, BM_FIRST_HALF)  # active, no have_last
    elif slot_state_name == "second_half":
        return (SS_SECOND_HALF, 0x81, 800, BM_SECOND_HALF)  # active + have_last
    elif slot_state_name == "near_complete":
        return (SS_NEAR_COMPLETE, 0x81, 800, BM_NEAR_COMPLETE)  # active + have_last
    else:
        raise ValueError(f"unknown slot_state: {slot_state_name}")


def oracle(slot_state_name: str, frag_offset: int, payload_len: int,
           mf_flag: int, pool_free: bool):
    """Predict the outcome of ip_reasm_input for one vector.

    Returns (ret_nonzero, reason, post_active, post_have_last,
             post_total_len, post_bitmap).
    """
    code, pre_flags, pre_total_len, pre_bm = slot_pre_state(slot_state_name)
    pre_active = bool(pre_flags & 0x80)
    pre_have_last = bool(pre_flags & 0x01)

    # 1. payload_len > 0
    if payload_len < 1:
        return (0, REASON_DROP_BOUNDS, pre_active, pre_have_last,
                pre_total_len, pre_bm)

    # 2. frag_offset + payload_len <= REASM_BUF_SIZE
    if frag_offset + payload_len > REASM_BUF_SIZE:
        return (0, REASON_DROP_BOUNDS, pre_active, pre_have_last,
                pre_total_len, pre_bm)

    # 3. MF=1 → payload_len must be multiple of 8
    if mf_flag == 1 and (payload_len % 8) != 0:
        return (0, REASON_DROP_NONALIGNED, pre_active, pre_have_last,
                pre_total_len, pre_bm)

    # 4. Slot search
    if not pre_active:
        # Need a free slot
        if not pool_free:
            # All slots occupied with dummy keys. ip_reasm_input drops.
            # The harness always checks slot 0, which is a dummy:
            # active=1, have_last=0, total_len=0, bitmap=zeros.
            return (0, REASON_DROP_NO_SLOT, True, False, 0, EMPTY_BITMAP)
        # Allocate: new slot becomes active, bitmap empty, min_ttl=255
        pre_bm = EMPTY_BITMAP
        pre_have_last = False
        pre_total_len = 0

    # 5. Overlap check: any bit in [start_bit, end_bit] already set?
    start_bit = frag_offset // 8
    end_bit = (frag_offset + payload_len - 1) // 8
    for b in range(start_bit, end_bit + 1):
        if bitmap_has_bit(pre_bm, b):
            # Overlap → drop. Slot stays in its current state
            # (if it was pre-existing). If it was just allocated,
            # it's now active with empty bitmap — but ip_reasm.S
            # does the overlap check AFTER slot allocation, so the
            # slot stays allocated. In practice, the drop path
            # (.Lri_drop) does NOT free the slot — only .Lri_free_drop
            # and completion free slots. So the slot stays active.
            post_active = True  # slot remains active (was just found or allocated)
            return (0, REASON_DROP_OVERLAP, post_active, pre_have_last,
                    pre_total_len, pre_bm)

    # 6. Accept: copy payload, set bitmap bits
    new_bm = make_bitmap((frag_offset, frag_offset + payload_len))
    post_bm = bitmap_or(pre_bm, new_bm)

    # 7. If MF=0, set have_last + total_len
    post_have_last = pre_have_last
    post_total_len = pre_total_len
    if mf_flag == 0:
        post_have_last = True
        post_total_len = frag_offset + payload_len

    # 8. Check completion
    if post_have_last:
        total_bits = (post_total_len + 7) // 8
        if bitmap_all_set(post_bm, total_bits):
            # 9. Frame size check
            if post_total_len + ETH_HDR_LEN + IP_HDR_MIN > ETH_FRAME_MAX:
                # Oversized → drop AND free slot
                return (0, REASON_DROP_OVERSIZED, False, False,
                        0, EMPTY_BITMAP)
            # Complete! Slot freed, frame returned.
            return (1, REASON_OK_COMPLETE, False, False,
                    0, EMPTY_BITMAP)

    # Incomplete: slot stays active
    return (0, REASON_OK_INCOMPLETE, True, post_have_last,
            post_total_len, post_bm)


# ---------------------------------------------------------------------------
# Binary encoding
# ---------------------------------------------------------------------------

def encode_entry(slot_state_name: str, frag_offset: int, payload_len: int,
                 mf_flag: int, pool_free_str: str) -> bytes:
    """Encode one PICT row as a 256-byte binary entry."""
    pool_free = (pool_free_str == "yes")
    code, pre_flags, pre_total_len, pre_bm = slot_pre_state(slot_state_name)

    ret_nz, reason, post_active, post_have_last, post_total_len, post_bm = \
        oracle(slot_state_name, frag_offset, payload_len, mf_flag, pool_free)

    frame = build_fragment_frame(frag_offset, payload_len, mf_flag)
    frame_len = len(frame)

    # Pad frame_data to 160 bytes
    FRAME_FIELD_SIZE = 256  # fits 14+20+200 = 234 max
    if len(frame) > FRAME_FIELD_SIZE:
        raise ValueError(
            f"frame too large ({len(frame)} B) for {FRAME_FIELD_SIZE}-byte "
            f"field — reduce payload_len in the PICT model"
        )
    frame_padded = frame + bytes(FRAME_FIELD_SIZE - len(frame))
    assert len(frame_padded) == FRAME_FIELD_SIZE

    # Pre-seed block (40 bytes)
    pre_seed = struct.pack("<BBBBHxx",
        code,
        1 if pool_free else 0,
        pre_flags,
        255,  # pre_min_ttl
        pre_total_len,
    )
    pre_seed += pre_bm
    assert len(pre_seed) == 40, f"pre_seed len {len(pre_seed)}"

    # Fragment input block (168 bytes: 8 header + 160 frame)
    frag_block = struct.pack("<HHHBx",
        frame_len,
        frag_offset,
        payload_len,
        mf_flag,
    )
    frag_block += frame_padded
    assert len(frag_block) == 264, f"frag_block len {len(frag_block)}"

    # Expected output block (48 bytes)
    post_flags_byte = (0x80 if post_active else 0) | (0x01 if post_have_last else 0)
    expected = struct.pack("<BBBBHxx",
        1 if ret_nz else 0,
        reason,
        1 if post_active else 0,
        1 if post_have_last else 0,
        post_total_len,
    )
    expected += post_bm
    assert len(expected) == 40, f"expected base len {len(expected)}"

    entry = pre_seed + frag_block + expected
    # Pad to ENTRY_SIZE
    entry += bytes(ENTRY_SIZE - len(entry))
    assert len(entry) == ENTRY_SIZE, f"entry len {len(entry)}"
    return entry


# ---------------------------------------------------------------------------
# Reason names (for --dry-run)
# ---------------------------------------------------------------------------

REASON_NAMES = {
    REASON_OK_COMPLETE:     "COMPLETE",
    REASON_OK_INCOMPLETE:   "INCOMPLETE",
    REASON_DROP_NONALIGNED: "DROP:nonaligned",
    REASON_DROP_NO_SLOT:    "DROP:no_slot",
    REASON_DROP_OVERLAP:    "DROP:overlap",
    REASON_DROP_BOUNDS:     "DROP:bounds",
    REASON_DROP_OVERSIZED:  "DROP:oversized",
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    dry_run = "--dry-run" in sys.argv

    lines = [l.strip() for l in sys.stdin if l.strip() and not l.startswith("#")]
    if not lines:
        print("ERROR: no input on stdin", file=sys.stderr)
        return 1

    header_line = lines[0]
    columns = header_line.split("\t")
    expected_cols = ["slot_state", "frag_offset", "payload_len", "mf_flag", "pool_free"]
    if columns != expected_cols:
        print(f"ERROR: unexpected columns: {columns}", file=sys.stderr)
        print(f"  expected: {expected_cols}", file=sys.stderr)
        return 1

    entries = []
    for i, line in enumerate(lines[1:], 1):
        fields = line.split("\t")
        if len(fields) != 5:
            print(f"ERROR: line {i}: expected 5 fields, got {len(fields)}: {line}",
                  file=sys.stderr)
            return 1

        slot_state  = fields[0]
        frag_offset = int(fields[1])
        payload_len = int(fields[2])
        mf_flag     = int(fields[3])
        pool_free   = fields[4]

        entry_bytes = encode_entry(slot_state, frag_offset, payload_len,
                                   mf_flag, pool_free)
        entries.append(entry_bytes)

        if dry_run:
            _, reason, post_active, _, _, _ = oracle(
                slot_state, frag_offset, payload_len, mf_flag,
                pool_free == "yes",
            )
            print(
                f"  {i:3d}: slot={slot_state:15s} off={frag_offset:4d} "
                f"len={payload_len:3d} mf={mf_flag} pool={pool_free:3s} "
                f"→ {REASON_NAMES.get(reason, '???'):18s} "
                f"post_active={int(post_active)}",
                file=sys.stderr,
            )

    count = len(entries)
    print(f"reasm_oracle: {count} vectors", file=sys.stderr)

    if dry_run:
        # Tally by reason
        from collections import Counter
        reasons = Counter()
        for line in lines[1:]:
            fields = line.split("\t")
            _, reason, _, _, _, _ = oracle(
                fields[0], int(fields[1]), int(fields[2]),
                int(fields[3]), fields[4] == "yes",
            )
            reasons[REASON_NAMES.get(reason, "???")] += 1
        print(f"\n  Tally: {dict(reasons)}", file=sys.stderr)
        return 0

    # Write binary blob: 16-byte header + entries
    blob_header = struct.pack("<I", count) + bytes(12)
    sys.stdout.buffer.write(blob_header)
    for e in entries:
        sys.stdout.buffer.write(e)

    return 0


if __name__ == "__main__":
    sys.exit(main())
