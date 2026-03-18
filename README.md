# Bare-Metal AArch64 Networking Stack

A ping-responding bare-metal kernel for Raspberry Pi 3, written entirely in AArch64 assembly through human-AI collaboration.

## The Experiment

This project is two things at once: a real artifact (a bare-metal kernel that responds to ICMP pings over USB Ethernet) and an experiment in how humans and AI can collaborate on systems programming.

Assembly is an interesting medium for AI collaboration because it resists the usual pattern of generating boilerplate. Every instruction matters — there's no framework to lean on, no abstraction layer to hide behind. The division of labor falls out naturally:

- **The human** provides architectural direction, testability discipline, and decides what abstractions to form.
- **The AI** handles the combinatorial detail — register allocation, calling conventions, protocol byte layouts, checksum algorithms — and proposes implementations that the human reviews and tests.

TDD at the ISA level keeps both parties honest. The test suite is the shared source of truth: if the tests pass on QEMU, the implementation is correct regardless of who wrote it. This eliminates the trust problem — you don't have to take the AI's word for anything.

## What It Does

Boots on a Raspberry Pi 3, brings up a USB Ethernet adapter (CDC-ECM class), and responds to ARP queries and ICMP echo requests. The full path:

```
boot.S          Core 0 init, stack, BSS zero
  main.S        uart_init → dwc2_init → cdc_ecm_init → cdc_ecm_activate
    net_loop    Receive Ethernet frames via USB bulk-IN
      net.S     Dispatch by EtherType
        ARP  →  arp.S    Validate request, build reply in-place
        IPv4 →  ip.S     Validate header + checksum, dispatch by protocol
          ICMP → icmp.S  Swap MACs/IPs, recompute checksums, reply
      cdc_ecm_send       Transmit reply via USB bulk-OUT
```

The kernel image is under 6 KB.

## Project Structure

```
src/            Main kernel source
  boot.S          Entry point — park cores 1-3, stack, BSS, call main
  main.S          USB bring-up sequence and net_loop dispatcher
lib/            Shared library code
  uart.S          PL011 UART init at 115200, putc, puts
  mailbox.S       VideoCore mailbox IPC (USB power-on)
  dwc2.S          DWC2 USB host controller init and port reset
  usb_enum.S      USB device enumeration via control transfers
  usb_desc.S      Config descriptor reading and bulk endpoint parsing
  usb_bulk.S      Bulk transfer execution with DATA toggle tracking
  cdc_ecm.S       CDC-ECM device init, activate, send/recv
  eth.S           Ethernet frame utilities — EtherType, header builder, MAC compare
  net_cfg.S       Wire-format MAC and IP address data
  net.S           Receive dispatcher — routes by EtherType
  arp.S           ARP request validation and in-place reply builder
  ip.S            RFC 1071 checksum, IPv4 header validation, protocol dispatch
  icmp.S          ICMP echo reply — swap addresses, recompute checksums
  vmio_queue.S    Circular event queue with priority levels
  vmio_engine.S   Finite state automaton engine — init, single-step
include/        Shared constants and macros (.inc files)
tests/          Test sources — 63 tests across 18 files
scripts/        Build and test automation
```

## Building

Requires the AArch64 cross-toolchain and QEMU:

```
sudo apt install gcc-aarch64-linux-gnu qemu-system-aarch64
```

Build the kernel image:

```
make
```

Run the test suite:

```
make test
```

Clean build artifacts:

```
make clean
```

## Testing

63 tests run on `qemu-system-aarch64 -M raspi3b`, covering every layer of the stack from UART output through USB enumeration to ICMP checksum calculation.

The test philosophy follows from the project's CLAUDE.md: failure handling code that is never tested is a liability. Functions accept MMIO base addresses as parameters rather than hardcoding constants — this is dependency injection at the ISA level, allowing tests to point hardware register accesses at fake register blocks in RAM.

The TDD workflow:

1. Write a test in `tests/` — call `test_pass` or `test_fail` with a test name string
2. Register it with `bl test_xxx` in `tests/test_main.S`
3. `make test` — verify it fails (red)
4. Implement in `lib/` or `src/`
5. `make test` — verify it passes (green)
6. Commit

The QEMU test runner (`scripts/run_tests.sh`) runs the test kernel in the background, polls serial output for pass/fail markers, and kills QEMU cleanly to ensure output is flushed.

## Hardware Test Plan

See [test_plan.md](test_plan.md) for the physical test setup:

- **Chromebook** — development host
- **Pi 4** — test host running PiOS, acts as CDC-ECM peer
- **Pi 3** — device under test, running the bare-metal kernel

Verification uses `arping`, `ping`, and `tcpdump` from the Pi 4.

## Current Status

**Working:**
- PL011 UART output
- DWC2 USB host controller initialization via VideoCore mailbox
- USB device enumeration (control transfers, descriptor parsing)
- CDC-ECM Ethernet device activation and bulk data transfer
- ARP request/reply
- ICMP echo request/reply (ping)

**Next:**
- TCP
- HTTP

## License

BSD 3-Clause. See [LICENSE](LICENSE).
