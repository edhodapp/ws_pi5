#!/usr/bin/env python3
# pylint: disable=inconsistent-quotes,wrong-import-position
# mypy: ignore-errors
#
# - inconsistent-quotes: original code uses single-quoted byte literals
#   (b'\\n') and small strings; newer additions use double quotes. This
#   is a style mismatch, not a correctness issue, and is not worth a
#   mechanical rewrite of the whole file.
# - wrong-import-position: `from intel_hex import ...` must come after
#   sys.path.insert so a bare `python3 scripts/hw_send.py` can find it.
# - mypy: ignore-errors: this module pre-dates the type-annotation push
#   (existing helpers like set_dtr/open_serial/read_line have no
#   annotations); a dedicated typing commit will migrate the whole
#   scripts/ tree at once rather than piecemeal here.
"""Send a kernel to the Pi 4 chainloader using Intel HEX over UART0.

Protocol:
  1. Chainloader prints "READY\\r\\n" when initialized
  2. Host sends Intel HEX records (\\r\\n terminated)
  3. Chainloader sends 2-byte ACK (line_len + checksum) or NAK
     (line_len + cksum^0xFF)
  4. After EOF ACK: chainloader sends BOOT:NNNN\\r\\n, jumps to kernel
  5. Host resets Pi via DTR (GLOBAL_EN) when needed

Usage: python3 hw_send.py <kernel.img> [serial_port]
"""

import fcntl
import os
import signal
import struct
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from intel_hex import kernel_to_hex_records  # noqa: E402

# Wait time after SIGKILL before returning — lets the kernel release
# held file descriptors (/dev/ttyUSB*, /proc state) so the next open()
# sees a clean port. Measured empirically: 0.2s is reliable, 0.3s is
# generous.
_STALE_QUIESCE_SECONDS = 0.3

# Hard cap on read_line's accumulator, in bytes. The chainloader's
# cl_getline caps its own buffer at 78 characters, so any reasonable
# line fits comfortably in 1 KiB; anything longer is protocol abuse
# or hostile input. Capping prevents a runaway stream of bytes
# without a newline from growing read_line's buffer unboundedly.
_READ_LINE_MAX_BYTES = 1024

# Kernel-output display chunk size. VMIN=1 guarantees os.read
# returns as soon as at least one byte is available, so reading up
# to 4 KiB per syscall still preserves live-feel but drains any
# burst the UART driver has buffered in one go (cp210x FIFOs hold
# up to 64 bytes, xHCI URBs deliver multi-byte chunks), trading
# ~11 kHz syscall rate at 115200 baud for ~few hundred Hz.
_KERNEL_READ_CHUNK = 4096

TIOCM_DTR = 0x002
TIOCMBIS = 0x5416
TIOCMBIC = 0x5417


def set_dtr(fd, state):
    """Set DTR line high (state=True) or low (state=False)."""
    bits = struct.pack('I', TIOCM_DTR)
    fcntl.ioctl(fd, TIOCMBIS if state else TIOCMBIC, bits)


def open_serial(path):
    """Open serial port: 115200 8N1, raw, no flow control.

    Opens with O_NONBLOCK so the open(2) call cannot hang waiting
    for DCD — a real TTY driver will block open() indefinitely
    until carrier-detect is asserted if the port isn't marked
    CLOCAL, and we haven't set CLOCAL yet (tcsetattr runs after
    open). USB-serial adapters like the cp210x rarely honor DCD,
    but the guard is cheap and makes this function safe against
    driver bugs and real UARTs. After tcsetattr installs the
    CLOCAL cflag, we clear O_NONBLOCK so subsequent reads are
    blocking as the read_line / ACK-wait loops expect.

    NOTE: must set ispeed/ospeed (attrs[4], attrs[5]) explicitly in
    addition to the CBAUD bits in cflag. On modern Linux the kernel
    keeps the legacy CBAUD bits in sync with the separate c_ispeed /
    c_ospeed fields, and when they conflict the explicit speed fields
    win. If a previous opener (e.g. ModemManager probing) left the
    cp210x at 9600, leaving attrs[4]/[5] alone preserves 9600 even
    though we set B115200 in cflag — and the chainloader's 115200
    output comes back as garbage. Setting both is the only reliable
    way.
    """
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                    # iflag: raw
    attrs[1] = 0                    # oflag: raw
    attrs[2] = (termios.CS8 | termios.CLOCAL | termios.CREAD
                | termios.B115200)
    attrs[3] = 0                    # lflag: raw
    attrs[4] = termios.B115200      # ispeed — required, not optional
    attrs[5] = termios.B115200      # ospeed — required, not optional
    attrs[6][termios.VMIN] = 1      # blocking read, 1 byte min
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
    # Now that CLOCAL is set, swap back to blocking mode so
    # os.read() in read_line and the ACK-wait loop can rely on
    # VMIN/VTIME semantics instead of returning EAGAIN.
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    return fd


def read_line(fd, timeout=10):
    """Read until \\n with timeout. Returns decoded stripped string.

    Uses VMIN=0 + VTIME=timeout. With VMIN=0, read(2) returns
    either when at least one byte is available, or when VTIME
    deciseconds have elapsed — which gives VTIME its "initial-
    byte timeout" meaning and lets the deadline loop below fire
    correctly on a quiet port. Do NOT set VMIN=1: that forces
    read(2) to block for the first byte regardless of VTIME, so
    a silent chainloader hangs this function forever.

    TCSANOW (not TCSADRAIN) because we are about to read, not
    write — waiting for the TX buffer to drain before applying
    read-side termios settings is pure latency.

    The VMIN/VTIME change is scoped to the body of this function:
    we snapshot the existing attrs at entry and restore them in a
    `finally` block. Without the restore, callers that read from
    the same fd after read_line returns inherit VMIN=0, and their
    os.read returns b'' immediately on a quiet port — which in
    main()'s kernel-output display loop means busy-spinning at
    100% CPU. Keep the save/restore local to this function.

    Buffer cap: reads stop at `_READ_LINE_MAX_BYTES` even without
    a newline, to prevent runaway byte streams (a misbehaving or
    malicious chainloader) from growing `buf` without bound.

    Timeout vs VTIME caveat: VTIME is a uint8 of deciseconds and
    clamps to 255 (25.5 s). If the caller passes a `timeout`
    larger than 25.5 s, a single read(2) call can return b'' after
    VTIME expires even though wall-clock time is less than
    `deadline` — and because `if not b: break` treats that as an
    end-of-stream signal, read_line actually returns after ~25.5 s.
    All current callers use ≤10 s timeouts, so this is dead code
    in practice; fix it by replacing `break` with deadline-aware
    retry if a future caller needs longer timeouts.
    """
    saved = termios.tcgetattr(fd)
    # Build a new attrs list with our transient VMIN/VTIME, leaving
    # `saved` untouched so the finally can restore it cleanly.
    vtime = min(255, max(1, int(timeout * 10)))
    new_cc = list(saved[6])
    new_cc[termios.VMIN] = 0
    new_cc[termios.VTIME] = vtime
    new_attrs = [saved[0], saved[1], saved[2], saved[3],
                 saved[4], saved[5], new_cc]
    termios.tcsetattr(fd, termios.TCSANOW, new_attrs)

    try:
        buf = b''
        deadline = time.time() + timeout
        while time.time() < deadline:
            b = os.read(fd, 1)
            if not b:
                break
            buf += b
            if b == b'\n':
                break
            if len(buf) >= _READ_LINE_MAX_BYTES:
                # Runaway stream without a newline — return what
                # we have rather than grow the buffer indefinitely.
                break
        return buf.decode('ascii', errors='ignore').strip()
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, saved)


def _read_proc_text(pid, name):
    """Read /proc/<pid>/<name> as text, or return None if unreadable.

    Returns an empty string for files that exist but are zero-length,
    so callers can distinguish "file gone" (None) from "file empty".
    """
    try:
        with open(f"/proc/{pid}/{name}", "rb") as fobj:
            return fobj.read().decode("utf-8", errors="replace")
    except OSError:
        return None


def _proc_ancestors(pid):
    """Return the set {pid, parent_pid, grandparent_pid, ...}.

    Walks `/proc/<current>/status` up the PPid chain until PID 1
    (init) or a cycle. This is how we avoid killing any process that
    owns our current execution — including grandparent shells whose
    `eval` strings happen to contain the cmdline needle we're
    sweeping for. Only excluding `os.getppid()` is not enough: a
    `bash -c '… python scripts/hw_send.py …'` wrapper is typically
    our parent's parent, not our parent.
    """
    chain = set()
    current = pid
    while current > 1 and current not in chain:
        chain.add(current)
        status = _read_proc_text(current, "status")
        if status is None:
            break
        next_ppid = 0
        for line in status.splitlines():
            if line.startswith("PPid:"):
                try:
                    next_ppid = int(line.split(maxsplit=1)[1])
                except (IndexError, ValueError):
                    next_ppid = 0
                break
        if next_ppid <= 0:
            break
        current = next_ppid
    return chain


def _proc_matches(pid, matchers):
    """True iff this pid's (comm, cmdline) matches any (comm_prefix, needle).

    Two-part match is deliberate: `/proc/<pid>/comm` holds the
    executable basename (truncated to 15 chars by the kernel), so
    checking `comm.startswith("python")` distinguishes a real
    python interpreter from `vim scripts/hw_send.py` (comm="vim")
    or `grep hw_send.py …` (comm="grep"). The cmdline needle then
    narrows to the script we actually care about. `pgrep -f` does
    only the cmdline half and over-matches badly.
    """
    comm_raw = _read_proc_text(pid, "comm")
    if comm_raw is None:
        return False
    comm = comm_raw.rstrip("\n")
    cmdline_raw = _read_proc_text(pid, "cmdline")
    if cmdline_raw is None:
        return False
    # /proc/<pid>/cmdline separates argv elements with NUL; join with
    # spaces for human-readable substring matching.
    cmdline = cmdline_raw.replace("\0", " ")
    for comm_prefix, cmdline_needle in matchers:
        if comm.startswith(comm_prefix) and cmdline_needle in cmdline:
            return True
    return False


def kill_stale_by_matchers(matchers, quiet=False):
    """Sweep /proc and SIGKILL processes matching (comm_prefix, needle).

    Returns the count killed.

    **Why this exists:** hw_send.py enters a "Kernel output" console
    mode after flashing and holds `/dev/ttyUSB*` open indefinitely.
    A backgrounded or disowned prior invocation steals the ACK bytes
    from the next flash and makes a working kernel look broken. QEMU
    instances from prior `make test` runs also linger and chew CPU.
    Ed's standing rule is to sweep at both ends of every hw run —
    this helper is the single source of truth for *how* to sweep.

    **Robustness properties:**

    1. **Enumerates via /proc directly**, not via `pgrep -f`. No
       shell-out, no pgrep flags to get wrong, no race between
       pgrep's snapshot and our iteration.
    2. **Two-part match** (comm prefix + cmdline substring). A
       matcher of `("python", "hw_send.py")` only kills real python
       interpreters running hw_send.py — it never touches
       `vim scripts/hw_send.py` or `less hw_send.py`.
    3. **Full ancestor-chain exclusion.** Walks PPid up /proc so any
       grandparent (wrapping shell, pytest session, make invocation)
       is safe even if its cmdline contains the needle.
    4. **TOCTOU re-verification.** Between the initial match and the
       SIGKILL, a target can exit and Linux can recycle the PID to
       an unrelated process. We re-read /proc/<pid>/{comm,cmdline}
       immediately before the kill and skip if the match no longer
       holds. Closes (most of) the window; the residual race is
       microseconds.
    5. **Best-effort PermissionError handling.** If the process is
       not ours to kill, we warn but do not fail; the caller's next
       open_serial() will surface the contention if it matters.
    """
    excluded = _proc_ancestors(os.getpid())
    killed = 0
    try:
        pid_entries = os.listdir("/proc")
    except OSError:
        return 0
    for entry in pid_entries:
        try:
            pid = int(entry)
        except ValueError:
            continue
        if pid in excluded:
            continue
        if not _proc_matches(pid, matchers):
            continue
        # Re-verify immediately before the kill — TOCTOU protection.
        # If the PID has been recycled into a non-matching process,
        # this second check skips it.
        if not _proc_matches(pid, matchers):
            continue
        try:
            os.kill(pid, signal.SIGKILL)
            killed += 1
        except ProcessLookupError:
            pass  # already gone — fine
        except PermissionError:
            if not quiet:
                print(
                    f"  kill_stale: cannot kill pid {pid} "
                    "(not owned by us)",
                    file=sys.stderr,
                    flush=True,
                )
    if killed and not quiet:
        # Let the kernel release held file descriptors (/dev/ttyUSB*,
        # listen sockets, etc.) before the caller's next open().
        time.sleep(_STALE_QUIESCE_SECONDS)
        print(
            f"  kill_stale: terminated {killed} stale process(es)",
            flush=True,
        )
    return killed


# Matcher for our own flasher — used by main() below and by callers
# (hw_test/conftest.py) who want to sweep for stale hw_send.py
# instances specifically.
#
# Design note (deliberate scope decision): this matches ANY python
# process running hw_send.py system-wide, regardless of which
# serial port it is targeting. That is intentional for the
# single-Pi development setup Ed runs today: if any hw_send.py is
# still alive when a new flash starts, it is either stale (port
# holder from an aborted run) or about to contend for the same
# port, and killing it unconditionally is always safe because
# there is exactly one target device. For a future multi-Pi
# setup the matcher would need to narrow to processes that hold
# the specific port_path open (walk /proc/<pid>/fd/ and readlink
# to the target device path) — revisit then. Code reviewers
# have flagged this as "too broad" multiple times; it is not a
# bug, it is a documented scope choice.
HW_SEND_MATCHERS = (("python", "hw_send.py"),)


def kill_stale_hw_send():
    """Convenience wrapper: sweep for stale hw_send.py instances only."""
    return kill_stale_by_matchers(HW_SEND_MATCHERS)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <kernel.img> [serial_port] [base_addr]")
        return 1

    kernel_path = sys.argv[1]
    port_path = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyUSB0"
    base_addr = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x200000

    # Always clear stale hw_send processes before touching the port.
    kill_stale_hw_send()

    with open(kernel_path, "rb") as fobj:
        kernel = fobj.read()

    records = kernel_to_hex_records(kernel, base_address=base_addr)
    print(f"Kernel: {kernel_path} ({len(kernel)} bytes)", flush=True)
    print(f"HEX: {len(records)} records", flush=True)

    fd = open_serial(port_path)
    try:
        return _flash_and_monitor(fd, records)
    finally:
        os.close(fd)


def _flash_and_monitor(fd, records):
    """Body of main() after the serial port is open.

    Split out so main() can wrap this in a try/finally that
    guarantees os.close(fd) on every exit path — including
    KeyboardInterrupt mid-loop and any unexpected exception.
    Prior versions scattered `os.close(fd); return 1` across
    every error branch and leaked the fd on KeyboardInterrupt.
    """
    # DTR reset
    print("DTR reset...", flush=True)
    set_dtr(fd, True)
    time.sleep(0.5)
    set_dtr(fd, False)
    termios.tcflush(fd, termios.TCIFLUSH)

    # Wait for READY with a TOTAL deadline rather than per-line
    # timeout. The Pi emits stray `\r\n` pairs during early boot
    # before the chainloader prints its banner, and read_line
    # returns "" for both empty lines and true silence — so an
    # `if not line: abort` check cannot distinguish them and used
    # to trip on the first blank line. Looping until we see
    # "READY" (or run out of total time) skips blank lines
    # naturally and aborts only on genuine silence.
    ready_deadline = time.time() + 15
    while time.time() < ready_deadline:
        line = read_line(fd, timeout=3)
        if "READY" in line:
            print("READY", flush=True)
            break
    else:
        print("Timeout waiting for READY", flush=True)
        return 1

    # Send records — 2-byte ACK: line length + checksum byte
    attrs = termios.tcgetattr(fd)
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 50    # 5 second pure timeout
    termios.tcsetattr(fd, termios.TCSADRAIN, attrs)

    # Flush any bytes the chainloader may have emitted after the
    # READY banner but before we enter the synchronous record
    # protocol. If the chainloader ever starts printing a second
    # line (e.g. a version string or "ready to receive") that
    # lands after we matched READY, those stale bytes would be
    # misread as the ACK for the first record and the protocol
    # would desync. Cheap insurance — TCIFLUSH only touches the
    # input queue, not anything we care about.
    termios.tcflush(fd, termios.TCIFLUSH)

    t_start = time.time()
    for i, record in enumerate(records):
        expected = int(record[-2:], 16)
        os.write(fd, (record + '\r\n').encode('ascii'))
        # The protocol is synchronous — we block on the 2-byte ACK
        # below before the next os.write — so the ACK round-trip
        # provides all the back-pressure we need. An explicit
        # termios.tcdrain() here would be dead weight.
        #
        # ACK is 2 bytes: line_len + checksum. VTIME=50 (set above)
        # caps each os.read at 5 seconds; an empty return means the
        # Pi went silent. We don't need a separate wall-clock
        # deadline — the kernel's VTIME timer is the timeout.
        ack = b''
        while len(ack) < 2:
            chunk = os.read(fd, 2 - len(ack))
            if not chunk:
                print(f"\n  Timeout on record {i}", flush=True)
                return 1
            ack += chunk
        line_len, cksum = ack[0], ack[1]
        # Validate line_len. The chainloader's cl_getline counts
        # bytes *excluding* \r and \n and tops out at 78 (see
        # chainload/boot.S); our `record` string likewise excludes
        # CRLF (we append \r\n at os.write time), so the two must
        # match exactly for an undamaged ACK. A mismatch here
        # catches framing errors the checksum alone would miss,
        # e.g. a dropped byte that shifts the remainder of the
        # record but happens to sum to the same checksum.
        if line_len != len(record):
            print(f"\n  LEN MISMATCH at record {i}: "
                  f"sent {len(record)}, chainloader echoed "
                  f"{line_len}", flush=True)
            return 1
        if cksum == expected:
            pass  # ACK
        elif cksum == (expected ^ 0xFF):
            print(f"\n  NAK on record {i} (len={line_len})",
                  flush=True)
            return 1
        else:
            print(f"\n  MISMATCH at record {i}: "
                  f"exp=0x{expected:02X} got=0x{cksum:02X} "
                  f"len={line_len}", flush=True)
            return 1
        if i % 200 == 0:
            print(f"\r  {i}/{len(records)}", end='', flush=True)

    elapsed = time.time() - t_start
    print(f"\r  {len(records)}/{len(records)} in {elapsed:.1f}s",
          flush=True)

    # Read BOOT line with the same total-deadline pattern as the
    # READY wait above: a single read_line would abort on a stray
    # blank line between the last record ACK and the BOOT banner.
    boot_deadline = time.time() + 15
    while time.time() < boot_deadline:
        line = read_line(fd, timeout=3)
        if line.startswith("BOOT"):
            print(f"  {line}", flush=True)
            break
    else:
        print("No BOOT", flush=True)
        return 1

    # Kernel output — explicitly re-enter blocking single-byte mode.
    #
    # VMIN=1 + VTIME=0 means read(2) blocks until at least one byte
    # arrives (no initial timeout, no inter-byte timer). This is the
    # canonical "live console display" mode. We set it explicitly
    # because the record-send loop above leaves VMIN=0/VTIME=50 on
    # the port; without this reset the display loop would return
    # b'' immediately on any empty buffer and busy-spin at 100% CPU.
    attrs = termios.tcgetattr(fd)
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    print("--- Kernel output (Ctrl-C to quit) ---", flush=True)
    try:
        while True:
            try:
                # VMIN=1 guarantees read(2) returns as soon as ≥1
                # byte arrives, so asking for up to 4 KiB does not
                # delay the live-feel of the console display — it
                # just drains whatever burst the UART driver has
                # buffered in a single syscall. At 115200 baud
                # that trades ~11 kHz syscall rate (1-byte reads)
                # for ~few hundred Hz.
                chunk = os.read(fd, _KERNEL_READ_CHUNK)
            except OSError as exc:
                print(f"\n--- Serial error: {exc} ---", flush=True)
                break
            if not chunk:
                # With VMIN=1 this should only happen on EOF
                # (e.g. cp210x unplugged); treat as clean exit.
                print("\n--- EOF on serial port ---", flush=True)
                break
            # Write raw bytes straight to stdout's underlying
            # buffer so the host terminal emulator decides the
            # encoding. Earlier revisions used
            # chunk.decode('ascii', errors='replace') which turned
            # every non-ASCII byte into '?' — fine for our
            # assembly kernel today but hostile to any future
            # UTF-8 log output or TUI escape sequences.
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    except KeyboardInterrupt:
        print("\n--- Done ---", flush=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
