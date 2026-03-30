#!/usr/bin/env python3
"""Unit tests for hw_send.py with mocked serial port."""

import sys
from unittest.mock import MagicMock

import hw_send
from intel_hex import kernel_to_hex_records


def make_port(**kwargs):
    """Create a mock serial port with sensible defaults."""
    port = MagicMock()
    port.timeout = 3
    port.readline.return_value = b''
    port.read.return_value = b''
    for key, val in kwargs.items():
        setattr(port, key, val)
    return port


# ── sync_chainloader ─────────────────────────────────────────


class TestSyncChainloader:

    def test_ready_on_first_attempt(self):
        port = make_port()
        port.readline.return_value = b'READY\r\n'
        assert hw_send.sync_chainloader(port) is True
        port.write.assert_called_with(b'\xff')

    def test_ready_after_empty_lines(self):
        port = make_port()
        port.readline.side_effect = [b'', b'READY\r\n']
        assert hw_send.sync_chainloader(port) is True

    def test_no_ready(self):
        port = make_port()
        port.readline.return_value = b''
        assert hw_send.sync_chainloader(port) is False

    def test_garbage_before_ready(self):
        port = make_port()
        port.readline.side_effect = [b'junk\r\n', b'READY\r\n']
        assert hw_send.sync_chainloader(port) is True


# ── _wait_for_ready ──────────────────────────────────────────


class TestWaitForReady:

    def test_found(self, mocker):
        mocker.patch('hw_send.time.time', side_effect=[0, 1])
        port = make_port()
        port.readline.return_value = b'READY\r\n'
        assert hw_send._wait_for_ready(port) is True

    def test_timeout(self, mocker):
        mocker.patch('hw_send.time.time', side_effect=[0, 10])
        port = make_port()
        assert hw_send._wait_for_ready(port) is False

    def test_empty_line_skipped(self, mocker):
        mocker.patch('hw_send.time.time', side_effect=[0, 1, 2])
        port = make_port()
        port.readline.side_effect = [b'\r\n', b'READY\r\n']
        assert hw_send._wait_for_ready(port) is True


# ── _send_one_record ─────────────────────────────────────────


class TestSendOneRecord:

    def test_ack(self):
        port = make_port()
        port.read.return_value = b'+'
        result = hw_send._send_one_record(port, ':00000001FF', 0)
        assert result is True

    def test_nak_then_ack(self):
        port = make_port()
        port.read.side_effect = [b'-', b'+']
        result = hw_send._send_one_record(port, ':00000001FF', 0)
        assert result is True
        assert port.write.call_count == 2

    def test_nak_exhausted(self):
        port = make_port()
        port.read.return_value = b'-'
        result = hw_send._send_one_record(port, ':00000001FF', 0)
        assert result is False

    def test_timeout(self):
        port = make_port()
        port.read.return_value = b''
        result = hw_send._send_one_record(port, ':00000001FF', 0)
        assert result is False

    def test_unexpected_byte(self):
        port = make_port()
        port.read.return_value = b'?'
        result = hw_send._send_one_record(port, ':00000001FF', 0)
        assert result is False


# ── send_hex_records ─────────────────────────────────────────


class TestSendHexRecords:

    def test_all_acked(self):
        port = make_port()
        port.read.return_value = b'+'
        records = [':020000040008F2', ':0100000055AA', ':00000001FF']
        assert hw_send.send_hex_records(port, records, 1)

    def test_failure_aborts(self):
        port = make_port()
        port.read.return_value = b''
        records = [':020000040008F2', ':0100000055AA']
        assert not hw_send.send_hex_records(port, records, 1)

    def test_progress_prints(self, capsys):
        port = make_port()
        port.read.return_value = b'+'
        # Need 100+ data records for rec_idx % 100 == 0 branch
        records = kernel_to_hex_records(b'\x00' * 1616)
        hw_send.send_hex_records(port, records, 1616)
        out = capsys.readouterr().out
        assert '/' in out


# ── wait_for_boot ────────────────────────────────────────────


class TestWaitForBoot:

    def test_boot_received(self):
        port = make_port()
        port.read.return_value = b'BOOT\r\n'
        assert hw_send.wait_for_boot(port) is True

    def test_boot_with_prefix(self):
        port = make_port()
        port.read.return_value = b'+BOOT\r\n'
        assert hw_send.wait_for_boot(port) is True

    def test_no_boot(self):
        port = make_port()
        port.read.return_value = b''
        assert hw_send.wait_for_boot(port) is False

    def test_wrong_response(self):
        port = make_port()
        port.read.return_value = b'GARBAGE\r\n'
        assert hw_send.wait_for_boot(port) is False


# ── _read_output_byte ────────────────────────────────────────


class TestReadOutputByte:

    def test_no_data(self):
        port = make_port()
        port.read.return_value = b''
        result, buf = hw_send._read_output_byte(port, "")
        assert result is None
        assert buf == ""

    def test_normal_char(self):
        port = make_port()
        port.read.return_value = b'A'
        result, buf = hw_send._read_output_byte(port, "")
        assert result is None
        assert buf == "A"

    def test_accumulate(self):
        port = make_port()
        port.read.return_value = b'B'
        result, buf = hw_send._read_output_byte(port, "A")
        assert result is None
        assert buf == "AB"

    def test_newline_resets(self):
        port = make_port()
        port.read.return_value = b'\n'
        result, buf = hw_send._read_output_byte(port, "hello")
        assert result is None
        assert buf == ""

    def test_done_detected(self):
        port = make_port()
        port.read.return_value = b'\n'
        result, buf = hw_send._read_output_byte(port, "DONE")
        assert result is True
        assert buf == ""

    def test_wait_sends_ff(self):
        port = make_port()
        port.read.return_value = b'\n'
        hw_send._read_output_byte(port, "WAIT")
        port.write.assert_called_with(b'\xff')

    def test_cr_resets(self):
        port = make_port()
        port.read.return_value = b'\r'
        result, buf = hw_send._read_output_byte(port, "stuff")
        assert result is None
        assert buf == ""


# ── collect_output ───────────────────────────────────────────


class TestCollectOutput:

    def test_done(self, mocker):
        times = [0, 1, 1, 1, 1, 1]
        mocker.patch('hw_send.time.time', side_effect=times)
        port = make_port()
        port.read.side_effect = [b'D', b'O', b'N', b'E', b'\n']
        assert hw_send.collect_output(port, 10) is True

    def test_timeout(self, mocker):
        mocker.patch('hw_send.time.time', side_effect=[0, 100])
        port = make_port()
        assert hw_send.collect_output(port, 1) is False

    def test_keyboard_interrupt(self, mocker):
        mocker.patch('hw_send.time.time', side_effect=[0, 1])
        port = make_port()
        port.read.side_effect = KeyboardInterrupt
        assert hw_send.collect_output(port, 10) is False


# ── _log_nak / _log_bad_ack ─────────────────────────────────


class TestLogHelpers:

    def test_log_nak_retryable(self, capsys):
        hw_send._log_nak(5, 0)
        assert "retry 1" in capsys.readouterr().out

    def test_log_nak_last(self, capsys):
        hw_send._log_nak(5, hw_send.MAX_RETRIES - 1)
        assert capsys.readouterr().out == ""

    def test_log_bad_ack_data(self, capsys):
        hw_send._log_bad_ack(3, b'\x99')
        assert "99" in capsys.readouterr().out

    def test_log_bad_ack_timeout(self, capsys):
        hw_send._log_bad_ack(3, b'')
        assert "Timeout" in capsys.readouterr().out


# ── _parse_args ──────────────────────────────────────────────


class TestParseArgs:

    def test_no_args(self, mocker):
        mocker.patch.object(sys, 'argv', ['hw_send.py'])
        assert hw_send._parse_args() is None

    def test_kernel_only(self, mocker):
        mocker.patch.object(sys, 'argv', ['hw_send.py', 'k.img'])
        result = hw_send._parse_args()
        assert result == ('k.img', '/dev/ttyUSB0', 15)

    def test_all_args(self, mocker):
        mocker.patch.object(
            sys, 'argv',
            ['hw_send.py', 'k.img', '/dev/tty1', '10'],
        )
        result = hw_send._parse_args()
        assert result == ('k.img', '/dev/tty1', 10)

    def test_timeout_too_high(self, mocker):
        mocker.patch.object(
            sys, 'argv',
            ['hw_send.py', 'k.img', '/dev/tty1', '256'],
        )
        assert hw_send._parse_args() is None

    def test_timeout_negative(self, mocker):
        mocker.patch.object(
            sys, 'argv',
            ['hw_send.py', 'k.img', '/dev/tty1', '-1'],
        )
        assert hw_send._parse_args() is None


# ── _print_banner ────────────────────────────────────────────


class TestPrintBanner:

    def test_with_watchdog(self, capsys):
        recs = [':020000040008F2', ':0100000055AA', ':00000001FF']
        hw_send._print_banner('k.img', '/dev/tty0', 10, b'\x00', recs)
        out = capsys.readouterr().out
        assert 'k.img' in out
        assert '10s' in out

    def test_no_watchdog(self, capsys):
        recs = [':020000040008F2', ':00000001FF']
        hw_send._print_banner('k.img', '/dev/tty0', 0, b'', recs)
        out = capsys.readouterr().out
        assert '(no watchdog)' in out


# ── main ─────────────────────────────────────────────────────


class TestMain:

    def test_no_args_returns_1(self, mocker):
        mocker.patch.object(sys, 'argv', ['hw_send.py'])
        assert hw_send.main() == 1

    def test_happy_path(self, mocker, tmp_path):
        kernel_file = tmp_path / "test.img"
        kernel_file.write_bytes(b'\x00' * 16)
        mocker.patch.object(
            sys, 'argv', ['hw_send.py', str(kernel_file)],
        )
        mocker.patch('hw_send.serial.Serial')
        mock_sync = mocker.patch(
            'hw_send.sync_chainloader', return_value=True,
        )
        mock_send = mocker.patch(
            'hw_send.send_hex_records', return_value=True,
        )
        mock_boot = mocker.patch(
            'hw_send.wait_for_boot', return_value=True,
        )
        mocker.patch('hw_send.collect_output')
        assert hw_send.main() == 0
        mock_sync.assert_called_once()
        mock_send.assert_called_once()
        mock_boot.assert_called_once()

    def test_sync_fail(self, mocker, tmp_path):
        kernel_file = tmp_path / "test.img"
        kernel_file.write_bytes(b'\x00')
        mocker.patch.object(
            sys, 'argv', ['hw_send.py', str(kernel_file)],
        )
        mocker.patch('hw_send.serial.Serial')
        mocker.patch(
            'hw_send.sync_chainloader', return_value=False,
        )
        assert hw_send.main() == 1

    def test_send_fail(self, mocker, tmp_path):
        kernel_file = tmp_path / "test.img"
        kernel_file.write_bytes(b'\x00')
        mocker.patch.object(
            sys, 'argv', ['hw_send.py', str(kernel_file)],
        )
        mocker.patch('hw_send.serial.Serial')
        mocker.patch(
            'hw_send.sync_chainloader', return_value=True,
        )
        mocker.patch(
            'hw_send.send_hex_records', return_value=False,
        )
        assert hw_send.main() == 1

    def test_boot_fail(self, mocker, tmp_path):
        kernel_file = tmp_path / "test.img"
        kernel_file.write_bytes(b'\x00')
        mocker.patch.object(
            sys, 'argv', ['hw_send.py', str(kernel_file)],
        )
        mocker.patch('hw_send.serial.Serial')
        mocker.patch(
            'hw_send.sync_chainloader', return_value=True,
        )
        mocker.patch(
            'hw_send.send_hex_records', return_value=True,
        )
        mocker.patch(
            'hw_send.wait_for_boot', return_value=False,
        )
        assert hw_send.main() == 1
