#!/usr/bin/env python3
"""Bidirectional serial adapter test.

Both sides send incrementing bytes (0x00-0xFF repeating).
Both sides verify the received sequence.
Pi signals RX error by switching TX to 0xDE,0xAD pattern.

Usage: python3 test_adapter.py [port] [byte_count]
"""

import sys
import threading
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
COUNT = int(sys.argv[2]) if len(sys.argv) > 2 else 10000


def main():
    port = serial.Serial(PORT, 115200, timeout=1, rtscts=False)

    # DTR reset
    print("DTR reset...", flush=True)
    port.dtr = True
    time.sleep(0.5)
    port.dtr = False
    time.sleep(3)
    port.reset_input_buffer()

    rx_buf = bytearray()
    rx_done = threading.Event()

    def reader():
        while not rx_done.is_set():
            chunk = port.read(256)
            if chunk:
                rx_buf.extend(chunk)

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    # Send incrementing bytes
    print(f"Sending {COUNT} bytes...", flush=True)
    tx_data = bytes(i % 256 for i in range(COUNT))
    t_start = time.time()
    port.write(tx_data)
    port.flush()

    # Wait for roughly the same number of bytes back
    # At 115200: ~11520 bytes/sec, so COUNT/11520 seconds + margin
    wait = max(COUNT / 8000, 2)
    time.sleep(wait)
    rx_done.set()
    t.join(timeout=2)
    elapsed = time.time() - t_start

    port.close()

    # Analyze RX
    print(f"Received {len(rx_buf)} bytes in {elapsed:.1f}s", flush=True)

    if len(rx_buf) == 0:
        print("FAIL: no data received from Pi")
        return 1

    # Check incrementing pattern (first byte sets the baseline)
    errors = 0
    dead_count = 0
    for i in range(1, len(rx_buf)):
        expected = (rx_buf[i - 1] + 1) % 256
        if rx_buf[i] != expected:
            if errors < 5:
                print(f"  RX error at byte {i}: "
                      f"expected 0x{expected:02X}, "
                      f"got 0x{rx_buf[i]:02X}")
            errors += 1
        if i > 0 and rx_buf[i - 1] == 0xDE and rx_buf[i] == 0xAD:
            dead_count += 1

    if dead_count > 2:
        print(f"  Pi detected RX errors (0xDE,0xAD seen {dead_count}x)")

    tx_rate = COUNT / elapsed if elapsed > 0 else 0
    rx_rate = len(rx_buf) / elapsed if elapsed > 0 else 0

    print(f"TX: {COUNT} bytes ({tx_rate:.0f} B/s)")
    print(f"RX: {len(rx_buf)} bytes ({rx_rate:.0f} B/s)")
    print(f"RX sequence errors: {errors}")

    if errors == 0 and len(rx_buf) > COUNT * 0.8:
        print("PASS")
        return 0
    else:
        print("FAIL")
        return 1


if __name__ == "__main__":
    sys.exit(main())
