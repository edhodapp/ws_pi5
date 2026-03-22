"""
test_http_get.py — HTTP GET integration tests

Verifies the Pi 4 serves correct HTTP responses.
"""

import http.client
import socket
import pytest
from conftest import requires_hardware, PI4_IP, PI4_HTTP_PORT, TEST_TIMEOUT


@requires_hardware
class TestHTTPGet:

    def _get(self, path: str, host: str = None) -> http.client.HTTPResponse:
        """Helper: send GET request, return response."""
        conn = http.client.HTTPConnection(PI4_IP, PI4_HTTP_PORT,
                                           timeout=TEST_TIMEOUT)
        headers = {}
        if host:
            headers["Host"] = host
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        return resp, conn

    def test_get_root_200(self):
        """GET / returns 200 OK."""
        resp, conn = self._get("/")
        try:
            assert resp.status == 200
            assert resp.reason == "OK"
        finally:
            conn.close()

    def test_get_root_body(self):
        """GET / body contains expected content."""
        resp, conn = self._get("/")
        try:
            body = resp.read()
            assert b"bare-metal" in body.lower() or b"Pi" in body
            assert b"<html>" in body.lower() or b"<!doctype" in body.lower()
        finally:
            conn.close()

    def test_get_root_content_length(self):
        """GET / has Content-Length header matching body."""
        resp, conn = self._get("/")
        try:
            body = resp.read()
            content_length = resp.getheader("Content-Length")
            assert content_length is not None, "Missing Content-Length header"
            assert int(content_length) == len(body)
        finally:
            conn.close()

    def test_get_root_content_type(self):
        """GET / has text/html content type."""
        resp, conn = self._get("/")
        try:
            ct = resp.getheader("Content-Type")
            assert ct is not None
            assert "text/html" in ct
        finally:
            conn.close()

    def test_get_root_connection_close(self):
        """GET / has Connection: close header."""
        resp, conn = self._get("/")
        try:
            connection = resp.getheader("Connection")
            assert connection is not None
            assert connection.lower() == "close"
        finally:
            conn.close()

    def test_get_404(self):
        """GET /notfound returns 404."""
        resp, conn = self._get("/notfound")
        try:
            assert resp.status == 404
        finally:
            conn.close()

    def test_get_404_body(self):
        """GET /notfound returns HTML error page."""
        resp, conn = self._get("/notfound")
        try:
            body = resp.read()
            assert b"404" in body
        finally:
            conn.close()

    def test_post_returns_404(self):
        """POST / returns 404 (only GET supported)."""
        conn = http.client.HTTPConnection(PI4_IP, PI4_HTTP_PORT,
                                           timeout=TEST_TIMEOUT)
        try:
            conn.request("POST", "/")
            resp = conn.getresponse()
            # Our server treats non-GET as 404
            assert resp.status == 404
        finally:
            conn.close()
