"""
test_eth_frames_unit.py — off-hardware unit tests for eth_frames.py.

These tests do NOT require Pi hardware — they exercise pure frame
construction and parsing in process. Run with:

    .venv/bin/pytest hw_test/test_eth_frames_unit.py -v

The hardware-gating @requires_hardware marker is intentionally NOT
applied here.
"""

import pytest

from eth_frames import (
    ARP_OP_REPLY,
    ARP_OP_REQUEST,
    ARP_PACKET_LEN,
    BROADCAST_MAC,
    ETH_HEADER_LEN,
    ETH_MAX_FRAME,
    ETH_MIN_FRAME,
    ETHERTYPE_ARP,
    ETHERTYPE_IPV4,
    ETHERTYPE_VLAN,
    ZERO_MAC,
    build_arp_reply,
    build_arp_request,
    build_bogus_ethertype,
    build_eth_frame,
    build_eth_header,
    build_oversize,
    build_runt,
    mac_bytes_to_str,
    mac_str_to_bytes,
    parse_arp,
    parse_eth_header,
)


# --- MAC conversion ---

class TestMacConversion:

    def test_str_to_bytes_lowercase(self):
        assert mac_str_to_bytes("aa:bb:cc:dd:ee:ff") == b"\xaa\xbb\xcc\xdd\xee\xff"

    def test_str_to_bytes_uppercase(self):
        assert mac_str_to_bytes("AA:BB:CC:DD:EE:FF") == b"\xaa\xbb\xcc\xdd\xee\xff"

    def test_str_to_bytes_short_octet(self):
        # "1" should parse as 0x01 (single hex char)
        assert mac_str_to_bytes("1:2:3:4:5:6") == b"\x01\x02\x03\x04\x05\x06"

    def test_str_to_bytes_zero(self):
        assert mac_str_to_bytes("00:00:00:00:00:00") == ZERO_MAC

    def test_str_to_bytes_broadcast(self):
        assert mac_str_to_bytes("ff:ff:ff:ff:ff:ff") == BROADCAST_MAC

    def test_str_to_bytes_too_few_octets(self):
        with pytest.raises(ValueError, match="6 octets"):
            mac_str_to_bytes("aa:bb:cc:dd:ee")

    def test_str_to_bytes_too_many_octets(self):
        with pytest.raises(ValueError, match="6 octets"):
            mac_str_to_bytes("aa:bb:cc:dd:ee:ff:00")

    def test_str_to_bytes_empty_octet(self):
        with pytest.raises(ValueError, match="octet 2 invalid"):
            mac_str_to_bytes("aa:bb::dd:ee:ff")

    def test_str_to_bytes_long_octet(self):
        with pytest.raises(ValueError, match="invalid"):
            mac_str_to_bytes("aaa:bb:cc:dd:ee:ff")

    def test_str_to_bytes_non_hex(self):
        with pytest.raises(ValueError):
            mac_str_to_bytes("zz:bb:cc:dd:ee:ff")

    def test_bytes_to_str(self):
        assert mac_bytes_to_str(b"\xaa\xbb\xcc\xdd\xee\xff") == "aa:bb:cc:dd:ee:ff"

    def test_bytes_to_str_zero(self):
        assert mac_bytes_to_str(ZERO_MAC) == "00:00:00:00:00:00"

    def test_bytes_to_str_wrong_length(self):
        with pytest.raises(ValueError, match="6 bytes"):
            mac_bytes_to_str(b"\xaa\xbb")

    def test_round_trip(self):
        original = "12:34:56:78:9a:bc"
        assert mac_bytes_to_str(mac_str_to_bytes(original)) == original


# --- Ethernet header ---

class TestEthHeader:

    def test_build_basic(self):
        dst = b"\x01\x02\x03\x04\x05\x06"
        src = b"\xaa\xbb\xcc\xdd\xee\xff"
        hdr = build_eth_header(dst, src, ETHERTYPE_ARP)
        assert len(hdr) == ETH_HEADER_LEN
        assert hdr[0:6] == dst
        assert hdr[6:12] == src
        assert hdr[12:14] == b"\x08\x06"  # ethertype 0x0806 big-endian

    def test_build_ipv4_ethertype(self):
        hdr = build_eth_header(BROADCAST_MAC, ZERO_MAC, ETHERTYPE_IPV4)
        assert hdr[12:14] == b"\x08\x00"

    def test_build_max_ethertype(self):
        hdr = build_eth_header(BROADCAST_MAC, ZERO_MAC, 0xFFFF)
        assert hdr[12:14] == b"\xff\xff"

    def test_build_dst_wrong_length(self):
        with pytest.raises(ValueError, match="6 bytes"):
            build_eth_header(b"\x01\x02", BROADCAST_MAC, ETHERTYPE_ARP)

    def test_build_src_wrong_length(self):
        with pytest.raises(ValueError, match="6 bytes"):
            build_eth_header(BROADCAST_MAC, b"\x01\x02", ETHERTYPE_ARP)

    def test_build_negative_ethertype(self):
        with pytest.raises(ValueError, match="out of range"):
            build_eth_header(BROADCAST_MAC, ZERO_MAC, -1)

    def test_build_ethertype_overflow(self):
        with pytest.raises(ValueError, match="out of range"):
            build_eth_header(BROADCAST_MAC, ZERO_MAC, 0x10000)

    def test_parse_basic(self):
        dst = b"\x01\x02\x03\x04\x05\x06"
        src = b"\xaa\xbb\xcc\xdd\xee\xff"
        hdr = build_eth_header(dst, src, ETHERTYPE_VLAN)
        parsed = parse_eth_header(hdr)
        assert parsed["dst"] == dst
        assert parsed["src"] == src
        assert parsed["ethertype"] == ETHERTYPE_VLAN

    def test_parse_with_payload(self):
        # parse_eth_header should ignore bytes after the header
        frame = build_eth_header(BROADCAST_MAC, ZERO_MAC, ETHERTYPE_IPV4) + b"X" * 100
        parsed = parse_eth_header(frame)
        assert parsed["ethertype"] == ETHERTYPE_IPV4

    def test_parse_too_short(self):
        with pytest.raises(ValueError, match="too short"):
            parse_eth_header(b"\x00" * 13)


# --- build_eth_frame and padding ---

class TestEthFrame:

    def test_no_padding_when_long_enough(self):
        payload = bytes(50)
        frame = build_eth_frame(BROADCAST_MAC, ZERO_MAC, ETHERTYPE_ARP, payload,
                                pad_to=ETH_MIN_FRAME)
        # 14 + 50 = 64 > 60, no pad expected
        assert len(frame) == 64

    def test_padding_short_payload(self):
        payload = bytes(10)
        frame = build_eth_frame(BROADCAST_MAC, ZERO_MAC, ETHERTYPE_ARP, payload,
                                pad_to=ETH_MIN_FRAME)
        assert len(frame) == ETH_MIN_FRAME
        # Pad bytes are zero
        assert frame[ETH_HEADER_LEN + 10:] == bytes(60 - ETH_HEADER_LEN - 10)

    def test_no_pad_arg(self):
        payload = b"hello"
        frame = build_eth_frame(BROADCAST_MAC, ZERO_MAC, ETHERTYPE_ARP, payload)
        assert len(frame) == ETH_HEADER_LEN + len(payload)


# --- ARP request/reply round-trip ---

class TestArp:

    SRC_MAC = b"\x00\xe0\x4c\x0a\x2b\xed"
    SRC_IP  = "10.0.0.1"
    PI_MAC  = b"\xdc\xa6\x32\x12\x34\x56"
    PI_IP   = "10.0.0.2"

    def test_request_structure(self):
        frame = build_arp_request(self.SRC_MAC, self.SRC_IP, self.PI_IP)
        assert len(frame) == ETH_MIN_FRAME  # padded to 60
        eth = parse_eth_header(frame)
        assert eth["dst"] == BROADCAST_MAC
        assert eth["src"] == self.SRC_MAC
        assert eth["ethertype"] == ETHERTYPE_ARP

    def test_request_unicast_dst(self):
        frame = build_arp_request(self.SRC_MAC, self.SRC_IP, self.PI_IP,
                                  dst_mac=self.PI_MAC)
        assert parse_eth_header(frame)["dst"] == self.PI_MAC

    def test_request_parses_back(self):
        frame = build_arp_request(self.SRC_MAC, self.SRC_IP, self.PI_IP)
        arp = parse_arp(frame)
        assert arp["opcode"] == ARP_OP_REQUEST
        assert arp["sha"] == self.SRC_MAC
        assert arp["spa"] == self.SRC_IP
        assert arp["tha"] == ZERO_MAC
        assert arp["tpa"] == self.PI_IP

    def test_reply_structure(self):
        frame = build_arp_reply(self.PI_MAC, self.PI_IP,
                                self.SRC_MAC, self.SRC_IP)
        eth = parse_eth_header(frame)
        # Reply is unicast back to the requester
        assert eth["dst"] == self.SRC_MAC
        assert eth["src"] == self.PI_MAC

    def test_reply_parses_back(self):
        frame = build_arp_reply(self.PI_MAC, self.PI_IP,
                                self.SRC_MAC, self.SRC_IP)
        arp = parse_arp(frame)
        assert arp["opcode"] == ARP_OP_REPLY
        assert arp["sha"] == self.PI_MAC
        assert arp["spa"] == self.PI_IP
        assert arp["tha"] == self.SRC_MAC
        assert arp["tpa"] == self.SRC_IP

    def test_request_payload_length(self):
        # ARP payload (post-Ethernet header, pre-padding) is 28 bytes
        frame = build_arp_request(self.SRC_MAC, self.SRC_IP, self.PI_IP)
        # First 14 bytes are eth header, next 28 bytes are ARP, rest is pad
        assert frame[ETH_HEADER_LEN:ETH_HEADER_LEN + ARP_PACKET_LEN][:2] == b"\x00\x01"  # htype=eth
        assert frame[ETH_HEADER_LEN + 2:ETH_HEADER_LEN + 4] == b"\x08\x00"  # ptype=ipv4
        assert frame[ETH_HEADER_LEN + 4] == 6  # hlen
        assert frame[ETH_HEADER_LEN + 5] == 4  # plen

    def test_parse_arp_rejects_non_arp_ethertype(self):
        frame = build_eth_frame(BROADCAST_MAC, self.SRC_MAC, ETHERTYPE_IPV4,
                                bytes(46), pad_to=ETH_MIN_FRAME)
        with pytest.raises(ValueError, match="not an ARP frame"):
            parse_arp(frame)

    def test_parse_arp_rejects_short_frame(self):
        # Valid Ethernet header + ARP ethertype but truncated body
        frame = build_eth_header(BROADCAST_MAC, self.SRC_MAC, ETHERTYPE_ARP) + b"\x00" * 10
        with pytest.raises(ValueError, match="too short for ARP"):
            parse_arp(frame)

    def test_arp_request_invalid_src_ip(self):
        with pytest.raises(OSError):
            build_arp_request(self.SRC_MAC, "not.an.ip", self.PI_IP)


# --- Boundary builders (runt / oversize / bogus ethertype) ---

class TestBoundaryFrames:

    DST = b"\x01\x02\x03\x04\x05\x06"
    SRC = b"\x0a\x0b\x0c\x0d\x0e\x0f"

    def test_runt_min_length(self):
        frame = build_runt(self.DST, self.SRC, ETH_HEADER_LEN)
        assert len(frame) == ETH_HEADER_LEN
        # Header still well-formed
        eth = parse_eth_header(frame)
        assert eth["dst"] == self.DST

    @pytest.mark.parametrize("length", [14, 30, 59])
    def test_runt_lengths(self, length):
        frame = build_runt(self.DST, self.SRC, length)
        assert len(frame) == length

    def test_runt_at_boundary_rejected(self):
        # 60 is the legal minimum, not a runt
        with pytest.raises(ValueError, match="< 60"):
            build_runt(self.DST, self.SRC, 60)

    def test_runt_below_header_rejected(self):
        with pytest.raises(ValueError, match=">= 14"):
            build_runt(self.DST, self.SRC, 13)

    @pytest.mark.parametrize("length", [1515, 1536, 1537, 1600])
    def test_oversize_lengths(self, length):
        frame = build_oversize(self.DST, self.SRC, length)
        assert len(frame) == length

    def test_oversize_at_boundary_rejected(self):
        # 1514 is the legal max, not oversize
        with pytest.raises(ValueError, match="> 1514"):
            build_oversize(self.DST, self.SRC, ETH_MAX_FRAME)

    @pytest.mark.parametrize("etype", [0x0000, 0x0001, 0x88cc, 0x9999, 0xFFFF])
    def test_bogus_ethertype(self, etype):
        frame = build_bogus_ethertype(self.DST, self.SRC, etype)
        # Padded to wire minimum
        assert len(frame) == ETH_MIN_FRAME
        eth = parse_eth_header(frame)
        assert eth["ethertype"] == etype
        assert eth["dst"] == self.DST
        assert eth["src"] == self.SRC

    def test_bogus_ethertype_vlan(self):
        # 0x8100 is the VLAN tag ethertype; Pi has no VLAN handling
        frame = build_bogus_ethertype(self.DST, self.SRC, ETHERTYPE_VLAN)
        assert parse_eth_header(frame)["ethertype"] == ETHERTYPE_VLAN
