# Bare-Metal Web Server

<!-- DO NOT MODIFY: This dedication was handwritten by Ed Hodapp. AI must not edit, move, or rephrase it. -->
*This work is dedicated to Jon Lasser - a good friend, good coworker, and very thoughtful soul on this Earth. Jon is a very bright spark in a very dark Universe. He is missed.*

---

A bare-metal web server written entirely in AArch64 assembly through human-AI collaboration. A complete HTTP server — from boot to serving pages — with no OS, no C runtime, and no abstraction layers.

The project targets the Raspberry Pi 4 (BCM2711). The protocol stack in `lib/` is platform-independent; only boot sequences and hardware drivers are Pi-specific.

**Current stage:** Pi 4 hardware bringup complete. The full stack runs on real hardware: UART chainloader, GENET Gigabit Ethernet RX+TX, live PHY speed renegotiation, DSB-barrier ordering guarantees, a hardware-error descriptor drop path, and an in-kernel register/driver-state snapshot for live forensics. A 49-test L2 hardening integration suite drives the Pi from a host laptop (reachability, 256-entry ring wraparound through 1024-frame bursts, link-flap recovery, malformed-frame survival, 100M/1G speed renegotiation, DSB integrity, dump-state consistency) with forensic pcap capture on any failure. Head-to-head on identical hardware, ws_pi5 measured ~1.48x faster per-frame burst-drain cost than the Raspberry Pi OS reference kernel.

## The Experiment

This project started as two questions:

1. Can humans and AI collaborate effectively on real systems programming in assembly?
2. Do implementation-specific tests become net-positive when AI eliminates the maintenance cost?

**The answer to both is yes.** The protocol stack — TCP with 128 connections, WSCALE, SACK, RFC 6298 RTO, multi-segment send — was developed through human-AI collaboration. The suite has grown to 385 assembly unit tests + 141 Python unit tests + 153 functional tests + 49 live-hardware integration tests (plus 39 fuzz seeds), with zero fuzz crashes to date and every bug caught by tests rather than inspection. Implementation-specific tests proved invaluable as a ratchet against AI hallucination, and the maintenance cost (AI regenerates tests in seconds) was negligible compared to the bugs caught.

Assembly is an interesting medium for AI collaboration because it resists the usual pattern of generating boilerplate. Every instruction matters — there's no framework to lean on, no abstraction layer to hide behind. The division of labor falls out naturally:

- **The human** provides architectural direction, testability discipline, and decides what abstractions to form.
- **The AI** handles the combinatorial detail — register allocation, calling conventions, protocol byte layouts, checksum algorithms — and proposes implementations that the human reviews and tests.

TDD at the ISA level keeps both parties honest. The test suite is the shared source of truth: if the tests pass, the implementation is correct regardless of who wrote it. This eliminates the trust problem — you don't have to take the AI's word for anything.

### Implementation-specific tests as an AI constraint

Conventional wisdom says: don't write tests that are tightly coupled to implementation details, because they break during refactors and create maintenance burden. This project deliberately violates that rule.

The reasoning: that conventional wisdom is calibrated to human costs. When a human has to rewrite 10 tests after a structural change, that's real friction. When an AI can regenerate the entire test file in seconds, the maintenance cost drops to near zero — and the value of catching bugs in internal logic dominates.

Implementation-specific tests serve as a ratchet against AI hallucination. A behavioral test says "the callback fired" — the AI could produce a broken scan loop that happens to work for one timer. An implementation-specific test says "slot 0's callback field is zero after cancel" — there's nowhere to hide. Every test that pins internal state narrows the space of wrong-but-compiles outputs the AI could produce.

## What It Does

Boots on a Raspberry Pi 4, brings up Ethernet, and serves HTTP on port 80. The full path:

```
boot.S          Core 0 init, EL2→EL1 drop, MMU + caches, stack, BSS zero
  main.S        uart_init → genet_init (Pi 4 hardware)
                uart_init → dwc2_init → cdc_ecm_init (QEMU raspi3b test harness)
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

Kernel image: 27.2 KB (27,848 bytes). Runtime memory: 32.6 MB (dominated by 128 × 256 KB TCP send buffers).

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
  main.S              uart_init, GENET (Pi 4 hardware) or DWC2 USB → CDC-ECM (QEMU test harness), net_loop, http_poll
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
chainload/          UART chainloader for Pi 4 development
  boot.S              Intel HEX receiver over UART0, PL011 no-FIFO mode
  hex_parse.S         Intel HEX record parser (platform-independent, testable)
  diag.S              Standalone UART diagnostic (error flags, byte counting)
  chainload.ld        Linked at 0x4000000 (above kernel footprint)
tests/              Unit and functional tests
  test_main.S         Test runner (boot, MMU, dispatch, pass/fail reporting)
  test_*.S            Shared protocol stack tests (341 tests including hex_parse)
  pi/                 Pi-specific driver tests (38 tests)
    test_pi_all.S       Aggregates Pi tests via test_platform_drivers symbol
    test_gpio.S         GPIO function select tests (5 tests)
    test_dwc2.S         DWC2 USB host tests
    test_usb_*.S        USB enumeration, descriptor, bulk, failure tests
    test_cdc_ecm*.S     CDC-ECM tests
    test_mailbox.S      VideoCore mailbox tests
    test_boot_main.S    Boot/main integration tests
  func/               PICT-based functional test model
fuzz/               Fuzz harness for network packet parsers
scripts/            Build and test automation
  run_tests.sh        QEMU test runner (configurable QEMU binary)
  run_func_tests.sh   QEMU functional test runner
  tcp_oracle.py       PICT functional test oracle (Python)
  hw_send.py          Host-side Intel HEX sender for chainloader
  intel_hex.py        Intel HEX record generation library
  uart_diag.py        Host driver for UART diagnostic (diag.S)
hw_test/            Hardware test scripts for Pi 4 test fixture
  uart_test/          UART test kernels and PL011 register reference
```

## Building

Requires the AArch64 cross-toolchain and QEMU:

```
sudo apt install gcc-aarch64-linux-gnu qemu-system-arm qemu-user-static
```

For functional tests, build [PICT](https://github.com/microsoft/pict) (Microsoft's pairwise/combinatorial testing tool) from source:

```
sudo apt install cmake
git clone --depth 1 https://github.com/microsoft/pict.git /tmp/pict-build
cd /tmp/pict-build && cmake -DCMAKE_INSTALL_PREFIX=$HOME/.local -B build && cmake --build build -j$(nproc)
cp /tmp/pict-build/build/cli/pict $HOME/.local/bin/
```

### Build Targets

| Target | Build Command | Test Command | Notes |
|--------|---------------|--------------|-------|
| **Pi 4** (QEMU test harness) | `make` | `make test` | Default. Runs the shared protocol-stack tests on QEMU raspi3b (BCM2837 peripheral base at 0x3F000000). Tests the platform-independent `lib/` code without needing real hardware. |
| **Pi 4** (hardware) | `make PLATFORM=pi4` | `make PLATFORM=pi4 && HW_TEST=1 .venv/bin/pytest hw_test/` | Real hardware via chainloader. Pi 4 peripheral base at 0xFE000000, UART0 on GPIO 14/15, GENET native Gigabit Ethernet. |

Test kernels run on QEMU `raspi3b` with MMU enabled (identity-mapped page tables, Normal cacheable RAM, Device-nGnRnE peripherals). All tests pass on QEMU 7.2, 8.2, and 11.0-rc0.

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

A UART chainloader (~1 KB) sits on the SD card at 0x4000000 and receives new kernels over serial using Intel HEX format with per-line checksums and 2-byte ACK/NAK flow control:

```
make PLATFORM=pi4
python3 scripts/hw_send.py kernel8.img /dev/ttyUSB0
```

The chainloader protocol:
1. Host asserts DTR to reset the Pi via CP2102N → GLOBAL_EN
2. Chainloader prints `READY\r\n` when initialized
3. Host sends Intel HEX records with `\r\n` terminators
4. Chainloader verifies each record's checksum, sends 2-byte ACK (line length + checksum) or NAK (line length + checksum XOR 0xFF)
5. On EOF record: ACK, print `BOOT:NNNN\r\n` (record count), jump to kernel at 0x200000

The Intel HEX parser (`hex_parse.S`) is extracted as a testable, platform-independent module with 17 QEMU unit tests. The HEX generation library (`intel_hex.py`) has 34 tests with **100% mutation score** (108/108 mutants killed via mutmut).

**Status:** Transfer of 27 KB kernel completes reliably (1735 records, zero errors, ~12 seconds at 115200 baud). DTR reset (CP2102N → GLOBAL_EN) provides deterministic Pi reboot from the host.

## Testing

### Unit Tests

385 assembly tests run on QEMU `raspi3b`. The shared tests cover every protocol layer from Ethernet through the full TCP connection lifecycle (128 connections, WSCALE, SACK, multi-segment send, RFC 6298 RTO), HTTP request/response handling, Intel HEX parsing, and the GENET RX drop-path bookkeeping. Pi-specific driver tests cover GPIO function select, DWC2 USB host, USB enumeration, CDC-ECM Ethernet, VideoCore mailbox, and boot/main integration.

141 Python unit tests run off-hardware: the Intel HEX library (34 tests, 100% mutation score under mutmut), the `hw_send.py` chainloader host tool (12 tests, covering ioctl DTR toggle and termios line-read deadline shaping), and the L2 hardening framework (95 tests covering `eth_frames`, `link`, and `wire` — the testable pieces of the `hw_test/` integration suite).

The test architecture uses a weak `test_platform_drivers` symbol in the shared test runner. Each platform provides a strong override that calls its platform-specific tests. This lets shared protocol tests run for all platforms without modification.

The test philosophy follows from the project's CLAUDE.md: failure handling code that is never tested is a liability. Functions accept MMIO base addresses as parameters rather than hardcoding constants — this is dependency injection at the ISA level, allowing tests to point hardware register accesses at fake register blocks in RAM.

Branch coverage is audited after each feature: every conditional branch in production code has at least one test exercising both the taken and not-taken paths. Every test branch has an explicit assertion — executing code without checking the result is not testing.

**Mutation testing** with [mutmut](https://github.com/boxed/mutmut) verifies test assertion quality on Python modules. The Intel HEX library achieves 100% mutation score (108/108 mutants killed). Surviving mutants revealed real test gaps in 64K boundary crossing logic that branch coverage alone missed.

The TDD workflow:

1. Write a test in `tests/` — call `test_pass` or `test_fail` with a test name string
2. Register it in the platform's test aggregator (`tests/pi/test_pi_all.S`)
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
- **Kernel load:** `0x200000` (2 MB) — see [firmware 0x80000 conflict](#firmware-0x80000-conflict) below
- **Boot:** EL2 → EL1 drop, MMU setup (4 GB identity map, Normal + Device), caches enabled
- **Ethernet:** GENET v5 Gigabit MAC (native, under development). USB CDC-ECM fallback via DWC2.
- **UART:** PL011 UART0 on GPIO 14/15 — serial debug and chainloader
- **GPIO:** Generic function select driver (`gpio_set_function`) using hardware divide for GPFSEL register/bit computation
- **USB:** DWC2 host at PERIPH_BASE + `0x980000`
- **Mailbox:** VideoCore IPC at PERIPH_BASE + `0x00B880`

#### GPIO Pin Assignments

| Header Pin | GPIO | Function | Notes |
|------------|------|----------|-------|
| Pin 8 | GPIO 14 | **UART0 TX** | Serial debug + chainloader (PL011) |
| Pin 10 | GPIO 15 | **UART0 RX** | Serial debug + chainloader (PL011) |

UART0 is configured by the GPU firmware via `enable_uart=1` and `dtoverlay=disable-bt` in config.txt.

#### Serial Adapter

A 6-pin USB-to-serial adapter with RTS/CTS and DTR is required for full chainloader functionality. Example: [DSD TECH SH-U09B3](https://www.amazon.com/dp/B09KXT6W46) (CP2102N, USB-C, 3.3V TTL).

The extra pins provide:
- **RTS/CTS** — hardware flow control prevents RX overrun during chainloader transfers
- **DTR** — connected to the Pi 4's GLOBAL_EN pin for software-controlled resets (no power cycling)

#### Serial Wiring

```
Pi 4 Pin 8  (GPIO 14 / UART0 TX)  → Adapter RX
Pi 4 Pin 10 (GPIO 15 / UART0 RX)  → Adapter TX
Pi 4 Pin 9  (GND)                  → Adapter GND
Pi 4 GLOBAL_EN                     → Adapter DTR (active-low reset)
```

**Must be 3.3V logic** — a 5V adapter will damage the Pi GPIO. Do not connect the adapter's VCC pin. Hardware flow control (RTS/CTS) is not used — the lock-step ACK protocol provides flow control.

DTR reset from Python (raw ioctl, no pyserial dependency):
```python
import fcntl, struct
TIOCM_DTR, TIOCMBIS, TIOCMBIC = 0x002, 0x5416, 0x5417
bits = struct.pack('I', TIOCM_DTR)
fcntl.ioctl(fd, TIOCMBIS, bits)   # DTR high → GLOBAL_EN LOW → Pi resets
time.sleep(0.1)
fcntl.ioctl(fd, TIOCMBIC, bits)   # DTR low → GLOBAL_EN HIGH → Pi boots
```

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
| **Chainloader** | Production ready | Intel HEX over UART0, 2-byte ACK/NAK, DTR reset, 27 KB in 12s |
| **GENET Ethernet** | Production ready | UMAC reset, RGMII with ID_MODE_DIS skew, PHY auto-negotiation, RX+TX with `ldp/stp` 16-byte vectorized copy loop, live speed renegotiation via periodic PHY poll, DSB-barrier ordering guarantees on both recv and send hot paths, hardware-error descriptor drop path (OV/CRC/RXER/NO/LG), and an in-kernel register/driver-state snapshot for live forensics via the 0x88B6 query protocol. |
| **Pi 4 drivers** | Hardware integration | DWC2 USB, CDC-ECM, GPIO, UART0, mailbox, MMU |
| **L2 hardening framework** | Production ready | `hw_test/` pytest suite: eth_frames, link (netlink up/down + ethtool), wire (tcpdump WireCapture + AF_PACKET RawL2Socket), conftest fixtures (RTT baseline measurement, failure-pcap forensics, session link guard). 95 off-hardware unit tests cover the framework itself; 49 live L2 integration tests (reachability, 256-entry ring wraparound through 1024-frame bursts, link-flap recovery, malformed-frame survival, 100M/1G speed renegotiation, DSB ordering integrity, dump-state consistency, HW RX drop counter) drive the Pi from the laptop. |
| **Perf instrumentation** | Production ready | Opt-in per-stage probe macros (`PERF=recv` / `send` / `dispatch` / `all`) around `genet_recv`, `genet_send`, and `net_recv_one`; 64-byte cache-line `perf_counters` struct; over-the-wire 0x88B6 query protocol for reset/dump/dump-regs; `hw_test/bin/burst_stats.py` per-stage breakdown and `perf_grind.sh` one-command per-commit validation loop. Production builds (no `PERF=`) pay zero overhead — probes compile out. |

**Kernel image:** 27.2 KB (27,848 bytes — text + rodata + data; BSS: 32.6 MB runtime, includes 512 KB GENET RX pool)

**Test coverage:**
- 385 assembly unit tests (QEMU raspi3b) + 153 TCP functional tests (PICT + handcrafted, QEMU) + 141 off-hardware Python unit tests (intel_hex, hw_send, L2 framework) + 49 live L2 integration tests (hw_test/, real Pi 4) + 39 fuzz seeds — **total 767 tests + 39 fuzz seeds**
- All QEMU unit tests pass on QEMU 7.2, 8.2, and 11.0-rc0
- All 49 L2 integration tests pass end-to-end against live Pi 4 hardware (2 additional tests skipped because the laptop's r8152 USB NIC cannot inject FCS errors; not a regression)
- 100% branch coverage on tracked code, every test has explicit assertions
- 100% mutation score on the Intel HEX library (108/108 mutants killed via mutmut)

**Measured performance vs. reference kernel:** Under a 1024-frame wire-rate ARP burst on identical hardware (Pi 4 Model B, 8 GB, same cable, same laptop harness, same 256-entry RX descriptor ring), ws_pi5 drains 1020/1024 frames (~99.6%) while Raspberry Pi OS drains 689/1024 frames (~67%) — a ~1.48x per-frame drain-cost advantage. Full conditions and measurement methodology in `hw_test/perf_history.md`.

### MMU and Caches

The kernel enables the MMU with identity-mapped page tables immediately after BSS zeroing. RAM is mapped as Normal cacheable (write-back, read/write-allocate); peripheral regions are mapped as Device-nGnRnE. This provides:

- **Data cache** — critical for the 32.6 MB TCP connection table and send buffers
- **Instruction cache** — reduces fetch latency for the net_loop hot path
- **Correct alignment semantics** — Normal memory allows unaligned accesses; Device memory requires natural alignment (enforced by QEMU 9+ and real hardware)

## Pi 4 Hardware Bringup Notes

Pi 4 hardware bringup is complete. This section documents the
non-obvious findings from getting the stack running on real
hardware — the chainloader, the firmware 0x80000 conflict, and
the GENET driver.

### UART Chainloader

The chainloader is complete and reliable. Development loop: build → DTR reset → send kernel over UART → boot → observe output. No SD card swaps, no power cycling.

| Item | Status | Notes |
|------|--------|-------|
| **Intel HEX protocol** | Done | Per-line checksums, 2-byte ACK/NAK flow control |
| **Transfer** | Done | 27 KB kernel, 1735 records, zero errors, ~12 seconds at 115200 |
| **DTR reset** | Done | CP2102N DTR → GLOBAL_EN for deterministic Pi reset from host |
| **Host tool** | Done | `hw_send.py` — raw termios, no pyserial dependency |

### Firmware 0x80000 Conflict

The Pi 4 GPU firmware (start4.elf) retains an active agent that references memory at 0x80000 — the default AArch64 kernel load address — after handing control to the ARM cores. Writing to this region during UART operation causes phantom data in the PL011 RX FIFO; writing 27+ KB kills the UART entirely (the VC-managed UART clock stops).

**Findings from hardware debugging:**
- SCTLR_EL1 = 0x00C50838 and SCTLR_EL2 = 0x30C50830 at boot — MMU and caches are OFF at both exception levels. This is not a cache coherency issue.
- Resetting ARM-side DMA channels 0-10 partially mitigates the problem (shifts the failure point) but does not eliminate it. The agent appears to be on the VideoCore side, inaccessible from ARM.
- Writing identical data to 0x200000 instead of 0x80000 works perfectly. The trigger is the address, not the data or the write pattern.
- A 27 KB write to 0x80000 makes the PL011 completely unresponsive — even brute-force writes to DR produce no output. The UART clock (managed by the VC) appears to stop.

**Solution:** Link the kernel at 0x200000 instead of 0x80000. The chainloader writes directly to 0x200000 (no staging or memcpy needed). The firmware's 0x80000 region is never touched.

This is not documented in the BCM2711 datasheet or Raspberry Pi firmware documentation. It was found empirically through binary search of the failure mode.

### GENET Gigabit Ethernet

Native GENET v5 driver for the BCM2711's built-in Gigabit MAC, replacing the USB CDC-ECM path used on the QEMU test harness.

| Item | Status | Notes |
|------|--------|-------|
| **UMAC reset + RGMII** | Done | Reset sequence, ID_MODE_DIS bit for RGMII skew, MAC0/MAC1 programming |
| **PHY auto-negotiation** | Done | Gigabit link established, AUX_STS polled for negotiated speed |
| **RX path** | Done | 256-entry descriptor ring on ring 16; RBUF_ALIGN_2B enabled; vectorized copy loop (ldp/stp 16-byte chunks); DSB-barrier ordering after `dc civac` invalidate before the copy |
| **TX path** | Done | Synchronous send, cache flush via `dc civac` loop + DSB + descriptor publish + PROD_INDEX kick; DSB-barrier ordering between flush and descriptor write |
| **PHY speed renegotiation** | Done | `genet_phy_check` on the `net_loop` idle path reads PHY_AUX_STS and updates `UMAC_CMD` SPEED bits; catches 1G → 100M transitions at runtime |
| **HW error descriptor drop** | Done | Hardware `DMA_RX_FI_MASK` bits (OV, CRC_ERROR, RXER, NO, LG) checked at dequeue; corrupted descriptors are consumed silently, `PERF_DROP_COUNT` is bumped, and the drop path is unit-tested via the `genet_rx_drop_bookkeeping` leaf helper (6 tests covering fresh state, 16-bit CIDX wrap, 8-bit RIDX wrap, perf pointer null, field preservation, and `FI_MASK` coverage) |
| **Register/state forensics** | Done | `perf_query(dump_regs=True)` over the 0x88B6 protocol returns a 64-byte snapshot: `UMAC_CMD`, FIFO status, RDMA/TDMA indices and control, XON/XOFF threshold, and the driver's own software copy of the ring indices. The driver's software state is verified to track the hardware indices exactly. |
| **L2 hardening tests** | 49 passing (2 skipped) | All tests in `hw_test/test_l2_*.py` pass against live hardware: reachability, ring wraparound through `N=1024`, link-flap recovery, malformed-frame survival, speed renegotiation, DSB ordering integrity, and dump-state consistency. The 2 skips are the r8152 USB NIC's inability to inject FCS errors for a negative-path CRC test — a host-side hardware limitation, not a Pi regression. |

The chainload + test cycle is fast enough for tight iteration: `make PLATFORM=pi4 → scripts/hw_send.py → HW_TEST=1 pytest hw_test/` takes about 60 seconds end to end. The L2 hardening framework at `hw_test/` is how every GENET behaviour claim in this README gets verified.

### Design Decisions

| Item | Rationale |
|------|-----------|
| No Nagle algorithm | HTTP servers disable Nagle anyway |
| No IP options parsing | Deliberately rejected (VER_IHL == 0x45 only) |
| 4-slot reassembly limit | Intentional resource constraint for bare-metal |
| Single-entry ARP cache | We only talk to the gateway |
| NTP 32-bit seconds | Sub-second precision not needed for HTTP timestamps |
| No PMTUD | Target network is direct Ethernet, MTU 1500; DF bit set |
| Shared protocol stack | `lib/` is pure computation — portable to any AArch64 board with zero changes |
| Platform-specific boot/drivers | Boot.S, main.S, and drivers live under `platform/pi/` |
| MMU identity map | Virtual = physical, all existing code works unchanged, caches enabled |
| Cache-line alignment directives | Deliberately out of scope — see below |

### Cache-line alignment: considered, rejected

During the L3 hardening cycle we stumbled into an empirical finding
worth recording: on Cortex-A72, the steady-state cost of
`ip_handle` and `icmp_handle` is dominated by L1 instruction-cache
line fetches, not by the raw instruction count of the protocol
logic. Specifically, a 24-byte code shift in `ip_handle` changed
`icmp_handle`'s entry from cache-line offset +28 to offset +60 —
the latter puts the function's first instruction alone at the end
of one 64-byte line with everything else on the next line, and
that mis-alignment cost ~14 ns per call in extra L1→L2 line
fetches. Full measurement in
[`hw_test/perf_history.md`](hw_test/perf_history.md) entry
`2026-04-09`.

The obvious next move is to add `.balign 16` or `.balign 64`
directives in front of every hot protocol handler (`ip_handle`,
`icmp_handle`, `udp_handle`, `tcp_handle`, `arp_handle`) so their
entry addresses are deterministically cache-friendly regardless
of what changes upstream in the file. That would trade up to ~60
bytes of padding per handler for a 1–3% steady-state per-frame
improvement on bare metal.

**We deliberately did not take that step in ws_pi5.** This is the
BSD-licensed reference implementation — the code you fork, study,
and re-use. Micro-architectural tuning (cache-line alignment,
branch predictor layout hints, loop-buffer sizing, manual
instruction scheduling) belongs in the *derivatives* that use
ws_pi5 as a foundation and are free to optimize for a specific
hardware target. Keeping the reference clean of that kind of
tuning makes it easier to review, easier to port to new aarch64
platforms, and easier to demonstrate the protocol logic without
layout noise.

**If you fork ws_pi5 to target specific bare-metal hardware**,
alignment directives are a legitimate free-lunch optimization
and you should add them after measuring. The technique is:
put a `PROBE_L3_ENTRY`/`EXIT` pair around the function you're
tuning, add the alignment, measure with
`hw_test/bin/burst_stats.py --icmp-burst`, and keep only the
changes whose deltas survive 10 trials at sub-1% stdev.

**If you fork ws_pi5 to target a virtualized host** (a microVM,
nested hypervisor, or any guest running on top of another OS),
alignment still works mechanically — the host cache honors the
guest's alignment within a page — but the per-frame cost in
those environments is dominated by hypercall / vmexit overhead
(hundreds to thousands of ns each) rather than L1 cache traffic.
The alignment win would be ~1% against a ~1 µs hypercall floor
versus ~3% against a ~550 ns bare-metal floor. Probably not
worth the readability cost in that environment; measure before
adopting.

## Future: Multi-Board Architecture

The network stack is composed of plain functions that operate on buffers — nothing ties them to a specific role or board. This opens the door to a cluster of bare-metal boards, each with a single narrow responsibility, sharing the same assembly library:

- **Firewall/filter** — inspects packets at the IP level, forwards or drops. No TCP state needed. Defends against DoS by rejecting traffic before it reaches the web server.
- **Load balancer** — parses through TCP, rewrites headers, distributes connections across multiple web server nodes. Needs connection tracking but not HTTP parsing.
- **Web server** — the current project. Handles TCP, serves HTTP responses. No persistent storage — reads files from the NAS over the local network.
- **NAS** — serves a fixed set of files over a minimal read-only protocol. No directory paths, no filesystem traversal — files identified by index. Nothing to steal, nothing to overwrite.

Each device runs bare-metal with fixed allocations — no OS, no heap, no dynamic loading. An attacker who compromises one node finds no writable filesystem to persist on, no shell to escalate through, and no heap to corrupt.

The protocol stack is board-independent — different boards can fill different roles, all running the same tested library code.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
