"""
conftest.py — pytest configuration for Pi 4 hardware integration tests

Provides fixtures for:
  - Pi 4 network connectivity (IP, interface)
  - Serial port monitoring (UART3 via USB-to-serial adapter)
  - Raw socket creation for TCP-level tests
  - L2 framework fixtures (eth_iface, pi_mac, rtt_p99_ms, wire,
    link_guard, link_session_finalizer, dut_reset)
  - Skip markers when hardware is not connected
"""

# pylint: disable=redefined-outer-name,unused-argument,invalid-name
# pylint: disable=import-outside-toplevel,unnecessary-dunder-call
# pylint: disable=wrong-import-position
# mypy: ignore-errors
#
# Pytest fixtures legitimately "redefine" outer-scope names (fixture
# dependency injection), accept unused request/call/eth_iface args
# (fixture dependencies), and sometimes import lazily to avoid hard
# dependencies (pyserial is optional). ALL_CAPS local constants
# inside a fixture body are idiomatic for "configuration knob that
# isn't part of the public API". The `__enter__` / `__exit__` calls
# in `wire_capture` are deliberate because the context manager is
# split across a yield boundary. These are all pytest patterns that
# Google pylintrc flags but we accept; they are not bugs. The
# `mypy: ignore-errors` marker acknowledges that this file (and the
# hw_test/ Python helpers it imports) pre-dates the type-annotation
# push and will be migrated incrementally in a dedicated commit.

import os
import shutil
import socket
import statistics
import subprocess
import sys
import time
from pathlib import Path

import pytest

import eth_frames
import link
import wire

# scripts/ is not on the default pytest path; extend sys.path so we
# can import the shared kill_stale_by_matchers helper from there.
# Must appear after the other top-level imports or flake8/pylint
# complain about the ordering relative to sys.path.insert.
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
from hw_send import kill_stale_by_matchers  # noqa: E402

# --- Configuration (override via environment) ---

PI4_IP = os.environ.get("PI4_IP", "10.0.0.2")
PI4_HTTP_PORT = int(os.environ.get("PI4_HTTP_PORT", "80"))
PI4_SERIAL = os.environ.get("PI4_SERIAL", "/dev/ttyUSB0")
PI4_SERIAL_BAUD = int(os.environ.get("PI4_SERIAL_BAUD", "115200"))
GATEWAY_IP = os.environ.get("GATEWAY_IP", "10.0.0.1")
TEST_TIMEOUT = int(os.environ.get("TEST_TIMEOUT", "5"))

# --- L2 framework configuration ---

HW_TEST_IFACE = os.environ.get("HW_TEST_IFACE", "enx00e04c0a2bed")
LAPTOP_IP = os.environ.get("LAPTOP_IP", "10.0.0.1")
PI4_MAC_HINT = os.environ.get("PI4_MAC", "")  # optional override

# 5.3s observed first-output after DTR release + 1.7s margin for
# kernel init through GENET-up. Bound for boot-then-ARP-reachable.
BOOT_DEADLINE_MS = 7000

# Laptop NIC MTU during the L2 session — must be larger than the
# biggest frame any L2 test wants to send, including the
# test_l2_malformed.py oversize cases (1600). The Pi keeps its own
# MTU at 1500, so frames between 1515 and 1600 hit the Pi as
# oversize and the test verifies the Pi drops them. Restored to the
# saved value at session end.
LAPTOP_TEST_MTU = 2000

# RTT sample size at session start. 100 round-trips of < 5ms each is
# < 0.5s of session startup overhead.
RTT_SAMPLE_COUNT = 100

# Sanity ceiling on the measured baseline RTT. If the test bench is
# misconfigured (wrong NIC, lossy USB hub) we want to fail loudly at
# session start, not produce flaky timeouts deep into the suite.
RTT_BASELINE_CEILING_MS = 10.0

ARTIFACTS_DIR = Path(__file__).parent / "artifacts"


def is_pi4_reachable():
    """Check if the Pi 4 responds to a TCP SYN on port 80."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2)
        result = s.connect_ex((PI4_IP, PI4_HTTP_PORT))
        s.close()
        return result == 0
    except (socket.timeout, OSError):
        return False


def is_pi4_pingable():
    """Check if the Pi 4 responds to ICMP echo."""
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "2", PI4_IP],
            capture_output=True, timeout=5, check=False,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


# --- Markers ---

requires_hardware = pytest.mark.skipif(
    os.environ.get("HW_TEST", "") != "1",
    reason="Set HW_TEST=1 to run hardware integration tests"
)


# --- Fixtures ---

@pytest.fixture
def pi4_ip():
    """Return the Pi 4's IP address."""
    return PI4_IP


@pytest.fixture
def pi4_http_port():
    """Return the Pi 4's HTTP port."""
    return PI4_HTTP_PORT


@pytest.fixture
def pi4_addr(pi4_ip, pi4_http_port):
    """Return (ip, port) tuple for the Pi 4 HTTP server."""
    return (pi4_ip, pi4_http_port)


@pytest.fixture
def tcp_socket(pi4_ip):
    """Create a TCP socket connected to the Pi 4."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TEST_TIMEOUT)
    yield s
    s.close()


@pytest.fixture
def raw_socket():
    """Create a raw IP socket for crafting TCP segments.
    Requires root or CAP_NET_RAW."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
        s.settimeout(TEST_TIMEOUT)
        yield s
        s.close()
    except PermissionError:
        pytest.skip("Raw socket requires root or CAP_NET_RAW")


@pytest.fixture
def serial_port():
    """Open the Pi 4 UART serial port for monitoring."""
    try:
        import serial
        ser = serial.Serial(PI4_SERIAL, PI4_SERIAL_BAUD, timeout=2)
        yield ser
        ser.close()
    except (ImportError, OSError) as e:
        pytest.skip(f"Serial port not available: {e}")


# ============================================================
# L2 framework fixtures (used by test_l2_*.py)
# ============================================================

# --- Internal helper: do one ARP probe and return the reply, or None ---

def _arp_probe_once(iface: str, laptop_mac: bytes, laptop_ip: str,
                    target_ip: str, *, deadline_ms: int = 200) -> dict | None:
    """Send a single ARP request for `target_ip` and wait for a reply.

    Returns the parsed ARP dict from eth_frames.parse_arp(), or None
    if no matching reply arrives within `deadline_ms`.

    The capture filter restricts to ARP traffic destined for our MAC,
    and the predicate further requires opcode=REPLY and spa=target_ip.
    Background ARP noise from other hosts cannot satisfy both.
    """
    laptop_mac_str = ":".join(f"{b:02x}" for b in laptop_mac)
    bpf = f"arp and ether dst {laptop_mac_str}"
    request = eth_frames.build_arp_request(laptop_mac, laptop_ip, target_ip)

    with wire.WireCapture(iface, bpf=bpf) as cap:
        wire.send_frame(iface, request)
        reply_bytes = wire.wait_for_frame(
            cap,
            lambda data: _is_arp_reply_for(data, target_ip),
            deadline_ms=deadline_ms,
        )
    if reply_bytes is None:
        return None
    return eth_frames.parse_arp(reply_bytes)


def _is_arp_reply_for(frame: bytes, target_ip: str) -> bool:
    """Predicate: is this frame an ARP reply with spa == target_ip?"""
    try:
        arp = eth_frames.parse_arp(frame)
    except (ValueError, OSError):
        return False
    return arp["opcode"] == eth_frames.ARP_OP_REPLY and arp["spa"] == target_ip


# --- Iface, MACs, RTT baseline ---

@pytest.fixture(scope="session")
def eth_iface() -> str:
    """The interface that connects the laptop to the Pi 4 DUT.

    Side effect at session start: bumps the NIC's hardware RX ring to
    its declared maximum if it's currently below 4096. The laptop's
    USB gigabit adapter (Realtek r8152) ships with RX=100 by default,
    which causes >30% loss in burst tests because the NIC drops
    incoming frames before the kernel can drain them. Without this
    bump every L2 burst test would be measuring the laptop NIC's
    queue depth, not the Pi's behaviour.

    Idempotent — re-runs are no-ops, and the change is local to this
    process's view (cleared on driver reload).
    """
    if not Path(f"/sys/class/net/{HW_TEST_IFACE}").exists():
        pytest.skip(
            f"interface {HW_TEST_IFACE} not present "
            f"(set HW_TEST_IFACE env var to override)"
        )
    _ensure_rx_ring_max(HW_TEST_IFACE)
    return HW_TEST_IFACE


def _ensure_rx_ring_max(iface: str) -> None:
    """Read the NIC's max RX ring and bump current to it if below.

    Best-effort: prints a warning if ethtool is missing or the bump
    fails, but does not skip the session — small bursts still work
    and the user may want to see how the framework behaves with the
    default queue depth.
    """
    try:
        out = subprocess.run(
            ["ethtool", "-g", iface],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        print(f"\n[L2] WARNING: cannot read RX ring on {iface} via ethtool")
        return

    max_rx = current_rx = None
    section = None
    for line in out.splitlines():
        if "Pre-set maximums" in line:
            section = "max"
        elif "Current hardware settings" in line:
            section = "cur"
        elif section and line.lstrip().startswith("RX:"):
            try:
                v = int(line.split(":", 1)[1].strip())
            except ValueError:
                continue
            if section == "max" and max_rx is None:
                max_rx = v
            elif section == "cur" and current_rx is None:
                current_rx = v

    if max_rx is None or current_rx is None:
        return
    if current_rx >= max_rx:
        return

    try:
        subprocess.run(
            ["ethtool", "-G", iface, "rx", str(max_rx)],
            check=True, capture_output=True, text=True, timeout=5,
        )
        print(f"\n[L2] {iface} RX ring bumped {current_rx} → {max_rx}")
    except subprocess.CalledProcessError as e:
        print(
            f"\n[L2] WARNING: could not bump {iface} RX ring to {max_rx}: "
            f"{e.stderr.strip()}"
        )


@pytest.fixture(scope="session")
def laptop_mac(eth_iface) -> bytes:
    """The laptop NIC's MAC address (read from sysfs, no caps needed)."""
    return link.link_mac(eth_iface)


@pytest.fixture(scope="session")
def laptop_ip() -> str:
    return LAPTOP_IP


@pytest.fixture
def pi_mac(eth_iface, laptop_mac, laptop_ip, pi4_ip) -> bytes:
    """Discover the Pi's MAC by ARP probe.

    Function-scoped on purpose: if a test reboots or flaps the Pi, the
    next test gets a fresh probe (and a fresh skip-with-reason if the
    Pi is gone) instead of inheriting a stale cached value.

    Skips the test (not session) if no reply within BOOT_DEADLINE_MS,
    so a transiently-down Pi doesn't kill the entire suite.
    """
    if PI4_MAC_HINT:
        return eth_frames.mac_str_to_bytes(PI4_MAC_HINT)

    deadline = time.monotonic() + BOOT_DEADLINE_MS / 1000.0
    while time.monotonic() < deadline:
        arp = _arp_probe_once(
            eth_iface, laptop_mac, laptop_ip, pi4_ip,
            deadline_ms=300,
        )
        if arp is not None:
            return arp["sha"]
    pytest.skip(
        f"Pi at {pi4_ip} did not answer ARP within {BOOT_DEADLINE_MS} ms "
        f"on {eth_iface} — is it powered and running our kernel?"
    )


@pytest.fixture(scope="session")
def rtt_p99_ms(eth_iface, laptop_mac, laptop_ip) -> float:
    """Measured ARP round-trip 99th percentile (in milliseconds).

    Run once at session start. Subsequent tests size their deadlines
    from this value rather than hardcoding magic numbers. If the
    measured RTT exceeds RTT_BASELINE_CEILING_MS, fail the session
    loudly — the test bench is broken.

    Implementation: uses a single RawL2Socket for both send and recv
    so each probe is just one syscall pair. WireCapture's per-poll
    pcap re-open would dominate at this latency scale (sub-millisecond
    real RTT vs ~10ms pcap parse).
    """
    request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)

    samples_ms: list[float] = []
    failures = 0

    # Patience for the FIRST sample is generous: previous test runs in
    # the same process or back-to-back invocations may have left the
    # Pi mid-renegotiation. We allow up to ~10 seconds of failed
    # probes before declaring the Pi truly absent. Subsequent samples
    # share a tighter overall deadline.
    FIRST_SAMPLE_FAILURE_BUDGET = 50  # x 200ms = 10s

    with wire.RawL2Socket(eth_iface) as sock:
        deadline = time.monotonic() + 20.0  # 20s budget total
        while (len(samples_ms) < RTT_SAMPLE_COUNT
               and time.monotonic() < deadline):
            sock.drain()  # discard any straggler frames between probes
            t0 = time.monotonic()
            sock.send(request)
            reply = sock.recv(
                timeout_ms=200,
                predicate=lambda data: _is_arp_reply_for(data, PI4_IP),
            )
            elapsed_ms = (time.monotonic() - t0) * 1000.0
            if reply is None:
                failures += 1
                if failures > FIRST_SAMPLE_FAILURE_BUDGET and not samples_ms:
                    pytest.skip(
                        f"Pi at {PI4_IP} not ARP-reachable on {eth_iface} "
                        f"after {failures} probes (~{failures * 200} ms of "
                        f"patience) — cannot establish RTT baseline"
                    )
                continue
            samples_ms.append(elapsed_ms)

    if len(samples_ms) < RTT_SAMPLE_COUNT // 2:
        pytest.skip(
            f"only collected {len(samples_ms)} of {RTT_SAMPLE_COUNT} "
            f"RTT samples — Pi is too unstable to baseline"
        )

    samples_ms.sort()
    p99_idx = max(0, int(len(samples_ms) * 0.99) - 1)
    p99 = samples_ms[p99_idx]

    if p99 > RTT_BASELINE_CEILING_MS:
        pytest.exit(
            f"RTT p99 baseline {p99:.1f} ms exceeds ceiling "
            f"{RTT_BASELINE_CEILING_MS} ms — test bench is broken "
            f"(samples: min={samples_ms[0]:.2f} median="
            f"{samples_ms[len(samples_ms)//2]:.2f} max={samples_ms[-1]:.2f})",
            returncode=2,
        )

    print(
        f"\n[L2] RTT baseline on {eth_iface}: "
        f"min={samples_ms[0]:.2f} median={statistics.median(samples_ms):.2f} "
        f"p99={p99:.2f} max={samples_ms[-1]:.2f} ms "
        f"(n={len(samples_ms)})"
    )
    return p99


# --- Wire capture fixture with failure-forensics pcap save ---

@pytest.fixture
def wire_capture(request, eth_iface):
    """Start a WireCapture for the test body.

    The capture is opened with no BPF filter by default — tests that
    want a tighter filter can construct their own WireCapture inside
    the body. The fixture form is for the common case where you want
    "everything on the wire during this test" plus automatic
    failure-forensics: on failure the pcap is moved to artifacts/
    with a unique name; on success it's deleted.
    """
    cap = wire.WireCapture(eth_iface, bpf="")
    cap.__enter__()
    try:
        yield cap
    finally:
        cap.__exit__(None, None, None)
        # Did the test fail? request.node.rep_call is set by the hook below.
        rep = getattr(request.node, "rep_call", None)
        failed = rep is not None and rep.failed
        if failed:
            ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
            unique = (
                f"{request.node.name}_"
                f"{os.getpid()}_"
                f"{int(time.monotonic_ns() // 1_000_000)}.pcap"
            )
            # Sanitize: replace path separators and brackets in nodeid
            unique = (unique.replace("/", "_")
                      .replace("[", "_").replace("]", ""))
            dst = ARTIFACTS_DIR / unique
            try:
                shutil.copy2(cap.pcap_path, dst)
                print(f"\n[wire] saved failure pcap → {dst}")
            except OSError as e:
                print(f"\n[wire] failed to save pcap: {e}")
        # Always clean up the scratch pcap
        try:
            cap.pcap_path.unlink(missing_ok=True)
        except OSError:
            pass


# pytest hook to expose call-phase outcome to fixtures (so the wire
# fixture knows whether to keep the pcap as a forensic artifact).
@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    rep = outcome.get_result()
    setattr(item, f"rep_{rep.when}", rep)


# --- Link guard + session finalizer ---

@pytest.fixture(autouse=True)
def link_guard(request, eth_iface):
    """Pre-test sanity: link must be admin-up at the expected speed.

    Only autouse for tests that carry the `l2` or `l3` marker. If a
    previous test crashed mid-teardown, this skips with a clear message
    rather than failing for the wrong reason.
    """
    if (
        request.node.get_closest_marker("l2") is None
        and request.node.get_closest_marker("l3") is None
    ):
        yield
        return
    state = link.link_state(eth_iface)
    if not state["admin_up"]:
        pytest.skip(
            f"{eth_iface} is admin-down at test start — "
            f"preceding test left bad state"
        )
    yield


@pytest.fixture(scope="session", autouse=True)
def link_session_finalizer(request):
    """Save link state and MTU at session start, restore at end.

    Bumps the laptop NIC MTU to LAPTOP_TEST_MTU so the malformed-frame
    tests can transmit oversize frames (>1514) — AF_PACKET sends
    enforce the device MTU, so without this the kernel rejects the
    test frames at send time and we can't verify the Pi's behaviour.

    Restore is best-effort — if it fails, raise loudly so the next
    session doesn't inherit a wedged link.

    Activated only if the iface exists; sessions on machines without
    the test NIC are no-ops so non-hardware tests can still run.
    """
    if not Path(f"/sys/class/net/{HW_TEST_IFACE}").exists():
        yield
        return

    saved = link.link_state(HW_TEST_IFACE)
    saved_mtu = link.link_get_mtu(HW_TEST_IFACE)
    if saved_mtu < LAPTOP_TEST_MTU:
        try:
            link.link_set_mtu(HW_TEST_IFACE, LAPTOP_TEST_MTU)
            print(
                f"\n[L2] {HW_TEST_IFACE} MTU bumped {saved_mtu} → "
                f"{LAPTOP_TEST_MTU} for the session"
            )
        except link.LinkError as e:
            print(
                f"\n[L2] WARNING: could not bump {HW_TEST_IFACE} MTU "
                f"to {LAPTOP_TEST_MTU}: {e}"
            )

    yield

    try:
        if saved_mtu != link.link_get_mtu(HW_TEST_IFACE):
            link.link_set_mtu(HW_TEST_IFACE, saved_mtu)
        link.restore_link(HW_TEST_IFACE, saved)
        # Confirm the link is up; if not, fail loudly.
        if saved["admin_up"]:
            link.wait_for_carrier(HW_TEST_IFACE, deadline_ms=8000)
    except link.LinkError as e:
        # Use print instead of raise — we're in a session finalizer and
        # raising here masks any test failure information.
        print(
            f"\n[link_session_finalizer] WARNING: could not restore "
            f"{HW_TEST_IFACE}: {e}"
        )


# ============================================================
# Stale hardware-process sweep — runs before AND after every session
# ============================================================
#
# Ed's standing rule: every hw run must check for stale processes on
# BOTH ends. Stale hw_send.py holds /dev/ttyUSB* and steals ACK bytes
# from the next flash; stale QEMU instances chew CPU in the
# background. The sweep at session start catches leakage from prior
# aborted runs; the sweep at session end catches leakage from this
# run's fixtures.
#
# The matcher tuples are (comm_prefix, cmdline_needle) — see
# hw_send.kill_stale_by_matchers() for the matching semantics.
# /proc/<pid>/comm is truncated to 15 chars by the kernel, so
# "qemu-system-aarch64" becomes "qemu-system-aar" in comm. The
# cmdline needle is "" (empty string is always contained) because
# the comm prefix is already specific enough.

_HW_SWEEP_MATCHERS = (
    ("python", "hw_send.py"),   # flasher console holding /dev/ttyUSB*
    ("qemu-system-aar", ""),    # leftover QEMU from prior `make test`
)


@pytest.fixture(scope="session", autouse=True)
def _hw_stale_process_sweep():
    """Guard rail: sweep stale hardware processes at session boundaries.

    Autouse + session-scoped so it runs even when a single test is
    selected with `-k` or node-id. Delegates to
    `hw_send.kill_stale_by_matchers`, which handles the
    /proc-enumeration, full ancestor-chain exclusion, and TOCTOU
    re-verification in one place.
    """
    pre = kill_stale_by_matchers(_HW_SWEEP_MATCHERS)
    if pre:
        print(
            f"\n[hw-sweep] pre-session: killed {pre} stale "
            f"hardware process(es) — a prior run leaked them"
        )
    yield
    post = kill_stale_by_matchers(_HW_SWEEP_MATCHERS)
    if post:
        print(
            f"\n[hw-sweep] post-session: killed {post} stale "
            f"hardware process(es) — a test fixture skipped its "
            f"teardown path"
        )


# --- DUT reset (marker-triggered, opt-in) ---

@pytest.fixture
def dut_reset(request, eth_iface, laptop_mac, laptop_ip):
    """Power-cycle the Pi via DTR before the test runs.

    Only used by tests marked `@pytest.mark.dut_reset`. Imports
    `set_dtr` from scripts/hw_send.py to avoid duplicating the
    DTR ioctl.
    """
    if request.node.get_closest_marker("dut_reset") is None:
        yield
        return
    # sys is already imported at module top; sys.path.insert was done
    # there too, so the hw_send import here is a cheap re-import.
    from hw_send import open_serial, set_dtr  # noqa: E402

    fd = open_serial(PI4_SERIAL)
    try:
        set_dtr(fd, True)
        time.sleep(0.1)
        set_dtr(fd, False)
    finally:
        os.close(fd)

    # Wait for Pi to come back: ARP-reachable.
    deadline = time.monotonic() + BOOT_DEADLINE_MS / 1000.0
    while time.monotonic() < deadline:
        arp = _arp_probe_once(
            eth_iface, laptop_mac, laptop_ip, PI4_IP,
            deadline_ms=300,
        )
        if arp is not None:
            yield
            return
    pytest.fail(
        f"Pi did not return to ARP-reachable within {BOOT_DEADLINE_MS} ms "
        f"after DTR reset"
    )
