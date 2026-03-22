"""
test_https.py — HTTPS/TLS integration tests (placeholder)

These tests will be enabled once TLS 1.3 is implemented.
For now they serve as the specification for what we need to verify.
"""

import ssl
import socket
import pytest
from conftest import requires_hardware, PI4_IP, TEST_TIMEOUT


HTTPS_PORT = 443


@requires_hardware
@pytest.mark.skip(reason="TLS 1.3 not yet implemented")
class TestHTTPS:

    def _create_tls_context(self):
        """Create a TLS context that accepts the Pi 4's self-signed cert."""
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE  # Self-signed cert
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        return ctx

    def test_tls_handshake(self):
        """TLS 1.3 handshake completes."""
        ctx = self._create_tls_context()
        with socket.create_connection((PI4_IP, HTTPS_PORT), timeout=TEST_TIMEOUT) as sock:
            with ctx.wrap_socket(sock, server_hostname=PI4_IP) as ssock:
                assert ssock.version() == "TLSv1.3"

    def test_https_get_200(self):
        """HTTPS GET / returns 200 OK."""
        ctx = self._create_tls_context()
        with socket.create_connection((PI4_IP, HTTPS_PORT), timeout=TEST_TIMEOUT) as sock:
            with ctx.wrap_socket(sock, server_hostname=PI4_IP) as ssock:
                ssock.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
                data = ssock.recv(4096)
                assert b"HTTP/1.1 200" in data

    def test_tls_cipher_suite(self):
        """Negotiated cipher is AES-128-GCM or CHACHA20-POLY1305."""
        ctx = self._create_tls_context()
        with socket.create_connection((PI4_IP, HTTPS_PORT), timeout=TEST_TIMEOUT) as sock:
            with ctx.wrap_socket(sock, server_hostname=PI4_IP) as ssock:
                cipher = ssock.cipher()
                assert cipher is not None
                name = cipher[0]
                assert "AES" in name or "CHACHA" in name

    def test_https_concurrent(self):
        """5 simultaneous HTTPS connections."""
        import threading
        results = [None] * 5

        def fetch(i):
            try:
                ctx = self._create_tls_context()
                with socket.create_connection((PI4_IP, HTTPS_PORT), timeout=TEST_TIMEOUT) as sock:
                    with ctx.wrap_socket(sock, server_hostname=PI4_IP) as ssock:
                        ssock.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
                        data = ssock.recv(4096)
                        results[i] = b"200" in data
            except Exception:
                results[i] = False

        threads = [threading.Thread(target=fetch, args=(i,)) for i in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=TEST_TIMEOUT * 2)

        assert all(r is True for r in results)
