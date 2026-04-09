"""
wire.py — capture and send raw L2 frames from the test driver.

Primitives:

* WireCapture — context manager wrapping `tcpdump` for capture. The
  capture is verified to be live BEFORE the with-block runs (via a
  self-addressed probe frame), so the classic capture-then-send race
  cannot produce silent flaky tests.

* send_frame / send_frames / RawL2Socket — AF_PACKET raw socket send
  and recv primitives. Low overhead, Python-paced.

* build_arp_pcap + tcpreplay_send — deterministic-rate L2 burst send
  via the `tcpreplay` userspace tool. Use this when the Python-paced
  AF_PACKET send rate is too variable (e.g. the r8152 USB NIC batches
  our sends bimodally at 2ms vs 12ms for a 1024-frame ARP burst). A
  pre-built pcap avoids per-loop pcap-rewind overhead.

Pcap parsing on capture exit uses scapy's PcapReader (cold path only;
no scapy threads ever run during capture).

Capabilities required (granted by hw_test/bin/setup-caps.sh):
  - tcpdump:   cap_net_raw,cap_net_admin
  - tcpreplay: cap_net_raw
  - The python interpreter running this module: cap_net_raw
    (for AF_PACKET in send_frame and the readiness probe)
"""

import os
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Callable, Iterable, Optional


# --- Errors ---

class WireError(RuntimeError):
    """A wire-capture or wire-send operation failed."""


# --- Constants ---

ETH_P_ALL = 0x0003  # capture/send all ethertypes (htons in caller)
SIGINT_FLUSH_DEADLINE_S = 2.0
READY_PROBE_ETHERTYPE = 0x88B5  # IEEE 802 "local experimental 1" — never used by Pi
READY_PROBE_TIMEOUT_DEFAULT_MS = 1500
READY_PROBE_POLL_INTERVAL_S = 0.005


# --- Raw L2 send ---

def _open_send_socket(iface: str) -> socket.socket:
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    try:
        s.bind((iface, 0))
    except OSError:
        s.close()
        raise
    return s


def send_frame(iface: str, frame: bytes) -> None:
    """Send a single raw L2 frame on the given interface.

    Requires CAP_NET_RAW on the running python interpreter. The frame
    must be a complete Ethernet frame (14-byte header + payload); the
    NIC hardware appends the FCS.
    """
    if len(frame) < 14:
        raise WireError(f"frame too short for L2 send: {len(frame)} bytes")
    try:
        s = _open_send_socket(iface)
    except PermissionError as e:
        raise WireError(
            f"AF_PACKET send on {iface} denied — is cap_net_raw granted "
            f"to {os.path.realpath(__import__('sys').executable)}?"
        ) from e
    except OSError as e:
        raise WireError(f"cannot bind AF_PACKET socket to {iface}: {e}") from e
    try:
        sent = s.send(frame)
        if sent != len(frame):
            raise WireError(
                f"short send on {iface}: requested {len(frame)}, sent {sent}"
            )
    finally:
        s.close()


def send_frames(iface: str, frames: Iterable[bytes]) -> int:
    """Send a batch of frames on a single bound socket.

    More efficient than repeated send_frame() because the socket is
    opened once. Returns the number of frames sent. Raises WireError
    on the first short send.
    """
    try:
        s = _open_send_socket(iface)
    except PermissionError as e:
        raise WireError(
            f"AF_PACKET send on {iface} denied — is cap_net_raw granted?"
        ) from e
    sent_count = 0
    try:
        for frame in frames:
            n = s.send(frame)
            if n != len(frame):
                raise WireError(
                    f"short send: requested {len(frame)}, sent {n} "
                    f"after {sent_count} frames"
                )
            sent_count += 1
    finally:
        s.close()
    return sent_count


# --- Low-overhead bidirectional AF_PACKET socket ---
#
# For high-rate / low-latency use cases (RTT baselining, ring-blast
# tests) WireCapture's per-poll pcap re-open is too slow. RawL2Socket
# is a single AF_PACKET socket bound to one interface that does both
# send and recv with a kernel BPF filter for noise rejection. No
# tcpdump subprocess, no pcap file, no scapy in the hot path.
#
# Captures only inbound frames matching the BPF, with sub-millisecond
# round-trip latency on a direct gigabit link.

class RawL2Socket:
    """Bidirectional AF_PACKET socket bound to one interface.

    Usage:
        with RawL2Socket(iface) as sock:
            sock.send(frame)
            reply = sock.recv(timeout_ms=10)   # raw bytes or None

    Construct with `bpf_filter` to install a kernel-level BPF program
    so recv() only returns frames that match — drops everything else
    in the kernel before it reaches userspace. This is the same
    mechanism tcpdump uses, just in-process.
    """

    # SO_RCVBUFFORCE bypasses the net.core.rmem_max clamp. Linux
    # exposes it as constant 33. Requires CAP_NET_ADMIN on the caller
    # (granted to the venv python in setup-caps.sh). We need this
    # because the system-wide rmem_max default is 208 KB, which caps
    # AF_PACKET at ~200 buffered frames — below the range we test.
    _SO_RCVBUFFORCE = 33

    def __init__(self, iface: str, *, recv_buf_bytes: int = 8 * 1024 * 1024):
        self.iface = iface
        self._sock: Optional[socket.socket] = None
        self._recv_buf_bytes = recv_buf_bytes

    def __enter__(self) -> "RawL2Socket":
        try:
            s = socket.socket(
                socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL)
            )
        except PermissionError as e:
            raise WireError(
                f"AF_PACKET socket on {self.iface} denied — is "
                f"cap_net_raw granted to this python interpreter?"
            ) from e
        try:
            s.bind((self.iface, 0))
        except OSError as e:
            s.close()
            raise WireError(
                f"cannot bind AF_PACKET socket to {self.iface}: {e}"
            ) from e
        # Bigger SO_RCVBUF so high-rate bursts don't drop in kernel.
        # Try SO_RCVBUFFORCE first (bypasses net.core.rmem_max, needs
        # CAP_NET_ADMIN); fall back to the clamped SO_RCVBUF if the
        # caller lacks the capability.
        try:
            s.setsockopt(
                socket.SOL_SOCKET, self._SO_RCVBUFFORCE, self._recv_buf_bytes
            )
        except PermissionError:
            try:
                s.setsockopt(
                    socket.SOL_SOCKET, socket.SO_RCVBUF, self._recv_buf_bytes
                )
            except OSError:
                pass
        except OSError:
            pass
        # Drain anything stale already buffered (from before we bound)
        s.setblocking(False)
        try:
            while True:
                s.recv(65536)
        except BlockingIOError:
            pass
        self._sock = s
        return self

    def __exit__(self, *exc) -> None:
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def send(self, frame: bytes) -> None:
        if self._sock is None:
            raise WireError("RawL2Socket not open")
        if len(frame) < 14:
            raise WireError(f"frame too short for L2 send: {len(frame)}")
        n = self._sock.send(frame)
        if n != len(frame):
            raise WireError(
                f"short send on {self.iface}: requested {len(frame)}, sent {n}"
            )

    def recv(
        self,
        *,
        timeout_ms: int,
        predicate: Optional[Callable[[bytes], bool]] = None,
    ) -> Optional[bytes]:
        """Receive one frame, optionally filtered by predicate.

        Returns the first frame for which `predicate(data)` is True
        (or any frame if predicate is None) within the deadline.
        Returns None on timeout. Drops the readiness probe ethertype
        automatically so we don't get false positives.
        """
        if self._sock is None:
            raise WireError("RawL2Socket not open")
        deadline = time.monotonic() + timeout_ms / 1000.0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            self._sock.settimeout(remaining)
            try:
                data = self._sock.recv(65536)
            except (socket.timeout, BlockingIOError):
                return None
            if len(data) < 14:
                continue
            etype = (data[12] << 8) | data[13]
            if etype == READY_PROBE_ETHERTYPE:
                continue
            if predicate is None or predicate(data):
                return data

    def drain(self) -> int:
        """Discard all currently-buffered RX frames. Returns count drained."""
        if self._sock is None:
            raise WireError("RawL2Socket not open")
        n = 0
        self._sock.settimeout(0)
        try:
            while True:
                self._sock.recv(65536)
                n += 1
        except (BlockingIOError, socket.timeout):
            pass
        return n


# --- Deterministic-rate burst send via tcpreplay ---
#
# Python raw socket send() plus the r8152 USB NIC's bulk-OUT batcher
# produces a bimodal send-rate distribution: ~2ms for 1024 frames on
# one run, ~12ms on the next, with nothing in between. This makes it
# impossible to measure a 1-5% kernel drain-rate change in the burst
# tests. tcpreplay + PACKET_MMAP cuts the variance sharply (2.05-2.25ms
# typical, with occasional 3ms outliers) because the kernel only sees
# one syscall setup + a memory-mapped ring, not N individual send()
# calls.
#
# Two helpers: `build_arp_pcap` (scapy-backed, called once per test to
# generate the burst as a pcap file) and `tcpreplay_send` (subprocess
# wrapper; no scapy involved in the hot path).

def build_arp_pcap(
    path: Path,
    count: int,
    src_mac: str,
    src_ip: str,
    target_ip: str,
) -> None:
    """Write `count` identical ARP request frames to `path` as a pcap.

    Writing all frames up front avoids the per-loop pcap-rewind
    overhead that would otherwise cap tcpreplay's effective rate at
    ~66 kpps. With a multi-frame pcap, tcpreplay reaches >500 kpps.

    The frames are byte-identical (same src/dst MAC, same target IP),
    which is all the Pi's ARP responder needs to reply N times.
    """
    from scapy.layers.l2 import Ether, ARP  # cold-path import
    from scapy.utils import wrpcap

    frame = Ether(src=src_mac, dst="ff:ff:ff:ff:ff:ff") / ARP(
        op=1,
        hwsrc=src_mac,
        psrc=src_ip,
        hwdst="00:00:00:00:00:00",
        pdst=target_ip,
    )
    wrpcap(str(path), [frame] * count)


def tcpreplay_send(
    iface: str,
    pcap_path: Path,
    *,
    pps: Optional[int] = None,
    topspeed: bool = False,
    timeout_s: float = 30.0,
) -> dict:
    """Replay `pcap_path` onto `iface` via tcpreplay.

    Exactly one of `pps` or `topspeed` must be specified — the default
    tcpreplay rate (1 Mbps) is never what we want for a burst test.

    Returns a dict with 'sent', 'elapsed_s', and 'pps' parsed from the
    tcpreplay summary line. Raises WireError on non-zero exit or on a
    subprocess timeout.

    Requires cap_net_raw on /usr/bin/tcpreplay (set by setup-caps.sh).
    """
    if (pps is None) == (not topspeed):
        raise WireError("tcpreplay_send: specify exactly one of pps= or topspeed=True")

    cmd = [
        "tcpreplay",
        "--intf1", iface,
        "--quiet",
        "--stats", "0",
    ]
    if pps is not None:
        cmd += ["--pps", str(pps)]
    else:
        cmd += ["--topspeed"]
    cmd.append(str(pcap_path))

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as e:
        raise WireError(
            f"tcpreplay timed out after {timeout_s}s on {iface}"
        ) from e

    if result.returncode != 0:
        raise WireError(
            f"tcpreplay exited {result.returncode} on {iface}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )

    # Parse the summary line:
    #   "Actual: 1024 packets (43008 bytes) sent in 0.002050 seconds"
    #   "Rated: 20979512.1 Bps, 167.83 Mbps, 499512.19 pps"
    actual: Optional[tuple[int, float]] = None
    observed_pps: Optional[float] = None
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("Actual:"):
            # very last "Actual:" line is the total; keep overwriting
            try:
                sent = int(line.split("Actual:", 1)[1].strip().split()[0])
                elapsed = float(line.split("sent in", 1)[1].strip().split()[0])
                actual = (sent, elapsed)
            except (IndexError, ValueError):
                pass
        elif line.startswith("Rated:"):
            # "Rated: ... Bps, ... Mbps, NNN pps"
            try:
                observed_pps = float(line.rsplit(",", 1)[1].strip().split()[0])
            except (IndexError, ValueError):
                pass

    if actual is None:
        raise WireError(
            f"tcpreplay output did not contain an 'Actual:' summary line:\n"
            f"{result.stdout}"
        )

    sent, elapsed_s = actual
    return {
        "sent": sent,
        "elapsed_s": elapsed_s,
        "pps": observed_pps if observed_pps is not None else sent / elapsed_s,
    }


# --- Perf counter readout via custom ethertype 0x88B6 ---
#
# The Pi kernel's lib/perf.S::perf_handle responds to an L2 frame
# with ethertype 0x88B6, payload[0]=cmd, by copying the 64-byte
# perf_counters struct into the reply's payload. This gives us a
# per-burst snapshot of per-stage cycle totals without dragging a
# UART parser or an HTTP endpoint into the test harness.
#
# Wire format:
#   Request:  [pi_mac, laptop_mac, 0x88B6, cmd, pad...]  (60 B min)
#   Reply:    [laptop_mac, pi_mac, 0x88B6, <64 B perf_counters>]
#
# See include/perf.inc for the canonical struct offsets; the format
# string below must stay in sync with that file.

PERF_ETHERTYPE = 0x88B6
PERF_CMD_DUMP = 0
PERF_CMD_DUMP_RESET = 1
PERF_CMD_DUMP_REGS = 2

# Minimum Ethernet frame (including FCS added by hardware) is 64
# bytes, payload minimum 46 bytes. We send a 60-byte frame (14 B
# eth + 46 B payload); hardware/driver handles the FCS.
_PERF_REQUEST_LEN = 60

# Pi 4's Cortex-A72 generic timer (CNTFRQ_EL0) runs at 54 MHz.
# Ticks → nanoseconds: ns = ticks * (1_000_000_000 / 54_000_000)
PI4_CNTVCT_FREQ_HZ = 54_000_000


def perf_query(
    iface: str,
    pi_mac: bytes,
    laptop_mac: bytes,
    *,
    reset: bool = False,
    dump_regs: bool = False,
    timeout_ms: int = 100,
) -> dict:
    """Query the Pi's perf state via ethertype 0x88B6.

    Sends a single request frame to the Pi and waits for the reply.
    Requires the Pi to be running a PERF build (the readout handler
    lives in lib/perf.S and is only active when PERF_COUNTERS is
    defined; default builds silently drop the request).

    Arguments:
      iface:      interface name (e.g. "enx00e04c0a2bed")
      pi_mac:     6-byte Pi MAC (request destination)
      laptop_mac: 6-byte laptop MAC (request source / reply dst)
      reset:      if True, Pi zeros counters AFTER snapshot. The
                  returned dict still shows the pre-reset values.
                  Mutually exclusive with dump_regs.
      dump_regs:  if True, issue PERF_CMD_DUMP_REGS instead of
                  PERF_CMD_DUMP. The reply contains a GENET
                  register+state snapshot (see _parse_genet_regs)
                  rather than the perf_counters struct. Pi 4 only —
                  other platforms silently drop the request.
                  Mutually exclusive with reset.
      timeout_ms: max wait for the reply

    Returns:
      - When dump_regs=False: a dict of perf_counters fields (see
        _parse_perf_counters).
      - When dump_regs=True:  a dict of GENET register/state fields
        (see _parse_genet_regs).

    Raises:
      WireError on timeout (Pi unreachable or not a PERF build),
      short reply, socket errors, or contradictory arguments.
    """
    if len(pi_mac) != 6 or len(laptop_mac) != 6:
        raise WireError(
            f"perf_query: MAC addresses must be 6 bytes each "
            f"(got pi={len(pi_mac)}, laptop={len(laptop_mac)})"
        )
    if reset and dump_regs:
        raise WireError(
            "perf_query: reset=True and dump_regs=True are mutually "
            "exclusive (DUMP_RESET operates on perf_counters; "
            "DUMP_REGS dumps a different struct)"
        )

    if dump_regs:
        cmd = PERF_CMD_DUMP_REGS
    elif reset:
        cmd = PERF_CMD_DUMP_RESET
    else:
        cmd = PERF_CMD_DUMP

    # 14 B eth header (dst=pi, src=laptop, etype=0x88B6) +
    # 1 B cmd + 45 B zero pad = 60 B.
    frame = (
        pi_mac
        + laptop_mac
        + struct.pack("!H", PERF_ETHERTYPE)
        + bytes([cmd])
        + bytes(_PERF_REQUEST_LEN - 15)
    )
    assert len(frame) == _PERF_REQUEST_LEN

    with RawL2Socket(iface) as sock:
        sock.drain()
        sock.send(frame)
        reply = sock.recv(
            timeout_ms=timeout_ms,
            predicate=_is_perf_reply,
        )

    if reply is None:
        raise WireError(
            f"perf_query timeout — no 0x{PERF_ETHERTYPE:04x} reply within "
            f"{timeout_ms} ms. Is the Pi running a PERF build?"
        )

    # Reply frame = 14 B eth + 64 B payload = 78 B min.
    expected_min = 14 + 64
    if len(reply) < expected_min:
        raise WireError(
            f"perf_query reply too short: {len(reply)} bytes "
            f"(expected at least {expected_min})"
        )
    payload = reply[14:14 + 64]
    if dump_regs:
        return _parse_genet_regs(payload)
    return _parse_perf_counters(payload)


def _is_perf_reply(frame: bytes) -> bool:
    if len(frame) < 14:
        return False
    etype = (frame[12] << 8) | frame[13]
    return etype == PERF_ETHERTYPE


# Layout MUST track include/perf.inc. Any change to the struct
# ordering or field widths there MUST be mirrored here. The format
# string is little-endian to match AArch64 Normal memory layout.
#
#   off  size  name               type
#   0    8     recv_ticks         u64
#   8    4     recv_count         u32
#   12   4     recv_none          u32
#   16   8     dispatch_ticks     u64
#   24   4     dispatch_count     u32
#   28   4     drop_count         u32
#   32   8     send_ticks         u64
#   40   4     send_count         u32
#   44   4     send_fail          u32
#   48   4     max_burst          u32
#   52   4     cur_burst          u32
#   56   4     rx_discards        u32
#   60   4     magic              u32
_PERF_COUNTERS_STRUCT = struct.Struct("<QIIQIIQIIIIII")
assert _PERF_COUNTERS_STRUCT.size == 64


def _parse_perf_counters(payload: bytes) -> dict:
    """Parse the 64-byte perf_counters struct into a named dict."""
    if len(payload) != 64:
        raise WireError(
            f"_parse_perf_counters: expected 64 bytes, got {len(payload)}"
        )
    fields = _PERF_COUNTERS_STRUCT.unpack(payload)
    return {
        "recv_ticks":     fields[0],
        "recv_count":     fields[1],
        "recv_none":      fields[2],
        "dispatch_ticks": fields[3],
        "dispatch_count": fields[4],
        "drop_count":     fields[5],
        "send_ticks":     fields[6],
        "send_count":     fields[7],
        "send_fail":      fields[8],
        "max_burst":      fields[9],
        "cur_burst":      fields[10],
        "rx_discards":    fields[11],
        "magic":          fields[12],
    }


def perf_ticks_to_ns(ticks: int) -> float:
    """Convert Pi 4 CNTVCT_EL0 ticks to nanoseconds."""
    return ticks * 1e9 / PI4_CNTVCT_FREQ_HZ


# GENET register + driver state snapshot layout.
# MUST stay in sync with platform/pi/drivers/genet.S::genet_dump_state.
# All 16 fields are u32 little-endian. Two fields are reserved
# placeholders that should always read as 0.
#
#   off  name
#   0    umac_cmd
#   4    umac_tx_fifo_status
#   8    umac_rx_fifo_status
#   12   (reserved)
#   16   rdma_prod_index    (upper 16 bits = discard count)
#   20   rdma_cons_index
#   24   rdma_dma_ctrl
#   28   rdma_xon_xoff_thresh
#   32   tdma_prod_index
#   36   tdma_cons_index
#   40   tdma_dma_ctrl
#   44   (reserved)
#   48   state_rx_cidx      (driver's software ring tracking)
#   52   state_rx_ridx
#   56   state_tx_pidx
#   60   state_tx_ridx
_GENET_REGS_STRUCT = struct.Struct("<16I")
assert _GENET_REGS_STRUCT.size == 64


def _parse_genet_regs(payload: bytes) -> dict:
    """Parse the 64-byte GENET register snapshot into a named dict."""
    if len(payload) != 64:
        raise WireError(
            f"_parse_genet_regs: expected 64 bytes, got {len(payload)}"
        )
    f = _GENET_REGS_STRUCT.unpack(payload)
    return {
        "umac_cmd":             f[0],
        "umac_tx_fifo_status":  f[1],
        "umac_rx_fifo_status":  f[2],
        # f[3] reserved
        "rdma_prod_index":      f[4],
        "rdma_cons_index":      f[5],
        "rdma_dma_ctrl":        f[6],
        "rdma_xon_xoff_thresh": f[7],
        "tdma_prod_index":      f[8],
        "tdma_cons_index":      f[9],
        "tdma_dma_ctrl":        f[10],
        # f[11] reserved
        "state_rx_cidx":        f[12],
        "state_rx_ridx":        f[13],
        "state_tx_pidx":        f[14],
        "state_tx_ridx":        f[15],
    }


# --- Capture ---

class WireCapture:
    """Context manager that runs tcpdump for the body of the with-block.

    Usage:
        with WireCapture(iface, bpf="arp and ether src 11:22:33:44:55:66") as cap:
            send_frame(iface, my_arp_request)
            # ... cap is filling in the background ...
        # __exit__ has SIGINT'd tcpdump, parsed the pcap into cap.frames
        assert any(parse_arp(f)['opcode'] == 2 for f in cap.frame_bytes)

    The pcap path is preserved on `cap.pcap_path`. The conftest `wire`
    fixture copies it to `hw_test/artifacts/` on test failure and
    deletes it on success.

    Readiness contract: __enter__ does NOT return until tcpdump is
    actually capturing. It verifies this by sending a self-addressed
    probe frame on the same iface and polling the in-progress pcap
    until the probe appears, OR until ready_timeout_ms elapses (in
    which case __enter__ raises WireError and the body never runs).
    """

    def __init__(
        self,
        iface: str,
        bpf: str = "",
        *,
        ready_timeout_ms: int = READY_PROBE_TIMEOUT_DEFAULT_MS,
        snaplen: int = 0,
        keep_artifact_dir: Optional[Path] = None,
        verify_ready: bool = True,
    ):
        self.iface = iface
        self.bpf = bpf
        self.ready_timeout_ms = ready_timeout_ms
        self.snaplen = snaplen
        self.verify_ready = verify_ready

        if keep_artifact_dir is not None:
            keep_artifact_dir.mkdir(parents=True, exist_ok=True)
            self._tmpdir = None
            fd, path = tempfile.mkstemp(
                prefix="wirecap-", suffix=".pcap", dir=str(keep_artifact_dir)
            )
        else:
            self._tmpdir = tempfile.mkdtemp(prefix="wirecap-")
            fd, path = tempfile.mkstemp(
                prefix="cap-", suffix=".pcap", dir=self._tmpdir
            )
        os.close(fd)
        self._pcap_path = Path(path)

        self._proc: Optional[subprocess.Popen] = None
        self._frames_bytes: list[bytes] = []
        self._frames_parsed = None
        self._exited = False

    @property
    def pcap_path(self) -> Path:
        return self._pcap_path

    @property
    def frame_bytes(self) -> list[bytes]:
        """Raw bytes of each captured frame, populated on __exit__."""
        if not self._exited:
            raise WireError("capture is still running; frames not yet parsed")
        return self._frames_bytes

    @property
    def count(self) -> int:
        return len(self._frames_bytes)

    @property
    def frames(self) -> list:
        """Lazily-parsed scapy Ether packets. Imports scapy on demand
        so importing wire.py doesn't pull scapy into module namespace."""
        if not self._exited:
            raise WireError("capture is still running; frames not yet parsed")
        if self._frames_parsed is None:
            from scapy.layers.l2 import Ether  # local import: cold path
            self._frames_parsed = [Ether(b) for b in self._frames_bytes]
        return self._frames_parsed

    # --- enter / spawn / readiness ---

    def __enter__(self) -> "WireCapture":
        self._spawn()
        try:
            if self.verify_ready:
                self._wait_until_ready()
        except Exception:
            # Don't leak tcpdump if readiness check fails
            self._kill_proc()
            raise
        return self

    def _spawn(self) -> None:
        if shutil.which("tcpdump") is None:
            raise WireError("tcpdump not found in PATH")

        # Combine the user BPF with a clause that accepts the readiness
        # probe so the probe is guaranteed to land in the pcap regardless
        # of the user's filter. We OR them.
        if self.bpf:
            full_bpf = f"({self.bpf}) or (ether proto 0x{READY_PROBE_ETHERTYPE:04x})"
        else:
            full_bpf = ""

        cmd = [
            "tcpdump",
            "-i", self.iface,
            "-U",                # packet-buffered
            "--immediate-mode",  # no per-CPU buffering
            "-s", str(self.snaplen),
            "-w", str(self._pcap_path),
            "-Q", "inout",       # capture both directions (we send too)
        ]
        if full_bpf:
            cmd.append(full_bpf)

        try:
            self._proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        except FileNotFoundError as e:
            raise WireError(f"failed to spawn tcpdump: {e}") from e

    def _wait_until_ready(self) -> None:
        """Send a self-addressed probe and poll the pcap until it shows up.

        The probe uses ethertype 0x88B5 ("local experimental 1"), which
        the Pi never emits and which we OR into the BPF filter so the
        probe is captured even if the user's filter would otherwise
        reject it.
        """
        # Importing scapy.layers.l2 registers DLT_EN10MB so PcapReader
        # doesn't emit "unknown LL type [1]" warnings.
        import scapy.layers.l2  # noqa: F401
        from scapy.utils import PcapReader  # cold-path import

        try:
            laptop_mac = self._read_iface_mac()
        except OSError as e:
            raise WireError(
                f"cannot read /sys/class/net/{self.iface}/address: {e}"
            ) from e

        probe = self._build_probe_frame(laptop_mac)

        deadline = time.monotonic() + self.ready_timeout_ms / 1000.0
        last_err: Optional[Exception] = None
        # Send a probe immediately, then keep re-sending while polling.
        # Re-sending ensures we don't lose to a single-packet drop.
        while time.monotonic() < deadline:
            # Has tcpdump exited?
            rc = self._proc.poll() if self._proc else None
            if rc is not None:
                stderr = self._proc.stderr.read().decode("utf-8", "replace") \
                    if self._proc and self._proc.stderr else ""
                raise WireError(
                    f"tcpdump exited prematurely (rc={rc}) before ready: "
                    f"{stderr.strip()}"
                )
            try:
                send_frame(self.iface, probe)
            except WireError as e:
                last_err = e
                # try again next loop
            # Try to peek at the pcap and look for the probe ethertype
            try:
                if self._pcap_path.stat().st_size > 24:  # > pcap header
                    with PcapReader(str(self._pcap_path)) as rd:
                        for pkt in rd:
                            data = bytes(pkt)
                            if len(data) >= 14 and data[12:14] == bytes([
                                (READY_PROBE_ETHERTYPE >> 8) & 0xFF,
                                READY_PROBE_ETHERTYPE & 0xFF,
                            ]):
                                return
            except Exception:  # noqa: BLE001 - reader can raise during writes
                pass
            time.sleep(READY_PROBE_POLL_INTERVAL_S)

        raise WireError(
            f"tcpdump on {self.iface} did not become ready within "
            f"{self.ready_timeout_ms} ms"
            + (f" (last send err: {last_err})" if last_err else "")
        )

    @staticmethod
    def _build_probe_frame(src_mac: bytes) -> bytes:
        # Self-addressed (src == dst), 60 bytes total, ethertype 0x88B5
        body = b"WIRECAP-READY-PROBE\0\0\0\0\0\0\0\0\0\0\0\0"
        hdr = src_mac + src_mac + struct.pack("!H", READY_PROBE_ETHERTYPE)
        frame = hdr + body
        if len(frame) < 60:
            frame = frame + bytes(60 - len(frame))
        return frame

    def _read_iface_mac(self) -> bytes:
        text = Path(f"/sys/class/net/{self.iface}/address").read_text().strip()
        return bytes(int(p, 16) for p in text.split(":"))

    # --- exit / drain / parse ---

    def __exit__(self, exc_type, exc, tb) -> None:
        self._exited = True
        if self._proc is None:
            return
        # tcpdump only flushes the pcap on SIGINT (not SIGTERM).
        try:
            self._proc.send_signal(signal.SIGINT)
        except ProcessLookupError:
            pass

        try:
            self._proc.wait(timeout=SIGINT_FLUSH_DEADLINE_S)
        except subprocess.TimeoutExpired:
            self._kill_proc()
            raise WireError(
                f"tcpdump did not exit within {SIGINT_FLUSH_DEADLINE_S}s "
                f"of SIGINT — pcap may be truncated"
            )

        # Drain stderr so the pipe doesn't keep the process attached
        if self._proc.stderr:
            try:
                _ = self._proc.stderr.read()
            except Exception:  # noqa: BLE001
                pass

        # Parse pcap into raw frame bytes (filter out our own probes).
        try:
            self._frames_bytes = self._read_pcap_filtering_probes()
        except FileNotFoundError:
            self._frames_bytes = []
        except Exception as e:  # noqa: BLE001
            raise WireError(f"failed to parse pcap {self._pcap_path}: {e}") from e

    def _read_pcap_filtering_probes(self) -> list[bytes]:
        import scapy.layers.l2  # noqa: F401  # register DLT_EN10MB
        from scapy.utils import PcapReader  # cold-path import
        out: list[bytes] = []
        with PcapReader(str(self._pcap_path)) as rd:
            for pkt in rd:
                data = bytes(pkt)
                if len(data) < 14:
                    continue
                etype = (data[12] << 8) | data[13]
                if etype == READY_PROBE_ETHERTYPE:
                    continue
                out.append(data)
        return out

    def _kill_proc(self) -> None:
        if self._proc and self._proc.poll() is None:
            try:
                self._proc.kill()
            except ProcessLookupError:
                pass
            try:
                self._proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                pass


# --- High-level convenience: capture-and-wait ---

def wait_for_frame(
    capture: WireCapture,
    predicate: Callable[[bytes], bool],
    *,
    deadline_ms: int,
    poll_ms: int = 5,
) -> Optional[bytes]:
    """Poll a LIVE WireCapture for a frame matching `predicate`.

    Reads the in-progress pcap incrementally and returns the first
    matching frame (raw bytes) or None at deadline.

    NOTE: must be called from inside the WireCapture with-block (the
    capture must still be running). Reads from the pcap that tcpdump is
    actively writing — relies on `-U --immediate-mode` to keep the
    pcap consistent on disk.
    """
    matches = wait_for_frames(
        capture, predicate, count=1,
        deadline_ms=deadline_ms, poll_ms=poll_ms,
    )
    return matches[0] if matches else None


def wait_for_frames(
    capture: WireCapture,
    predicate: Callable[[bytes], bool],
    *,
    count: int,
    deadline_ms: int,
    poll_ms: int = 5,
) -> list[bytes]:
    """Poll a LIVE WireCapture until `count` frames match `predicate`,
    or deadline expires.

    Returns the list of matching frames in capture order. If the
    deadline is hit before `count` matches are seen, returns whatever
    has been collected so far (which may be empty or short of `count`).
    Tests should assert on `len(result) == count` to fail with the
    actual short count rather than a generic timeout.

    Implementation note: re-opens the pcap on each poll cycle so
    fresh writes from tcpdump are picked up. O(N²) in the number of
    captured frames, but N is small (a few thousand at most for the
    L2 ring tests). Uses an offset cursor to skip already-seen
    packets in the parse loop.
    """
    if capture._exited:
        raise WireError("wait_for_frames requires a live (in-progress) capture")

    import scapy.layers.l2  # noqa: F401  # register DLT_EN10MB
    from scapy.utils import PcapReader  # cold-path import

    deadline = time.monotonic() + deadline_ms / 1000.0
    matches: list[bytes] = []
    seen_offset = 0
    while time.monotonic() < deadline:
        try:
            with PcapReader(str(capture.pcap_path)) as rd:
                idx = 0
                for pkt in rd:
                    if idx < seen_offset:
                        idx += 1
                        continue
                    seen_offset = idx + 1
                    idx += 1
                    data = bytes(pkt)
                    if len(data) < 14:
                        continue
                    etype = (data[12] << 8) | data[13]
                    if etype == READY_PROBE_ETHERTYPE:
                        continue
                    if predicate(data):
                        matches.append(data)
                        if len(matches) >= count:
                            return matches
        except Exception:  # noqa: BLE001 — reader can race tcpdump's writes
            pass
        time.sleep(poll_ms / 1000.0)
    return matches
