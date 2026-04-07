"""
conftest.py — pytest configuration for Pi 4 hardware integration tests

Provides fixtures for:
  - Pi 4 network connectivity (IP, interface)
  - Serial port monitoring (UART3 via USB-to-serial adapter)
  - Raw socket creation for TCP-level tests
  - Skip markers when hardware is not connected
"""

import os
import socket
import subprocess
import pytest

# --- Configuration (override via environment) ---

PI4_IP = os.environ.get("PI4_IP", "10.0.0.2")
PI4_HTTP_PORT = int(os.environ.get("PI4_HTTP_PORT", "80"))
PI4_SERIAL = os.environ.get("PI4_SERIAL", "/dev/ttyUSB0")
PI4_SERIAL_BAUD = int(os.environ.get("PI4_SERIAL_BAUD", "115200"))
GATEWAY_IP = os.environ.get("GATEWAY_IP", "10.0.0.1")
TEST_TIMEOUT = int(os.environ.get("TEST_TIMEOUT", "5"))


def is_pi4_reachable():
    """Check if the Pi 4 responds to a TCP SYN on port 80."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2)
        result = s.connect_ex((PI4_IP, PI4_HTTP_PORT))
        s.close()
        return result == 0
    except (socket.timeout, OSError):
        return False


def is_pi4_pingable():
    """Check if the Pi 4 responds to ICMP echo."""
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "2", PI4_IP],
            capture_output=True, timeout=5
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


# --- Markers ---

requires_hardware = pytest.mark.skipif(
    os.environ.get("HW_TEST", "") != "1",
    reason="Set HW_TEST=1 to run hardware integration tests"
)


# --- Fixtures ---

@pytest.fixture
def pi4_ip():
    """Return the Pi 4's IP address."""
    return PI4_IP


@pytest.fixture
def pi4_http_port():
    """Return the Pi 4's HTTP port."""
    return PI4_HTTP_PORT


@pytest.fixture
def pi4_addr(pi4_ip, pi4_http_port):
    """Return (ip, port) tuple for the Pi 4 HTTP server."""
    return (pi4_ip, pi4_http_port)


@pytest.fixture
def tcp_socket(pi4_ip):
    """Create a TCP socket connected to the Pi 4."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TEST_TIMEOUT)
    yield s
    s.close()


@pytest.fixture
def raw_socket():
    """Create a raw IP socket for crafting TCP segments.
    Requires root or CAP_NET_RAW."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
        s.settimeout(TEST_TIMEOUT)
        yield s
        s.close()
    except PermissionError:
        pytest.skip("Raw socket requires root or CAP_NET_RAW")


@pytest.fixture
def serial_port():
    """Open the Pi 4 UART serial port for monitoring."""
    try:
        import serial
        ser = serial.Serial(PI4_SERIAL, PI4_SERIAL_BAUD, timeout=2)
        yield ser
        ser.close()
    except (ImportError, OSError) as e:
        pytest.skip(f"Serial port not available: {e}")
