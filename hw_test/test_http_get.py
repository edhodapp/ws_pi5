"""
test_http_get.py — HTTP GET integration tests

Verifies the Pi 4 serves correct HTTP responses.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=unused-import,inconsistent-quotes,line-too-long
# mypy: ignore-errors
#
# hw_test integration tests pre-date the type-annotation and strict-
# style push; matches the pattern established in conftest.py. The
# unused-import disable covers names re-exported for test discovery
# and legacy scaffolding that other tests in this file reference.

import http.client
from conftest import (  # noqa: F401
    requires_hardware, PI4_IP, PI4_HTTP_PORT, TEST_TIMEOUT,
)


@requires_hardware
class TestHTTPGet:

    def _get(self, path: str, host: str = None) -> http.client.HTTPResponse:
        """Helper: send GET request, return (response, connection).

        Opens the connection and issues the request; the caller is
        responsible for calling conn.close(). If request/getresponse
        raises, the connection is closed before propagating — otherwise
        a transient error on open would leak the socket past the
        caller's try/finally (which runs only when a conn was returned).
        """
        conn = http.client.HTTPConnection(
            PI4_IP, PI4_HTTP_PORT, timeout=TEST_TIMEOUT,
        )
        try:
            headers = {}
            if host:
                headers["Host"] = host
            conn.request("GET", path, headers=headers)
            resp = conn.getresponse()
        except Exception:
            conn.close()
            raise
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

    def test_get_root_connection_keepalive(self):
        """GET / on HTTP/1.1 is persistent by default — server must NOT
        advertise Connection: close unless the client asked for it."""
        resp, conn = self._get("/")
        try:
            connection = resp.getheader("Connection")
            # Either absent (implicit keep-alive) or explicitly keep-alive,
            # but not "close" — that would break HTTP/1.1 pipelining.
            if connection is not None:
                assert connection.lower() != "close", (
                    f"HTTP/1.1 keep-alive expected, got Connection: "
                    f"{connection!r}"
                )
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

    def test_post_returns_405_with_allow(self):
        """POST / returns 405 Method Not Allowed with an Allow header
        that reflects the route's actual accepted methods (GET+HEAD).
        Previously the test expected 404, but after the per-route
        method allow-list landed the server correctly returns 405."""
        conn = http.client.HTTPConnection(
            PI4_IP, PI4_HTTP_PORT, timeout=TEST_TIMEOUT,
        )
        try:
            conn.request("POST", "/", headers={"Content-Length": "0"})
            resp = conn.getresponse()
            assert resp.status == 405, (
                f"expected 405, got {resp.status}"
            )
            allow = resp.getheader("Allow")
            assert allow is not None, "Missing Allow header on 405"
            # Route "/" accepts GET and HEAD; Allow must NOT advertise POST.
            assert "POST" not in allow, (
                f"Allow should not advertise POST for a GET-only route, "
                f"got {allow!r}"
            )
        finally:
            conn.close()
