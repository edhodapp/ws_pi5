# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=subprocess-run-check
# mypy: ignore-errors
"""
test_ping.py — ICMP echo request/reply integration test

Verifies the Pi 4 responds to ping via the network stack.
"""

import subprocess
import pytest
from conftest import requires_hardware, PI4_IP

pytestmark = pytest.mark.l3


@requires_hardware
class TestPing:

    def test_single_ping(self):
        """Single ICMP echo request gets a reply."""
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "3", PI4_IP],
            capture_output=True, text=True, timeout=10
        )
        assert result.returncode == 0, f"Ping failed: {result.stderr}"

    def test_ping_5_packets(self):
        """5 consecutive pings, 0% loss."""
        result = subprocess.run(
            ["ping", "-c", "5", "-W", "2", PI4_IP],
            capture_output=True, text=True, timeout=30
        )
        assert result.returncode == 0
        assert "0% packet loss" in result.stdout

    def test_ping_payload_size(self):
        """Ping with 1000-byte payload (tests IP fragmentation handling)."""
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "3", "-s", "1000", PI4_IP],
            capture_output=True, text=True, timeout=10
        )
        assert result.returncode == 0
