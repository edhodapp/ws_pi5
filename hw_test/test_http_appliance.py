"""
test_http_appliance.py — integration tests for the appliance feature set

Exercises routes and behaviors specific to the default (un-packaged)
kernel build: per-route Content-Type, dynamic /status, counter handler
with query-string split, guestbook store with XSS escape, form_log,
method allow-list edges, and raw-socket checks for 411 / 413 /
duplicate Content-Length. Complements test_http_get.py which pins the
core GET / 404 / root-route contract.

Every test assumes the Pi 4 is running the default build
(`make PLATFORM=pi4`). The same test module would report false
failures against a packaged kernel, since packaging replaces the
built-in route table entirely — that is an intended property of the
packaged-appliance workflow and not a test bug.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=unused-import,inconsistent-quotes,line-too-long
# mypy: ignore-errors

import http.client
import socket

from conftest import (  # noqa: F401
    requires_hardware, PI4_IP, PI4_HTTP_PORT, TEST_TIMEOUT,
)


def _req(method, path, body=None, headers=None):
    """Issue one HTTP request; return (status, headers_dict, body_bytes)."""
    conn = http.client.HTTPConnection(
        PI4_IP, PI4_HTTP_PORT, timeout=TEST_TIMEOUT,
    )
    try:
        hdrs = dict(headers or {})
        hdrs.setdefault("Host", PI4_IP)
        if body is not None and "Content-Length" not in hdrs:
            hdrs["Content-Length"] = str(len(body))
        conn.request(method, path, body=body, headers=hdrs)
        resp = conn.getresponse()
        data = resp.read()
        return resp.status, dict(resp.getheaders()), data
    finally:
        conn.close()


def _raw(req_bytes):
    """Send raw bytes; return (headers_bytes, body_bytes).

    Used where the stdlib client would refuse to build the request
    (duplicate Content-Length, bodyless POST, etc.).
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(TEST_TIMEOUT)
    try:
        sock.connect((PI4_IP, PI4_HTTP_PORT))
        sock.sendall(req_bytes)
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    finally:
        sock.close()
    split = data.find(b"\r\n\r\n")
    if split < 0:
        return data, b""
    return data[:split], data[split + 4:]


@requires_hardware
class TestStaticRoutes:

    def test_about_200(self):
        status, _, _ = _req("GET", "/about")
        assert status == 200

    def test_test_css_content_type(self):
        """The /_test_css route asserts the per-route Content-Type path:
        response header MUST be text/css with the packaged CSS bytes."""
        status, hdrs, body = _req("GET", "/_test_css")
        assert status == 200
        assert hdrs.get("Content-Type") == "text/css"
        assert body == b"body{color:#333;}\n"


@requires_hardware
class TestStatusDynamic:

    def test_status_chunked(self):
        """The dynamic /status route MUST use chunked transfer encoding
        (the runtime body length is not known up front)."""
        status, hdrs, body = _req("GET", "/status")
        assert status == 200
        assert hdrs.get("Transfer-Encoding", "").lower() == "chunked"
        assert len(body) > 0


@requires_hardware
class TestCounter:

    def test_counter_emits_integer(self):
        _, _, body = _req("GET", "/counter")
        assert body.strip().isdigit(), f"non-integer body: {body!r}"

    def test_counter_increments_across_calls(self):
        _, _, before = _req("GET", "/counter")
        _, _, after = _req("GET", "/counter")
        assert int(after) > int(before), (
            f"counter did not increment: {before!r} -> {after!r}"
        )

    def test_counter_query_string_stripped(self):
        """A query string MUST NOT break route matching — the counter
        still dispatches and returns an integer body."""
        status, _, body = _req("GET", "/counter?foo=bar")
        assert status == 200
        assert body.strip().isdigit(), f"non-integer body: {body!r}"


@requires_hardware
class TestGuestbook:

    def test_post_then_get_renders_message(self):
        msg = b"smoke-hello"
        status, _, _ = _req("POST", "/guestbook", body=msg)
        assert status == 200
        status, _, body = _req("GET", "/guestbook")
        assert status == 200
        assert msg in body, f"posted message missing: tail={body[-80:]!r}"

    def test_post_html_payload_is_escaped(self):
        """Posting <script>…</script> MUST be HTML-escaped on render —
        reflecting the exact posted bytes would be XSS. Pin both halves:
        the unescaped payload MUST be absent AND the escaped form MUST
        be present, so a test that merely drops the message entirely
        can't pass by accident."""
        payload = b"<script>xss_probe_77</script>"
        escaped = b"&lt;script&gt;xss_probe_77&lt;/script&gt;"
        _req("POST", "/guestbook", body=payload)
        _, _, body = _req("GET", "/guestbook")
        assert payload not in body, (
            f"unescaped payload reflected in response: body={body!r}"
        )
        assert escaped in body, (
            f"escaped form missing: body={body!r}"
        )


@requires_hardware
class TestFormLog:

    def test_post_form_log_200(self):
        status, _, _ = _req(
            "POST", "/form_log", body=b"name=alice&msg=hi",
        )
        assert status == 200


@requires_hardware
class TestMethodAllowList:

    def test_post_about_405(self):
        """POST to a GET/HEAD-only route MUST return 405, not 200."""
        status, _, _ = _req("POST", "/about")
        assert status == 405


@requires_hardware
class TestPostEcho:

    def test_echo_returns_body(self):
        status, _, body = _req("POST", "/_test_echo", body=b"ping")
        assert status == 200
        assert b"ping" in body, f"echo body missing 'ping': {body!r}"


@requires_hardware
class TestPostErrorPaths:

    def test_post_without_content_length_411(self):
        headers, _ = _raw(
            b"POST /_test_echo HTTP/1.1\r\nHost: x\r\n"
            b"Connection: close\r\n\r\n"
        )
        status_line = headers.split(b"\r\n", 1)[0]
        assert b"411" in status_line, f"expected 411: {status_line!r}"

    def test_post_oversize_content_length_413(self):
        headers, _ = _raw(
            b"POST /_test_echo HTTP/1.1\r\nHost: x\r\n"
            b"Connection: close\r\n"
            b"Content-Length: 2000\r\n\r\n"
        )
        status_line = headers.split(b"\r\n", 1)[0]
        assert b"413" in status_line, f"expected 413: {status_line!r}"

    def test_duplicate_content_length_400(self):
        headers, _ = _raw(
            b"POST /_test_echo HTTP/1.1\r\nHost: x\r\n"
            b"Connection: close\r\n"
            b"Content-Length: 5\r\nContent-Length: 99\r\n\r\nhello"
        )
        status_line = headers.split(b"\r\n", 1)[0]
        assert b"400" in status_line, f"expected 400: {status_line!r}"
