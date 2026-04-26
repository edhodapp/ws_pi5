# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=unused-import,unused-variable,inconsistent-quotes
# pylint: disable=line-too-long
# mypy: ignore-errors
"""
test_tcp_concurrent.py — Concurrent TCP connection wedge test.

The Pi historically wedges after ~10 concurrent HTTP connections.
This test reproduces that scenario and verifies the Pi survives.
Uses kernel TCP sockets (the full stack is under test).

After each concurrent burst, verify the Pi still responds to ICMP
(L3 liveness) and can accept a new TCP connection (L4 liveness).
"""

import socket
import threading
import time

import pytest

from conftest import (
    PI4_IP,
    PI4_HTTP_PORT,
    requires_hardware,
)
from icmp_helpers import send_echo_and_wait

pytestmark = pytest.mark.l4


def _http_get(addr: tuple[str, int], timeout: float = 3.0) -> bool:
    """Attempt a complete HTTP GET. Returns True on success."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(addr)
        s.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
        data = b""
        while True:
            try:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            except socket.timeout:
                break
        return b"HTTP/1.1 200" in data
    except (ConnectionRefusedError, socket.timeout, OSError):
        return False
    finally:
        s.close()


def _concurrent_gets(
    addr: tuple[str, int],
    n: int,
    timeout: float = 5.0,
) -> tuple[int, int]:
    """Launch N concurrent HTTP GETs. Returns (success, fail) counts."""
    results: list[bool] = [False] * n

    def worker(idx: int) -> None:
        results[idx] = _http_get(addr, timeout)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=timeout + 2)

    ok = sum(1 for r in results if r)
    return ok, n - ok


def _verify_l3_alive(
    eth_iface: str,
    pi_mac: bytes,
    laptop_mac: bytes,
    laptop_ip: str,
    rtt_p99_ms: float,
    *,
    tag: str,
) -> None:
    """Assert the Pi responds to ICMP echo (L3 liveness)."""
    deadline = int(max(20.0 * rtt_p99_ms, 2000.0))
    reply = send_echo_and_wait(
        eth_iface,
        pi_mac=pi_mac, laptop_mac=laptop_mac,
        pi_ip=PI4_IP, laptop_ip=laptop_ip,
        ident=0xBEEF, seq=1, payload=b"alive?",
        deadline_ms=deadline,
    )
    assert reply is not None, (
        f"Pi did not respond to ping after {tag} "
        f"(waited {deadline} ms) — GENET wedge?"
    )


def _verify_l4_alive(addr: tuple[str, int]) -> None:
    """Assert the Pi accepts a new TCP connection (L4 liveness)."""
    ok = _http_get(addr, timeout=5.0)
    assert ok, "Pi did not respond to HTTP after concurrent burst"


@requires_hardware
class TestTCPConcurrentBurst:
    """Send concurrent HTTP connections and verify the Pi survives.

    This is the scenario that historically wedges the GENET.
    The test progressively increases concurrency.
    """

    @pytest.mark.parametrize("n", [5, 10, 15, 20])
    def test_concurrent_burst_survives(
        self, n,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """N concurrent HTTP GETs; Pi must survive."""
        addr = (PI4_IP, PI4_HTTP_PORT)

        ok, fail = _concurrent_gets(addr, n)
        print(
            f"CONCURRENT: n={n} ok={ok} fail={fail}"
        )

        # Some connections may fail under load — that's fine.
        # The critical assertion is that the Pi is still alive.
        time.sleep(1.0)

        _verify_l3_alive(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            rtt_p99_ms, tag=f"concurrent burst N={n}",
        )
        _verify_l4_alive(addr)

    def test_repeated_bursts(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """10 rounds of 10 concurrent connections. Stresses close-path
        state cleanup across repeated bursts.
        """
        addr = (PI4_IP, PI4_HTTP_PORT)

        for i in range(10):
            ok, fail = _concurrent_gets(addr, 10)
            print(
                f"REPEATED_BURST: round={i+1}/10 ok={ok} fail={fail}"
            )
            time.sleep(0.5)

        # Final liveness check
        time.sleep(1.0)
        _verify_l3_alive(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            rtt_p99_ms, tag="repeated bursts (10x10)",
        )
        _verify_l4_alive(addr)
