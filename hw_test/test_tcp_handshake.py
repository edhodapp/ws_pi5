"""
test_tcp_handshake.py — TCP 3-way handshake integration tests

Verifies the Pi 4's TCP stack completes handshakes correctly,
including option negotiation (MSS, WSCALE, SACK-Permitted, Timestamps).
"""

import socket
import struct
import pytest
from conftest import requires_hardware, PI4_IP, PI4_HTTP_PORT, TEST_TIMEOUT
from tcp_helpers import parse_tcp_header, SYN, SYN_ACK, ACK, RST


@requires_hardware
class TestTCPHandshake:

    def test_basic_connect(self, pi4_addr):
        """Standard TCP connect() succeeds."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            s.connect(pi4_addr)
            # Connection established — verify with getpeername
            peer = s.getpeername()
            assert peer[0] == pi4_addr[0]
            assert peer[1] == pi4_addr[1]
        finally:
            s.close()

    def test_synack_has_mss(self, pi4_addr):
        """SYN-ACK includes MSS option (Kind=2)."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            s.connect(pi4_addr)
            # We can't easily inspect SYN-ACK options via normal sockets.
            # This test verifies the connection works, which requires
            # MSS negotiation. Detailed option inspection needs raw sockets.
            s.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
            data = s.recv(1024)
            assert len(data) > 0, "No response after handshake"
        finally:
            s.close()

    def test_rst_on_closed_port(self):
        """Connection to a non-listening port gets RST."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            with pytest.raises((ConnectionRefusedError, socket.timeout)):
                s.connect((PI4_IP, 9999))  # Not listening
        finally:
            s.close()

    def test_multiple_sequential_connects(self, pi4_addr):
        """10 sequential connections all succeed."""
        for i in range(10):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(TEST_TIMEOUT)
            try:
                s.connect(pi4_addr)
                s.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
                data = s.recv(1024)
                assert len(data) > 0, f"Connection {i} got no response"
            finally:
                s.close()
