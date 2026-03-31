"""
test_http_concurrent.py — Concurrent HTTP connection tests

Verifies the Pi 4 handles multiple simultaneous connections correctly.
"""

import http.client
import socket
import threading
import time
import pytest
from conftest import requires_hardware, PI4_IP, PI4_HTTP_PORT, TEST_TIMEOUT


@requires_hardware
class TestHTTPConcurrent:

    def _fetch(self, results: list, index: int):
        """Thread worker: fetch GET / and store result."""
        try:
            conn = http.client.HTTPConnection(PI4_IP, PI4_HTTP_PORT,
                                               timeout=TEST_TIMEOUT)
            conn.request("GET", "/")
            resp = conn.getresponse()
            body = resp.read()
            results[index] = {
                'status': resp.status,
                'body_len': len(body),
                'error': None,
            }
            conn.close()
        except Exception as e:
            results[index] = {
                'status': 0,
                'body_len': 0,
                'error': str(e),
            }

    def test_10_concurrent(self):
        """10 simultaneous GET / requests all get 200 OK."""
        n = 10
        results = [None] * n
        threads = []

        for i in range(n):
            t = threading.Thread(target=self._fetch, args=(results, i))
            threads.append(t)

        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=TEST_TIMEOUT * 2)

        for i, r in enumerate(results):
            assert r is not None, f"Thread {i} did not complete"
            assert r['error'] is None, f"Thread {i} error: {r['error']}"
            assert r['status'] == 200, f"Thread {i} status: {r['status']}"
            assert r['body_len'] > 0, f"Thread {i} empty body"

    def test_50_concurrent(self):
        """50 simultaneous connections."""
        n = 50
        results = [None] * n
        threads = []

        for i in range(n):
            t = threading.Thread(target=self._fetch, args=(results, i))
            threads.append(t)

        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=TEST_TIMEOUT * 3)

        successes = sum(1 for r in results
                       if r and r['error'] is None and r['status'] == 200)
        assert successes == n, f"Only {successes}/{n} succeeded"

    def test_sequential_after_concurrent(self):
        """Server still works after burst of concurrent connections."""
        # Burst
        n = 20
        results = [None] * n
        threads = []
        for i in range(n):
            t = threading.Thread(target=self._fetch, args=(results, i))
            threads.append(t)
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=TEST_TIMEOUT * 2)

        # Assert on burst results — at least half should succeed
        burst_ok = sum(1 for r in results
                       if r and r['error'] is None and r['status'] == 200)
        assert burst_ok >= n // 2, (
            f"Burst: only {burst_ok}/{n} succeeded"
        )

        # Sequential follow-up
        time.sleep(0.5)
        conn = http.client.HTTPConnection(PI4_IP, PI4_HTTP_PORT,
                                           timeout=TEST_TIMEOUT)
        conn.request("GET", "/")
        resp = conn.getresponse()
        assert resp.status == 200
        conn.close()
