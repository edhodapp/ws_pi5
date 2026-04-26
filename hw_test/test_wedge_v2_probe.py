# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=line-too-long,too-few-public-methods
# pylint: disable=too-many-locals
# mypy: ignore-errors
# flake8: noqa: E501
"""
test_wedge_v2_probe.py — D2 confirmation probe for the concurrent-burst wedge.

Opt-in: only runs when WEDGE_V2_PROBE=1 is set. Off by default so a
normal `scripts/hw_tests.sh L4` doesn't deliberately wedge the Pi.

Hypothesis (from wedge_v2_log.md / D1):
  the wedge is TCONN pool exhaustion — 128 slots × ~60 s TIME_WAIT
  fills up after ~130 sequential connections during the L4 prefix +
  test_repeated_bursts. ICMP keeps working; TCP refuses new SYNs
  because tcp_listen finds no CLOSED slot.

This probe:
  1. Reproduces the prefix workload (5+10+15+20 conns) that on its own
     does not wedge but pre-loads the pool.
  2. Runs 10 rounds of 10 concurrent HTTP GETs.
  3. After every round, queries TCP slot state via the new
     PERF_CMD_DUMP_TCP (always-on, no PERF build needed).
  4. Logs the per-state distribution to wedge_v2_d2.log.

Theory is confirmed if TIME_WAIT count climbs toward TCP_MAX_CONNS as
the rounds progress and reaches ~127 around the round where ok < 10.
"""

import os
import socket
import threading
import time

import pytest

from conftest import (
    PI4_IP,
    PI4_HTTP_PORT,
    requires_hardware,
)

import wire

pytestmark = pytest.mark.l4

WEDGE_PROBE_LOG = "wedge_v2_d2.log"


def _http_get(addr, timeout: float = 3.0) -> bool:
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


def _concurrent_gets(addr, n: int, timeout: float = 5.0):
    results = [False] * n

    def worker(idx: int) -> None:
        results[idx] = _http_get(addr, timeout)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=timeout + 2)
    ok = sum(1 for r in results if r)
    return ok, n - ok


def _snapshot_tcp_state(eth_iface, pi_mac, laptop_mac):
    """Returns (state_dict, error_str_or_None)."""
    try:
        return wire.perf_query(
            eth_iface, pi_mac, laptop_mac,
            block="tcp", timeout_ms=500,
        ), None
    except wire.WireError as exc:
        return None, str(exc)


def _format_snap(snap):
    if snap is None:
        return "    <no reply>"
    parts = []
    for name in ("listen", "syn_rcvd", "established", "close_wait",
                 "last_ack", "fin_wait_1", "fin_wait_2", "time_wait",
                 "closing"):
        if snap[name]:
            parts.append(f"{name}={snap[name]}")
    parts.append(f"closed={snap['closed']}")
    parts.append(f"nonclosed={snap['nonclosed']}/{snap['max_conns']}")
    return "    " + " ".join(parts)


@requires_hardware
@pytest.mark.skipif(
    os.environ.get("WEDGE_V2_PROBE") != "1",
    reason="opt-in probe; set WEDGE_V2_PROBE=1 to run",
)
class TestWedgeV2Probe:

    def test_pool_state_during_repeated_bursts(
        self, eth_iface, laptop_mac, pi_mac,
    ):
        addr = (PI4_IP, PI4_HTTP_PORT)
        log_lines = []

        def log(msg: str) -> None:
            print(msg)
            log_lines.append(msg)

        log(f"=== wedge-v2 D2 probe @ {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} ===")

        # Confirm the dump is reachable before we start.
        snap0, err = _snapshot_tcp_state(eth_iface, pi_mac, laptop_mac)
        if snap0 is None:
            pytest.skip(f"perf_query(block='tcp') unreachable: {err}")
        log(f"baseline (post-boot, pre-prefix):\n{_format_snap(snap0)}")

        # Phase 1: prefix workload (5 + 10 + 15 + 20 = 50 conns).
        for n in (5, 10, 15, 20):
            ok, fail = _concurrent_gets(addr, n)
            log(f"\nPREFIX n={n}: ok={ok} fail={fail}")
            time.sleep(1.0)
            snap, err = _snapshot_tcp_state(eth_iface, pi_mac, laptop_mac)
            log(_format_snap(snap) if snap else f"    <query err: {err}>")

        # Phase 2: 10 rounds of 10 concurrent — the wedger.
        for i in range(10):
            ok, fail = _concurrent_gets(addr, 10)
            log(f"\nREPEATED_BURST round={i+1}/10: ok={ok} fail={fail}")
            time.sleep(0.5)
            snap, err = _snapshot_tcp_state(eth_iface, pi_mac, laptop_mac)
            log(_format_snap(snap) if snap else f"    <query err: {err}>")

        # Final state.
        time.sleep(1.0)
        snap_final, err = _snapshot_tcp_state(eth_iface, pi_mac, laptop_mac)
        log("\nFINAL state:")
        log(_format_snap(snap_final) if snap_final else f"    <query err: {err}>")

        with open(WEDGE_PROBE_LOG, "w", encoding="utf-8") as fh:
            fh.write("\n".join(log_lines) + "\n")
        log(f"\n[probe log written to {WEDGE_PROBE_LOG}]")

        # The probe is informational — we do NOT assert on the wedge
        # itself, just on the underlying tooling working. The TIME_WAIT
        # climb and the wedge-onset round are read off the log.
        assert snap_final is not None, "perf_query(tcp) unreachable at end"
        assert snap_final["max_conns"] == 128, (
            f"unexpected max_conns={snap_final['max_conns']} "
            f"— TCP_MAX_CONNS != 128?"
        )
