#!/usr/bin/env python3
"""UART diagnostic driver for Pi 4 (v2: no echo).

Syncs with diag.img, sends a stream of bytes, reads only diagnostic
output from the Pi (no echo expected). Reports PL011 error flags.

Usage: python3 uart_diag.py [port] [count]
  Default port: /dev/ttyUSB0
  Default count: 2048 bytes
"""

import sys
import time

import serial


def main():
    port_path = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 2048

    port = serial.Serial(port_path, 115200, timeout=2)

    # Sync: send 0xFF, wait for anything containing "EADY"
    print("Syncing...", flush=True)
    port.reset_input_buffer()
    synced = False
    for attempt in range(10):
        port.write(b'\xff')
        port.flush()
        if wait_for(port, "EADY"):
            synced = True
            break
    if not synced:
        # Brute force: send sync, pause, flush, assume Pi is ready
        print("No READY seen, proceeding anyway...", flush=True)
        time.sleep(0.5)
        port.reset_input_buffer()

    print(f"Sending {count} bytes...", flush=True)

    # Send all data in one shot — Pi doesn't echo, so no interleaving
    # Use bytes 0x00-0xFE (avoid 0xFF which is the sync byte)
    data = bytes(i % 255 for i in range(count))
    port.write(data)
    port.flush()
    print(f"Sent {count} bytes. Reading diagnostics...", flush=True)

    # Read diagnostic output for up to 10 seconds
    port.timeout = 1
    deadline = time.time() + 10
    while time.time() < deadline:
        line = port.readline()
        if not line:
            continue
        text = line.decode('ascii', errors='replace').strip()
        if not text:
            continue
        print(f"  PI: {text}", flush=True)
        if text.startswith("DONE:"):
            break
        deadline = time.time() + 5  # extend on activity

    port.close()
    return 0


def wait_for(port, keyword):
    """Read lines looking for keyword."""
    deadline = time.time() + 3
    while time.time() < deadline:
        line = port.readline()
        if not line:
            continue
        text = line.decode('ascii', errors='replace').strip()
        if text:
            print(f"  RX: '{text}'", flush=True)
        if keyword in text:
            return True
    return False


if __name__ == "__main__":
    sys.exit(main())
