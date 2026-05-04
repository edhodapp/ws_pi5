"""Intel HEX record generation for UART chainloader protocol."""


def make_hex_record(rec_type, address, data=b''):
    """Build one Intel HEX record string (without \\r\\n).

    Args:
        rec_type: Record type (0x00=data, 0x01=EOF, 0x04=extended address)
        address: 16-bit address field
        data: Payload bytes

    Returns:
        String like ':10000000...CC'
    """
    ll = len(data)
    addr_hi = (address >> 8) & 0xFF
    addr_lo = address & 0xFF
    raw = bytes([ll, addr_hi, addr_lo, rec_type]) + data
    checksum = (~sum(raw) + 1) & 0xFF
    return ':' + raw.hex().upper() + f'{checksum:02X}'


def kernel_to_hex_records(kernel, base_address=0x80000, chunk_size=16,
                          include_eof=True):
    """Convert raw bytes to list of Intel HEX record strings.

    Args:
        kernel: Raw binary bytes
        base_address: Load address (default 0x80000)
        chunk_size: Bytes per data record (default 16)
        include_eof: Append a type-01 EOF record (default True). Set to
            False when these records will be followed by another payload
            (e.g., a network.conf preamble before the kernel) — the
            chainloader treats EOF as "stop receiving + jump", so only
            the very last payload in a multi-payload transfer should
            carry it.

    Returns:
        List of Intel HEX record strings (without \\r\\n)
    """
    records = []

    upper16 = (base_address >> 16) & 0xFFFF
    ext_data = bytes([(upper16 >> 8) & 0xFF, upper16 & 0xFF])
    records.append(make_hex_record(0x04, 0x0000, ext_data))

    offset = base_address & 0xFFFF
    for i in range(0, len(kernel), chunk_size):
        chunk = kernel[i:i+chunk_size]
        if offset > 0xFFFF:
            upper16 += 1
            records.append(make_hex_record(0x04, 0x0000,
                                           bytes([(upper16 >> 8) & 0xFF,
                                                  upper16 & 0xFF])))
            offset = 0
        records.append(make_hex_record(0x00, offset, chunk))
        offset += len(chunk)

    if include_eof:
        records.append(make_hex_record(0x01, 0x0000))
    return records


def verify_checksum(record):
    """Verify the checksum of an Intel HEX record string.

    Returns:
        True if checksum is valid, False otherwise
    """
    if not record.startswith(':'):
        return False
    hex_body = record[1:]
    if len(hex_body) % 2 != 0:
        return False
    raw = bytes.fromhex(hex_body)
    return sum(raw) & 0xFF == 0


def parse_hex_record(record):
    """Parse an Intel HEX record string into its fields.

    Returns:
        dict with keys: type, address, data, checksum_valid
    """
    if not record.startswith(':'):
        return None
    hex_body = record[1:]
    raw = bytes.fromhex(hex_body)
    ll = raw[0]
    address = (raw[1] << 8) | raw[2]
    rec_type = raw[3]
    data = raw[4:4+ll]
    checksum_valid = sum(raw) & 0xFF == 0
    return {
        'type': rec_type,
        'address': address,
        'data': data,
        'checksum_valid': checksum_valid,
    }
