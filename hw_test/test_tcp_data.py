"""
test_tcp_data.py — TCP data transfer integration tests

Verifies data delivery, window management, and connection lifecycle
on real hardware.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=unused-import,unused-variable,inconsistent-quotes
# pylint: disable=line-too-long
# mypy: ignore-errors
#
# hw_test integration tests pre-date the type-annotation and strict-
# style push; matches the pattern established in conftest.py.

import socket
import time
import pytest  # noqa: F401
from conftest import (  # noqa: F401
    requires_hardware, PI4_IP, PI4_HTTP_PORT, TEST_TIMEOUT,
)


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

    def test_server_closes_when_client_asks(self, pi4_addr):
        """Server closes the connection only when the client requests
        it via `Connection: close`. HTTP/1.1 is persistent by default,
        so a bare GET must NOT trigger a close. Previously this test
        expected close-by-default; corrected to match RFC 7230."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            s.connect(pi4_addr)
            s.sendall(
                b"GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n"
            )

            response = b""
            while True:
                try:
                    data = s.recv(4096)
                    if not data:
                        break
                    response += data
                except socket.timeout:
                    pytest.fail(
                        "Server did not close after Connection: close"
                    )

            assert b"HTTP/1." in response, (
                f"Expected HTTP response, got {response[:40]!r}"
            )
        finally:
            s.close()

    def test_partial_request(self, pi4_addr):
        """Send request in two parts with delay — server waits for
        full headers before dispatching."""
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
        """Request with many extra headers (tests rx buffer capacity).

        Previously omitted a Host header, which makes the server
        correctly reject HTTP/1.1 with 400 per RFC 7230 §5.4. Corrected
        to include Host — the test's actual intent is to exercise the
        parser across a large but well-formed request."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TEST_TIMEOUT)
        try:
            s.connect(pi4_addr)

            headers = "GET / HTTP/1.1\r\nHost: test\r\n"
            for i in range(20):
                headers += f"X-Test-{i}: {'A' * 40}\r\n"
            headers += "\r\n"

            s.sendall(headers.encode())
            data = s.recv(4096)
            assert b"HTTP/1.1 200" in data, (
                f"Expected 200 OK for large-but-valid request, got "
                f"{data[:80]!r}"
            )
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
