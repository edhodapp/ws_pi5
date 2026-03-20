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
  main.S        uart_init → dwc2_init → cdc_ecm_init → cdc_ecm_activate → ntp_start
    net_loop    Receive Ethernet frames via USB bulk-IN
      net.S     Dispatch by EtherType
        ARP  →  arp.S    Validate request, build reply in-place, cache gateway MAC
        IPv4 →  ip.S     Validate header + checksum, dispatch by protocol
          ICMP → icmp.S  Swap MACs/IPs, recompute checksums, reply
          UDP  → udp.S   Checksum with pseudo-header, echo on port 7, NTP dispatch
          TCP  → tcp.S   Table-driven FSA, connection tracking, data transfer
      timer_check        Fire expired software timers (NTP poll, etc.)
      cdc_ecm_send       Transmit reply via USB bulk-OUT
```

The kernel image is under 10 KB.

## Project Structure

```
src/            Main kernel source
  boot.S          Entry point — park cores 1-3, stack, BSS, call main
  main.S          USB bring-up sequence and net_loop dispatcher
lib/            Pure computation libraries
  eth.S           Ethernet frame utilities — EtherType, header builder, MAC compare
  net_cfg.S       Wire-format MAC and IP address data
  net.S           Receive dispatcher — routes by EtherType
  arp.S           ARP request validation and in-place reply builder
  ip.S            RFC 1071 checksum, IPv4 header validation, protocol dispatch
  icmp.S          ICMP echo reply — swap addresses, recompute checksums
  udp.S           UDP checksum with pseudo-header, validation, echo service (port 7)
  tcp.S           TCP — table-driven FSA, connection table, three-way handshake, data transfer
  ntp.S           SNTP client — request builder, response parser, timer-driven polling
  timer_pool.S    Software timer pool — set, cancel, check expired
  vmio_queue.S    Circular event queue with priority levels
  vmio_engine.S   Finite state automaton engine — init, single-step
drivers/        Hardware drivers
  uart.S          PL011 UART init at 115200, putc, puts
  mailbox.S       VideoCore mailbox IPC (USB power-on)
  dwc2.S          DWC2 USB host controller init and port reset
  usb_enum.S      USB device enumeration via control transfers
  usb_desc.S      Config descriptor reading and bulk endpoint parsing
  usb_bulk.S      Bulk transfer execution with DATA toggle tracking
  cdc_ecm.S       CDC-ECM device init, activate, send/recv
  timer_hw.S      ARM generic timer access (CNTPCT_EL0, CNTFRQ_EL0)
include/        Shared constants and macros (.inc files)
tests/          Test sources — 143 unit tests across 22 files
tests/func/     PICT-based functional test models
fuzz/           Fuzz harness for network packet parsers
scripts/        Build and test automation (including Python oracle)
hw_test/        Hardware test scripts for Pi 4 test fixture
```

## Building

Requires the AArch64 cross-toolchain and QEMU:

```
sudo apt install gcc-aarch64-linux-gnu qemu-system-aarch64
```

For functional tests, install [PICT](https://github.com/microsoft/pict) (Microsoft's pairwise/combinatorial testing tool):

```
sudo apt install pict
```

Build the kernel image:

```
make
```

Run the unit test suite:

```
make test
```

Run exhaustive functional tests:

```
make test-functional
```

Clean build artifacts:

```
make clean
```

## Testing

### Unit Tests

143 tests run on `qemu-system-aarch64 -M raspi3b`, covering every layer of the stack from UART output through USB enumeration to TCP data transfer and passive close.

The test philosophy follows from the project's CLAUDE.md: failure handling code that is never tested is a liability. Functions accept MMIO base addresses as parameters rather than hardcoding constants — this is dependency injection at the ISA level, allowing tests to point hardware register accesses at fake register blocks in RAM.

Branch coverage is audited after each feature: every conditional branch in production code has at least one test that exercises it. Two dedicated coverage-gap tests (`test_tcp_fsa_null_handler`, `test_tcp_scan_lport_miss`) exist solely to cover edge-case branches that no behavioral test would naturally hit.

The TDD workflow:

1. Write a test in `tests/` — call `test_pass` or `test_fail` with a test name string
2. Register it with `bl test_xxx` in `tests/test_main.S`
3. `make test` — verify it fails (red)
4. Implement in `lib/`, `drivers/`, or `src/`
5. `make test` — verify it passes (green)
6. Commit

The QEMU test runner (`scripts/run_tests.sh`) runs the test kernel in the background, polls serial output for pass/fail markers, and kills QEMU cleanly to ensure output is flushed.

### Functional Tests (PICT-Based Exhaustive Testing)

Beyond unit tests, the TCP state machine has exhaustive functional coverage using [PICT](https://github.com/microsoft/pict) (Microsoft's Pairwise Independent Combinatorial Testing tool) with `/o:max` for full cross-product generation.

Six independent parameters — connection state, TCP flags, port match type, payload, checksum validity, and header validity — produce a constrained cross-product of 77 test vectors. A Python oracle (`scripts/tcp_oracle.py`) independently computes the expected behavior for each vector: return value, reply flags, and post-state. This gives two independent specifications of TCP correctness written in different languages — if both agree on all cases, confidence is very high.

The pipeline:

```
tcp_func.pict  →  pict /o:max  →  tcp_vectors.tsv  →  tcp_oracle.py  →  tcp_vectors.bin
                                                                              ↓
                                              test_tcp_func.S (.incbin)  →  QEMU  →  PASS/FAIL
```

The assembly harness (`tests/test_tcp_func.S`) loads the binary table via `.incbin`, loops over every entry, calls `tcp_init` and pre-seeds connection state, invokes `tcp_handle`, and verifies the result against the oracle's expectations. A strong `tcp_isn` symbol overrides the weak default to ensure deterministic ISN values.

If PICT is unavailable, the oracle has a `--generate` fallback that enumerates the full cross-product directly in Python:

```
python3 scripts/tcp_oracle.py --generate > build/tcp_vectors.bin
```

## TCP: Table-Driven Finite State Automaton

The TCP implementation uses a table-driven FSA instead of a hand-coded `cmp`/`b.eq` dispatch chain. The transition table IS the state machine — 9 states x 5 events = 45 entries, stored as 720 bytes in `.rodata`.

Each entry is 16 bytes: a next-state word and a handler function pointer (reusing the vmio transition table layout). Dispatch is a single indexed load — `state * 5 + event` — followed by `blr`. Unpopulated entries (handler = NULL) fall through to RST generation.

Event classification maps TCP flags to 5 event codes in priority order: RST > SYN > FIN > ACK. This collapses the flag-combination space into a small, well-defined set that the table can address directly.

**Implemented states:** LISTEN, SYN_RCVD, ESTABLISHED, CLOSE_WAIT, CLOSED.

**What works:**
- Three-way handshake (passive open): SYN → SYN-ACK → ACK → ESTABLISHED
- Data transfer: ACK+PSH with payload → ACK reply, RCV_NXT tracking
- Out-of-order detection: segments with wrong SEQ are silently dropped
- Passive close: FIN → ACK, transition to CLOSE_WAIT
- RST generation for invalid packets, unknown ports, and unpopulated FSA entries
- Connection table with 16 slots, scanned on each incoming segment

The FSA approach made adding data transfer and passive close trivial — each was a new handler function and a populated table entry, with no changes to the dispatch logic.

## Fuzzing

Coverage-guided fuzzing of the network packet parsers (`eth_type`, `arp_handle`, `ip_handle`, `icmp_handle`, `udp_handle`, `tcp_handle`, `net_recv_one`). All functions are pure computation on caller-provided buffers — no MMIO, no syscalls — making them ideal for user-mode fuzzing.

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
- ARP request/reply with passive gateway MAC learning
- ICMP echo request/reply (ping)
- UDP with echo service (port 7)
- TCP with table-driven FSA — three-way handshake, data transfer, passive close, RST generation
- Timer infrastructure (ARM generic timer, software timer pool)
- SNTP client — timer-driven polling, request builder, response parser, wall-clock time via `ntp_time`
- Dependency injection for testability (send function pointer in NTP context, MMIO base addresses as parameters)

**Test coverage:** 143 unit tests (complete branch coverage) + 77 PICT-generated functional tests (exhaustive combinatorial coverage of TCP state machine). All tests run on QEMU raspi3b.

**Next:**
- TCP active close (FIN from our side)
- HTTP request parsing and response generation

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
