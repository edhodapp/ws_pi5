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

TIOCM_DTR = 0x002
TIOCMBIS = 0x5416
TIOCMBIC = 0x5417


def set_dtr(fd, state):
    """Set DTR line high (state=True) or low (state=False)."""
    bits = struct.pack('I', TIOCM_DTR)
    fcntl.ioctl(fd, TIOCMBIS if state else TIOCMBIC, bits)


def open_serial(path):
    """Open serial port: 115200 8N1, raw, no flow control.

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
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
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
    return fd


def read_line(fd, timeout=10):
    """Read until \\n with timeout. Returns decoded stripped string.

    Uses VMIN=0 + VTIME=timeout: the read(2) call returns either
    when at least one byte is available, or when the inter-byte
    timer expires — which also fires as the initial-byte timeout
    because VMIN is zero. Earlier versions of this function set
    VMIN=1, which makes read(2) block indefinitely waiting for the
    first byte regardless of VTIME, so a silent chainloader would
    hang forever instead of returning an empty string. That bug
    was caught in the Gemini review of commit 2a2b6cf (HIGH).

    TCSANOW (not TCSADRAIN) because we are about to read, not
    write — waiting for the TX buffer to drain before applying
    read-side termios settings is pure latency.

    The VMIN/VTIME change is scoped to the body of this function:
    we snapshot the existing attrs at entry and restore them in a
    `finally` block. Without the restore, callers that read from
    the same fd after read_line returns inherit VMIN=0 and any
    subsequent os.read returns b'' immediately on a quiet port,
    causing the kernel-output display loop in main() to busy-spin
    at 100% CPU. Gemini flagged this in the review of commit
    4e49b9c (MEDIUM); the fix is local to this function.
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

    # DTR reset
    print("DTR reset...", flush=True)
    set_dtr(fd, True)
    time.sleep(0.5)
    set_dtr(fd, False)
    termios.tcflush(fd, termios.TCIFLUSH)

    # Wait for READY
    while True:
        line = read_line(fd, timeout=10)
        if "READY" in line:
            print("READY", flush=True)
            break
        if not line:
            print("Timeout waiting for READY", flush=True)
            os.close(fd)
            return 1

    # Send records — 2-byte ACK: line length + checksum byte
    attrs = termios.tcgetattr(fd)
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 50    # 5 second pure timeout
    termios.tcsetattr(fd, termios.TCSADRAIN, attrs)

    t_start = time.time()
    for i, record in enumerate(records):
        expected = int(record[-2:], 16)
        os.write(fd, (record + '\r\n').encode('ascii'))
        # NOTE: no termios.tcdrain(fd) here — the protocol is
        # synchronous (we block on the 2-byte ACK below before the
        # next os.write), so draining the TX buffer explicitly is
        # dead weight. Removed in the Gemini-review follow-up;
        # the ACK-wait provides all the back-pressure we need.
        ack = b''
        deadline = time.time() + 5
        while len(ack) < 2 and time.time() < deadline:
            chunk = os.read(fd, 2 - len(ack))
            if chunk:
                ack += chunk
        if len(ack) != 2:
            print(f"\n  Timeout on record {i}", flush=True)
            os.close(fd)
            return 1
        line_len, cksum = ack[0], ack[1]
        if cksum == expected:
            pass  # ACK
        elif cksum == (expected ^ 0xFF):
            print(f"\n  NAK on record {i} (len={line_len})",
                  flush=True)
            os.close(fd)
            return 1
        else:
            print(f"\n  MISMATCH at record {i}: "
                  f"exp=0x{expected:02X} got=0x{cksum:02X} "
                  f"len={line_len}", flush=True)
            os.close(fd)
            return 1
        if i % 200 == 0:
            print(f"\r  {i}/{len(records)}", end='', flush=True)

    elapsed = time.time() - t_start
    print(f"\r  {len(records)}/{len(records)} in {elapsed:.1f}s",
          flush=True)

    # Read BOOT line
    line = read_line(fd, timeout=10)
    print(f"  {line}", flush=True)
    if not line.startswith("BOOT"):
        print("No BOOT", flush=True)
        os.close(fd)
        return 1

    # Kernel output — explicitly re-enter blocking single-byte mode.
    #
    # VMIN=1 + VTIME=0 means read(2) blocks until at least one byte
    # arrives (no initial timeout, no inter-byte timer). This is the
    # canonical "live console display" mode. We set it explicitly
    # instead of inheriting from whatever read_line or the record-
    # send loop left on the port — read_line restores its own state
    # now, but the record-send loop still leaves VMIN=0/VTIME=50,
    # which would make the display loop busy-spin on empty reads.
    # Gemini flagged this in commit 4e49b9c (MEDIUM).
    attrs = termios.tcgetattr(fd)
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    print("--- Kernel output (Ctrl-C to quit) ---", flush=True)
    try:
        while True:
            try:
                b = os.read(fd, 1)
            except OSError as exc:
                print(f"\n--- Serial error: {exc} ---", flush=True)
                break
            if not b:
                # With VMIN=1 this should only happen on EOF
                # (e.g. cp210x unplugged); treat as clean exit.
                print("\n--- EOF on serial port ---", flush=True)
                break
            sys.stdout.write(b.decode('ascii', errors='replace'))
            sys.stdout.flush()
    except KeyboardInterrupt:
        print("\n--- Done ---", flush=True)

    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
