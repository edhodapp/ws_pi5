#!/usr/bin/env python3
"""Send a kernel to the Pi 4 chainloader using Intel HEX over UART0.

Protocol:
  1. Chainloader prints "READY\\r\\n" when initialized
  2. Host sends Intel HEX records (\\r\\n terminated)
  3. Chainloader sends 2-byte ACK (line_len + checksum) or NAK (line_len + cksum^0xFF)
  4. After EOF ACK: chainloader sends BOOT:NNNN\\r\\n, jumps to kernel
  5. Host resets Pi via DTR (GLOBAL_EN) when needed

Usage: python3 hw_send.py <kernel.img> [serial_port]
"""

import fcntl
import os
import struct
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from intel_hex import kernel_to_hex_records  # noqa: E402

TIOCM_DTR = 0x002
TIOCMBIS = 0x5416
TIOCMBIC = 0x5417


def set_dtr(fd, state):
    """Set DTR line high (state=True) or low (state=False)."""
    bits = struct.pack('I', TIOCM_DTR)
    fcntl.ioctl(fd, TIOCMBIS if state else TIOCMBIC, bits)


def open_serial(path):
    """Open serial port: 115200 8N1, raw, no flow control.

    NOTE: must set ispeed/ospeed (attrs[4], attrs[5]) explicitly in
    addition to the CBAUD bits in cflag. On modern Linux the kernel
    keeps the legacy CBAUD bits in sync with the separate c_ispeed /
    c_ospeed fields, and when they conflict the explicit speed fields
    win. If a previous opener (e.g. ModemManager probing) left the
    cp210x at 9600, leaving attrs[4]/[5] alone preserves 9600 even
    though we set B115200 in cflag — and the chainloader's 115200
    output comes back as garbage. Setting both is the only reliable
    way.
    """
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                    # iflag: raw
    attrs[1] = 0                    # oflag: raw
    attrs[2] = (termios.CS8 | termios.CLOCAL | termios.CREAD
                | termios.B115200)
    attrs[3] = 0                    # lflag: raw
    attrs[4] = termios.B115200      # ispeed — required, not optional
    attrs[5] = termios.B115200      # ospeed — required, not optional
    attrs[6][termios.VMIN] = 1      # blocking read, 1 byte min
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
    return fd


def read_line(fd, timeout=10):
    """Read until \\n with timeout. Returns decoded stripped string."""
    # Set VTIME once for the whole read
    attrs = termios.tcgetattr(fd)
    vtime = min(255, max(1, int(timeout * 10)))
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = vtime
    termios.tcsetattr(fd, termios.TCSADRAIN, attrs)

    buf = b''
    deadline = time.time() + timeout
    while time.time() < deadline:
        b = os.read(fd, 1)
        if not b:
            break
        buf += b
        if b == b'\n':
            break
    return buf.decode('ascii', errors='ignore').strip()


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <kernel.img> [serial_port] [base_addr]")
        return 1

    kernel_path = sys.argv[1]
    port_path = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyUSB0"
    base_addr = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x200000

    with open(kernel_path, "rb") as fobj:
        kernel = fobj.read()

    records = kernel_to_hex_records(kernel, base_address=base_addr)
    print(f"Kernel: {kernel_path} ({len(kernel)} bytes)", flush=True)
    print(f"HEX: {len(records)} records", flush=True)

    fd = open_serial(port_path)

    # DTR reset
    print("DTR reset...", flush=True)
    set_dtr(fd, True)
    time.sleep(0.5)
    set_dtr(fd, False)
    termios.tcflush(fd, termios.TCIFLUSH)

    # Wait for READY
    while True:
        line = read_line(fd, timeout=10)
        if "READY" in line:
            print("READY", flush=True)
            break
        if not line:
            print("Timeout waiting for READY", flush=True)
            os.close(fd)
            return 1

    # Send records — 2-byte ACK: line length + checksum byte
    attrs = termios.tcgetattr(fd)
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 50    # 5 second pure timeout
    termios.tcsetattr(fd, termios.TCSADRAIN, attrs)

    t_start = time.time()
    for i, record in enumerate(records):
        expected = int(record[-2:], 16)
        os.write(fd, (record + '\r\n').encode('ascii'))
        termios.tcdrain(fd)
        ack = b''
        deadline = time.time() + 5
        while len(ack) < 2 and time.time() < deadline:
            chunk = os.read(fd, 2 - len(ack))
            if chunk:
                ack += chunk
        if len(ack) != 2:
            print(f"\n  Timeout on record {i}", flush=True)
            os.close(fd)
            return 1
        line_len, cksum = ack[0], ack[1]
        if cksum == expected:
            pass  # ACK
        elif cksum == (expected ^ 0xFF):
            print(f"\n  NAK on record {i} (len={line_len})",
                  flush=True)
            os.close(fd)
            return 1
        else:
            print(f"\n  MISMATCH at record {i}: "
                  f"exp=0x{expected:02X} got=0x{cksum:02X} "
                  f"len={line_len}", flush=True)
            os.close(fd)
            return 1
        if i % 200 == 0:
            print(f"\r  {i}/{len(records)}", end='', flush=True)

    elapsed = time.time() - t_start
    print(f"\r  {len(records)}/{len(records)} in {elapsed:.1f}s",
          flush=True)

    # Read BOOT line
    line = read_line(fd, timeout=10)
    print(f"  {line}", flush=True)
    if not line.startswith("BOOT"):
        print("No BOOT", flush=True)
        os.close(fd)
        return 1

    # Kernel output
    print("--- Kernel output (Ctrl-C to quit) ---", flush=True)
    try:
        while True:
            b = os.read(fd, 1)
            if b:
                sys.stdout.write(b.decode('ascii', errors='replace'))
                sys.stdout.flush()
    except KeyboardInterrupt:
        print("\n--- Done ---", flush=True)

    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
