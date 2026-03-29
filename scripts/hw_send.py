#!/usr/bin/env python3
"""Send a kernel to the Pi 4 chainloader using Intel HEX over UART0.

Protocol:
  1. Host sends 0xFF sync bytes until chainloader responds with READY
  2. Host sends 1-byte timeout (seconds, 0 = no watchdog)
  3. Host sends Intel HEX records (ASCII lines, \\r\\n terminated)
  4. Chainloader verifies checksum, sends '+' (ACK) or '-' (NAK)
  5. On EOF record ACK: chainloader arms PM watchdog, prints BOOT
  6. After timeout: Pi resets via PM watchdog, chainloader restarts

Usage: python3 hw_send.py <kernel.img> [serial_port] [timeout_sec]
  Default port: /dev/ttyUSB0
  Default timeout: 15 seconds (PM watchdog max ~16s)
"""

import os
import sys
import time

import serial

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from intel_hex import kernel_to_hex_records  # noqa: E402


MAX_RETRIES = 3
ACK_TIMEOUT = 5
SYNC_ATTEMPTS = 10


def sync_chainloader(port):
    """Send 0xFF until chainloader responds with READY."""
    port.timeout = 2
    for attempt in range(SYNC_ATTEMPTS):
        port.reset_input_buffer()
        print(f"TX: 0xFF sync (attempt {attempt + 1})", flush=True)
        port.write(b'\xff')
        port.flush()
        if _wait_for_ready(port):
            return True
    return False


def _wait_for_ready(port):
    """Read lines for up to 3 seconds looking for READY."""
    deadline = time.time() + 3
    while time.time() < deadline:
        line = port.readline().decode("ascii", errors="ignore")
        line = line.strip()
        if line:
            print(f"RX: '{line}'", flush=True)
        if line == "READY":
            return True
    return False


def send_hex_records(port, records, kernel_size):
    """Send Intel HEX records with ACK/NAK flow control."""
    port.timeout = ACK_TIMEOUT
    sent_bytes = 0

    for rec_idx, record in enumerate(records):
        if not _send_one_record(port, record, rec_idx):
            return False
        if record[7:9] == '00':
            sent_bytes += int(record[1:3], 16)
            if rec_idx % 100 == 0:
                pct = sent_bytes * 100 // kernel_size
                print(
                    f"\r  {sent_bytes}/{kernel_size} ({pct}%)",
                    end='', flush=True,
                )
    return True


def _send_one_record(port, record, rec_idx):
    """Send a single HEX record, retrying on NAK."""
    for retry in range(MAX_RETRIES):
        port.write((record + '\r\n').encode('ascii'))
        port.flush()
        ack = port.read(1)
        if ack == b'+':
            return True
        if ack == b'-':
            _log_nak(rec_idx, retry)
            continue
        _log_bad_ack(rec_idx, ack)
        return False
    print(f"\n  NAK on record {rec_idx}, giving up", flush=True)
    return False


def _log_nak(rec_idx, retry):
    """Log a NAK retry if not the last attempt."""
    if retry < MAX_RETRIES - 1:
        print(
            f"\n  NAK on record {rec_idx}, retry {retry + 1}",
            flush=True,
        )


def _log_bad_ack(rec_idx, ack):
    """Log an unexpected ACK byte."""
    if ack:
        print(f"\n  Unexpected byte: {ack.hex()}", flush=True)
    else:
        print(f"\n  Timeout on record {rec_idx}", flush=True)


def wait_for_boot(port):
    """Wait for BOOT response from chainloader."""
    port.timeout = 5
    line = port.readline().decode("ascii", errors="ignore").strip()
    if line:
        print(f"RX: '{line}'", flush=True)
    return line == "BOOT"


def collect_output(port, duration):
    """Collect serial output byte-by-byte for duration seconds."""
    print(f"--- Output ({duration}s) ---", flush=True)
    port.timeout = 1
    line_buf = ""
    deadline = time.time() + duration
    try:
        while time.time() < deadline:
            result, line_buf = _read_output_byte(port, line_buf)
            if result is True:
                print("--- DONE ---", flush=True)
                return True
    except KeyboardInterrupt:
        print("\n--- Interrupted ---", flush=True)
    print("--- Timeout ---", flush=True)
    return False


def _read_output_byte(port, line_buf):
    """Read and process one byte of kernel output.

    Returns:
        (True, buf) if DONE seen, (None, buf) otherwise.
    """
    byte = port.read(1)
    if not byte:
        return None, line_buf
    char = byte.decode("ascii", errors="ignore")
    sys.stdout.write(char)
    sys.stdout.flush()
    if char not in ('\r', '\n'):
        return None, line_buf + char
    stripped = line_buf.strip()
    if stripped == "WAIT":
        port.write(b'\xff')
        port.flush()
    if stripped == "DONE":
        return True, ""
    return None, ""


def main():
    """Entry point: parse args, sync, send HEX, collect output."""
    args = _parse_args()
    if not args:
        return 1
    kernel_path, port_path, timeout = args

    with open(kernel_path, "rb") as fobj:
        kernel = fobj.read()

    records = kernel_to_hex_records(kernel)
    _print_banner(kernel_path, port_path, timeout, kernel, records)

    port = serial.Serial(port_path, 115200, timeout=3)

    if not sync_chainloader(port):
        print("No READY. Power cycle the Pi.", flush=True)
        port.close()
        return 1

    print(f"TX: timeout = {timeout}s", flush=True)
    port.write(bytes([timeout]))
    port.flush()

    t_start = time.time()
    if not send_hex_records(port, records, len(kernel)):
        port.close()
        return 1
    elapsed = time.time() - t_start
    rate = len(kernel) / elapsed if elapsed > 0 else 0
    print(f"\n  {len(kernel)} bytes in {elapsed:.1f}s "
          f"({rate:.0f} B/s)", flush=True)

    if not wait_for_boot(port):
        print("No BOOT received.", flush=True)
        port.close()
        return 1
    print("Kernel loaded. Booting.", flush=True)

    duration = timeout if timeout > 0 else 3600
    collect_output(port, duration)
    port.close()
    return 0


def _parse_args():
    """Parse command line arguments. Returns tuple or None."""
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <kernel.img> "
              "[serial_port] [timeout_sec]")
        return None
    kernel_path = sys.argv[1]
    port_path = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyUSB0"
    timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 15
    if timeout < 0 or timeout > 255:
        print(f"Timeout must be 0-255 (got {timeout})", flush=True)
        return None
    return kernel_path, port_path, timeout


def _print_banner(kernel_path, port_path, timeout, kernel, records):
    """Print startup info."""
    data_count = sum(1 for r in records if r[7:9] == '00')
    wd_note = '(no watchdog)' if timeout == 0 else ''
    print(f"Kernel: {kernel_path} ({len(kernel)} bytes)", flush=True)
    print(f"Port:   {port_path}", flush=True)
    print(f"Timeout: {timeout}s {wd_note}", flush=True)
    print(f"HEX: {len(records)} records ({data_count} data)",
          flush=True)


if __name__ == "__main__":
    sys.exit(main())
