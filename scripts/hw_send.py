#!/usr/bin/env python3
"""
Send a test kernel to the Pi 4 via the step5 loader, collect output.

Usage: python3 hw_send.py <kernel.img> [serial_port] [timeout_sec]
  Default port: /dev/ttyUSB0
  Default timeout: 10 seconds after BOOT
"""

import sys
import struct
import serial
import time


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <kernel.img> [serial_port] [timeout_sec]")
        sys.exit(1)

    kernel_path = sys.argv[1]
    port_path = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyUSB0"
    timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 10

    with open(kernel_path, "rb") as f:
        kernel = f.read()

    print(f"Kernel: {kernel_path} ({len(kernel)} bytes)", flush=True)
    print(f"Port:   {port_path}", flush=True)

    port = serial.Serial(port_path, 115200, timeout=3)

    # Quick check: is READY already waiting?
    print("RX: checking for READY...", flush=True)
    found_ready = False
    for _ in range(2):
        line = port.readline().decode("ascii", errors="ignore").strip()
        if line:
            print(f"RX: '{line}'", flush=True)
        if line == "READY":
            found_ready = True
            break

    # If not, send reset byte to trigger watchdog in a waiting kernel
    if not found_ready:
        print("TX: 0xFF (reset)", flush=True)
        port.write(b'\xff')
        port.flush()

        # Wait for reboot + READY
        port.timeout = 5
        print("RX: waiting for reboot + READY...", flush=True)
        deadline = time.time() + 15
        while time.time() < deadline:
            line = port.readline().decode("ascii", errors="ignore").strip()
            if line:
                print(f"RX: '{line}'", flush=True)
            if line == "READY":
                found_ready = True
                break

    if not found_ready:
        print("RX: timeout. Power cycle the Pi.", flush=True)
        port.close()
        sys.exit(1)

    # Send size + kernel
    size_bytes = struct.pack("<I", len(kernel))
    print(f"TX: size = {size_bytes.hex()} ({len(kernel)} bytes)", flush=True)
    t0 = time.time()
    port.write(size_bytes)
    port.write(kernel)
    port.flush()
    elapsed = time.time() - t0
    print(f"TX: {len(kernel)} bytes sent in {elapsed:.1f}s ({len(kernel) / elapsed:.0f} B/s)", flush=True)

    # Wait for BOOT
    port.timeout = 10
    line = port.readline().decode("ascii", errors="ignore").strip()
    if line:
        print(f"RX: '{line}'", flush=True)
    if line == "BOOT":
        print("Kernel loaded. Booting.", flush=True)
    else:
        print(f"Unexpected response.", flush=True)
        port.close()
        sys.exit(1)

    # Collect output until DONE or timeout
    print("--- Output ---", flush=True)
    port.timeout = timeout
    done = False
    while True:
        line = port.readline()
        if not line:
            break
        text = line.decode("ascii", errors="ignore").rstrip('\r\n')
        print(text, flush=True)
        if text == "DONE":
            done = True
            break

    if done:
        print("--- DONE ---", flush=True)
    else:
        print("--- Timeout ---", flush=True)

    port.close()
    sys.exit(0 if done else 1)


if __name__ == "__main__":
    main()
