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

    def test_default_base_address(self):
        """Default base_address=0x80000 produces correct offset."""
        recs = kernel_to_hex_records(b'\xFF' * 4)
        data = parse_hex_record(recs[1])
        self.assertEqual(data['address'], 0x0000)
        ext = parse_hex_record(recs[0])
        self.assertEqual(ext['data'], b'\x00\x08')

    def test_ext_addr_address_field_zero(self):
        """Type 04 records must have address field = 0x0000."""
        kernel = b'\xAA' * 512
        recs = kernel_to_hex_records(kernel, base_address=0x8FF00)
        for rec in recs:
            p = parse_hex_record(rec)
            if p['type'] == 0x04:
                self.assertEqual(p['address'], 0x0000,
                                 f"Type 04 address must be 0: {rec}")

    def test_eof_address_field_zero(self):
        """EOF record must have address field = 0x0000."""
        recs = kernel_to_hex_records(b'\x00' * 16)
        eof = parse_hex_record(recs[-1])
        self.assertEqual(eof['type'], 0x01)
        self.assertEqual(eof['address'], 0x0000)

    def test_large_upper16_ext_addr(self):
        """Base address with non-zero high byte in upper16."""
        recs = kernel_to_hex_records(b'\xFF' * 4,
                                     base_address=0x12340000)
        ext = parse_hex_record(recs[0])
        self.assertEqual(ext['type'], 0x04)
        self.assertEqual(ext['data'], b'\x12\x34')

    def test_data_integrity_across_64k_boundary(self):
        """Reconstruct data crossing 64K boundary, compare to original."""
        kernel = bytes(range(256)) * 4  # 1024 bytes
        base = 0x8FF00  # starts near boundary
        recs = kernel_to_hex_records(kernel, base_address=base)
        memory = _reconstruct_memory(recs)
        for i, byte in enumerate(kernel):
            addr = base + i
            self.assertEqual(memory.get(addr), byte,
                             f"Mismatch at 0x{addr:X}: "
                             f"expected 0x{byte:02X}, "
                             f"got {memory.get(addr)}")

    def test_boundary_record_at_exact_offset(self):
        """64K boundary ext addr fires at offset 0x10000, not before/after."""
        kernel = b'\xBB' * 512
        base = 0x8FF00
        recs = kernel_to_hex_records(kernel, base_address=base)
        # After boundary, first data record should have offset=0x0000
        ext_indices = [i for i, r in enumerate(recs)
                       if parse_hex_record(r)['type'] == 0x04]
        self.assertEqual(len(ext_indices), 2)
        # Data record immediately after second ext addr
        after_boundary = parse_hex_record(recs[ext_indices[1] + 1])
        self.assertEqual(after_boundary['type'], 0x00)
        self.assertEqual(after_boundary['address'], 0x0000)

    def test_boundary_at_exact_0xFFFF(self):
        """Offset exactly 0xFFFF: boundary must NOT fire prematurely."""
        # base=0x8FFFF puts initial offset at 0xFFFF
        kernel = b'\xCC' * 32
        recs = kernel_to_hex_records(kernel, base_address=0x8FFFF)
        memory = _reconstruct_memory(recs)
        # First byte should be at 0x8FFFF, not wrapped to next segment
        self.assertEqual(memory.get(0x8FFFF), 0xCC,
                         "First byte should be at 0x8FFFF")
        # Byte 17 (after first chunk) should be at 0x9000F
        self.assertEqual(memory.get(0x9000F), 0xCC)

    def test_boundary_ext_addr_large_upper16(self):
        """Second ext addr after boundary must encode upper16 high byte."""
        # base=0x12FFFF00 → initial upper16=0x12FF
        # After 256 bytes, crosses to upper16=0x1300
        kernel = b'\xDD' * 512
        base = 0x12FFFF00
        recs = kernel_to_hex_records(kernel, base_address=base)
        ext_recs = [parse_hex_record(r) for r in recs
                    if parse_hex_record(r)['type'] == 0x04]
        self.assertEqual(len(ext_recs), 2)
        self.assertEqual(ext_recs[0]['data'], b'\x12\xFF')
        self.assertEqual(ext_recs[1]['data'], b'\x13\x00')
        # Verify data integrity
        memory = _reconstruct_memory(recs)
        for i in range(len(kernel)):
            addr = base + i
            self.assertEqual(memory.get(addr), 0xDD,
                             f"Mismatch at 0x{addr:X}")

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

    def test_no_eof_when_include_eof_false(self):
        """include_eof=False: no type-01 record at the end. Used when
        a network.conf preamble is followed by the kernel records that
        carry their own EOF — only the very last payload's EOF tells
        the chainloader to stop receiving and jump."""
        recs = kernel_to_hex_records(b'\xAB' * 8, base_address=0x20000000,
                                     include_eof=False)
        eof_recs = [r for r in recs
                    if parse_hex_record(r)['type'] == 0x01]
        self.assertEqual(eof_recs, [])
        # ext-addr to 0x2000 + one data record = 2 records total
        self.assertEqual(len(recs), 2)
        self.assertEqual(parse_hex_record(recs[0])['type'], 0x04)
        self.assertEqual(parse_hex_record(recs[0])['data'], b'\x20\x00')
        self.assertEqual(parse_hex_record(recs[1])['type'], 0x00)

    def test_concat_preamble_and_kernel(self):
        """Real use case: preamble (no EOF) + kernel (with EOF). The
        chainloader sees a single stream where the kernel's leading
        type-04 resets extended_base, then the kernel data records,
        then the kernel's EOF — exactly the sequence we want."""
        nc_bytes = b'# WSPI5CFG\nhostname=wspi5\ndhcp=yes\n'
        kernel = b'\xAB' * 32
        preamble = kernel_to_hex_records(nc_bytes, base_address=0x20000000,
                                         include_eof=False)
        records = preamble + kernel_to_hex_records(kernel,
                                                   base_address=0x80000)
        types = [parse_hex_record(r)['type'] for r in records]
        # Exactly one EOF, at the very end.
        self.assertEqual(types.count(0x01), 1)
        self.assertEqual(types[-1], 0x01)
        # Two type-04 records: 0x2000 then 0x0008 (in that order).
        ext_recs = [parse_hex_record(r) for r in records
                    if parse_hex_record(r)['type'] == 0x04]
        self.assertEqual(len(ext_recs), 2)
        self.assertEqual(ext_recs[0]['data'], b'\x20\x00')
        self.assertEqual(ext_recs[1]['data'], b'\x00\x08')


if __name__ == '__main__':
    unittest.main()
