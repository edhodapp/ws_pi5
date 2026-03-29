#!/usr/bin/env python3
"""Unit tests for Intel HEX generation and parsing."""

import unittest
from intel_hex import (make_hex_record, kernel_to_hex_records,
                       verify_checksum, parse_hex_record)


def _reconstruct_memory(records):
    """Rebuild memory dict from Intel HEX records."""
    memory = {}
    base = 0
    for rec in records:
        parsed = parse_hex_record(rec)
        if parsed['type'] == 0x04:
            high = parsed['data'][0] << 8 | parsed['data'][1]
            base = high << 16
        elif parsed['type'] == 0x00:
            addr = base + parsed['address']
            for j, byte in enumerate(parsed['data']):
                memory[addr + j] = byte
    return memory


class TestMakeHexRecord(unittest.TestCase):

    def test_eof_record(self):
        rec = make_hex_record(0x01, 0x0000)
        self.assertEqual(rec, ':00000001FF')

    def test_data_record_zeros(self):
        rec = make_hex_record(0x00, 0x0000, b'\x00' * 16)
        self.assertTrue(rec.startswith(':10000000'))
        self.assertTrue(verify_checksum(rec))

    def test_data_record_known(self):
        # Known example from Intel HEX spec
        data = bytes([0x21, 0x46, 0x01, 0x36, 0x01, 0x21, 0x47, 0x01,
                      0x36, 0x00, 0x7E, 0xFE, 0x09, 0xD2, 0x19, 0x01])
        rec = make_hex_record(0x00, 0x0000, data)
        self.assertEqual(rec[:9], ':10000000')
        self.assertTrue(verify_checksum(rec))

    def test_ext_address_record(self):
        rec = make_hex_record(0x04, 0x0000, b'\x00\x08')
        self.assertEqual(rec, ':020000040008F2')

    def test_checksum_always_valid(self):
        """Every record we generate must have a valid checksum."""
        for addr in [0x0000, 0x1234, 0xFFFF]:
            for data in [b'', b'\xFF', b'\x00' * 16, bytes(range(16))]:
                for rtype in [0x00, 0x01, 0x04]:
                    rec = make_hex_record(rtype, addr, data)
                    self.assertTrue(verify_checksum(rec),
                                    f"Bad checksum: {rec}")

    def test_single_byte_data(self):
        rec = make_hex_record(0x00, 0x1000, b'\xAB')
        parsed = parse_hex_record(rec)
        self.assertEqual(parsed['data'], b'\xAB')
        self.assertEqual(parsed['address'], 0x1000)
        self.assertTrue(parsed['checksum_valid'])

    def test_address_encoding(self):
        rec = make_hex_record(0x00, 0xABCD, b'\x00')
        parsed = parse_hex_record(rec)
        self.assertEqual(parsed['address'], 0xABCD)


class TestParseHexRecord(unittest.TestCase):

    def test_parse_eof(self):
        p = parse_hex_record(':00000001FF')
        self.assertEqual(p['type'], 0x01)
        self.assertEqual(p['address'], 0x0000)
        self.assertEqual(p['data'], b'')
        self.assertTrue(p['checksum_valid'])

    def test_parse_ext_addr(self):
        p = parse_hex_record(':020000040008F2')
        self.assertEqual(p['type'], 0x04)
        self.assertEqual(p['data'], b'\x00\x08')
        self.assertTrue(p['checksum_valid'])

    def test_bad_checksum(self):
        p = parse_hex_record(':00000001FE')  # should be FF
        self.assertFalse(p['checksum_valid'])

    def test_no_colon(self):
        self.assertIsNone(parse_hex_record('00000001FF'))

    def test_roundtrip(self):
        """Generate and parse should roundtrip."""
        data = bytes(range(16))
        rec = make_hex_record(0x00, 0x4000, data)
        p = parse_hex_record(rec)
        self.assertEqual(p['type'], 0x00)
        self.assertEqual(p['address'], 0x4000)
        self.assertEqual(p['data'], data)
        self.assertTrue(p['checksum_valid'])


class TestVerifyChecksum(unittest.TestCase):

    def test_valid(self):
        self.assertTrue(verify_checksum(':00000001FF'))
        self.assertTrue(verify_checksum(':020000040008F2'))

    def test_invalid(self):
        self.assertFalse(verify_checksum(':00000001FE'))

    def test_no_colon(self):
        self.assertFalse(verify_checksum('00000001FF'))

    def test_odd_length(self):
        self.assertFalse(verify_checksum(':0000001FF'))


class TestKernelToHexRecords(unittest.TestCase):

    def test_empty_kernel(self):
        recs = kernel_to_hex_records(b'')
        # Should have ext addr + EOF
        self.assertEqual(len(recs), 2)
        self.assertEqual(parse_hex_record(recs[0])['type'], 0x04)
        self.assertEqual(parse_hex_record(recs[1])['type'], 0x01)

    def test_small_kernel(self):
        recs = kernel_to_hex_records(b'\xAB' * 8, base_address=0x80000)
        # ext addr + 1 data + EOF = 3
        self.assertEqual(len(recs), 3)
        p = parse_hex_record(recs[0])
        self.assertEqual(p['type'], 0x04)
        self.assertEqual(p['data'], b'\x00\x08')  # upper 16 = 0x0008
        p = parse_hex_record(recs[1])
        self.assertEqual(p['type'], 0x00)
        self.assertEqual(p['address'], 0x0000)  # offset within segment
        self.assertEqual(p['data'], b'\xAB' * 8)
        self.assertEqual(parse_hex_record(recs[2])['type'], 0x01)

    def test_exact_chunk(self):
        """16 bytes = exactly one data record."""
        recs = kernel_to_hex_records(b'\x00' * 16)
        data_recs = [r for r in recs if parse_hex_record(r)['type'] == 0x00]
        self.assertEqual(len(data_recs), 1)
        self.assertEqual(len(parse_hex_record(data_recs[0])['data']), 16)

    def test_chunk_boundary(self):
        """17 bytes = two data records (16 + 1)."""
        recs = kernel_to_hex_records(b'\x00' * 17)
        data_recs = [r for r in recs if parse_hex_record(r)['type'] == 0x00]
        self.assertEqual(len(data_recs), 2)
        self.assertEqual(len(parse_hex_record(data_recs[0])['data']), 16)
        self.assertEqual(len(parse_hex_record(data_recs[1])['data']), 1)

    def test_all_checksums_valid(self):
        """Every record must have valid checksum."""
        kernel = bytes(range(256)) * 100
        recs = kernel_to_hex_records(kernel)
        for i, rec in enumerate(recs):
            self.assertTrue(
                verify_checksum(rec), f"Record {i}: {rec}",
            )

    def test_data_integrity(self):
        """Reassemble data from records, compare to original."""
        kernel = bytes(range(256)) * 4
        recs = kernel_to_hex_records(kernel, base_address=0x80000)
        memory = _reconstruct_memory(recs)
        for i, byte in enumerate(kernel):
            addr = 0x80000 + i
            self.assertEqual(memory.get(addr), byte)

    def test_base_address_offset(self):
        """Offset starts at 0x0000 within segment 0x0008."""
        recs = kernel_to_hex_records(b'\xFF' * 4, base_address=0x80000)
        ext = parse_hex_record(recs[0])
        self.assertEqual(ext['data'], b'\x00\x08')
        data = parse_hex_record(recs[1])
        self.assertEqual(data['address'], 0x0000)

    def test_base_address_nonzero_offset(self):
        """Offset starts at 0x1000 within segment 0x0008."""
        recs = kernel_to_hex_records(b'\xFF' * 4, base_address=0x81000)
        data = parse_hex_record(recs[1])
        self.assertEqual(data['address'], 0x1000)

    def test_64k_boundary_crossing(self):
        """Crossing 64K boundary emits new Type 04 record."""
        kernel = b'\xAA' * 512
        recs = kernel_to_hex_records(kernel, base_address=0x8FF00)
        ext_recs = [
            r for r in recs
            if parse_hex_record(r)['type'] == 0x04
        ]
        self.assertEqual(len(ext_recs), 2)
        first = parse_hex_record(ext_recs[0])['data']
        self.assertEqual(first, b'\x00\x08')
        second = parse_hex_record(ext_recs[1])['data']
        self.assertEqual(second, b'\x00\x09')

    def test_record_count_27k(self):
        """27576 bytes = 1724 data records."""
        kernel = b'\x00' * 27576
        recs = kernel_to_hex_records(kernel)
        data_recs = [
            r for r in recs
            if parse_hex_record(r)['type'] == 0x00
        ]
        expected = 27576 // 16 + (1 if 27576 % 16 else 0)
        self.assertEqual(len(data_recs), expected)


if __name__ == '__main__':
    unittest.main()
