# Bare-Metal Web Server

<!-- DO NOT MODIFY: This dedication was handwritten by Ed Hodapp. AI must not edit, move, or rephrase it. -->
*This work is dedicated to Jon Lasser - a good friend, good coworker, and very thoughtful soul on this Earth. Jon is a very bright spark in a very dark Universe. He is missed.*

---

## Installation

Two paths, pick the one that matches what you want to do.

### Deploy a site (no compiler needed)

Enough to package a static site into a bootable kernel image and
flash it to an SD card. You never touch the AArch64 toolchain.

Debian / Ubuntu:

```
sudo apt install python3 mtools
```

macOS (Homebrew):

```
brew install python@3.12 mtools
```

Then follow [Deploy Your Site](#deploy-your-site) below — that's the
complete workflow end-to-end, starting from `wget` of a prebuilt
kernel.

### Build from source (developer setup)

Adds the AArch64 cross-assembler + QEMU for running the QEMU test
suite, plus `pict` for the functional-test oracle. After these
prereqs are in place, see [Building](#building) below for the full
developer workflow (build, package, ship, UART iteration).

Debian / Ubuntu:

```
sudo apt install \
    binutils-aarch64-linux-gnu \
    qemu-system-arm qemu-user-static \
    mtools \
    python3 python3-venv \
    cmake
```

macOS (Homebrew):

```
brew install aarch64-elf-binutils qemu mtools python@3.12 cmake
```

PICT (Microsoft's combinatorial test-vector generator — same on both
platforms):

```
git clone --depth 1 https://github.com/microsoft/pict.git /tmp/pict-build
cmake -S /tmp/pict-build -B /tmp/pict-build/build -DCMAKE_INSTALL_PREFIX=$HOME/.local
cmake --build /tmp/pict-build/build -j
cp /tmp/pict-build/build/cli/pict $HOME/.local/bin/
```

Python dev dependencies (for the hardware-test framework, branch
coverage analyzer, and in-repo quality gates):

```
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Build + run the QEMU unit tests as a smoke check:

```
make test
```

### Capacity: how big can your site be?

> Reference shared by both install paths. The no-compiler path gets
> the one-size-fits-all 256 MiB prebuilt by default — read this if
> you want to know what's actually in there, or skip ahead. The
> build-from-source path uses [Size the kernel to your
> site](#size-the-kernel-to-your-site) to pick a smaller slab.

Static content is baked into the kernel image at package time — the
packager copies files into a reserved region of `.data`, and the
running kernel serves them from RAM. The reserved region is sized at
**compile time**.

The default build (`make PLATFORM=pi4` with no `CONTENT_MAX`
override) produces a kernel image of exactly **256 MiB** (clean power
of two): a 1 MiB code-and-globals reserve at the front followed by a
255 MiB appliance slab. The linker `ASSERT`s this size invariant
loudly — code/globals growing past the 1 MiB reserve, or the slab
shrinking away from 255 MiB, fails the link.

| Constant | Default | What it caps |
|---|---|---|
| `APPLIANCE_CONTENT_MAX` | `255 MiB − header/routes ≈ 254.98 MiB` (compile-time default for the locked 256 MiB image; overridable with `make CONTENT_MAX=<bytes>`) | total bytes across all packaged files (paths + headers + bodies) |
| `APPLIANCE_MAX_ROUTES` | `512` (overridable with `make MAX_ROUTES=<n>`) | number of files (one route per file, plus a `/` alias for top-level `index.html`) |

When `CONTENT_MAX` is overridden, the SIZE_LOCK is dropped and the
slab packs immediately after `.data` for a compact image — used by
the `appliance` Makefile target (64 KiB slab → ~150 KiB kernel) so
UART chainloader iteration stays fast.

**Maximum available content region on a 1 GB Pi 4** — bigger Pis have
proportionally more headroom:

| Content ceiling | Kernel image size | Fits on |
|---|---|---|
| 1 MiB | ~1 MiB | 128 MB SD and up |
| 16 MiB | ~16 MiB | 128 MB SD and up |
| 64 MiB | ~64 MiB | 128 MB SD and up |
| 255 MiB (default, SIZE_LOCKED) | exactly 256 MiB | 512 MB SD and up |
| >512 MiB | uncomfortable on 1 GB Pi | use a 2 GB+ model |

The runtime reserves ~33 MiB of fixed buffers (128 TCP connections ×
256 KiB send buffer each is the dominant share). What's left of the
1 GB is shared between the kernel image (which holds the baked-in
content) and the 64 KiB stack. Bigger sites also take longer to load
off SD at boot — figure ~20–50 MiB/s on a Class 10 card.

#### Size the kernel to your site

The cleanest path is `scripts/mk_sd.sh --build`, which measures the
site, rebuilds the kernel with a matching `CONTENT_MAX`, packages the
content, and writes a raw SD image — one command, one shot:

```
scripts/mk_sd.sh --build path/to/your/site/ pi4_sd.img
```

If you'd rather drive the steps manually:

```
SITE_BYTES=$(du -sb public/ | cut -f1)
# round up, add ~25 % slack for HTTP header overhead
CONTENT_MAX=$(( (SITE_BYTES * 5 / 4 + 1048575) / 1048576 * 1048576 ))
make clean && make PLATFORM=pi4 CONTENT_MAX=$CONTENT_MAX
scripts/mk_appliance.py --content-max $CONTENT_MAX kernel8.img public/ out.img
```

The kernel always links at 0x80000 (the firmware default kernel
load address). The same binary serves both SD-direct boot and the
UART chainloader path — see the chainloader self-relocation note
under [Pi 4 Development Workflow](#pi-4-development-workflow).

The `CONTENT_MAX` value must match on both sides. An `HDR_KSIZE` field
is baked into the kernel's placeholder slab at compile time; the
packager reads it and aborts loudly on mismatch — so a typo or
forgotten flag fails clearly instead of over-writing past the
placeholder into adjacent kernel code.

#### Why `kernel8.img` is so big by default

The prebuilt kernel from the Releases page is a one-size-fits-all
image with the full 256 MiB content region reserved — ~268 MB total.
Nearly all of that is the reserved slab. The executable web server
itself — `.text` + `.rodata` + non-slab `.data` — is well under
**60 KB**. Rebuild locally with a smaller `CONTENT_MAX` to get a
kernel sized to your actual site.

---

A bare-metal web server written entirely in AArch64 assembly through human-AI collaboration. A complete HTTP server — from boot to serving pages — with no OS, no C runtime, and no abstraction layers.

The project targets the Raspberry Pi 4 (BCM2711). The protocol stack in `lib/` is platform-independent; only boot sequences and hardware drivers are Pi-specific.

**Current stage:** Complete HTTP/1.1 web server appliance running on real Pi 4 hardware. Measured throughput on 2026-04-24: 25,050 req/s at 10 connections, 44,803 req/s at 50, 40,275 req/s at 100 (wrk, 10-second runs — raw output in `hw_test/perf_history.md`). Features: FSA-driven request parser; VMIO-driven response-side FSA (4 states × 8 events, per-way state, per-(way,event) gating — see `lib/http_output_fsa.S` and the spec in `tests/func/http_output_fsa.pict`); data-driven route table with dynamic `/status` and `/fsa_stats` endpoints over chunked transfer encoding; packager (`scripts/mk_appliance.py`) that bakes a user's static site directly into a bootable kernel image; RFC 5322 Date header from NTP time; Slowloris protection; first-byte input guard (rejects TLS ClientHello and other non-HTTP traffic at the http_poll edge before any parser state is reached); exception vectors for fault diagnosis. The full network stack — from GENET Gigabit Ethernet through TCP (all 8 RFC compliance defects closed, dual Claude+Gemini audit) to HTTP — is written in AArch64 assembly with 482 unit tests on QEMU.

## The Experiment

This project started as two questions:

1. Can humans and AI collaborate effectively on real systems programming in assembly?
2. Do implementation-specific tests become net-positive when AI eliminates the maintenance cost?

**The answer to both is yes.** The protocol stack — TCP with 128 connections, WSCALE, SACK, RFC 6298 RTO, multi-segment send, congestion control with fast recovery — was developed through human-AI collaboration. The suite has grown to 482 assembly unit tests + 141 Python unit tests + 153 functional tests + 56 live-hardware integration tests (plus 39 fuzz seeds), with zero fuzz crashes to date and every bug caught by tests rather than inspection. Implementation-specific tests proved invaluable as a ratchet against AI hallucination, and the maintenance cost (AI regenerates tests in seconds) was negligible compared to the bugs caught.

Assembly is an interesting medium for AI collaboration because it resists the usual pattern of generating boilerplate. Every instruction matters — there's no framework to lean on, no abstraction layer to hide behind. The division of labor falls out naturally:

- **The human** provides architectural direction, testability discipline, and decides what abstractions to form.
- **The AI** handles the combinatorial detail — register allocation, calling conventions, protocol byte layouts, checksum algorithms — and proposes implementations that the human reviews and tests.

TDD at the ISA level keeps both parties honest. The test suite is the shared source of truth: if the tests pass, the implementation is correct regardless of who wrote it. This eliminates the trust problem — you don't have to take the AI's word for anything.

### Implementation-specific tests as an AI constraint

Conventional wisdom says: don't write tests that are tightly coupled to implementation details, because they break during refactors and create maintenance burden. This project deliberately violates that rule.

The reasoning: that conventional wisdom is calibrated to human costs. When a human has to rewrite 10 tests after a structural change, that's real friction. When an AI can regenerate the entire test file in seconds, the maintenance cost drops to near zero — and the value of catching bugs in internal logic dominates.

Implementation-specific tests serve as a ratchet against AI hallucination. A behavioral test says "the callback fired" — the AI could produce a broken scan loop that happens to work for one timer. An implementation-specific test says "slot 0's callback field is zero after cancel" — there's nowhere to hide. Every test that pins internal state narrows the space of wrong-but-compiles outputs the AI could produce.

### A data point: DHCP client, first-boot success

The DHCP client (D017 — RFC 2131 client subset, table-driven 11-state FSA in `lib/dhcp_fsa.S`, builders/parser in `lib/dhcp.S`, 54-cell transition table cross-checked against the ELF by `scripts/verify_dhcp_fsa_table.py`) was developed entirely under the process described above: TSV transition table → PICT model → unit tests → assembly implementation → independent Gemini and clean-Claude reviews → QEMU green → flash. It worked on the first boot against a real `dnsmasq` server: DISCOVER → OFFER → REQUEST → ACK → lease commit → mDNS announce on the assigned address, with HTTP serving on the new IP. No serial-console debugging cycle, no panic-LED diagnosis, no incremental fixes.

This is not a claim that the AI produced perfect code in isolation — the process did. The transition-table-first design forced the receive-path validators to be enumerated before any handler was written; the PICT model surfaced edge combinations that drove specific test cases; the dual-review step caught register-clobber bugs (a caller-saved register held across `blr`) and a 32-bit multiplication that would have wrapped at large lease values, both before they shipped. The result was an end-to-end protocol implementation that lit up correctly on first contact with real hardware.

A skilled human engineer could have achieved the same correctness, given enough time. What changed is the cycle time: the kind of methodical, table-driven, exhaustively-reviewed work that used to be reserved for safety-critical code is now within reach for routine protocol features.

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

Kernel image: 37.4 KB (38,264 bytes, including exception vector table and HTTP response templates). Runtime memory: ~32.6 MB (dominated by 128 × 256 KB TCP send buffers).

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
  http.S              HTTP/1.1 server — input-side FSA parser, route dispatch, keep-alive
  http_output_fsa.S   VMIO-driven send path — 4-state × 8-event FSA, per-way state,
                        per-(way,event) gating; /fsa_stats exposes engine counters
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
  boot.S              Entry point — EL2→EL1 drop, MMU setup, exception vectors, park cores 1-3
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
  test_*.S            Shared protocol stack tests (~376 tests including hex_parse)
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

## Deploy Your Site

Four-step flow for putting your own static site on a Pi 4 with no
AArch64 cross-toolchain. (If you'd rather build from source, see
[Building](#building) below — that section is the full developer
workflow end-to-end.)

### 1. Download the prebuilt kernel

Clone the repo for the helper scripts, then grab `kernel8.img` from
the [Releases page](https://github.com/edhodapp/ws_pi5/releases):

```
git clone https://github.com/edhodapp/ws_pi5.git
cd ws_pi5
wget -O kernel8.img https://github.com/edhodapp/ws_pi5/releases/latest/download/kernel8.img
```

The prebuilt is one-size-fits-all with the full 256 MiB content
slab reserved (~268 MB total), so the resulting SD image is ~265 MiB.
That fits on any modern SD card. (For a kernel sized to your site
instead, see [Building](#building).)

### 2. Package your site into the kernel

Drop your static files into a directory (HTML, CSS, images — see
`examples/public/` for a starter layout), then run the packager:

```
scripts/mk_appliance.py kernel8.img path/to/your/site/ appliance.img
```

Output: `appliance.img` — same format as the input kernel, but with
your files baked in as served routes. The packager shows what each
file got mapped to (`/index.html` is also aliased to `/`).

### 3. Write an SD image and boot

Build a flashable SD image:

```
sudo apt install mtools   # Debian/Ubuntu; brew install mtools on macOS
scripts/mk_sd.sh --image appliance.img pi4_sd.img
```

Flash `pi4_sd.img` to an SD card with **Raspberry Pi Imager** (choose
"Use custom"), **balenaEtcher**, or `dd`.

### 4. Edit `network.conf` for your network

Before booting, edit `network.conf` on the SD card's FAT boot
partition. Mount the SD card on your laptop (Imager and Etcher
re-eject it after flashing — re-insert), open the boot partition,
and pick a network mode:

- **Static IP** — set `ip`, `netmask`, `gateway`, and `hostname`. The
  shipped defaults fail by design (gateway `0.0.0.0` won't ARP) so
  the Pi halts with [panic pattern G](docs/PANIC_PATTERNS.md) until
  you customize.
- **DHCP** — set `dhcp=yes` and `hostname`; the lease supplies the
  rest. Useful on a typical home router. On DHCP failure the kernel
  halts with [panic pattern D](docs/PANIC_PATTERNS.md) so a
  misconfigured rig is loud, not silent.

See the [`network.conf` reference](#networkconf-reference) below for
each field's format and the optional keys (`ntp_server`, `mac`).
`scripts/mk_sd.sh` lint-validated whatever it shipped, so a malformed
default would have failed the build before you got here — but if you
edit by hand on the SD, you're outside that gate; double-check
syntax against the reference if the Pi halts with
[panic pattern N](docs/PANIC_PATTERNS.md).

Insert the SD into the Pi 4, power on, and the appliance is live on
`http://<hostname>.local/` once mDNS comes up (D006). The `<pi-ip>` you
configured in `network.conf` also works.

> If you'd rather drop files onto a pre-formatted FAT32 card by hand
> (no `mtools` dependency), run `scripts/mk_sd.sh appliance.img
> sd_boot/` for the directory form and `cp -r sd_boot/* /media/.../boot/`.
> Edit `network.conf` in `sd_boot/` before the copy.

## `network.conf` reference

`network.conf` lives at the FAT root of the SD card and configures
the Pi's network identity. Format and validation rules are normative
in [`docs/DECISIONS.md`](docs/DECISIONS.md) (D003 / D006 / D012);
this section is the user-facing summary.

The first non-empty line MUST be the magic sentinel:

```
# WSPI5CFG
```

A file without this line is rejected (the linter at build time, the
asm parser at boot — both produce [panic pattern N](docs/PANIC_PATTERNS.md)
on mismatch).

### Keys

| Key | Required? | Type | Notes |
|---|---|---|---|
| `dhcp` | no | `yes` / `no` (default `no`) | When `yes`, `ip`/`netmask`/`gateway` become **optional** — DHCP supplies them on boot. On DHCP failure (3 retries, no OFFER or no ACK) the kernel halts with [panic pattern D](docs/PANIC_PATTERNS.md) per D017 |
| `ip` | yes (static), no (DHCP) | dotted-decimal IPv4 | This Pi's static address |
| `netmask` | yes (static), no (DHCP) | dotted-decimal IPv4 | Recorded for documentation; the runtime uses always-via-gateway routing per D010 and ignores the value |
| `gateway` | yes (static), no (DHCP) | dotted-decimal IPv4 | Default gateway; ARPed at boot, [panic pattern G](docs/PANIC_PATTERNS.md) on timeout |
| `hostname` | yes | RFC 1123 LDH, 1–63 chars | Reachable as `<hostname>.local` via mDNS. Also sent as DHCP option 12 in DHCP mode so the lease record carries the name |
| `ntp_server` | no | dotted-decimal IPv4 | NTP source; omit to skip NTP |
| `mac` | no | six colon-separated hex bytes | Override the factory MAC; omit to use Pi 4 OTP fuses (mailbox tag `0x00010003`). If the mailbox call fails AND no `mac=` override is given, the kernel halts with [panic pattern M](docs/PANIC_PATTERNS.md) per D011 |

### Syntax rules

- `key=value` per line. Whitespace around `=` is allowed and stripped.
- `#` starts a comment. Whitespace must precede `#` for it to be
  treated as an inline comment (so `hostname=my#name` is a
  syntactically invalid hostname rather than silently truncated to
  `my`); a `#` at the start of a line is always a comment.
- Blank lines are ignored.
- Values are validated by key:
  - IPv4 octets must be plain decimal `0–255`. Leading-zero octets
    like `010` are rejected (different stacks interpret them
    inconsistently).
  - Hostnames are LDH (letters, digits, hyphens) per RFC 1123; first
    AND last character must be a letter or digit.
  - MAC bytes are case-insensitive 2-digit hex (`de:ad:be:ef:ca:fe`
    and `DE:AD:BE:EF:CA:FE` both work).

### Example — static IP

```
# WSPI5CFG
# My home network appliance.

ip=192.168.1.50
netmask=255.255.255.0
gateway=192.168.1.1
hostname=hodapp-www

# Optional: pin a specific NTP server.
ntp_server=216.239.35.0
```

### Example — DHCP

For appliances that should follow the router's lease pool — drop in,
power on, get an IP. The kernel handles RENEW (T1), REBIND (T2),
DHCPNAK rebinds (e.g. router scope changes), and re-announces over
mDNS when the IP moves so `<hostname>.local` keeps resolving.

```
# WSPI5CFG
dhcp=yes
hostname=hodapp-www

# Optional, same as static-IP mode.
ntp_server=216.239.35.0
```

### When the lint catches you

The linter at `scripts/lint_network_conf.py` runs at SD-build time
and fires a clear diagnostic if `network.conf` is malformed. Run it
manually to debug a hand-edited file:

```
.venv/bin/python scripts/lint_network_conf.py /path/to/network.conf
```

Exit codes: `0` valid, `1` invalid (per-error diagnostics on stderr),
`2` IO error.

## Building

Full developer workflow end-to-end: build the kernel, package a
site, ship it. Prereqs (cross-toolchain, QEMU, PICT, Python venv)
are covered above in [Build from
source](#build-from-source-developer-setup).

### 1. Build the kernel

For real hardware:

```
make PLATFORM=pi4
```

Produces `kernel8.img` — by default the 256 MiB SIZE_LOCKED layout
(1 MiB code reserve + 255 MiB appliance slab). To size the slab to
your actual site instead, see [Size the kernel to your
site](#size-the-kernel-to-your-site).

For QEMU smoke tests:

```
make           # raspi3b, BCM2837 peripheral base; tests platform-independent lib/
make test      # unit tests on QEMU
```

The kernel always links at the firmware default address (0x80000).
The same image works for SD-direct boot and the UART chainloader
path; the chainloader self-relocates from 0x80000 to 0x4000000 at
startup so it can receive a fresh kernel into 0x80000 without
overwriting itself.

### 2. Package your site

Same packager as the no-compiler path:

```
scripts/mk_appliance.py kernel8.img path/to/your/site/ appliance.img
```

### 3. Write an SD image, edit `network.conf`, boot

Identical to the no-compiler path — the SD imaging, `network.conf`
edit, and flash steps don't change just because the kernel came
out of `make` instead of `wget`. See [Write an SD image and
boot](#3-write-an-sd-image-and-boot) and [Edit
`network.conf`](#4-edit-networkconf-for-your-network) in [Deploy
Your Site](#deploy-your-site) above.

For dev iteration you can skip the SD entirely and push a kernel
over UART — see the chainloader workflow below.

### Build targets

| Target | Build Command | Test Command | Notes |
|--------|---------------|--------------|-------|
| **Pi 4** (QEMU test harness) | `make` | `make test` | Default. Runs the shared protocol-stack tests on QEMU raspi3b (BCM2837 peripheral base at 0x3F000000). Tests the platform-independent `lib/` code without needing real hardware. |
| **Pi 4** (hardware) | `make PLATFORM=pi4` | `make PLATFORM=pi4 && HW_TEST=1 .venv/bin/pytest hw_test/` | Real hardware. Pi 4 peripheral base at 0xFE000000, UART0 on GPIO 14/15, GENET native Gigabit Ethernet. Development flashing via UART chainloader; production via SD-card boot (`scripts/mk_sd.sh`). |
| Functional tests | — | `make test-functional` | PICT-driven combinatorial tests. |
| UART chainloader | `make chainload` | — | Dev-only — see [Pi 4 Development Workflow](#pi-4-development-workflow). |
| Clean | `make clean` | — | |

Test kernels run on QEMU `raspi3b` with MMU enabled (identity-mapped
page tables, Normal cacheable RAM, Device-nGnRnE peripherals). All
tests pass on QEMU 7.2, 8.2, and 11.0-rc0.

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
5. On EOF record: ACK, print `BOOT:NNNN\r\n` (record count), jump to kernel at 0x80000

The chainloader and SD-direct boot use the **same kernel binary**
linked at 0x80000. The chainloader image itself is linked at
0x4000000 but loaded by firmware at 0x80000; on entry it copies
itself to 0x4000000 and jumps there, freeing 0x80000 to receive the
incoming kernel. `make PLATFORM=pi4` produces the kernel; `make
chainload` produces the chainloader image (`chainload.img`) used
by `scripts/mk_sd.sh --chainload`.

For dual-config testing (one chainloader SD, multiple network configs)
`hw_send.py --network-conf <path>` prepends the config bytes as Intel
HEX records targeting `0x20000000` so the kernel reads the
UART-pushed config instead of the SD's. `scripts/dual_config_tests.sh`
drives the full pre-push gate twice — once with `network-static.conf`,
once with `network-dhcp.conf` — without rebuilding or reflashing the
SD between passes.

The Intel HEX parser (`hex_parse.S`) is extracted as a testable, platform-independent module with 17 QEMU unit tests. The HEX generation library (`intel_hex.py`) has 34 tests with **100% mutation score** (108/108 mutants killed via mutmut).

**Status:** Transfer of 27 KB kernel completes reliably (1735 records, zero errors, ~12 seconds at 115200 baud). DTR reset (CP2102N → GLOBAL_EN) provides deterministic Pi reboot from the host.

## Testing

The complete test inventory — every QEMU unit test, hardware
integration test, fuzz harness, and FSA-vector model — lives in
[`docs/TEST_PLAN.md`](docs/TEST_PLAN.md), top-down from the
multi-day burn-in down to per-protocol assembly tests. The bucket
discipline (A: local lints + Python unit; B: QEMU; C: hardware Pi 4)
and the perf-gating policy live in [`TESTING.md`](TESTING.md). When
someone says "the full test suite," it means **A + B + C**, in
that order, run by `scripts/pre_push_tests.sh` on every push.

Headline numbers (point-in-time; `docs/TEST_PLAN.md` is the
authoritative source):

- ~480 assembly unit tests on QEMU `raspi3b` covering every
  protocol layer (Ethernet through HTTP/1.1) plus FSA-table
  cross-checks pinned to the compiled ELF by `make
  verify-fsa-table` and `make verify-dhcp-fsa-table`.
- ~180 hardware integration tests across L2/L3/L4/L5 layered
  pytest selections, gated by per-layer reflashes.
- 141 Python unit tests for the host-side tooling (Intel HEX
  builder at 100 % mutation score under mutmut, `hw_send.py`,
  `link`, `wire`, frame builders).
- Coverage-guided fuzz harnesses for the protocol parsers
  (`make fuzz`, `make fuzz-seq`) with 23 single-packet and 16
  multi-packet TCP seeds.
- A dual-reviewer RFC compliance audit (Claude + independent
  Gemini review) closed all 8 TCP defects across RFC 9293, 7323,
  5681, and 5961 — see [`docs/l4_rfc1122_compliance.md`](docs/l4_rfc1122_compliance.md).

Test philosophy (excerpted from `CLAUDE.md`): failure-handling code
that's never tested is a liability; every conditional branch has
both-side coverage; every test branch has an explicit assertion —
running code without checking a result is not a test. Functions
accept MMIO base addresses as parameters rather than hardcoding
constants, enabling dependency injection at the ISA level so tests
can point hardware register accesses at fake register blocks in RAM.

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
- Fast recovery: cwnd inflation on dup ACKs beyond 3rd, deflation on new ACK (RFC 5681 §3.2)
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
- RST SEQ validation (RFC 5961): exact-match required; in-window non-exact sends Challenge ACK
- RST rate limiting: token-bucket at 10/sec burst
- ICMP soft errors for ESTABLISHED+ (RFC 5461): only hard-close SYN_RCVD
- Idle connection reaper: per-state timeouts (SYN_RCVD 60s, ESTABLISHED 120s, FIN states 60s)
- State rollback on handler failure (prevents state corruption from invalid segments)
- Persist timer: zero-window probing with exponential backoff (5s–60s)
- DF bit set on all outgoing IP packets
- RST generation for invalid packets, unknown ports, and unpopulated FSA entries

## Platform Details

### Raspberry Pi 4 (BCM2711)

- **SoC:** BCM2711, Cortex-A72 quad-core, 8 GB RAM
- **Kernel load:** `0x80000` (firmware default) for both SD-direct boot and the UART chainloader path. The chainloader image itself is linked at `0x4000000` and self-relocates from `0x80000` to that address on entry (see commit `7e3e774`); a single kernel binary serves both paths. See [debug_log_0x80000.md](debug_log_0x80000.md) for the 2026-04-26 SD-direct verification that preceded the unification.
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
| **HTTP** | Production ready | FSA parser, data-driven route table, VMIO-driven output FSA, keep-alive, chunked encoding, first-byte guard against non-HTTP traffic (TLS / scanners), packager for static sites |
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

### Firmware 0x80000 Conflict (chainloader-only)

The Pi 4 GPU firmware (start4.elf) retains an active agent that
references memory at 0x80000 *during the chainloader's UART transfer
phase*. ARM-side writes to that region while the chainloader is
running (HEX records being received) corrupt the PL011 RX FIFO;
sustained writes kill the UART entirely (the VC-managed UART clock
stops). This was discovered empirically in 2026-04 and not
documented anywhere in BCM2711 docs.

**Original workaround (superseded):** an earlier commit landed the
chainloader and dev-time kernel at 0x200000 to keep ARM writes off
0x80000 during UART transfer. That worked but split the build into
two binaries and two link addresses.

**Current solution (commit `7e3e774`):** both paths use 0x80000 —
the firmware default. The firmware's own load of `kernel8.img` at
0x80000 works correctly because the agent isn't active during
firmware-side load (the CPU is held off until hand-off). The
chainloader image is also loaded by firmware at 0x80000, but on
entry it copies itself to 0x4000000 and jumps there *before* doing
any UART work — so during HEX-record reception the chainloader is
running at 0x4000000 and 0x80000 is quiet, which inherits the same
firmware-quiescence guarantee that SD-direct already had. One kernel
binary, one link address; no `SHIP=1` flag, no per-build choice.
End-to-end verification of the SD-direct path at 2026-04-26 in
[debug_log_0x80000.md](debug_log_0x80000.md) preceded the
unification.

**Findings from the chainloader-side hardware debugging:**
- SCTLR_EL1 = 0x00C50838 and SCTLR_EL2 = 0x30C50830 at boot — MMU and caches are OFF at both exception levels. This is not a cache coherency issue.
- Resetting ARM-side DMA channels 0-10 partially mitigates the problem (shifts the failure point) but does not eliminate it. The agent appears to be on the VideoCore side, inaccessible from ARM.
- Writing identical data to 0x200000 instead of 0x80000 works perfectly. The trigger is the address, not the data or the write pattern.
- A 27 KB write to 0x80000 (during chainloader UART transfer) makes the PL011 completely unresponsive — even brute-force writes to DR produce no output. The UART clock (managed by the VC) appears to stop.

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
| Martian source filter — partial | Three checks (zero, 127/8, self); remaining RFC 6890 ranges deliberately omitted — see below |
| 4-slot reassembly limit | Intentional resource constraint for bare-metal |
| Reassembly ceiling = 1480 B, not 2048 | In-place rebuild into the 1514 B frame buffer — see below |
| Single-entry ARP cache | We only talk to the gateway |
| NTP 32-bit seconds | Sub-second precision not needed for HTTP timestamps |
| No PMTUD | Target network is direct Ethernet, MTU 1500; DF bit set |
| Shared protocol stack | `lib/` is pure computation — portable to any AArch64 board with zero changes |
| Platform-specific boot/drivers | Boot.S, main.S, and drivers live under `platform/pi/` |
| MMU identity map | Virtual = physical, all existing code works unchanged, caches enabled |
| Cache-line alignment directives | Deliberately out of scope — see below |

### IP reassembly ceiling: 1480 bytes, not REASM_BUF_SIZE

`include/net.inc` defines `REASM_BUF_SIZE = 2048`. That number is
misleading on its own — the **effective** reassembly ceiling is
**1480 bytes** of reassembled IP total_length. Any fragmented
datagram larger than that is silently dropped by
`ip_reasm_input` at the completion check (RFC-compliant: hosts
may cap their reassembly buffer).

Two independent constraints produced the gap:

1. **The bitmap geometry drove `REASM_BUF_SIZE`.** IPv4's
   fragment-offset field is in 8-byte units, so the receiver
   tracks filled units with a bitmap. The bitmap is 32 bytes
   (256 bits), sized so `ip_reasm_init` can zero it in exactly
   two `stp xzr, xzr` instructions. 256 bits × 8 bytes/bit =
   2048 bytes of addressable slot-buffer capacity. `2048` fell
   out of that choice; nobody sat down and said "we want to
   reassemble up to 2 KB." It was a derived number.

2. **The in-place rebuild enforces the 1480 B ceiling.** The
   engine reassembles *in place* in the same 1514-byte
   Ethernet frame buffer the last fragment arrived in, then
   dispatches the reassembled frame to the protocol handler
   just like any other incoming frame. `icmp_handle`,
   `udp_handle`, and `tcp_handle` all assume they own a
   single 1514-byte frame — none of them know how to receive
   an oversized reassembled datagram. So `ip_reasm_input`'s
   completion check enforces
   `total_length + 34 ≤ ETH_FRAME_MAX`, i.e. `total_length ≤ 1480`.

The consequence is ~568 bytes per slot × 4 slots ≈ 2.3 KB of
BSS that's *addressable* through the bitmap but *never usable*
through the completion check. At a ~32 MB runtime memory
budget, that's negligible, so we leave the over-provisioning
in place rather than try to shrink the bitmap (which doesn't
have a clean smaller size — 16 bytes is too tight, 24 bytes
doesn't zero cleanly in stp pairs) or rewrite the protocol
handlers to accept a separate reassembly output buffer (a
bigger refactor, out of scope for the L3 hardening cycle).

The inconsistency is worth knowing about because the L3
hardening plan I wrote against `REASM_BUF_SIZE = 2048`
proposed 2×1024-byte fragment test cases that would have
silently dropped at the completion check — which is what drove
me to shrink the fragment test matrix to 2×736 / 3×480 / 8×168
in the final `test_l3_frag.py`. The fix also lives as a
multi-page DESIGN NOTE at the top of the reassembly constant
block in `include/net.inc` so future work can't be surprised
by it the way the L3 cycle was.

### Martian source filter: partial coverage by design

`lib/ip.S::ip_handle` filters three classes of "never valid on
the wire" source IP addresses:

| Check | What it catches |
|---|---|
| `src == 0.0.0.0` | Zero-source spoofing (DHCP DISCOVER is the only legitimate zero-source; ws_pi5 doesn't do DHCP) |
| `src in 127.0.0.0/8` | Loopback (first-octet mask, covers the full /8 — verified by unit tests at both 127.0.0.1 and 127.255.255.254) |
| `src == net_our_ip` | Self-spoof (forged frame claiming to be from us) |

These three cover the **most common attack vectors** for a
single-host direct-cable deployment: zero-source SYN floods,
loopback spoofing, and self-spoof reflection.

**Deliberately not filtered** (scope decision, not oversight):

| Range | Why omitted |
|---|---|
| `0.0.0.0/8` (beyond `.0.0.0`) | Only the exact zero address is checked. The rest of `0/8` ("this network") is theoretically invalid as source but never appears in practice. |
| `169.254.0.0/16` | Link-local. Only shows up if the laptop loses its static IP config. Not a realistic vector on the demo rig. |
| `224.0.0.0/4` | Multicast as source (RFC 1112 forbids). Would require a malicious or broken sender. |
| `240.0.0.0/4` | Reserved / "Class E". Never assigned, never valid. |
| `255.255.255.255` | Broadcast as source. Nonsense on the wire. |

Each additional check costs ~2 instructions (~4 ns per frame
on the A72). The full RFC 6890 filter would be 7–8 checks
instead of 3. On a production internet-facing deployment that
extra coverage is worthwhile; on the demo Pi 4 direct-cable
setup, the omitted ranges are noise that would never appear in
legitimate traffic and would require a deliberately malicious
sender to exercise.

**For derivatives:** if you fork ws_pi5 to face the open
internet, expand the filter to cover the full RFC 6890 list.
The existing test infrastructure (`test_ip_handle_martian_src_*`
in `tests/test_ip.S` plus `TestMartianSourceDropped` in
`hw_test/test_l3_malformed_ip.py`) provides the pattern — add
a data frame, add a test, flip the assertion from "accepted" to
"dropped."

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
