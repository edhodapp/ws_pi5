#!/usr/bin/env python3
# pylint: disable=missing-class-docstring,import-outside-toplevel
# pylint: disable=unused-argument,protected-access
# mypy: ignore-errors
#
# Test-file pylint exemptions: pytest test methods and helpers
# legitimately accept unused fd/request/mock arguments (for mock
# dispatch or shared signatures), and test classes don't need
# docstrings when the method docstrings describe what's tested.
# Importing termios inside a test keeps the constant scoped.
# mypy: ignore-errors — tests use mocks and lambdas heavily; type
# annotations would be pure ceremony for no correctness benefit.
"""Unit tests for scripts/hw_send.py.

hw_send.py was rewritten on 2026-04-04 (commit 2878c79) to drop
pyserial in favour of raw os + termios. The protocol changed from a
single '+' ACK byte to a 2-byte (line_length, checksum) ACK, and all
the previous helper functions (sync_chainloader, _send_one_record,
_read_output_byte, etc.) were inlined into main(). That made the
previous test file's references stale.

This rewrite drops the dead tests and covers what the new module
actually exposes:

    set_dtr(fd, state)       — ioctl-based DTR toggle
    read_line(fd, timeout)   — bounded line read with VTIME shaping

Everything else in hw_send.py is inside main(), which is a long
imperative sequence tied to os.open / termios / os.read / os.write
on a real tty fd. A meaningful unit test of main() would require
refactoring the module first, which is out of scope here.
"""

from unittest.mock import MagicMock, patch

import hw_send


# ── set_dtr ──────────────────────────────────────────────────

class TestSetDtr:
    """Verify DTR toggle calls fcntl.ioctl with the right op codes.

    set_dtr's entire behaviour is the ioctl call, so the test must
    pin the exact (fd, op, payload) tuple — no "didn't throw"
    stubs. If the command codes ever drift, this catches it.
    """

    def test_state_true_sets_dtr(self):
        with patch("hw_send.fcntl.ioctl") as mock_ioctl:
            hw_send.set_dtr(42, True)
            mock_ioctl.assert_called_once()
            fd, op, payload = mock_ioctl.call_args[0]
            assert fd == 42
            assert op == hw_send.TIOCMBIS
            # payload is a 4-byte little-endian struct holding TIOCM_DTR
            assert len(payload) == 4
            assert int.from_bytes(payload, "little") == hw_send.TIOCM_DTR

    def test_state_false_clears_dtr(self):
        with patch("hw_send.fcntl.ioctl") as mock_ioctl:
            hw_send.set_dtr(42, False)
            mock_ioctl.assert_called_once()
            fd, op, payload = mock_ioctl.call_args[0]
            assert fd == 42
            assert op == hw_send.TIOCMBIC
            assert int.from_bytes(payload, "little") == hw_send.TIOCM_DTR

    def test_bis_and_bic_are_distinct(self):
        """Regression fence: if someone swaps the two constants, both
        set_dtr(True) and set_dtr(False) would still look reasonable
        in isolation. Pin that they're different values."""
        assert hw_send.TIOCMBIS != hw_send.TIOCMBIC


# ── read_line ────────────────────────────────────────────────

class _FakeTerm:
    """Minimal termios double.

    hw_send.read_line calls tcgetattr -> mutates attrs[6] (the cc
    array) -> tcsetattr. Our fake captures the final VTIME so tests
    can assert on the timeout-to-deciseconds conversion.
    """

    def __init__(self):
        # attrs shape per termios.tcgetattr: [iflag, oflag, cflag,
        # lflag, ispeed, ospeed, cc]. cc is a list where we only
        # touch VMIN (index ~6) and VTIME (index ~5). We just give
        # a big placeholder list so any index works.
        self.attrs = [0, 0, 0, 0, 0, 0, [0] * 32]
        self.set_calls = []

    def tcgetattr(self, fd):
        # Return a fresh copy so callers can mutate safely.
        return [0, 0, 0, 0, 0, 0, list(self.attrs[6])]

    def tcsetattr(self, fd, when, attrs):
        self.set_calls.append((fd, when, attrs))
        self.attrs = attrs


def _mk_read_line_env(bytes_yielded, times):
    """Build a (termios_mock, os_read_mock, time_mock) patcher bundle.

    bytes_yielded: sequence of 1-byte bytes strings + possibly b''
                   to signal EOF
    times: sequence of time.time() return values
    """
    fake = _FakeTerm()
    # os.read returns one byte at a time
    read_mock = MagicMock(side_effect=list(bytes_yielded))
    time_mock = MagicMock(side_effect=list(times))
    return fake, read_mock, time_mock


class TestReadLine:

    def test_returns_line_without_trailing_newline(self):
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"R", b"E", b"A", b"D", b"Y", b"\r", b"\n"],
            times=[0.0, 0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            result = hw_send.read_line(fd=10, timeout=1)
        assert result == "READY"

    def test_returns_empty_on_eof(self):
        """os.read returning b'' (no bytes) should break the loop
        and return whatever has accumulated so far."""
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"R", b"E", b""],
            times=[0.0, 0.01, 0.02, 0.03],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            result = hw_send.read_line(fd=10, timeout=1)
        assert result == "RE"

    def test_returns_empty_string_when_deadline_hit_immediately(self):
        """time.time()'s very first call places the deadline in the
        past. read_line's loop condition is strict (<), so it never
        executes — os.read is not called, and the decoded buffer
        is ''."""
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[],
            # First call sets deadline = 0.0 + 1 = 1.0; second call
            # returns 2.0 so the while check fails immediately.
            times=[0.0, 2.0],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            result = hw_send.read_line(fd=10, timeout=1)
        assert result == ""
        assert read_mock.call_count == 0

    def test_vtime_set_to_timeout_in_deciseconds(self):
        """The driver converts timeout seconds to VTIME deciseconds
        and clamps to [1, 255]. A 3.0-second timeout must land as
        30 (3.0 * 10). This pins the conversion formula.

        Checks set_calls (the read-time config) rather than the
        final fake.attrs because read_line save/restores state."""
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"\n"],
            times=[0.0, 0.01, 0.02],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            hw_send.read_line(fd=10, timeout=3.0)
        import termios as _t
        vtimes_set = [c[2][6][_t.VTIME] for c in fake.set_calls]
        assert 30 in vtimes_set, (
            f"no tcsetattr set VTIME=30; got {vtimes_set}"
        )

    def test_vtime_clamped_to_upper_bound(self):
        """Timeout large enough to overflow a uint8 VTIME field
        must clamp to 255 (25.5 seconds), not wrap."""
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"\n"],
            times=[0.0, 0.01, 0.02],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            hw_send.read_line(fd=10, timeout=9999)
        import termios as _t
        vtimes_set = [c[2][6][_t.VTIME] for c in fake.set_calls]
        assert 255 in vtimes_set, (
            f"no tcsetattr set VTIME=255 (clamp); got {vtimes_set}"
        )

    def test_vtime_clamped_to_lower_bound(self):
        """Tiny (sub-decisecond) timeouts must round up to 1, not
        collapse to 0 (which would disable the inter-byte timeout
        and block forever on a slow stream)."""
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"\n"],
            times=[0.0, 0.01, 0.02],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            hw_send.read_line(fd=10, timeout=0.01)
        import termios as _t
        vtimes_set = [c[2][6][_t.VTIME] for c in fake.set_calls]
        assert 1 in vtimes_set, (
            f"no tcsetattr set VTIME=1 (clamp); got {vtimes_set}"
        )

    def test_vmin_is_zero_during_read_regression_fence(self):
        """VMIN MUST be 0 during the actual os.read so read() does
        not block indefinitely on an initial-byte wait. An earlier
        version of this function set VMIN=1, making read() ignore
        VTIME's initial-byte semantics and hang forever if the
        chainloader never prints. Caught in the Gemini review of
        commit 2a2b6cf.

        Note: we check the tcsetattr calls (not the final fake.attrs)
        because read_line now save/restores termios state — the
        final state reflects the restore, not the read-time config.
        """
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"\n"],
            times=[0.0, 0.01, 0.02],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            hw_send.read_line(fd=10, timeout=1.0)
        import termios as _t
        # At least one tcsetattr call must have set VMIN=0. The
        # saved-state snapshot + transient read config + restore
        # sequence yields at least two tcsetattr calls; the read
        # config is the one we care about.
        vmins_during_read = [
            call_args[2][6][_t.VMIN] for call_args in fake.set_calls
        ]
        assert 0 in vmins_during_read, (
            f"read_line never set VMIN=0; tcsetattr VMIN sequence "
            f"was {vmins_during_read}. VMIN=1 would make read() "
            f"block forever on silence."
        )

    def test_read_line_restores_termios_on_return(self):
        """read_line must not leak VMIN=0 / VTIME=N into subsequent
        reads on the same fd.

        Bug history: commit 4e49b9c introduced VMIN=0 to fix the
        hang-on-silence bug, but did not save/restore the original
        state. The kernel-output display loop in main() then
        inherited VMIN=0 and busy-waited on quiet/disconnected
        ports. Gemini flagged it as MEDIUM. This fence pins the
        restore behavior so a future refactor can't silently drop
        the finally block.
        """
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"\n"],
            times=[0.0, 0.01, 0.02],
        )
        # Pre-populate the fake port with a distinctive initial
        # state that differs from read_line's transient config.
        import termios as _t
        fake.attrs[6][_t.VMIN] = 1
        fake.attrs[6][_t.VTIME] = 42  # distinctive marker
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            hw_send.read_line(fd=10, timeout=1.0)
        # After read_line, the port must be restored to VMIN=1 / VTIME=42.
        assert fake.attrs[6][_t.VMIN] == 1, (
            f"VMIN not restored: got {fake.attrs[6][_t.VMIN]}, "
            f"expected 1 (state leaked from read_line)"
        )
        assert fake.attrs[6][_t.VTIME] == 42, (
            f"VTIME not restored: got {fake.attrs[6][_t.VTIME]}, "
            f"expected 42 (state leaked from read_line)"
        )

    def test_read_line_restores_termios_even_on_exception(self):
        """The save/restore is in a `finally` block, so an
        exception raised by os.read mid-loop must still restore the
        original state. Without the finally, a failed read would
        leave the port in VMIN=0 forever and the exception handler
        in main() would see corrupted termios state."""
        fake, read_mock, _ = _mk_read_line_env(
            bytes_yielded=[],  # unused
            times=[0.0, 0.01],
        )
        # Configure os.read to raise instead of returning bytes.
        read_mock.side_effect = OSError(5, "Input/output error")
        import termios as _t
        fake.attrs[6][_t.VMIN] = 1
        fake.attrs[6][_t.VTIME] = 77
        time_mock = MagicMock(side_effect=[0.0, 0.01, 0.02])
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            try:
                hw_send.read_line(fd=10, timeout=1.0)
            except OSError:
                pass  # expected — we're testing the finally fires
        assert fake.attrs[6][_t.VMIN] == 1
        assert fake.attrs[6][_t.VTIME] == 77

    def test_tcsetattr_uses_tcsanow_not_tcsadrain(self):
        """read_line is about to read, not write — applying
        termios settings with TCSADRAIN waits for the TX buffer
        to drain first, which is latency we never need on a
        read-only code path. Pin TCSANOW."""
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"\n"],
            times=[0.0, 0.01, 0.02],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            hw_send.read_line(fd=10, timeout=1.0)
        import termios as _t
        # set_calls[-1] is the final tcsetattr call; [1] is `when`.
        assert fake.set_calls, "read_line should call tcsetattr"
        when = fake.set_calls[-1][1]
        assert when == _t.TCSANOW, (
            f"read_line must use TCSANOW, not {when}"
        )

    def test_read_line_caps_buffer_at_max_bytes(self):
        """A runaway stream of non-newline bytes must stop at
        _READ_LINE_MAX_BYTES instead of growing indefinitely.

        This is a defensive check against a misbehaving or
        hostile chainloader that emits an unbounded stream of
        non-newline characters. Without a cap, buf grows by one
        byte per os.read until wall-clock deadline or memory
        pressure — neither is a clean failure mode.
        """
        cap = hw_send._READ_LINE_MAX_BYTES
        # Generate cap + 50 filler bytes, none a newline. The
        # cap-th byte is where read_line should bail; everything
        # after it must not be appended.
        filler = [bytes([0x41 + (j % 26)]) for j in range(cap + 50)]
        # Time sequence: 1 for initial deadline + N for each loop
        # iteration's `time.time() < deadline` check. Keep the
        # clock well under `deadline` so the cap is the only
        # thing that can terminate the loop.
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=filler,
            times=[0.0] + [0.01] * (cap + 50),
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            result = hw_send.read_line(fd=10, timeout=1.0)
        # We should have seen exactly `cap` bytes consumed from
        # os.read — no more. Any further draining of the mock
        # would indicate the cap did not fire.
        assert read_mock.call_count == cap, (
            f"read_line consumed {read_mock.call_count} bytes; "
            f"expected exactly {cap} (the cap)"
        )
        assert len(result) == cap

    def test_non_ascii_bytes_ignored_in_decode(self):
        """The decode uses errors='ignore', so a stray high-bit
        byte in the middle of a line must be dropped from the
        returned string instead of raising UnicodeDecodeError."""
        fake, read_mock, time_mock = _mk_read_line_env(
            bytes_yielded=[b"B", b"\xff", b"O", b"O", b"T", b"\n"],
            times=[0.0, 0.01, 0.02, 0.03, 0.04, 0.05, 0.06],
        )
        with patch("hw_send.termios.tcgetattr", fake.tcgetattr), \
             patch("hw_send.termios.tcsetattr", fake.tcsetattr), \
             patch("hw_send.os.read", read_mock), \
             patch("hw_send.time.time", time_mock):
            result = hw_send.read_line(fd=10, timeout=1)
        assert result == "BOOT"


# ── open_serial ──────────────────────────────────────────────


class TestOpenSerial:

    def test_closes_fd_on_tcgetattr_failure(self):
        """If tcgetattr raises (e.g. the port vanished between
        open() and the first termios call), open_serial must
        close the fd before propagating the error — otherwise
        the caller has no way to recover the fd to clean it up.

        Reproduces the fd-leak Gemini flagged (LOW) in the
        review of commit 6c1245b.
        """
        closed_fds = []

        def tracking_close(fd):
            closed_fds.append(fd)

        with patch("hw_send.os.open", return_value=42), \
             patch("hw_send.os.close", side_effect=tracking_close), \
             patch("hw_send.termios.tcgetattr",
                   side_effect=OSError("simulated port loss")):
            try:
                hw_send.open_serial("/dev/null")
            except OSError:
                pass
        assert closed_fds == [42], (
            f"expected os.close(42) exactly once; "
            f"got calls: {closed_fds}"
        )

    def test_closes_fd_on_tcsetattr_failure(self):
        """Same guard for the tcsetattr failure path — the fd was
        opened, tcgetattr succeeded, but the driver rejects the
        new termios settings. We must not leak the fd.
        """
        closed_fds = []

        def tracking_close(fd):
            closed_fds.append(fd)

        fake_attrs = [0, 0, 0, 0, 0, 0, [0] * 32]
        with patch("hw_send.os.open", return_value=99), \
             patch("hw_send.os.close", side_effect=tracking_close), \
             patch("hw_send.termios.tcgetattr", return_value=fake_attrs), \
             patch("hw_send.termios.tcsetattr",
                   side_effect=OSError("EINVAL")):
            try:
                hw_send.open_serial("/dev/null")
            except OSError:
                pass
        assert closed_fds == [99], (
            f"expected os.close(99) exactly once; "
            f"got calls: {closed_fds}"
        )


# ── constants ────────────────────────────────────────────────

class TestConstants:
    """Pin the ioctl command constants so a future termios import
    re-shuffle can't silently invalidate set_dtr."""

    def test_tiocm_dtr_value(self):
        # Linux TIOCM_DTR bit is 0x002 — part of the stable kernel
        # ABI, not a derived constant.
        assert hw_send.TIOCM_DTR == 0x002

    def test_tiocmbis_and_tiocmbic_values(self):
        # Linux _IOW('T', 22, int) / _IOW('T', 23, int). These are
        # ABI-stable and the only reason to hardcode them here is
        # that Python's termios module doesn't expose them.
        assert hw_send.TIOCMBIS == 0x5416
        assert hw_send.TIOCMBIC == 0x5417
