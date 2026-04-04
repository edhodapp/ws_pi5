#!/usr/bin/env python3
"""Send a kernel to the Pi 4 chainloader using Intel HEX over UART0.

Protocol:
  1. Chainloader prints "READY\\r\\n" when initialized
  2. Host sends Intel HEX records (\\r\\n terminated)
  3. Chainloader sends 2-byte ACK (big-endian record index) or NAK (0xFFFF)
  4. After EOF ACK: chainloader sends BOOT:NNNN\\r\\n, jumps to kernel

Usage: python3 hw_send.py <kernel.img> [serial_port]
"""

import fcntl
import os
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from intel_hex import kernel_to_hex_records  # noqa: E402

TIOCM_DTR = 0x002
TIOCMBIS = 0x5416   # set modem bits
TIOCMBIC = 0x5417   # clear modem bits


def set_dtr(fd, state):
    """Set DTR line high (state=True) or low (state=False)."""
    import struct
    bits = struct.pack('I', TIOCM_DTR)
    fcntl.ioctl(fd, TIOCMBIS if state else TIOCMBIC, bits)


def open_serial(path):
    """Open serial port: 115200 8N1, raw, CRTSCTS."""
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                    # iflag: raw
    attrs[1] = 0                    # oflag: raw
    attrs[2] = (termios.CS8 | termios.CLOCAL | termios.CREAD
                | termios.CRTSCTS | termios.B115200)
    attrs[3] = 0                    # lflag: raw
    attrs[6][termios.VMIN] = 1      # blocking read
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def read_exact(fd, n, timeout=10):
    """Read exactly n bytes with timeout. Returns bytes or short on timeout."""
    buf = b''
    deadline = time.time() + timeout
    while len(buf) < n:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        # Use VTIME for timeout (tenths of seconds, max 25.5s)
        attrs = termios.tcgetattr(fd)
        attrs[6][termios.VMIN] = 1
        attrs[6][termios.VTIME] = min(255, max(1, int(remaining * 10)))
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        chunk = os.read(fd, n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def read_line(fd, timeout=10):
    """Read until \\n with timeout. Returns decoded stripped string."""
    buf = b''
    deadline = time.time() + timeout
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return buf.decode('ascii', errors='ignore').strip()
        attrs = termios.tcgetattr(fd)
        attrs[6][termios.VMIN] = 1
        attrs[6][termios.VTIME] = min(255, max(1, int(remaining * 10)))
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        b = os.read(fd, 1)
        if not b:
            return buf.decode('ascii', errors='ignore').strip()
        buf += b
        if b == b'\n':
            return buf.decode('ascii', errors='ignore').strip()


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <kernel.img> [serial_port]")
        return 1

    kernel_path = sys.argv[1]
    port_path = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyUSB0"

    with open(kernel_path, "rb") as fobj:
        kernel = fobj.read()

    records = kernel_to_hex_records(kernel)
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
    attrs[6][termios.VMIN] = 2
    attrs[6][termios.VTIME] = 50    # 5 second timeout
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    t_start = time.time()
    for i, record in enumerate(records):
        expected = int(record[-2:], 16)
        os.write(fd, (record + '\r\n').encode('ascii'))
        termios.tcdrain(fd)
        ack = os.read(fd, 2)
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
                  f"exp_cksum=0x{expected:02X} "
                  f"got_cksum=0x{cksum:02X} "
                  f"line_len={line_len}", flush=True)
            os.close(fd)
            return 1
        if i < 20 or i % 200 == 0:
            print(f"  {i}: len={line_len} cksum=0x{cksum:02X}",
                  flush=True)

    elapsed = time.time() - t_start
    print(f"\r  {len(records)}/{len(records)} in {elapsed:.1f}s", flush=True)

    # Read BOOT line
    line = read_line(fd, timeout=10)
    print(f"  {line}", flush=True)
    if not line.startswith("BOOT"):
        print("No BOOT", flush=True)
        os.close(fd)
        return 1

    print("--- Kernel output (Ctrl-C to quit) ---", flush=True)
    try:
        while True:
            b = os.read(fd, 1)
            if b:
                sys.stdout.write(b.decode('ascii', errors='?'))
                sys.stdout.flush()
    except KeyboardInterrupt:
        print("\n--- Done ---", flush=True)

    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
