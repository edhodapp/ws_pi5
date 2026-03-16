# Ways of Working

## Assembly Philosophy
- Don't write "C in assembly" — a strong optimizing compiler will always win at that.
- Map ISA abstractions directly to the problem using techniques that can't be easily expressed in HLLs.
- Think in the ISA's primitives, not in translated C.

## Testability
- When writing functions with failure paths, discuss whether those paths are reachable under test.
- If not reachable, discuss the cost of making them testable (e.g., parameterizing MMIO base addresses instead of hardcoded constants, so tests can point at fake register blocks in RAM).
- Failure handling code that is never tested is a liability — it can generate new errors when it finally runs.
- Prefer passing base addresses as parameters over hardcoded constants — enables dependency injection at the ISA level.

## Git Workflow
- Trunk-based development: commit directly to `main`, push after each group of changes.
- Commit after every group of code changes. Don't wait to be asked.

## GNU as Gotchas (AArch64)
- Use `.include "file"` NOT `#include "file"` — GNU as doesn't run the C preprocessor.
- `.equ` symbols can't use `|` (bitwise OR) with other `.equ` symbols — pre-compute combined values as hex literals.
- Linker warning about RWX LOAD segment is expected for simple bare-metal projects.

## QEMU Gotchas
- Don't use `timeout` to kill QEMU — it won't flush `-serial file:` output. Instead, run QEMU in background and poll the output file, then `kill` cleanly.
- `-serial mon:stdio` doesn't work reliably when stdout is redirected. Use `-serial file:<path>` instead.

---

# Project: Bare-Metal AArch64 Raspberry Pi 3

## Overview
Bare-metal ARM assembly project targeting Raspberry Pi 3 (AArch64). No OS — runs directly on hardware (or QEMU `raspi3b`).

## Toolchain
- Assembler: `aarch64-linux-gnu-as`
- Linker: `aarch64-linux-gnu-ld`
- Objcopy: `aarch64-linux-gnu-objcopy`
- Emulator: `qemu-system-aarch64 -M raspi3b`
- Build: `make` (GNU Make 4.3)

## Project Structure
- `src/` — Main kernel source (boot.S, future app code)
- `lib/` — Shared library code (uart.S, reusable by app and tests)
- `include/` — Shared constants and macros (.inc files)
- `tests/` — Test sources (test_main.S runner + individual test files)
- `scripts/` — Build/test automation scripts
- `build/` — Build artifacts (gitignored)

## Build Commands
- `make` — Build `kernel8.img`
- `make test` — Build test kernel + run on QEMU, exit 0 on pass
- `make clean` — Remove build artifacts

## TDD Workflow
1. Write test in `tests/` — call `test_pass`/`test_fail` with a test name string
2. Register test by adding `bl test_xxx` in `tests/test_main.S`
3. `make test` → verify it fails (red)
4. Implement in `src/` or `lib/`
5. `make test` → verify it passes (green)
6. Commit

## Assembly Conventions
- `-I include/` is passed to the assembler for `.include` search path
- Callee-saved registers: save/restore `x19-x28`, `x29` (FP), `x30` (LR) per AAPCS64
- Use `.section .text._start` for the entry point so the linker places it first

## Hardware Details
- Target: BCM2837 (Raspberry Pi 3)
- Kernel load address: `0x80000` (aarch64 boot)
- PL011 UART base: `0x3F201000`
- Stack top: `0x100000`

## Git
- user.name: edhodapp
- user.email: ed@hodapp.com
