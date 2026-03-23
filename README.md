# Bare-Metal Web Server

<!-- DO NOT MODIFY: This dedication was handwritten by Ed Hodapp. AI must not edit, move, or rephrase it. -->
*This work is dedicated to Jon Lasser - a good friend, good coworker, and very thoughtful soul on this Earth. Jon is a very bright spark in a very dark Universe. He is missed.*

---

A bare-metal web server written entirely in AArch64 assembly through human-AI collaboration. The goal is a complete, production-quality web server — from boot to TLS to serving pages — with no OS, no C runtime, and no abstraction layers.

The project targets multiple AArch64 platforms: Raspberry Pi 4 (BCM2711) and BeaglePlay (TI AM625). The protocol stack is platform-independent; only boot sequences and hardware drivers differ between boards.

**Current stage:** The protocol stack is complete and verified. The project is entering hardware integration on Pi 4 — first bare-metal boot on real silicon.

## The Experiment

This project started as two questions:

1. Can humans and AI collaborate effectively on real systems programming in assembly?
2. Do implementation-specific tests become net-positive when AI eliminates the maintenance cost?

**The answer to both is yes.** The protocol stack — TCP with 128 connections, WSCALE, SACK, RFC 6298 RTO, multi-segment send — was developed through human-AI collaboration with 872 verified tests, zero fuzz crashes, and every bug caught by tests rather than inspection. Implementation-specific tests proved invaluable as a ratchet against AI hallucination, and the maintenance cost (AI regenerates tests in seconds) was negligible compared to the bugs caught.

Assembly is an interesting medium for AI collaboration because it resists the usual pattern of generating boilerplate. Every instruction matters — there's no framework to lean on, no abstraction layer to hide behind. The division of labor falls out naturally:

- **The human** provides architectural direction, testability discipline, and decides what abstractions to form.
- **The AI** handles the combinatorial detail — register allocation, calling conventions, protocol byte layouts, checksum algorithms — and proposes implementations that the human reviews and tests.

TDD at the ISA level keeps both parties honest. The test suite is the shared source of truth: if the tests pass, the implementation is correct regardless of who wrote it. This eliminates the trust problem — you don't have to take the AI's word for anything.

### Implementation-specific tests as an AI constraint

Conventional wisdom says: don't write tests that are tightly coupled to implementation details, because they break during refactors and create maintenance burden. This project deliberately violates that rule.

The reasoning: that conventional wisdom is calibrated to human costs. When a human has to rewrite 10 tests after a structural change, that's real friction. When an AI can regenerate the entire test file in seconds, the maintenance cost drops to near zero — and the value of catching bugs in internal logic dominates.

Implementation-specific tests serve as a ratchet against AI hallucination. A behavioral test says "the callback fired" — the AI could produce a broken scan loop that happens to work for one timer. An implementation-specific test says "slot 0's callback field is zero after cancel" — there's nowhere to hide. Every test that pins internal state narrows the space of wrong-but-compiles outputs the AI could produce.

## What It Does

Boots on a Raspberry Pi 4, brings up USB Ethernet (CDC-ECM), and serves HTTP on port 80. The full path:

```
boot.S          Core 0 init, EL2→EL1 drop, MMU + caches, stack, BSS zero
  main.S        uart_init → GPIO mux (UART3) → dwc2_init → cdc_ecm_init
                  → timer_pool_init → ip_reasm_init → icmp_init
                  → tcp_init → tcp_listen(80) → tcp_set_timer_pool
                  → tcp_start_reaper → tcp_set_send_ctx
                  → arp_start → ntp_init → ntp_start → http_init
    net_loop    Receive Ethernet frames, dispatch, send replies
      net.S     Dispatch by EtherType (MAC filtering, 802.3 rejection)
        ARP  →  arp.S    Request/reply, SPA validation, proactive cache refresh
        IPv4 →  ip.S     Validate header + checksum, dispatch by protocol
          ICMP → icmp.S  Echo reply + error generation (Protocol/Port Unreachable)
          UDP  → udp.S   Checksum with pseudo-header, echo on port 7, NTP dispatch
          TCP  → tcp.S   128-conn FSA, WSCALE, SACK, multi-segment send
      timer_check        Fire expired software timers (NTP, ARP, retransmit)
      http_poll          Parse requests, send responses (cooperative, non-blocking)
```

Kernel image: 25 KB. Runtime memory: 32.6 MB (dominated by 128 × 256 KB TCP send buffers).

## Project Structure

```
lib/                Platform-independent protocol stack (no MMIO dependencies)
  eth.S               Ethernet frame utilities — EtherType, header builder, MAC compare
  net_cfg.S           Wire-format MAC and IP address data
  net.S               Receive dispatcher — routes by EtherType with MAC filtering
  arp.S               ARP request/reply handler, proactive cache refresh (timer-driven)
  ip.S                RFC 1071 checksum, IPv4 header validation, protocol dispatch
  ip_reasm.S          IP fragment reassembly — 4-slot engine with overlap detection
  icmp.S              ICMP echo reply + error generation (rate-limited, loop-suppressed)
  udp.S               UDP checksum with pseudo-header, validation, echo service (port 7)
  tcp.S               TCP — 3600 lines: 128-conn FSA, WSCALE, SACK, RFC 6298 RTO,
                        multi-segment send, 256 KB circular send buffer
  http.S              HTTP/1.1 server — GET parser, 200/404 responses, cooperative poll
  ntp.S               SNTP client — timer-driven polling, auth, monotonicity, backoff
  md5.S               MD5 hash — used for TCP ISN generation (RFC 6528)
  timer_hw.S          ARM generic timer access (CNTPCT_EL0, CNTFRQ_EL0) — architectural
  timer_pool.S        Software timer pool — set, cancel, check expired
  vmio_queue.S        Circular event queue with priority levels
  vmio_engine.S       Finite state automaton engine — init, single-step
include/            Shared constants and macros (.inc files)
  tcp.inc             TCONN struct layout, TCP constants
  http.inc            HCONN struct layout, HTTP state machine constants
  net.inc             Ethernet/ARP/IP/ICMP constants
  ntp.inc             NTP constants
  timer.inc           Timer pool constants
  vmio.inc            VMIO engine constants
platform/pi/        Raspberry Pi 4 (BCM2711)
  boot.S              Entry point — EL2→EL1 drop, MMU setup, park cores 1-3, stack, BSS
  main.S              GPIO mux, UART3 init, DWC2 USB → CDC-ECM, net_loop, http_poll
  include/            Pi-specific constants
    platform.inc        PERIPH_BASE (0xFE for Pi 4, 0x3F for QEMU testing)
    dwc2.inc            DWC2 USB host register map
    usb.inc             USB protocol constants
    usb_desc.inc        USB descriptor parsing constants
    cdc_ecm.inc         CDC-ECM constants
    uart.inc            PL011 UART register offsets
    gpio.inc            GPIO function select constants
    mailbox.inc         VideoCore mailbox constants
  drivers/            Pi hardware drivers
    uart.S              PL011 UART with configurable base (UART0 or UART3)
    gpio.S              GPIO function select (generic, any pin/function)
    mailbox.S           VideoCore mailbox IPC (USB power-on, temperature)
    dwc2.S              DWC2 USB host controller init and port reset
    usb_enum.S          USB device enumeration via control transfers
    usb_desc.S          Config descriptor reading and bulk endpoint parsing
    usb_bulk.S          Bulk transfer execution with DATA toggle tracking
    cdc_ecm.S           CDC-ECM device init, activate, send/recv
platform/beagleplay/ BeaglePlay (TI AM625)
  boot.S              Entry point — core parking, stack, BSS (A53 enters at EL1)
  main.S              CPSW Ethernet init, net_loop with full protocol stack wiring
  include/            AM625-specific constants
    platform.inc        AM625 peripheral addresses (UART0, CPSW, DMTIMER, GPIO, GTC)
    uart.inc            16550 UART register offsets and bit masks
    cpsw.inc            CPSW 3G Ethernet MAC + MDIO + ALE + port register offsets
  drivers/            BeaglePlay hardware drivers
    cpsw_mdio.S         MDIO bus — PHY register read/write, link status, PHY detect
    cpsw_port.S         CPSW port/ALE/MACSL — port config, MAC address, ALE bypass
    cpsw.S              Top-level CPSW init (wires MDIO + port/ALE), send/recv stubs
chainload/          UART chainloader for Pi 4 development
  boot.S              Receives kernel over UART3, writes to 0x80000, jumps to it
  chainload.ld        Linked at 0x200000 (doesn't overlap kernel target)
tests/              Unit and functional tests
  test_main.S         Test runner (boot, MMU, dispatch, pass/fail reporting)
  test_*.S            Shared protocol stack tests (322 tests)
  pi/                 Pi-specific driver tests (41 tests)
    test_pi_all.S       Aggregates Pi tests via test_platform_drivers symbol
    test_gpio.S         GPIO function select tests (5 tests)
    test_dwc2.S         DWC2 USB host tests
    test_usb_*.S        USB enumeration, descriptor, bulk, failure tests
    test_cdc_ecm*.S     CDC-ECM tests
    test_mailbox.S      VideoCore mailbox tests
    test_boot_main.S    Boot/main integration tests
  beagleplay/         BeaglePlay-specific driver tests (35 tests)
    test_bp_all.S       Aggregates BeaglePlay tests
    test_cpsw_mdio.S    MDIO bus tests (13 tests)
    test_cpsw_port.S    Port/ALE/MACSL tests (15 tests)
    test_cpsw.S         Top-level init + stub tests (7 tests)
  func/               PICT-based functional test model
fuzz/               Fuzz harness for network packet parsers
scripts/            Build and test automation
  run_tests.sh        QEMU test runner (configurable QEMU binary)
  run_func_tests.sh   QEMU functional test runner
  tcp_oracle.py       PICT functional test oracle (Python)
  send_kernel.py      Host-side UART kernel sender for chainloader
hw_test/            Hardware test scripts for Pi 4 test fixture
```

## Building

Requires the AArch64 cross-toolchain and QEMU:

```
sudo apt install gcc-aarch64-linux-gnu qemu-system-arm ninja-build
```

For functional tests, install [PICT](https://github.com/microsoft/pict) (Microsoft's pairwise/combinatorial testing tool):

```
sudo apt install pict
```

### Multi-Platform Build

The codebase supports multiple target platforms. Each platform has its own boot sequence, drivers, and peripheral addresses under `platform/<name>/`. The shared protocol stack in `lib/` compiles identically for all platforms — only the assembler include path (`-I platform/<name>/include/`) changes.

| Target | Build Command | Test Command | Notes |
|--------|---------------|--------------|-------|
| **Pi 4** (QEMU testing) | `make` | `make test` | Default. Uses QEMU raspi3b with Pi 3 peripheral addresses |
| **Pi 4** (hardware) | `make PLATFORM=pi4` | Real hardware via chainloader | Pi 4 peripheral addresses, UART3 on GPIO 4/5 |
| **BeaglePlay** (AM625) | `make PLATFORM=beagleplay` | `make test PLATFORM=beagleplay` | CPSW driver with send/recv stubs |

Test kernels run on QEMU `raspi3b` with MMU enabled (identity-mapped page tables, Normal cacheable RAM, Device-nGnRnE peripherals). All tests pass on both QEMU 7.2 and QEMU 11.0-rc0.

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

Build the UART chainloader for Pi 4 development:

```
make chainload
```

Clean build artifacts:

```
make clean
```

### Pi 4 Development Workflow

A UART chainloader (671 bytes) sits on the SD card permanently and receives new kernels over serial:

```
make PLATFORM=pi4
python3 scripts/send_kernel.py kernel8.img
```

No SD card swaps needed — the development loop is edit → build → send over serial → running.

## Testing

### Unit Tests

363 tests (Pi) / 356 tests (BeaglePlay) run on QEMU `raspi3b`. The shared tests (322) cover every protocol layer from Ethernet through the full TCP connection lifecycle (128 connections, WSCALE, SACK, multi-segment send, RFC 6298 RTO) and HTTP request/response handling.

Pi-specific tests (41) cover GPIO function select, DWC2 USB host, USB enumeration, CDC-ECM Ethernet, VideoCore mailbox, and boot/main integration. BeaglePlay tests (35) cover CPSW MDIO bus, port/ALE configuration, MACSL reset/speed, and top-level init sequencing.

The test architecture uses a weak `test_platform_drivers` symbol in the shared test runner. Each platform provides a strong override that calls its platform-specific tests. This lets shared protocol tests run for all platforms without modification.

The test philosophy follows from the project's CLAUDE.md: failure handling code that is never tested is a liability. Functions accept MMIO base addresses as parameters rather than hardcoding constants — this is dependency injection at the ISA level, allowing tests to point hardware register accesses at fake register blocks in RAM.

Branch coverage is audited after each feature: every conditional branch in production code has at least one test exercising both the taken and not-taken paths.

The TDD workflow:

1. Write a test in `tests/` — call `test_pass` or `test_fail` with a test name string
2. Register it in the platform's test aggregator (`tests/pi/test_pi_all.S` or `tests/beagleplay/test_bp_all.S`)
3. `make test` — verify it fails (red)
4. Implement in `lib/` or `platform/<name>/`
5. `make test` — verify it passes (green)
6. Commit

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

- **`test_tcp_send_window_exhaustion`** (S8) — Full send-window lifecycle: drain, block, reopen, resume. Sets SND_WND=15, sends three 5-byte segments (SND_WND drains 15→10→5→0), verifies a fourth send is rejected and `tcp_send_ready` returns 0. Then injects a pure ACK with window=1000, verifies SND_WND reopens to 1000, `tcp_send_ready` returns 1000, and a subsequent send succeeds with SND_WND=995.
- **`test_tcp_window_update_partial`** (S9) — Window update with non-empty receive buffer. Handshakes, receives 500 bytes, then calls `tcp_window_update`. Verifies the returned frame advertises window = `rev16(2048-500)` = `rev16(1548)`.
- **`test_tcp_send_boundary`** (S10) — Payload length exactly equals SND_WND. Sets SND_WND=5, sends 5 bytes. Verifies ret=59 (succeeds) and SND_WND=0.
- **`test_tcp_send_ready_zero`** (S11) — SND_WND=0 returns 0.
- **`test_tcp_snd_wnd_pure_ack`** (S12) — Pure ACK (no data) updates SND_WND.
- **`test_tcp_snd_wnd_data_ack`** (S13) — Data ACK updates both rx buffer and SND_WND.

### Functional Tests (PICT-Based Exhaustive Testing)

Beyond unit tests, the TCP state machine has exhaustive functional coverage using [PICT](https://github.com/microsoft/pict) (Microsoft's Pairwise Independent Combinatorial Testing tool) with `/o:max` for full cross-product generation.

Six independent parameters — connection state (10 states), TCP flags, port match type, payload, checksum validity, and header validity — produce a constrained cross-product of 138 PICT-generated test vectors plus 15 handcrafted scenario tests for a total of 153 functional tests. A Python oracle (`scripts/tcp_oracle.py`) independently computes the expected behavior for each vector. This gives two independent specifications of TCP correctness written in different languages.

Functional tests are platform-independent and pass identically for all platforms.

The pipeline:

```
tcp_func.pict  →  pict /o:max  →  tcp_vectors.tsv  →  tcp_oracle.py  →  tcp_vectors.bin
                                                                              ↓
                                              test_tcp_func.S (.incbin)  →  QEMU  →  PASS/FAIL
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
- Connection table with 128 slots, SYN_RCVD eviction on table-full
- 256 KB circular send buffer per connection (32 MB pool)
- Multi-segment send: in-flight window check, no 1-segment gate

**Reliability:**
- RFC 6298 RTO: SRTT/RTTVAR measurement, Karn's algorithm, doubling on timeout
- Fast retransmit on 3 duplicate ACKs (RFC 5681) with multiplicative decrease
- SACK (RFC 2018): parse SACK blocks, SACK-aware selective retransmit
- Congestion control: slow start, congestion avoidance, ssthresh tracking (256 KB cap)
- OOO segment buffering: 4 slots per connection, receive window check, merge on in-order delivery

**Options:**
- MSS negotiation (advertise 1460, parse peer MSS, default 536)
- WSCALE (RFC 7323): negotiated from SYN, applied to SND_WND (256 KB windows)
- TCP timestamps (TSopt): negotiated from SYN, echoed in all replies
- PAWS: reject stale segments via TSval comparison (applies to all segments including pure ACKs)
- SACK-Permitted: negotiated from SYN, included in SYN-ACK

**Security hardening:**
- RST SEQ validation (RFC 5961): out-of-window RSTs silently dropped
- RST rate limiting: token-bucket at 10/sec burst
- ICMP soft errors for ESTABLISHED+ (RFC 5461): only hard-close SYN_RCVD
- Idle connection reaper: per-state timeouts (SYN_RCVD 60s, ESTABLISHED 120s, FIN states 60s)
- State rollback on handler failure (prevents state corruption from invalid segments)
- Persist timer: zero-window probing with exponential backoff (5s–60s)
- DF bit set on all outgoing IP packets
- RST generation for invalid packets, unknown ports, and unpopulated FSA entries

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

**16 seed files** cover: handshake, data transfer, passive/active/simultaneous close, duplicate SYN flood, OOO merge, timestamp negotiation, and bad-sequence rejection.

## Platform Details

### Raspberry Pi 4 (BCM2711)

- **SoC:** BCM2711, Cortex-A72 quad-core, 8 GB RAM
- **Kernel load:** `0x80000` (standard AArch64 boot)
- **Boot:** EL2 → EL1 drop, MMU setup (4 GB identity map, Normal + Device), caches enabled
- **Ethernet:** USB CDC-ECM (via DWC2 host controller). Native GENET Gigabit MAC planned.
- **UART:** PL011 — UART0 for early boot, UART3 on GPIO 4/5 (ALT4) for serial debug
- **GPIO:** Generic function select driver (`gpio_set_function`) using hardware divide for GPFSEL register/bit computation
- **USB:** DWC2 host at PERIPH_BASE + `0x980000`
- **Mailbox:** VideoCore IPC at PERIPH_BASE + `0x00B880`

#### GPIO Pin Assignments

| Header Pin | GPIO | Function | Notes |
|------------|------|----------|-------|
| Pin 7 | GPIO 4 | **UART3 TX** | Serial debug output |
| Pin 29 | GPIO 5 | **UART3 RX** | Serial debug input |
| Pin 8 | GPIO 14 | **Fan control** | Official Pi 4 case fan (on/off, planned) |

#### Serial Debug Wiring

Connect a **3.3V** USB-to-serial adapter (CP2102 or FTDI FT232RL):

```
Pi 4 Pin 7  (GPIO 4 / UART3 TX) → Adapter RX
Pi 4 Pin 29 (GPIO 5 / UART3 RX) → Adapter TX
Pi 4 Pin 9  (GND)                → Adapter GND
```

**Must be 3.3V logic** — a 5V adapter will damage the Pi GPIO. Do not connect the adapter's VCC pin.

### BeaglePlay (TI AM625)

- **SoC:** TI AM625, Cortex-A53 quad-core, 2 GB RAM
- **Kernel load:** `0x80000` (standard AArch64 boot)
- **Boot:** A53 enters at EL1 after TI ROM/SPL — no EL drop needed
- **Ethernet:** CPSW 3G native Gigabit MAC at `0x08000000` — direct memory-mapped, no USB involved
- **UART:** 16550-compatible UART0 at `0x02800000`
- **Documentation:** TI AM62x TRM (SPRUJ87A) — full register-level documentation publicly available

The CPSW Ethernet driver stack (MDIO, port/ALE, top-level init) is implemented and tested. Send/recv are stubbed pending PKTDMA implementation on hardware.

## Current Status

| Layer | Status | Key Features |
|-------|--------|-------------|
| **Boot** | Production ready | EL2→EL1, MMU (identity map), data + instruction caches |
| **Ethernet** | Production ready | Frame validation, MAC filtering, 802.3 rejection |
| **ARP** | Production ready | Request/reply, SPA validation, timer-driven cache refresh |
| **IP** | Production ready | Checksum, TTL, fragment reassembly with overlap detection |
| **ICMP** | Production ready | Echo reply, error generation, rate limiting |
| **UDP** | Production ready | Checksum, echo service, NTP dispatch |
| **TCP** | Production ready | 128 conns, WSCALE, SACK, RFC 6298 RTO, multi-segment send, 256 KB send buffer |
| **HTTP** | Implemented | GET parser, 200/404 responses, cooperative poll loop |
| **NTP** | Production ready | Timer-driven polling, LI/version/dispersion checks, monotonicity |
| **VMIO/Timers** | Production ready | Bounds-checked FSA engine, timer pool |
| **Pi 4 drivers** | Hardware integration | DWC2 USB, CDC-ECM, GPIO, UART3, MMU — entering hardware validation |
| **BeaglePlay drivers** | Tested (stubs) | CPSW MDIO + port/ALE + init tested; send/recv pending PKTDMA on hardware |
| **TLS/HTTPS** | Planned | TLS 1.3 with ARMv8 crypto extensions |

**Kernel image:** 25 KB (text + rodata + data; BSS: 32.6 MB runtime)

**Test coverage:**
- **Pi:** 363 unit tests + 153 functional tests + 39 fuzz seeds = **555 total**
- **BeaglePlay:** 356 unit tests + 153 functional tests = **509 total**
- All tests pass on both QEMU 7.2 and QEMU 11.0-rc0
- Complete branch coverage on all production code

### MMU and Caches

The kernel enables the MMU with identity-mapped page tables immediately after BSS zeroing. RAM is mapped as Normal cacheable (write-back, read/write-allocate); peripheral regions are mapped as Device-nGnRnE. This provides:

- **Data cache** — critical for the 32.6 MB TCP connection table and send buffers
- **Instruction cache** — reduces fetch latency for the net_loop hot path
- **Correct alignment semantics** — Normal memory allows unaligned accesses; Device memory requires natural alignment (enforced by QEMU 9+ and real hardware)

## Work in Progress

### Pi 4 Hardware Integration

Entering hardware validation — all software is built, UART chainloader is ready, waiting for serial adapter.

| Item | Status | Notes |
|------|--------|-------|
| **EL2→EL1 drop** | Done | Pi 4 boots at EL2; boot.S configures HCR/CNTHCTL/CPTR and erets to EL1 |
| **MMU + caches** | Done | 4 GB identity map, Normal RAM + Device peripherals |
| **UART3 on GPIO 4/5** | Done | GPIO driver + UART base switching in main.S |
| **UART chainloader** | Done | 671 bytes, receives kernels over serial at 115200 |
| **USB CDC-ECM** | Built, untested on hardware | DWC2 + USB enum + CDC-ECM — needs hardware validation |
| **GENET Ethernet driver** | Planned | Native Gigabit MAC, replaces USB CDC-ECM path |
| **Fan control** | Planned | GPIO 14 output + mailbox temperature reading |

### BeaglePlay Port (AM625)

| Item | Status | Notes |
|------|--------|-------|
| **CPSW MDIO driver** | Done (13 tests) | PHY register read/write, link status, BFI field composition |
| **CPSW port/ALE** | Done (15 tests) | Port config, MAC address, MACSL reset/speed, ALE bypass |
| **CPSW top-level** | Done (7 tests) | Init sequence wires all sub-drivers; send/recv stubbed |
| **PKTDMA** | Pending | Deferred to hardware — descriptor rings can't be meaningfully tested on QEMU |
| **16550 UART driver** | Pending | Register definitions ready, driver TBD |
| **Hardware bringup** | Pending | Board not yet acquired |

### HTTPS / TLS 1.3

| Item | Status | Notes |
|------|--------|-------|
| **AES-GCM** | Planned | ARMv8 crypto extensions (AESE/AESD/AESMC hardware instructions) |
| **SHA-256** | Planned | ARMv8 SHA instructions (SHA256H/SHA256SU0/SHA256SU1) |
| **X25519** | Planned | Key exchange (Curve25519 ECDH) |
| **Ed25519/RSA** | Planned | Server certificate authentication |
| **TLS 1.3 handshake** | Planned | RFC 8446 state machine |
| **Certificate parsing** | Planned | X.509 / ASN.1 DER |
| **HTTPS integration** | Planned | TLS record layer between TCP and HTTP |

### Design Decisions

| Item | Rationale |
|------|-----------|
| No Nagle algorithm | HTTP servers disable Nagle anyway |
| No IP options parsing | Deliberately rejected (VER_IHL == 0x45 only) |
| 4-slot reassembly limit | Intentional resource constraint for bare-metal |
| Single-entry ARP cache | We only talk to the gateway |
| NTP 32-bit seconds | Sub-second precision not needed for HTTP timestamps |
| No PMTUD | Target network is direct Ethernet, MTU 1500; DF bit set |
| Shared protocol stack | `lib/` is pure computation — ports to any AArch64 board with zero changes |
| Platform-specific boot/drivers | Each board has its own boot.S, main.S, and drivers under `platform/<name>/` |
| MMU identity map | Virtual = physical, all existing code works unchanged, caches enabled |

## Future: Multi-Board Architecture

The network stack is composed of plain functions that operate on buffers — nothing ties them to a specific role or board. This opens the door to a cluster of bare-metal boards, each with a single narrow responsibility, sharing the same assembly library:

- **Firewall/filter** — inspects packets at the IP level, forwards or drops. No TCP state needed. Defends against DoS by rejecting traffic before it reaches the web server.
- **Load balancer** — parses through TCP, rewrites headers, distributes connections across multiple web server nodes. Needs connection tracking but not HTTP parsing.
- **Web server** — the current project. Handles TLS, TCP, serves HTTPS responses. No persistent storage — reads files from the NAS over the local network.
- **NAS** — serves a fixed set of files over a minimal read-only protocol. No directory paths, no filesystem traversal — files identified by index. Nothing to steal, nothing to overwrite.

Each device runs bare-metal with fixed allocations — no OS, no heap, no dynamic loading. An attacker who compromises one node finds no writable filesystem to persist on, no shell to escalate through, and no heap to corrupt. With TLS termination on the web server node and hardware AES-GCM, encryption adds negligible latency.

The multi-platform build system (`platform/pi/`, `platform/beagleplay/`) means different boards can fill different roles — all running the same tested protocol stack.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
