# Bare-Metal Web Server Appliance

A bare-metal web server for Raspberry Pi 3, written entirely in AArch64 assembly through human-AI collaboration. The goal is a complete HTTP server — from boot to TCP to serving pages — with no OS, no C runtime, and no abstraction layers.

## The Experiment

This project is two things at once: a real artifact (a bare-metal web server appliance built from scratch in assembly) and an experiment in how humans and AI can collaborate on systems programming.

Assembly is an interesting medium for AI collaboration because it resists the usual pattern of generating boilerplate. Every instruction matters — there's no framework to lean on, no abstraction layer to hide behind. The division of labor falls out naturally:

- **The human** provides architectural direction, testability discipline, and decides what abstractions to form.
- **The AI** handles the combinatorial detail — register allocation, calling conventions, protocol byte layouts, checksum algorithms — and proposes implementations that the human reviews and tests.

TDD at the ISA level keeps both parties honest. The test suite is the shared source of truth: if the tests pass on QEMU, the implementation is correct regardless of who wrote it. This eliminates the trust problem — you don't have to take the AI's word for anything.

### Implementation-specific tests as an AI constraint

Conventional wisdom says: don't write tests that are tightly coupled to implementation details, because they break during refactors and create maintenance burden. This project deliberately violates that rule as an experiment.

The reasoning: that conventional wisdom is calibrated to human costs. When a human has to rewrite 10 tests after a structural change, that's real friction. When an AI can regenerate the entire test file in seconds, the maintenance cost drops to near zero — and the value of catching bugs in internal logic dominates.

Implementation-specific tests serve as a ratchet against AI hallucination. A behavioral test says "the callback fired" — the AI could produce a broken scan loop that happens to work for one timer. An implementation-specific test says "slot 0's callback field is zero after cancel" — there's nowhere to hide. Every test that pins internal state narrows the space of wrong-but-compiles outputs the AI could produce.

This is an open question, not a conclusion. The hypothesis is that the human rule "don't test implementation details" is really "don't create maintenance burdens that outlive their value," and that AI collaboration changes the cost structure enough to flip the tradeoff. Whether this holds up across larger refactors remains to be seen.

## What It Does

Boots on a Raspberry Pi 3, brings up a USB Ethernet adapter (CDC-ECM class), and handles network traffic. The full path:

```
boot.S          Core 0 init, stack, BSS zero
  main.S        uart_init → dwc2_init → cdc_ecm_init → cdc_ecm_activate
    net_loop    Receive Ethernet frames via USB bulk-IN
      net.S     Dispatch by EtherType
        ARP  →  arp.S    Validate request, build reply in-place
        IPv4 →  ip.S     Validate header + checksum, dispatch by protocol
          ICMP → icmp.S  Swap MACs/IPs, recompute checksums, reply
          UDP  → udp.S   Checksum with pseudo-header, echo on port 7
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
  udp.S           UDP checksum with pseudo-header, validation, echo service (port 7)
  timer.S         ARM generic timer access and software timer pool
  vmio_queue.S    Circular event queue with priority levels
  vmio_engine.S   Finite state automaton engine — init, single-step
include/        Shared constants and macros (.inc files)
tests/          Test sources — 97 tests across 20 files
scripts/        Build and test automation
hw_test/        Hardware test scripts for Pi 4 test fixture
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

97 tests run on `qemu-system-aarch64 -M raspi3b`, covering every layer of the stack from UART output through USB enumeration to UDP checksum calculation and timer infrastructure.

The test philosophy follows from the project's CLAUDE.md: failure handling code that is never tested is a liability. Functions accept MMIO base addresses as parameters rather than hardcoding constants — this is dependency injection at the ISA level, allowing tests to point hardware register accesses at fake register blocks in RAM.

The TDD workflow:

1. Write a test in `tests/` — call `test_pass` or `test_fail` with a test name string
2. Register it with `bl test_xxx` in `tests/test_main.S`
3. `make test` — verify it fails (red)
4. Implement in `lib/` or `src/`
5. `make test` — verify it passes (green)
6. Commit

The QEMU test runner (`scripts/run_tests.sh`) runs the test kernel in the background, polls serial output for pass/fail markers, and kills QEMU cleanly to ensure output is flushed.

## Fuzzing

Coverage-guided fuzzing of the network packet parsers (`eth_type`, `arp_handle`, `ip_handle`, `icmp_handle`, `udp_handle`, `net_recv_one`). All functions are pure computation on caller-provided buffers — no MMIO, no syscalls — making them ideal for user-mode fuzzing.

### Prerequisites

```
sudo apt install gcc-aarch64-linux-gnu
```

### Build and run

Build the fuzz harness (static aarch64 Linux ELF):

```
make fuzz
```

Generate seed corpus:

```
make fuzz-corpus
```

Run a single input manually:

```
qemu-aarch64 -L /usr/aarch64-linux-gnu ./build/fuzz_net < fuzz/corpus/arp_request.bin
```

With AFL++ (QEMU mode for aarch64 coverage):

```
afl-fuzz -Q -i fuzz/corpus -o fuzz/findings -- ./build/fuzz_net
```

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
- UDP with echo service (port 7)
- Timer infrastructure (ARM generic timer, software timer pool)

**Next:**
- DNS client (UDP) — resolve hostnames for NTP
- NTP client (UDP) — wall-clock time for HTTP `Date` headers
- TCP
- HTTP

## Future: Multi-Pi Architecture

The network stack is composed of plain functions that operate on buffers — nothing ties them to a specific role. This opens the door to a cluster of bare-metal Pi 3s, each with a single narrow responsibility, sharing the same assembly library:

- **Firewall/filter** — inspects packets at the IP level, forwards or drops. No TCP state needed. Defends against DoS by rejecting traffic before it reaches the web server.
- **Load balancer** — parses through TCP, rewrites headers, distributes connections across multiple web server nodes. Needs connection tracking but not HTTP parsing.
- **Web server** — the current project. Handles TCP, serves HTTP responses. No persistent storage — reads files from the NAS over the local network.
- **NAS** — serves a fixed set of files over a minimal read-only protocol. No directory paths, no filesystem traversal — files identified by index. Nothing to steal, nothing to overwrite.

Each device runs bare-metal with fixed allocations — no OS, no heap, no dynamic loading. An attacker who compromises one node finds no writable filesystem to persist on, no shell to escalate through, and no heap to corrupt. The total codebase across all four roles might stay under 20 KB, small enough to audit by hand.

Four Pi 3s is roughly $140 of hardware for a complete hardened web stack.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
