#!/usr/bin/env python3
"""
Send a kernel to the Pi 4 chainloader over UART3, collect output.

Protocol:
  1. Host sends 0xFF sync bytes until chainloader responds with READY
  2. Host sends 1-byte timeout (seconds, 0 = no watchdog)
  3. Host sends 4-byte LE kernel size
  4. Host sends kernel bytes
  5. Chainloader prints BOOT, arms timer, jumps to kernel
  6. After timeout: Pi resets via PM watchdog, chainloader restarts

Usage: python3 hw_send.py <kernel.img> [serial_port] [timeout_sec]
  Default port: /dev/ttyUSB0
  Default timeout: 60 seconds (sent to chainloader as watchdog timer)
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
    timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 60

    if timeout < 0 or timeout > 255:
        print(f"Timeout must be 0-255 seconds (got {timeout})", flush=True)
        sys.exit(1)

    with open(kernel_path, "rb") as f:
        kernel = f.read()

    print(f"Kernel: {kernel_path} ({len(kernel)} bytes)", flush=True)
    print(f"Port:   {port_path}", flush=True)
    print(f"Timeout: {timeout}s {'(no watchdog)' if timeout == 0 else ''}", flush=True)

    port = serial.Serial(port_path, 115200, timeout=3)

    # Send 0xFF sync bytes until chainloader responds with READY.
    # The chainloader discards all non-0xFF bytes before entering the
    # protocol, so stale FIFO data from a previous kernel is harmless.
    # If a kernel is currently running, the watchdog will eventually
    # reset the Pi and the chainloader will restart.
    port.timeout = 2
    found_ready = False
    for attempt in range(10):
        port.reset_input_buffer()
        print(f"TX: 0xFF sync (attempt {attempt + 1})", flush=True)
        port.write(b'\xff')
        port.flush()

        deadline = time.time() + 3
        while time.time() < deadline:
            line = port.readline().decode("ascii", errors="ignore").strip()
            if line:
                print(f"RX: '{line}'", flush=True)
            if line == "READY":
                found_ready = True
                break
        if found_ready:
            break

    if not found_ready:
        print("RX: no READY after 10 attempts. Power cycle the Pi.", flush=True)
        port.close()
        sys.exit(1)

    # Send timeout byte + size + kernel
    print(f"TX: timeout = {timeout}s", flush=True)
    port.write(bytes([timeout]))

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

    # Collect output byte-by-byte so non-newline chars (e.g. dots) show
    # immediately. Also accumulate line buffer for WAIT/DONE detection.
    collect_time = timeout if timeout > 0 else 3600  # 1 hour if no watchdog
    print(f"--- Output ({collect_time}s) ---", flush=True)
    port.timeout = 1  # per-byte read timeout
    done = False
    line_buf = ""
    deadline = time.time() + collect_time
    try:
        while time.time() < deadline:
            b = port.read(1)
            if not b:
                continue
            ch = b.decode("ascii", errors="ignore")
            sys.stdout.write(ch)
            sys.stdout.flush()
            if ch in ('\r', '\n'):
                stripped = line_buf.strip()
                if stripped == "WAIT":
                    print("TX: 0xFF (start)", flush=True)
                    port.write(b'\xff')
                    port.flush()
                if stripped == "DONE":
                    done = True
                    break
                line_buf = ""
            else:
                line_buf += ch
    except KeyboardInterrupt:
        print("\n--- Interrupted ---", flush=True)

    if done:
        print("--- DONE ---", flush=True)
    else:
        print("--- Timeout ---", flush=True)

    port.close()
    sys.exit(0 if done else 1)


if __name__ == "__main__":
    main()
