# Panic LED Patterns

When the kernel halts because of an unrecoverable error, it blinks a
short Morse-coded pattern on the Pi 4 ACT LED (GPIO 42). The pattern
tells you what category of failure occurred without needing UART
connected.

UART always carries the full diagnostic message. The LED is the backup
channel for users who don't have a serial cable hooked up.

---

## How to read a pattern

The kernel sends one short letter (2 or 3 elements) on the green ACT
LED, pauses for 3 seconds, then repeats indefinitely until the Pi is
power-cycled.

Element timing:

- 1 dit (`·`) = 200 ms on
- 1 dah (`—`) = 600 ms on  (3 dit-units, per Morse convention)
- gap between elements within a letter = 200 ms off
- inter-cycle pause = 3000 ms off

A complete pattern fits in under 1.5 seconds; the inter-cycle pause
makes the boundary obvious. Wait through 2–3 cycles to confirm what
you're seeing.

---

## Pattern catalog

| Pattern        | Morse  | Letter | Tier              | Meaning                                                                 |
|----------------|--------|--------|-------------------|-------------------------------------------------------------------------|
| `— ·`          | `—·`   | **N**  | 1 — User-fixable  | **Network** config error in `network.conf`                              |
| `— — ·`        | `——·`  | **G**  | 1 — User-fixable  | **Gateway** unreachable — ARP for configured gateway timed out          |
| `· ·`          | `··`   | **I**  | 2 — Hardware      | **Init** failed (GENET / USB / mailbox / clock — generic hardware init) |
| `— —`          | `——`   | **M**  | 2 — Hardware      | **MAC** unreadable: OTP mailbox failed AND no `mac=` override           |
| `— · —`        | `—·—`  | **K**  | 3 — Kernel        | **Kernel** panic (exception vector / assert)                            |
| `· · —`        | `··—`  | **U**  | 3 — Kernel        | **Unknown** / unclassified panic (escape hatch)                         |

### Tier 1 — User-fixable

The Pi booted, the kernel ran, and a setting in `network.conf` is
wrong. You can fix this from your laptop without touching code.

- **N (`—·`)** — `network.conf` failed to parse. Missing magic
  sentinel, malformed value (e.g. `ip=192.168.1.42x`), missing
  required key, or unknown value out of range. Pop the SD card,
  open `network.conf` in a text editor, fix the flagged line, save,
  re-insert.

- **G (`——·`)** — `network.conf` parsed cleanly, but the configured
  gateway didn't answer ARP. Most common cause: `gateway=` is set to
  an address your router doesn't actually own. Check your router's
  admin page for the gateway IP and update `network.conf`.

### Tier 2 — Hardware

The kernel started, but a piece of hardware didn't come up the way it
should. This is rare on a working Pi 4. If you see it after a power
cycle on the same SD, suspect the SD card or the board itself.

- **I (`··`)** — Generic hardware init failure. The kernel got far
  enough to start probing peripherals but one of them refused to
  initialize. UART output names the specific peripheral (GENET, USB,
  mailbox, clock, etc.). First troubleshooting step: try a
  freshly-flashed SD on a known-good Pi 4.

- **M (`——`)** — The kernel asked the firmware for the factory MAC
  address (Pi OTP fuses, mailbox tag `0x00010003`) and got back
  garbage (all zeros, all 0xFFs, multicast bit set, or no response).
  Fix: add `mac=...` to `network.conf` to provide a MAC explicitly.
  If you see this on a genuine Pi 4 the OTP fuses may be unblown
  (very rare on retail boards).

### Tier 3 — Kernel

The kernel encountered an internal error. These are bugs in the
software, not configuration problems. Connect UART and capture the
output before reporting.

- **K (`—·—`)** — A CPU exception was taken (data abort, prefetch
  abort, undefined instruction, SP misalignment) or an assertion
  failed. UART carries the EXC dump with PC, registers, and a fault
  classification. File a bug with that output.

- **U (`··—`)** — Catch-all for kernel panics that don't fit any
  other category. If you see this, UART is the only useful
  diagnostic; please file a bug.

---

## Visual distinguishability

The six patterns are designed to be tellable apart by cadence alone,
without needing to count or know Morse code:

| Length     | Pattern   | Cadence                            |
|------------|-----------|------------------------------------|
| 2 elements | N (`—·`)  | long-short — "DAH-dit"             |
| 2 elements | M (`——`)  | long-long — slow "DAH-DAH"         |
| 2 elements | I (`··`)  | short-short — rapid "dit-dit"      |
| 3 elements | G (`——·`) | heavy-then-light — "DAH-DAH-dit"   |
| 3 elements | K (`—·—`) | symmetric — "DAH-dit-DAH"          |
| 3 elements | U (`··—`) | light-then-heavy — "dit-dit-DAH"   |

No two patterns share both length and shape. If you can tell "fast
staccato" from "slow heavy" from "alternating," you can tell these
apart without knowing the alphabet.

---

## Why this approach

The panic LED is a backup diagnostic channel for users who don't have
UART connected. It is not the primary one — every panic also writes
a full diagnostic to UART, including stack traces, register dumps,
and the originating source line where applicable.

The categorization is informational. The kernel doesn't recover from
any of these states; the pattern just tells you whether to grab an
SD card reader (Tier 1), a different Pi (Tier 2), or a developer
(Tier 3) before power-cycling.

If a panic doesn't have a clear category, the kernel uses **U**
(Unknown). Adding new categories is easy — pick another short Morse
letter (any 2–3 element letter not already in the table) and update
this catalog plus `lib/panic.S`.
