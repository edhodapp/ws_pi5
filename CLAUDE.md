# Ways of Working

## Assembly Philosophy
- Don't write "C in assembly" — a strong optimizing compiler will always win at that.
- Map ISA abstractions directly to the problem using techniques that can't be easily expressed in HLLs.
- Think in the ISA's primitives, not in translated C.

## Testability
- A critical job for a programmer is to prove to themselves that their code is correct — trust nothing without verification.
- When writing functions with failure paths, discuss whether those paths are reachable under test.
- If not reachable, discuss the cost of making them testable (e.g., parameterizing MMIO base addresses instead of hardcoded constants, so tests can point at fake register blocks in RAM).
- Failure handling code that is never tested is a liability — it can generate new errors when it finally runs.
- Prefer passing base addresses as parameters over hardcoded constants — enables dependency injection at the ISA level.
- At the end of EVERY stage: branch coverage (both sides), functional tests (ALL new integration paths — do NOT skip any), PICT review, fuzz review. Implement all tests before committing.
- **Every test branch MUST have an assertion.** 100% branch coverage without assertions is worthless — it's just running code, not testing it. Never call a function and unconditionally pass. Every `test_pass`/`test_fail` must be gated by an explicit check on the return value or observable side effect. In Python, every `assert` must check a meaningful value, not just "didn't throw." Mutation testing is the proof: if a mutant survives, the test is broken.

## Git Workflow
- Trunk-based development: commit directly to `main`, push after each group of changes.
- Commit after every group of code changes. Don't wait to be asked.

## GNU as Gotchas (AArch64)
- Use `.include "file"` NOT `#include "file"` — GNU as doesn't run the C preprocessor.
- `.equ` symbols can't use `|` (bitwise OR) with other `.equ` symbols — pre-compute combined values as hex literals.
- `.equ` symbols are file-local — they cannot be exported via `.global`. Use labels for cross-file constants.
- Linker warning about RWX LOAD segment is expected for simple bare-metal projects.
- `ldr/str` with register offset: `lsl #3` is NOT valid for word loads. Use `add` then `ldr` at base.
- `ldrh`/`strh` require 2-byte aligned addresses with MMU off. For packed byte streams (USB descriptors), use two `ldrb` + `orr w, w, w, lsl #8` instead.

## QEMU Gotchas
- Don't use `timeout` to kill QEMU — it won't flush `-serial file:` output. Instead, run QEMU in background and poll the output file, then `kill` cleanly.
- `-serial mon:stdio` doesn't work reliably when stdout is redirected. Use `-serial file:<path>` instead.
- QEMU 9+/10+ enforce alignment with MMU off (Device-nGnRnE) — QEMU 7.2 silently ignored this. Fix: enable MMU with Normal memory type in boot.S (pending).
- QEMU 7.2 does NOT support `raspi4b`. Test on `raspi3b` with Pi 3 addresses (default build).

---

# Project: Bare-Metal AArch64 Web Server

## Overview
Bare-metal HTTPS web server targeting Raspberry Pi 4 (AArch64, BCM2711, 8 GB). Complete network stack from Ethernet to HTTP in assembly. No OS, no C runtime, no abstraction layers.

## Toolchain
- Assembler: `aarch64-linux-gnu-as`
- Linker: `aarch64-linux-gnu-ld`
- Objcopy: `aarch64-linux-gnu-objcopy`
- Test emulator: `qemu-system-aarch64 -M raspi3b` (QEMU 7.2)
- Build: `make` (Pi 3/QEMU), `make PLATFORM=pi4` (Pi 4)

## Project Structure
- `lib/` — Platform-independent protocol stack (eth, arp, ip, icmp, udp, tcp, http, ntp, md5, timers, vmio)
- `include/` — Shared constants: tcp.inc (256-byte TCONN), http.inc, net.inc, timer.inc
- `platform/pi/` — Pi boot.S, main.S, drivers/ (UART, DWC2, USB, CDC-ECM, mailbox), include/ (platform.inc, dwc2.inc, etc.)
- `tests/` — 363 unit tests (shared protocol tests + tests/pi/ for Pi driver tests)
- `tests/func/` — PICT model for exhaustive TCP functional testing (138 vectors)
- `fuzz/` — Fuzz harness: 23 single-packet + 16 multi-packet seeds, http_poll integrated
- `scripts/` — Build/test automation, Python TCP oracle

## Build Commands
- `make` — Build `kernel8.img` (Pi 3 addresses for QEMU testing)
- `make PLATFORM=pi4` — Build for Pi 4 hardware (0xFE peripheral base)
- `make test` — Build test kernel + run on QEMU raspi3b
- `make test-functional` — Run PICT + handcrafted functional tests
- `make fuzz` / `make fuzz-seq` — Build fuzz harnesses
- `make clean` — Remove build artifacts

## TDD Workflow
1. Write test in `tests/` — call `test_pass`/`test_fail` with a test name string
2. Register test by adding `bl test_xxx` in `tests/test_main.S`
3. `make test` → verify it fails (red)
4. Implement in `src/`, `lib/`, or `drivers/`
5. `make test` → verify it passes (green)
6. Full review: branch coverage, functional tests, PICT, fuzz
7. Commit

## Assembly Conventions
- `-I include/ -I platform/pi/include/` is passed to the assembler for `.include` search path
- Callee-saved registers: save/restore `x19-x28`, `x29` (FP), `x30` (LR) per AAPCS64
- Use `.section .text._start` for the entry point so the linker places it first
- TCONN struct: 256 bytes per connection, indexed via `lsr x, x, #TCONN_SHIFT` (8)
- TCP send buffer: 256 KB per connection, indexed via `lsl x, x, #TCP_SNDBUF_SHIFT` (18)

## Hardware Details
- Production target: BCM2711 (Raspberry Pi 4, 8 GB)
- Test target: BCM2837 (Raspberry Pi 3 via QEMU 7.2 raspi3b)
- Kernel load address: `0x80000` (aarch64 boot)
- Boot: EL2 → EL1 drop in boot.S (Pi 4 starts at EL2; Pi 3/QEMU 7.2 starts at EL1, drop is skipped)
- Platform switching: `platform/pi/include/platform.inc` derives PERIPH_BASE from build flag
- Pi 3 peripheral base: `0x3F000000` (default, for QEMU testing)
- Pi 4 peripheral base: `0xFE000000` (via `make PLATFORM=pi4`)
- UART: PL011 at PERIPH_BASE + 0x201000 (Pi 4 hardware will use UART3 on GPIO 4/5)
- DWC2 USB: PERIPH_BASE + 0x980000
- Mailbox: PERIPH_BASE + 0x00B880
- Stack top: dynamically placed above BSS (`ALIGN(__bss_end, 16) + 0x10000`)
- Runtime memory: ~32.6 MB (dominated by 128 × 256 KB TCP send buffers)

## Pi 4 GPIO Pin Assignments
- GPIO 4 (Pin 7): UART3 TX — serial debug to Chromebook (planned)
- GPIO 5 (Pin 29): UART3 RX — serial debug from Chromebook (planned)
- GPIO 14 (Pin 8): Fan control — official Pi 4 case fan on/off (planned)
- 3.3V USB-to-serial adapter required (CP2102 or FTDI) — 5V will damage GPIO

## TCP Capabilities (current)
- 128 concurrent connections, 256-byte TCONN, 256 KB circular send buffer each
- WSCALE (RFC 7323), SACK (RFC 2018), RFC 6298 RTO (SRTT/RTTVAR)
- Multi-segment send, congestion control, fast retransmit, timestamps, PAWS
- 10-state FSA, OOO buffering, persist timer, idle reaper, RST rate limiting

## Next Steps
1. Pi 4 hardware bringup (serial adapter arriving): GENET Ethernet, UART3, fan control
2. TLS 1.3 / HTTPS (~3000-5000 lines): ARMv8 crypto extensions for AES-GCM, SHA-256

## Git
- user.name: edhodapp
- user.email: ed@hodapp.com
