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
                  → timer_pool_init → ip_reasm_init → tcp_init → tcp_listen(80)
                  → tcp_set_timer_pool → tcp_start_reaper → tcp_set_send_ctx
                  → ntp_init → ntp_start
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

The kernel image is under 20 KB.

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
  ip_reasm.S      IP fragment reassembly — 4-slot reassembly engine with timeout
  icmp.S          ICMP echo reply — swap addresses, recompute checksums
  udp.S           UDP checksum with pseudo-header, validation, echo service (port 7)
  tcp.S           TCP — 2900-line implementation: 10-state FSA, congestion control,
                    timestamps, retransmission, OOO buffering, security hardening
  ntp.S           SNTP client — request builder, response parser, timer-driven polling
  md5.S           MD5 hash — used for TCP ISN generation (RFC 6528)
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
tests/          Test sources — 332 unit tests across 26 files
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

332 tests run on `qemu-system-aarch64 -M raspi3b`, covering every layer of the stack from UART output through USB enumeration to the full TCP connection lifecycle including congestion control, retransmission, timestamps, OOO buffering, and security hardening.

The test philosophy follows from the project's CLAUDE.md: failure handling code that is never tested is a liability. Functions accept MMIO base addresses as parameters rather than hardcoding constants — this is dependency injection at the ISA level, allowing tests to point hardware register accesses at fake register blocks in RAM.

Branch coverage is audited after each feature: every conditional branch in production code has at least one test exercising both the taken and not-taken paths. Dedicated coverage-gap tests exist solely to close branches that no behavioral test would naturally hit — examples include FSA null-handler dispatch, connection scan miss paths, ICMP soft-error state guards, FIN-with-data SEQ/overflow rejection, and TIME_WAIT timer-cancel edge cases.

The TDD workflow:

1. Write a test in `tests/` — call `test_pass` or `test_fail` with a test name string
2. Register it with `bl test_xxx` in `tests/test_main.S`
3. `make test` — verify it fails (red)
4. Implement in `lib/`, `drivers/`, or `src/`
5. `make test` — verify it passes (green)
6. Commit

The QEMU test runner (`scripts/run_tests.sh`) runs the test kernel in the background, polls serial output for pass/fail markers, and kills QEMU cleanly to ensure output is flushed.

### Scenario Tests — Windowing and Buffer Contents

Thirteen multi-step protocol-level tests verify correctness properties across sequences of TCP operations. These go beyond single-call unit tests to exercise the interaction between receive buffering, window advertisement, data sending, send window tracking, and buffer management.

**Window tests (S1-S3):**

- **`test_tcp_window_tracks_fill`** (S1) — Verifies the window shrinks monotonically as data accumulates. Handshakes, sends 100 bytes, checks ACK window = `rev16(2048-100)`, then sends 200 more and checks window = `rev16(2048-300)`. Tests that the running RXLEN total feeds correctly into the NBO window computation across multiple segments.
- **`test_tcp_window_after_flush`** (S2) — Verifies the application can reclaim buffer space. Sends 100 bytes (window shrinks), calls `tcp_rx_flush`, sends 50 more. Checks that the ACK window reflects only the 50 post-flush bytes — `rev16(2048-50)` — not the cumulative 150. This is the critical test for the consume-then-advertise cycle that prevents deadlock.
- **`test_tcp_window_zero`** (S3) — Boundary test for zero-window advertisement. Pre-sets RXLEN to 2043, sends 5 bytes to fill the buffer exactly to 2048. Verifies the ACK window is literally 0. This is what tells the peer to stop sending until a window update arrives.

**Buffer contents tests (S4-S5):**

- **`test_tcp_buffer_contents`** (S4) — Verifies data integrity and ordering across concatenation. Sends "AAAA" then "BBBB" as separate segments. Peeks and byte-compares all 8 bytes against `0x41414141 0x42424242`. Catches off-by-one errors in the destination offset calculation (`pool + (slot << 11) + rxlen`).
- **`test_tcp_buffer_survives_flush`** (S5) — Verifies flush doesn't leave stale data visible. Sends "AAAA", flushes, sends "CCCC". Peeks and verifies 4 bytes of "CCCC" — not 8 bytes with stale "AAAA" prefix. This works because flush zeroes RXLEN, so the next write starts at offset 0 in the slot, overwriting the old data.

**Send + integration tests (S6-S7):**

- **`test_tcp_send_frame_fields`** (S6) — Exhaustive field-level verification of a `tcp_send` output frame. Receives 100 bytes first (so the window isn't full-size), then sends "World". Checks: ETH dst matches RMAC, IP total length = 45 (NBO), TCP sport=80, dport=12345, SEQ = `rev(SND_NXT_before)`, ACK = `rev(RCV_NXT)`, flags = PSH+ACK, window = `rev16(2048-100)`, TCP checksum validates to 0, and payload bytes at offset 54 are 'W' and 'd'. This is the only test that verifies `tcp_build_frame` produces a wire-correct frame from `tcp_send`'s perspective.
- **`test_tcp_send_rx_independent`** (S7) — Verifies send and receive paths don't interfere. Receives 50 bytes of 'X', then sends "World". Checks three things: rx peek still returns 50 bytes with 'X' at offset 0, send returned 59 (54+5), and SND_NXT advanced by exactly 5. This catches any accidental clobbering of RXLEN or the rx buffer pointer during the send path.

**Send window scenario tests (S8-S13):**

- **`test_tcp_send_window_exhaustion`** (S8) — Full send-window lifecycle: drain, block, reopen, resume. Sets SND_WND=15, sends three 5-byte segments (SND_WND drains 15→10→5→0), verifies a fourth send is rejected and `tcp_send_ready` returns 0. Then injects a pure ACK with window=1000, verifies SND_WND reopens to 1000, `tcp_send_ready` returns 1000, and a subsequent send succeeds with SND_WND=995. This is the most important scenario — it proves the complete flow that motivated the feature.
- **`test_tcp_window_update_partial`** (S9) — Window update with non-empty receive buffer. Handshakes, receives 500 bytes, then calls `tcp_window_update`. Verifies the returned frame advertises window = `rev16(2048-500)` = `rev16(1548)`. The existing window update tests only check empty buffer (window=2048) or invalid state — this verifies `tcp_build_frame`'s dynamic window computation when RXLEN > 0 via the explicit window-update path.
- **`test_tcp_send_boundary`** (S10) — Payload length exactly equals SND_WND. Sets SND_WND=5, sends 5 bytes. Verifies ret=59 (succeeds) and SND_WND=0. Tests the `cmp`/`b.hi` guard at the exact boundary — a `b.hs` bug would reject this case.
- **`test_tcp_send_ready_zero`** (S11) — SND_WND=0 returns 0. The existing `tcp_send_ready` tests check SND_WND=500 and SND_WND=2000; this tests the zero case — the caller's signal to stop sending and wait for a window update.
- **`test_tcp_snd_wnd_pure_ack`** (S12) — Pure ACK (no data) updates SND_WND. Sets SND_WND=0, injects a pure ACK with window=4096. Verifies `tcp_handle` returns 0 (pure ACK drop) and SND_WND=4096. This exercises the SND_WND update through the `cbz w4, .Leak_pure_ack` code path, which the existing data-carrying ACK test doesn't reach.
- **`test_tcp_snd_wnd_data_ack`** (S13) — Data ACK updates both rx buffer and SND_WND. Sets SND_WND=100, sends a 5-byte data frame with window=8192. Verifies ret=54 (ACK reply), RXLEN=5 (data accepted), and SND_WND=8192. Proves the SND_WND write at the handler top isn't clobbered by the data-copy or ACK-reply logic that follows.

### Functional Tests (PICT-Based Exhaustive Testing)

Beyond unit tests, the TCP state machine has exhaustive functional coverage using [PICT](https://github.com/microsoft/pict) (Microsoft's Pairwise Independent Combinatorial Testing tool) with `/o:max` for full cross-product generation.

Six independent parameters — connection state (10 states), TCP flags, port match type, payload, checksum validity, and header validity — produce a constrained cross-product of 138 PICT-generated test vectors plus 7 handcrafted scenario tests (ICMP teardown, timestamp negotiation, PAWS rejection, etc.) for a total of 145 functional tests. A Python oracle (`scripts/tcp_oracle.py`) independently computes the expected behavior for each vector: return value, post-state, reply flags, SEQ/ACK values, and post-connection fields (RCV_NXT, RXLEN, SND_UNA). This gives two independent specifications of TCP correctness written in different languages — if both agree on all 145 cases, confidence is very high.

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

The TCP implementation uses a table-driven FSA instead of a hand-coded `cmp`/`b.eq` dispatch chain. The transition table IS the state machine — 10 states x 5 events = 50 entries, stored as 800 bytes in `.rodata`.

Each entry is 16 bytes: a next-state word and a handler function pointer (reusing the vmio transition table layout). Dispatch is a single indexed load — `state * 5 + event` — followed by `blr`. Unpopulated entries (handler = NULL) fall through to RST generation.

Event classification maps TCP flags to 5 event codes in priority order: RST > SYN > FIN > ACK. This collapses the flag-combination space into a small, well-defined set that the table can address directly.

**Implemented states:** CLOSED, LISTEN, SYN_RCVD, ESTABLISHED, CLOSE_WAIT, LAST_ACK, FIN_WAIT_1, FIN_WAIT_2, CLOSING, TIME_WAIT.

**Core protocol:**
- Three-way handshake (passive open): SYN → SYN-ACK → ACK → ESTABLISHED
- Data transfer: ACK+PSH with payload → receive buffering, ACK reply with dynamic window
- `tcp_send`: application-driven data transmission with PSH+ACK
- `tcp_rx_peek`/`tcp_rx_flush`: application access to receive buffer (2 KB per connection)
- Dynamic window advertisement: tracks buffer fill, advertises zero when full
- Passive close: peer FIN → ACK, CLOSE_WAIT → LAST_ACK → CLOSED (accepts data on FIN)
- Active close: `tcp_close` → FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT → CLOSED (and simultaneous close via CLOSING)
- TIME_WAIT with 2MSL timer, re-ACKs retransmitted FINs
- Send window tracking: SND_WND captured from handshake, updated from incoming ACKs
- `tcp_send_ready` / `tcp_window_update`: query and advertise window state
- Connection table with 16 slots, SYN_RCVD eviction on table-full

**Reliability:**
- Retransmission timer with exponential backoff (1s base, capped at 60s, max 8 retries)
- Fast retransmit on 3 duplicate ACKs (RFC 5681) with multiplicative decrease
- Congestion control: slow start, congestion avoidance, ssthresh tracking
- OOO segment buffering: 4 slots per connection, merge on in-order delivery

**Options:**
- MSS negotiation (advertise 1460, parse peer MSS, default 536)
- TCP timestamps (TSopt): negotiated from SYN, echoed in all replies
- PAWS: reject stale segments via TSval comparison

**Security hardening:**
- RST SEQ validation (RFC 5961): out-of-window RSTs silently dropped
- RST rate limiting: token-bucket at 10/sec burst
- ICMP soft errors for ESTABLISHED+ (RFC 5461): only hard-close SYN_RCVD
- Idle connection reaper: per-state timeouts (ESTABLISHED 120s, FIN states 60s)
- Persist timer: zero-window probing with exponential backoff (5s–60s)
- DF bit set on all outgoing IP packets
- RST generation for invalid packets, unknown ports, and unpopulated FSA entries

The FSA approach made adding each new feature trivial — a new handler function and a populated table entry, with no changes to the dispatch logic.

## Fuzzing

Coverage-guided fuzzing of the network packet parsers (`eth_type`, `arp_handle`, `ip_handle`, `icmp_handle`, `udp_handle`, `tcp_handle`, `net_recv_one`). All functions are pure computation on caller-provided buffers — no MMIO, no syscalls — making them ideal for user-mode fuzzing.

### Prerequisites

```
sudo apt install gcc-aarch64-linux-gnu qemu-user-static
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

### Multi-packet TCP fuzzing

The single-packet harness resets `tcp_init()` each run, so TCP can only ever reach SYN_RCVD. The multi-packet harness (`fuzz/fuzz_tcp_seq.c`) feeds a *sequence* of frames per run, letting the fuzzer explore handshake completion, ESTABLISHED-state data transfer, window management, and close sequences.

**Input format:** Concatenated length-prefixed frames: `[u16be len][frame bytes]...`

Build the harness and generate seeds:

```
make fuzz-seq
make fuzz-corpus-seq
```

Run a single seed manually:

```
qemu-aarch64 -L /usr/aarch64-linux-gnu ./build/fuzz_tcp_seq < fuzz/corpus_seq/tcp_handshake.bin
```

With AFL++:

```
afl-fuzz -Q -i fuzz/corpus_seq -o fuzz/findings_seq -- ./build/fuzz_tcp_seq
```

**16 seed files** (generated by `fuzz/gen_corpus_seq.py`):

| File | Frames | TCP path exercised |
|------|--------|--------------------|
| `tcp_handshake.bin` | SYN + ACK | ESTABLISHED state |
| `tcp_handshake_data.bin` | SYN + ACK + PSH+ACK("Hello") | Data acceptance, rx buffer copy |
| `tcp_handshake_fin.bin` | SYN + ACK + FIN+ACK | Passive close (CLOSE_WAIT) |
| `tcp_handshake_rst.bin` | SYN + ACK + RST | ESTABLISHED → CLOSED |
| `tcp_handshake_multi.bin` | SYN + ACK + 3× PSH+ACK data | Multi-segment buffering, window shrink |
| `tcp_full_close.bin` | Handshake + FIN + ACK | Full passive close to CLOSED |
| `tcp_active_close.bin` | Handshake + close sentinel | Active close (FIN_WAIT path) |
| `tcp_simultaneous_close.bin` | Handshake + cross-FINs | CLOSING → TIME_WAIT |
| `tcp_last_ack.bin` | Handshake + FIN + close sentinel | LAST_ACK → CLOSED |
| `tcp_dup_data.bin` | Handshake + 2× same data | Duplicate segment handling |
| `tcp_dup_syn.bin` | 2× SYN to same port | Duplicate SYN |
| `tcp_dup_syn_flood.bin` | 17× SYN (exceeds 16 slots) | SYN_RCVD eviction |
| `tcp_data_then_rst.bin` | Handshake + data + RST | Mid-transfer teardown |
| `tcp_bad_seq_data.bin` | Handshake + wrong-SEQ data | OOO / bad SEQ rejection |
| `tcp_ts_handshake.bin` | SYN(TSopt) + ACK | Timestamp negotiation |
| `tcp_ooo_merge.bin` | Handshake + OOO + in-order | OOO buffering and merge |

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
- IP with checksum validation, fragment reassembly (4-slot engine with timeouts)
- ICMP echo request/reply (ping)
- UDP with echo service (port 7)
- TCP — complete transport layer: 10-state FSA, congestion control (slow start / avoidance), retransmission with backoff, fast retransmit (RFC 5681), TCP timestamps with PAWS, OOO buffering, MSS negotiation, persist timer, idle reaper, RST rate limiting, RST SEQ validation (RFC 5961), ICMP soft errors (RFC 5461), SYN flood eviction, DF bit, data-on-FIN, TIME_WAIT re-ACK
- Timer infrastructure (ARM generic timer, software timer pool)
- SNTP client — timer-driven polling, request builder, response parser, wall-clock time via `ntp_time`
- MD5 hash for TCP ISN generation (RFC 6528)
- Dependency injection for testability (send function pointer, MMIO base addresses as parameters)

**Test coverage:** 332 unit tests (complete branch coverage) + 145 functional tests (138 PICT-generated exhaustive combinatorial + 7 handcrafted scenario) + 29 fuzz corpus inputs (13 single-packet + 16 multi-packet sequence). All tests run on QEMU raspi3b, zero crashes.

**Next:**
- Complete the production-quality network stack hardening described below, then implement HTTP

## Work in Progress

### Network Stack Production-Quality Audit

A full audit of every layer against the relevant RFCs identified ~50 issues spanning compliance gaps, missing validation, security vulnerabilities, and robustness failures. All audit items have been resolved — the stack is now production-quality for its current feature set. Next: TCP send path redesign for high-throughput page serving, then HTTP.

#### Completed Layers

All ~50 audit items resolved across every layer:

| Layer | Key Fixes |
|-------|-----------|
| **Ethernet/Glue** | Frame length from HCTSIZ, upper-bound + 802.3 checks, MAC filtering, init ordering |
| **ARP** | Reply processing, SPA validation, proactive cache refresh (timer-driven) |
| **IP** | TTL=0 rejection, fragment overlap detection, alignment validation, min-TTL tracking |
| **ICMP** | Checksum validation, error generation (Protocol/Port Unreachable), rate limiting, code distinction |
| **TCP** | OOO window check, PAWS on all segments, state rollback on handler failure, ISN granularity, DUP_ACK reset, SYN_RCVD 60s timeout |
| **UDP** | Verified correct (existing validation sufficient) |
| **NTP** | LI/version/dispersion checks, timestamp monotonicity, sync staleness, poll backoff |
| **VMIO/Timers** | State bounds check, timer_cancel index validation |

#### Next: TCP Send Path Redesign

The current 1-segment-in-flight design delivers a 200 KB page in 6.8 seconds at 50ms RTT. Target: ~50ms (1 RTT) via 256 KB windows.

| Parameter | Current | Target |
|-----------|---------|--------|
| Connections | 16 | 128 |
| Send buffer | 1514 bytes (1 frame) | 256 KB (circular) |
| Window | 64 KB max (no WSCALE) | 256 KB via WSCALE |
| Rxbuf | 2 KB | 2 KB (unchanged) |
| Memory | ~68 KB | ~32.5 MB (~3.2% of Pi 3 RAM) |

Implementation:
1. WSCALE negotiation in SYN-ACK
2. Circular send buffer (replaces single-frame retransmit)
3. Multi-segment send loop
4. Sliding window ACK processing
5. SACK (selective acknowledgment)
6. RFC 6298 RTO (SRTT/RTTVAR measurement)

#### After TCP: HTTP

| Gap | Impact |
|-----|--------|
| **HTTP request parser** | Cannot understand what client wants |
| **HTTP response generator** | Cannot reply to client |

#### Design Decisions

| Item | Rationale |
|------|-----------|
| No Nagle algorithm | HTTP servers disable Nagle anyway |
| No IP options parsing | Deliberately rejected (VER_IHL == 0x45 only) |
| 4-slot reassembly limit | Intentional resource constraint for bare-metal |
| Single-entry ARP cache | We only talk to the gateway |
| NTP 32-bit seconds | Sub-second precision not needed for HTTP timestamps |
| No PMTUD | Target network is direct Ethernet, MTU 1500; DF bit set |

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
