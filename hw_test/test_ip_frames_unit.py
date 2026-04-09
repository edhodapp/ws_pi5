"""
test_ip_frames_unit.py — off-hardware unit tests for ip_frames.py.

These tests do NOT require Pi hardware — they exercise pure frame
construction, parsing, and the Python reference reassembler. Run with:

    .venv/bin/pytest hw_test/test_ip_frames_unit.py -v

The hardware-gating @requires_hardware marker is intentionally NOT
applied here. Every test either:
  (a) round-trips a build→parse and asserts field equality, or
  (b) cross-checks ip_checksum against an independent reference.

This is "prove the tool before using it" — verification checkpoint #1
and #2 from the L3 hardening plan.
"""

import pytest

from eth_frames import (
    ETH_HEADER_LEN,
    ETHERTYPE_IPV4,
    parse_eth_header,
)
from ip_frames import (
    ICMP_CODE_HOST_UNREACH,
    ICMP_DEST_UNREACHABLE,
    ICMP_ECHO_REPLY,
    ICMP_ECHO_REQUEST,
    ICMP_HDR_LEN,
    IP_DEFAULT_TTL,
    IP_FLAG_DF,
    IP_FLAG_MF,
    IP_HDR_MIN,
    IP_PROTO_ICMP,
    IP_PROTO_UDP,
    IP_VERSION_4,
    REASM_COMPLETE_LIMIT,
    UDP_HDR_LEN,
    build_bogus_ip_frame,
    build_fragment_frames,
    build_icmp_echo_frame,
    build_icmp_echo_request,
    build_icmp_raw,
    build_ip_frame_with_proto,
    build_ipv4_header,
    build_udp_frame,
    build_udp_header,
    ip_checksum,
    parse_icmp,
    parse_ipv4_header,
    reassemble_fragments_python,
)


SRC_MAC = b"\x00\xe0\x4c\x0a\x2b\xed"
DST_MAC = b"\xdc\xa6\x32\x12\x34\x56"
SRC_IP  = "10.0.0.1"
DST_IP  = "10.0.0.2"


# ==============================================================
# RFC 1071 one's-complement checksum
# ==============================================================

class TestIpChecksum:

    def test_zero_input(self):
        # Checksum of zero bytes is 0xFFFF (ones' complement of 0).
        assert ip_checksum(b"") == 0xFFFF

    def test_known_vector_rfc1071(self):
        # RFC 1071 §3 example: sum of 0x0001 0xf203 0xf4f5 0xf6f7
        # → ~0xddf2 = 0x220d
        data = bytes.fromhex("0001f203f4f5f6f7")
        assert ip_checksum(data) == 0x220D

    def test_odd_length_pads_zero(self):
        # The tail byte becomes the high byte of an implicit halfword,
        # so "ab" (1 byte) and "ab 00" (2 bytes) checksum identically.
        assert ip_checksum(b"\xab") == ip_checksum(b"\xab\x00")

    def test_verify_self(self):
        # Building a header with checksum=None and then verifying
        # the resulting bytes must produce 0 (the RFC 1071 property).
        hdr = build_ipv4_header(
            SRC_IP, DST_IP, protocol=IP_PROTO_ICMP, payload_len=8,
        )
        assert ip_checksum(hdr) == 0

    def test_all_ones_saturates_to_zero(self):
        # 0xFFFF summed with itself folds to 0xFFFF; ~0xFFFF = 0.
        assert ip_checksum(b"\xff\xff") == 0x0000

    def test_multi_word_carry_fold(self):
        # 4 × 0xFFFF = 0x3FFFC → fold → 0xFFFC + 3 = 0xFFFF → ~ = 0.
        # Ones' complement property: summing any number of 0xFFFF
        # words folds to 0xFFFF, which complements to 0. Exercises
        # the multi-pass fold path.
        assert ip_checksum(b"\xff\xff" * 4) == 0x0000

    def test_carry_fold_multi_pass(self):
        # Force a genuine second-pass fold: sum enough non-0xFFFF
        # words to overflow the 16-bit slot twice.
        # 0x8000 × 5 = 0x28000 → fold → 0x8000 + 2 = 0x8002 → ~ = 0x7FFD
        data = b"\x80\x00" * 5
        assert ip_checksum(data) == 0x7FFD


# ==============================================================
# IPv4 header build + parse round-trip
# ==============================================================

class TestIpv4Header:

    def test_build_length_is_20(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8)
        assert len(hdr) == IP_HDR_MIN

    def test_build_ver_ihl_is_0x45(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8)
        assert hdr[0] == 0x45  # pinned — the Pi rejects anything else

    def test_build_parse_round_trip_defaults(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8)
        p = parse_ipv4_header(hdr)
        assert p["version"] == IP_VERSION_4
        assert p["ihl"] == 5
        assert p["tos"] == 0
        assert p["total_length"] == 28
        assert p["ident"] == 0
        assert p["flags"] == 0
        assert p["frag_off"] == 0
        assert p["ttl"] == IP_DEFAULT_TTL
        assert p["protocol"] == IP_PROTO_ICMP
        assert p["src_ip"] == SRC_IP
        assert p["dst_ip"] == DST_IP

    def test_build_checksum_verifies(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=100)
        assert ip_checksum(hdr) == 0

    def test_build_forced_checksum_stored(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8,
                                checksum=0xBEEF)
        assert parse_ipv4_header(hdr)["checksum"] == 0xBEEF

    def test_build_df_flag(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8,
                                flags=IP_FLAG_DF)
        assert parse_ipv4_header(hdr)["flags"] == IP_FLAG_DF

    def test_build_mf_flag(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8,
                                flags=IP_FLAG_MF)
        assert parse_ipv4_header(hdr)["flags"] == IP_FLAG_MF

    def test_build_frag_off(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8,
                                flags=IP_FLAG_MF, frag_off=1480)
        p = parse_ipv4_header(hdr)
        assert p["flags"] == IP_FLAG_MF
        assert p["frag_off"] == 1480

    def test_build_ident_preserved(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8,
                                ident=0xABCD)
        assert parse_ipv4_header(hdr)["ident"] == 0xABCD

    def test_build_ttl_0_accepted_by_builder(self):
        # Builder accepts TTL=0; it's ip_handle's job to drop it.
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8,
                                ttl=0)
        assert parse_ipv4_header(hdr)["ttl"] == 0

    def test_build_ttl_255_accepted(self):
        hdr = build_ipv4_header(SRC_IP, DST_IP,
                                protocol=IP_PROTO_ICMP, payload_len=8,
                                ttl=255)
        assert parse_ipv4_header(hdr)["ttl"] == 255

    def test_build_rejects_bad_version(self):
        with pytest.raises(ValueError, match="version"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=1, payload_len=8,
                              version=16)

    def test_build_rejects_bad_ihl(self):
        with pytest.raises(ValueError, match="ihl"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=1, payload_len=8,
                              ihl=16)

    def test_build_rejects_bad_ttl(self):
        with pytest.raises(ValueError, match="ttl"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=1, payload_len=8,
                              ttl=256)

    def test_build_rejects_negative_ttl(self):
        with pytest.raises(ValueError, match="ttl"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=1, payload_len=8,
                              ttl=-1)

    def test_build_rejects_bad_protocol(self):
        with pytest.raises(ValueError, match="protocol"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=-1, payload_len=8)

    def test_build_rejects_bad_ident(self):
        with pytest.raises(ValueError, match="ident"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=1, payload_len=8,
                              ident=0x10000)

    def test_build_rejects_unaligned_frag_off(self):
        with pytest.raises(ValueError, match="multiple of 8"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=1, payload_len=8,
                              frag_off=7)

    def test_build_rejects_flags_in_offset_bits(self):
        # flags must not leak into the low 13 bits
        with pytest.raises(ValueError, match="overlap"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=1, payload_len=8,
                              flags=0x0001)

    def test_build_rejects_huge_payload(self):
        with pytest.raises(ValueError, match="payload_len"):
            build_ipv4_header(SRC_IP, DST_IP, protocol=1, payload_len=0xFFFF)

    def test_parse_too_short(self):
        with pytest.raises(ValueError, match="too short"):
            parse_ipv4_header(b"\x00" * 19)


# ==============================================================
# ICMP echo request build + parse
# ==============================================================

class TestIcmp:

    def test_echo_request_header_bytes(self):
        icmp = build_icmp_echo_request(ident=0x1234, seq=0x5678)
        assert len(icmp) == ICMP_HDR_LEN
        assert icmp[0] == ICMP_ECHO_REQUEST
        assert icmp[1] == 0  # code

    def test_echo_request_parse(self):
        payload = b"hello world"
        icmp = build_icmp_echo_request(ident=0xDEAD, seq=0xBEEF,
                                       payload=payload)
        p = parse_icmp(icmp)
        assert p["type"] == ICMP_ECHO_REQUEST
        assert p["code"] == 0
        assert p["ident"] == 0xDEAD
        assert p["seq"] == 0xBEEF
        assert p["payload"] == payload

    def test_echo_request_checksum_verifies(self):
        # Independent verify: build, then run ip_checksum over the
        # whole thing and assert it folds to 0.
        icmp = build_icmp_echo_request(ident=1, seq=1, payload=b"abcd")
        assert ip_checksum(icmp) == 0

    def test_echo_request_odd_payload_checksum(self):
        # Odd payload length exercises the tail-byte path in ip_checksum.
        icmp = build_icmp_echo_request(ident=1, seq=1,
                                       payload=bytes(37))
        assert ip_checksum(icmp) == 0

    def test_echo_request_bad_checksum_flag(self):
        icmp = build_icmp_echo_request(ident=1, seq=1, payload=b"abc",
                                       bad_checksum=True)
        assert parse_icmp(icmp)["checksum"] == 0xDEAD
        # Independent verify: the folded checksum must NOT be 0.
        assert ip_checksum(icmp) != 0

    def test_echo_request_rejects_bad_ident(self):
        with pytest.raises(ValueError, match="ident"):
            build_icmp_echo_request(ident=0x10000, seq=1)

    def test_echo_request_rejects_bad_seq(self):
        with pytest.raises(ValueError, match="seq"):
            build_icmp_echo_request(ident=1, seq=-1)

    def test_icmp_raw_dest_unreachable(self):
        rest = b"\x00\x00\x00\x00"
        icmp = build_icmp_raw(ICMP_DEST_UNREACHABLE, ICMP_CODE_HOST_UNREACH,
                              rest)
        p = parse_icmp(icmp)
        assert p["type"] == ICMP_DEST_UNREACHABLE
        assert p["code"] == ICMP_CODE_HOST_UNREACH
        assert p["rest"] == rest
        assert ip_checksum(icmp) == 0

    def test_icmp_raw_rejects_wrong_rest_length(self):
        with pytest.raises(ValueError, match="4 bytes"):
            build_icmp_raw(8, 0, b"\x00\x00\x00")

    def test_parse_too_short(self):
        with pytest.raises(ValueError, match="too short"):
            parse_icmp(b"\x00" * 7)


# ==============================================================
# UDP header build
# ==============================================================

class TestUdp:

    def test_header_length_no_payload(self):
        udp = build_udp_header(src_port=1234, dst_port=5678, payload=b"")
        assert len(udp) == UDP_HDR_LEN

    def test_header_length_with_payload(self):
        udp = build_udp_header(src_port=1234, dst_port=5678, payload=b"hi")
        assert len(udp) == UDP_HDR_LEN + 2

    def test_default_checksum_is_zero(self):
        # Default: no pseudo-header, no explicit checksum → 0 ("not computed")
        udp = build_udp_header(src_port=1, dst_port=2, payload=b"x")
        assert udp[6:8] == b"\x00\x00"

    def test_length_field_in_wire_order(self):
        udp = build_udp_header(src_port=1, dst_port=2, payload=b"abcd")
        # length field is big-endian in bytes [4:6]
        assert udp[4:6] == b"\x00\x0c"   # 12 = 8 hdr + 4 payload

    def test_port_fields_in_wire_order(self):
        udp = build_udp_header(src_port=0x1234, dst_port=0x5678,
                               payload=b"")
        assert udp[0:2] == b"\x12\x34"
        assert udp[2:4] == b"\x56\x78"

    def test_computed_checksum_with_pseudo_header(self):
        # When pseudo_src_ip + pseudo_dst_ip + checksum=None are given,
        # the result must be non-zero (echo payload is non-trivial).
        udp = build_udp_header(src_port=1, dst_port=7, payload=b"hello",
                               checksum=None,
                               pseudo_src_ip=SRC_IP, pseudo_dst_ip=DST_IP)
        cksum_bytes = udp[6:8]
        assert cksum_bytes != b"\x00\x00"

    def test_rejects_bad_src_port(self):
        with pytest.raises(ValueError, match="src_port"):
            build_udp_header(src_port=0x10000, dst_port=1, payload=b"")

    def test_rejects_bad_dst_port(self):
        with pytest.raises(ValueError, match="dst_port"):
            build_udp_header(src_port=1, dst_port=-1, payload=b"")


# ==============================================================
# Combined Ethernet+IP+L4 frame builders
# ==============================================================

class TestCombinedFrames:

    def test_icmp_echo_frame_structure(self):
        frame = build_icmp_echo_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ident=1, seq=1, payload=b"ABCD",
        )
        # 14 + 20 + 8 + 4 = 46
        assert len(frame) == 46
        eth = parse_eth_header(frame)
        assert eth["src"] == SRC_MAC
        assert eth["dst"] == DST_MAC
        assert eth["ethertype"] == ETHERTYPE_IPV4

        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["src_ip"] == SRC_IP
        assert ip["dst_ip"] == DST_IP
        assert ip["protocol"] == IP_PROTO_ICMP
        assert ip["total_length"] == 20 + 8 + 4

        icmp = parse_icmp(frame[ETH_HEADER_LEN + IP_HDR_MIN:])
        assert icmp["type"] == ICMP_ECHO_REQUEST
        assert icmp["ident"] == 1
        assert icmp["seq"] == 1
        assert icmp["payload"] == b"ABCD"

    def test_icmp_echo_frame_full_checksum_chain(self):
        # Both IP and ICMP checksums must verify.
        frame = build_icmp_echo_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ident=7, seq=42, payload=b"checksum-me",
        )
        ip_bytes = frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]
        assert ip_checksum(ip_bytes) == 0
        ip = parse_ipv4_header(ip_bytes)
        icmp_bytes = frame[ETH_HEADER_LEN + IP_HDR_MIN:
                           ETH_HEADER_LEN + ip["total_length"]]
        assert ip_checksum(icmp_bytes) == 0

    def test_icmp_echo_frame_df_flag(self):
        frame = build_icmp_echo_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ident=1, seq=1, df=True,
        )
        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["flags"] == IP_FLAG_DF

    def test_icmp_echo_frame_bad_ip_checksum(self):
        frame = build_icmp_echo_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ident=1, seq=1, bad_ip_checksum=True,
        )
        ip_bytes = frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]
        assert ip_checksum(ip_bytes) != 0
        assert parse_ipv4_header(ip_bytes)["checksum"] == 0x1234

    def test_icmp_echo_frame_bad_icmp_checksum(self):
        frame = build_icmp_echo_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ident=1, seq=1, bad_icmp_checksum=True,
        )
        # IP checksum still OK
        ip_bytes = frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]
        assert ip_checksum(ip_bytes) == 0
        # ICMP checksum stored as 0xDEAD, fold NOT zero
        ip = parse_ipv4_header(ip_bytes)
        icmp_bytes = frame[ETH_HEADER_LEN + IP_HDR_MIN:
                           ETH_HEADER_LEN + ip["total_length"]]
        assert parse_icmp(icmp_bytes)["checksum"] == 0xDEAD
        assert ip_checksum(icmp_bytes) != 0

    def test_icmp_echo_frame_payload_sizes(self):
        # Parametric spot check across the plan's size matrix.
        for size in [1, 37, 64, 512, 1000, 1400, 1472]:
            payload = bytes((i & 0xFF) for i in range(size))
            frame = build_icmp_echo_frame(
                SRC_MAC, DST_MAC, SRC_IP, DST_IP,
                ident=1, seq=1, payload=payload,
            )
            assert len(frame) == 14 + 20 + 8 + size
            ip_bytes = frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]
            assert ip_checksum(ip_bytes) == 0
            ip = parse_ipv4_header(ip_bytes)
            icmp_bytes = frame[ETH_HEADER_LEN + IP_HDR_MIN:
                               ETH_HEADER_LEN + ip["total_length"]]
            assert ip_checksum(icmp_bytes) == 0
            assert parse_icmp(icmp_bytes)["payload"] == payload

    def test_udp_frame_structure(self):
        frame = build_udp_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            src_port=12345, dst_port=9999, payload=b"xyz",
        )
        assert len(frame) == 14 + 20 + 8 + 3
        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["protocol"] == IP_PROTO_UDP
        assert ip["total_length"] == 20 + 8 + 3

    def test_ip_frame_with_arbitrary_proto(self):
        # protocol=99 is the "unassigned" sentinel used by the
        # protocol-unreachable test.
        frame = build_ip_frame_with_proto(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=99, payload=b"payload",
        )
        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["protocol"] == 99
        assert ip_checksum(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]) == 0


# ==============================================================
# Fragment splitter + python-side reassembler round-trip
# ==============================================================
#
# This is verification checkpoint #2 from the plan: prove the
# splitter is correct BEFORE sending a fragment to the Pi. If this
# round-trip breaks, all hardware fragment tests are lying.

class TestFragmentSplitter:

    def test_two_fragments_ordered(self):
        payload = bytes(range(0, 16)) * 46  # 16 * 46 = 736 bytes
        assert len(payload) == 736
        frames = build_fragment_frames(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=IP_PROTO_ICMP,
            payload=payload,
            ident=0x1234,
            frag_size=368,  # multiple of 8
        )
        assert len(frames) == 2
        # First fragment: MF=1, frag_off=0
        ip0 = parse_ipv4_header(frames[0][ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip0["flags"] == IP_FLAG_MF
        assert ip0["frag_off"] == 0
        assert ip0["ident"] == 0x1234
        # Second fragment: MF=0, frag_off=368
        ip1 = parse_ipv4_header(frames[1][ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip1["flags"] == 0
        assert ip1["frag_off"] == 368
        assert ip1["ident"] == 0x1234

    def test_three_fragments_ident_shared(self):
        payload = bytes(500)   # not 8-aligned; last frag may be short
        frames = build_fragment_frames(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=IP_PROTO_ICMP,
            payload=payload, ident=42, frag_size=200,
        )
        assert len(frames) == 3
        for f in frames:
            ip = parse_ipv4_header(f[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
            assert ip["ident"] == 42

    def test_last_fragment_has_mf_0(self):
        payload = bytes(1000)
        frames = build_fragment_frames(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=IP_PROTO_ICMP,
            payload=payload, ident=1, frag_size=400,
        )
        last_ip = parse_ipv4_header(
            frames[-1][ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]
        )
        assert last_ip["flags"] == 0

    def test_all_but_last_have_mf_1(self):
        payload = bytes(1200)
        frames = build_fragment_frames(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=IP_PROTO_ICMP,
            payload=payload, ident=1, frag_size=400,
        )
        for f in frames[:-1]:
            ip = parse_ipv4_header(f[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
            assert ip["flags"] == IP_FLAG_MF

    @pytest.mark.parametrize("n,size", [
        (2, 368),
        (3, 480),
        (8, 168),
    ])
    def test_python_reassembly_round_trip(self, n, size):
        # Generate n*size bytes of patterned payload, split, then
        # round-trip via reassemble_fragments_python. Must match
        # byte-for-byte.
        total = n * size
        assert total <= REASM_COMPLETE_LIMIT  # stays within Pi's ceiling
        payload = bytes(((i * 31 + 7) & 0xFF) for i in range(total))
        frames = build_fragment_frames(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=IP_PROTO_ICMP,
            payload=payload, ident=0xCAFE, frag_size=size,
        )
        assert len(frames) == n
        reassembled = reassemble_fragments_python(frames)
        assert reassembled == payload

    def test_reassembly_works_on_shuffled_order(self):
        # The Python reference reassembler sorts by frag_off, so out-
        # of-order input must still produce the original bytes.
        payload = bytes(((i * 13 + 1) & 0xFF) for i in range(1000))
        frames = build_fragment_frames(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=IP_PROTO_ICMP,
            payload=payload, ident=1, frag_size=200,
        )
        shuffled = [frames[3], frames[0], frames[4], frames[1], frames[2]]
        assert reassemble_fragments_python(shuffled) == payload

    def test_splitter_rejects_zero_frag_size(self):
        with pytest.raises(ValueError, match="> 0"):
            build_fragment_frames(
                SRC_MAC, DST_MAC, SRC_IP, DST_IP,
                protocol=1, payload=b"x", ident=1, frag_size=0,
            )

    def test_splitter_rejects_unaligned_frag_size(self):
        with pytest.raises(ValueError, match="multiple of 8"):
            build_fragment_frames(
                SRC_MAC, DST_MAC, SRC_IP, DST_IP,
                protocol=1, payload=b"x" * 100, ident=1, frag_size=17,
            )

    def test_splitter_rejects_empty_payload(self):
        with pytest.raises(ValueError, match="non-empty"):
            build_fragment_frames(
                SRC_MAC, DST_MAC, SRC_IP, DST_IP,
                protocol=1, payload=b"", ident=1, frag_size=8,
            )

    def test_splitter_single_small_payload(self):
        # Payload shorter than frag_size — produces one fragment with
        # MF=0 (i.e. an un-fragmented datagram that happened to go
        # through the splitter).
        payload = b"small"
        frames = build_fragment_frames(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=IP_PROTO_ICMP,
            payload=payload, ident=1, frag_size=8,
        )
        assert len(frames) == 1
        ip = parse_ipv4_header(frames[0][ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["flags"] == 0
        assert ip["frag_off"] == 0

    def test_splitter_preserves_ttl(self):
        frames = build_fragment_frames(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            protocol=IP_PROTO_ICMP,
            payload=bytes(200), ident=1, frag_size=8,
            ttl=17,
        )
        for f in frames:
            ip = parse_ipv4_header(f[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
            assert ip["ttl"] == 17


# ==============================================================
# build_bogus_ip_frame — malformed-header knobs
# ==============================================================

class TestBogusIpFrame:

    def test_default_is_well_formed(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            payload=b"AB",
        )
        ip_bytes = frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]
        assert ip_checksum(ip_bytes) == 0
        ip = parse_ipv4_header(ip_bytes)
        assert ip["version"] == 4
        assert ip["ihl"] == 5
        assert ip["protocol"] == IP_PROTO_ICMP

    def test_version_6_in_ipv4_ethertype(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            version=6, payload=b"AB",
        )
        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["version"] == 6
        assert ip["ihl"] == 5
        # VER_IHL byte = (6 << 4) | 5 = 0x65
        assert frame[ETH_HEADER_LEN] == 0x65

    def test_ihl_below_minimum(self):
        # ihl=4 is nonsense — the header itself claims to be 16 bytes,
        # which cannot fit the mandatory IPv4 fields.
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ihl=4, payload=b"AB",
        )
        # VER_IHL byte = (4 << 4) | 4 = 0x44
        assert frame[ETH_HEADER_LEN] == 0x44

    def test_ihl_6_with_options(self):
        options = b"\x00" * 4  # NOP NOP NOP NOP
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ihl=6, options=options, payload=b"AB",
        )
        # 14 eth + 20 fixed header + 4 options + 2 payload = 40
        assert len(frame) == 40
        # VER_IHL byte = 0x46
        assert frame[ETH_HEADER_LEN] == 0x46

    def test_ihl_6_requires_matching_options_length(self):
        with pytest.raises(ValueError, match="options length"):
            build_bogus_ip_frame(
                SRC_MAC, DST_MAC, SRC_IP, DST_IP,
                ihl=6, options=b"\x00" * 8,
            )

    def test_total_length_override_below_20(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            total_length_override=10, payload=b"ABCD",
        )
        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["total_length"] == 10

    def test_total_length_override_exceeds_frame(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            total_length_override=1500, payload=b"only4b",
        )
        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["total_length"] == 1500
        # Actual frame length is much smaller than 1500 + 14
        assert len(frame) < 1500

    def test_bad_checksum(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            bad_checksum=True, payload=b"AB",
        )
        ip_bytes = frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]
        assert parse_ipv4_header(ip_bytes)["checksum"] == 0xBEEF
        assert ip_checksum(ip_bytes) != 0

    def test_ttl_zero(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ttl=0, payload=b"AB",
        )
        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["ttl"] == 0
        # Checksum still valid — only TTL is out of spec
        assert ip_checksum(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN]) == 0

    def test_ttl_one(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            ttl=1, payload=b"AB",
        )
        ip = parse_ipv4_header(frame[ETH_HEADER_LEN:ETH_HEADER_LEN + IP_HDR_MIN])
        assert ip["ttl"] == 1

    def test_truncate_cuts_frame(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            payload=b"ABCDEFGHIJ", truncate_to=12,
        )
        # 14 eth + 12 post-eth bytes
        assert len(frame) == 14 + 12

    def test_truncate_preserves_ethernet_header(self):
        frame = build_bogus_ip_frame(
            SRC_MAC, DST_MAC, SRC_IP, DST_IP,
            payload=b"0123456789", truncate_to=8,
        )
        eth = parse_eth_header(frame)
        assert eth["src"] == SRC_MAC
        assert eth["dst"] == DST_MAC
        assert eth["ethertype"] == ETHERTYPE_IPV4
