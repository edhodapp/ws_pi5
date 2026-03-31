"""
test_tcp_data.py — TCP data transfer integration tests

Verifies data delivery, window management, and connection lifecycle
on real hardware.
"""

import socket
import time
import pytest
from conftest import requires_hardware, PI4_IP, PI4_HTTP_PORT, TEST_TIMEOUT


@requires_hardware
class TestTCPData:

    def test_send_receive_basic(self, pi4_addr):
        """Send HTTP request, receive complete response."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            s.connect(pi4_addr)
            s.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")

            # Receive all data until connection closes
            chunks = []
            while True:
                try:
                    data = s.recv(4096)
                    if not data:
                        break
                    chunks.append(data)
                except socket.timeout:
                    break

            response = b"".join(chunks)
            assert b"HTTP/1.1 200" in response
            assert b"</html>" in response.lower()
        finally:
            s.close()

    def test_server_closes_after_response(self, pi4_addr):
        """Server closes connection after sending response (Connection: close)."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            s.connect(pi4_addr)
            s.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")

            # Read until EOF
            response = b""
            while True:
                try:
                    data = s.recv(4096)
                    if not data:
                        break
                    response += data
                except socket.timeout:
                    pytest.fail("Server did not close connection")

            assert b"HTTP/1." in response, (
                f"Expected HTTP response, got {response[:40]!r}"
            )
        finally:
            s.close()

    def test_partial_request(self, pi4_addr):
        """Send request in two parts with delay — server waits for full headers."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT * 2)
        try:
            s.connect(pi4_addr)

            # Send first half
            s.sendall(b"GET / HTTP/1.1\r\n")
            time.sleep(0.5)

            # Send rest
            s.sendall(b"Host: test\r\n\r\n")

            # Should still get a response
            data = s.recv(4096)
            assert b"HTTP/1.1 200" in data
        finally:
            s.close()

    def test_large_header(self, pi4_addr):
        """Request with many headers (tests rx buffer capacity)."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            s.connect(pi4_addr)

            # Build request with ~1 KB of headers
            headers = "GET / HTTP/1.1\r\n"
            for i in range(20):
                headers += f"X-Test-{i}: {'A' * 40}\r\n"
            headers += "\r\n"

            s.sendall(headers.encode())
            data = s.recv(4096)
            assert b"HTTP/1.1 200" in data
        finally:
            s.close()

    def test_rapid_connect_disconnect(self, pi4_addr):
        """100 rapid connect/disconnect cycles — most should succeed."""
        connected = 0
        refused = 0
        for i in range(100):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(TEST_TIMEOUT)
            try:
                s.connect(pi4_addr)
                connected += 1
                s.close()
            except (ConnectionRefusedError, socket.timeout):
                refused += 1

        assert connected >= 50, (
            f"Too many refused: {connected} connected, {refused} refused"
        )

        # Server should still be alive
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            s.connect(pi4_addr)
            s.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
            data = s.recv(1024)
            assert b"HTTP/1.1" in data
        finally:
            s.close()
