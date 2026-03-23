#!/usr/bin/env python3
"""
Send a kernel image to the Pi 4 UART chainloader.

Protocol:
  1. Wait for "READY" on serial
  2. Send 4-byte LE kernel size
  3. Send kernel bytes
  4. Wait for "BOOT", then pass through serial output

Usage: python3 send_kernel.py <kernel.img> [serial_port]
  Default port: /dev/ttyUSB0
"""

import sys
import struct
import serial
import time


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <kernel.img> [serial_port]")
        sys.exit(1)

    kernel_path = sys.argv[1]
    port_path = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyUSB0"

    with open(kernel_path, "rb") as f:
        kernel = f.read()

    print(f"Kernel: {kernel_path} ({len(kernel)} bytes)")
    print(f"Port:   {port_path}")

    port = serial.Serial(port_path, 115200, timeout=10)

    # Wait for READY
    print("Waiting for chainloader...")
    while True:
        line = port.readline().decode("ascii", errors="ignore").strip()
        if line == "READY":
            break
        if line:
            print(f"  [{line}]")

    # Send size (4-byte LE) + kernel data
    print(f"Sending {len(kernel)} bytes...")
    t0 = time.time()
    port.write(struct.pack("<I", len(kernel)))
    port.write(kernel)
    port.flush()
    elapsed = time.time() - t0
    print(f"Sent in {elapsed:.1f}s ({len(kernel) / elapsed:.0f} bytes/sec)")

    # Wait for BOOT
    line = port.readline().decode("ascii", errors="ignore").strip()
    if line == "BOOT":
        print("Kernel loaded. Booting.")
    else:
        print(f"Unexpected response: [{line}]")

    # Pass through serial output until Ctrl-C
    print("--- Serial output ---")
    try:
        while True:
            data = port.read(port.in_waiting or 1)
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
    except KeyboardInterrupt:
        print("\n--- Disconnected ---")
    finally:
        port.close()


if __name__ == "__main__":
    main()
