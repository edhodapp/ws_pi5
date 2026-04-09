#!/usr/bin/env python3
"""Burst statistics for the Pi 4 hw_test harness.

Two modes:

  L2 ARP burst (default):
      burst_stats.py <burst_size> <runs>

    Runs test_l2_ring.py's burst test N times, parses BURST_STATS /
    PERF_STATS output, and reports mean/stddev/kurtosis/Sarle's b for
    reply counts and send times. Used during the GENET bringup to
    quantify ARP burst loss at large N.

  L3 ICMP burst:
      burst_stats.py --icmp-burst N [--size B] [--runs R] [--iface IF]

    Sends N ICMP echo requests at payload size B (default 64) directly
    to the Pi, counts replies, and reports:
      * delivered count, send time
      * per-frame cost derived from the Pi's PERF_L3_ICMP_TICKS /
        PERF_L3_ICMP_COUNT counters (requires a PERF=l3 Pi build)
      * a snapshot of the PERF_L3 counter deltas across the burst

    The L3 mode bypasses pytest and talks to the Pi directly via
    wire.send_frame + wire.WireCapture. The tool takes a DUMP_L3_RESET
    before the burst so the delta is exactly this burst's work.
"""
import argparse
import math
import os
import re
import statistics
import subprocess
import sys
import time


# Allow imports of hw_test modules when run from repo root.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


# --- L2 burst parsing ---

BURST_RE = re.compile(
    r"BURST_STATS: n=(\d+) replies=(\d+) send_ms=([\d.]+) "
    r"wire_pps=([\d.]+) total_ms=([\d.]+)"
)

# PERF_STATS line is OPTIONAL — only present when the Pi is running
# a PERF build that responds to the 0x88B6 perf_query. Default
# kernels skip it. We parse what we can; missing fields are None.
PERF_RE = re.compile(
    r"PERF_STATS: n=(\d+) "
    r"recv_count=(\d+) recv_none=(\d+) "
    r"dispatch_count=(\d+) drop_count=(\d+) "
    r"send_count=(\d+) send_fail=(\d+) "
    r"max_burst=(\d+) rx_discards=(\d+) "
    r"recv_ns=(\d+) dispatch_ns=(\d+) send_ns=(\d+)"
)


def run_once(n: int) -> dict:
    """Run one pytest invocation of the L2 burst test, return a
    dict with all parsed stats. Always populates: replies, send_ms.
    Populated only when the Pi has perf instrumentation: recv_count,
    ..., recv_ns, dispatch_ns, send_ns.
    """
    env = os.environ.copy()
    env["HW_TEST"] = "1"
    result = subprocess.run(
        [
            ".venv/bin/pytest",
            f"hw_test/test_l2_ring.py::TestRingWraparound::"
            f"test_burst_n_arp_replies_received[{n}]",
            "-s",  # don't capture -- BURST_STATS print must reach us
            "-q",
            "--tb=line",
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    output = result.stdout + result.stderr

    burst_m = BURST_RE.search(output)
    if not burst_m:
        raise RuntimeError(
            f"Could not parse BURST_STATS line from pytest output:\n"
            f"{output}"
        )
    out = {
        "replies": int(burst_m.group(2)),
        "send_ms": float(burst_m.group(3)),
        "wire_pps": float(burst_m.group(4)),
    }

    perf_m = PERF_RE.search(output)
    if perf_m:
        out.update({
            "recv_count":     int(perf_m.group(2)),
            "recv_none":      int(perf_m.group(3)),
            "dispatch_count": int(perf_m.group(4)),
            "drop_count":     int(perf_m.group(5)),
            "send_count":     int(perf_m.group(6)),
            "send_fail":      int(perf_m.group(7)),
            "max_burst":      int(perf_m.group(8)),
            "rx_discards":    int(perf_m.group(9)),
            "recv_ns":        int(perf_m.group(10)),
            "dispatch_ns":    int(perf_m.group(11)),
            "send_ns":        int(perf_m.group(12)),
        })

    return out


# --- Statistics helpers ---

def central_moment(xs: list[float], k: int) -> float:
    """k-th central moment = E[(X - mean)^k]."""
    mu = statistics.fmean(xs)
    return sum((x - mu) ** k for x in xs) / len(xs)


def skewness(xs: list[float]) -> float:
    """Sample skewness (3rd standardized moment)."""
    sd = statistics.pstdev(xs)
    if sd == 0:
        return 0.0
    return central_moment(xs, 3) / (sd**3)


def excess_kurtosis(xs: list[float]) -> float:
    """Excess kurtosis = 4th standardized moment - 3.

    Normal distribution has 0. Narrow peak / heavy tails: positive.
    Flat / bimodal: negative (typically < -1 for clear bimodality)."""
    sd = statistics.pstdev(xs)
    if sd == 0:
        return 0.0
    return central_moment(xs, 4) / (sd**4) - 3.0


def sarle_bimodality(xs: list[float]) -> float:
    """Sarle's bimodality coefficient.

    b = (g^2 + 1) / (k + 3*(n-1)^2 / ((n-2)*(n-3)))

    where g = skewness, k = excess kurtosis, n = sample size.
    b > 5/9 (~0.555) suggests bimodality. Uniform distribution
    has b = 5/9 exactly. Standard normal has b = 1/3."""
    n = len(xs)
    if n < 4:
        return float("nan")
    g = skewness(xs)
    k = excess_kurtosis(xs)
    correction = 3.0 * (n - 1) ** 2 / ((n - 2) * (n - 3))
    return (g * g + 1.0) / (k + correction)


def _summarize(name: str, xs: list[float], unit: str = "") -> None:
    """Print mean / stdev / range for a list of measurements."""
    if not xs:
        return
    mean = statistics.fmean(xs)
    sd = statistics.stdev(xs) if len(xs) > 1 else 0.0
    suffix = f" {unit}" if unit else ""
    print(
        f"  {name:<18} mean={mean:8.2f}{suffix}  "
        f"stdev={sd:7.2f}{suffix}  "
        f"min={min(xs):.0f} max={max(xs):.0f}"
    )


# --- L2 mode ---

def run_l2_mode(burst_size: int, runs: int) -> int:
    if runs < 4:
        print("Need at least 4 runs for kurtosis to be meaningful.",
              file=sys.stderr)
        return 2

    print(f"Running test_l2_ring[{burst_size}] {runs} times...", flush=True)
    trials: list[dict] = []
    for i in range(runs):
        t = run_once(burst_size)
        trials.append(t)
        perf_tag = ""
        if "recv_ns" in t:
            perf_tag = (
                f"  perf: recv={t['recv_ns']}ns "
                f"disp={t['dispatch_ns']}ns send={t['send_ns']}ns"
            )
        print(
            f"  run {i+1:>2}/{runs}: {t['replies']:>4} replies, "
            f"send_time={t['send_ms']:.1f}ms{perf_tag}",
            flush=True,
        )

    counts = [t["replies"] for t in trials]
    send_times = [t["send_ms"] for t in trials]

    print()
    print(f"=== Reply counts (target = {burst_size}) ===")
    print(f"  samples: {counts}")
    mean = statistics.fmean(counts)
    sd = statistics.stdev(counts) if runs > 1 else 0.0
    g = skewness(counts)
    k = excess_kurtosis(counts)
    b = sarle_bimodality(counts)
    print(f"  mean          : {mean:8.2f}")
    print(f"  stdev         : {sd:8.2f}")
    print(f"  min, max      : {min(counts)}, {max(counts)}")
    print(f"  skewness (g)  : {g:8.3f}")
    print(f"  ex. kurtosis  : {k:8.3f}  (normal=0; flat/bimodal<0; peaked>0)")
    print(f"  Sarle's b     : {b:8.3f}  (bimodal if > 0.555; uniform=0.555)")

    flags: list[str] = []
    if k < -1.0:
        flags.append(f"excess kurtosis {k:.2f} < -1 (flat distribution)")
    if b > 0.555:
        flags.append(f"Sarle's b {b:.3f} > 0.555 (likely bimodal)")
    if flags:
        print()
        print("  ==> BIMODALITY LIKELY:", "; ".join(flags))
    else:
        print()
        print("  ==> No bimodality detected (Sarle's b <= 0.555 and kurtosis >= -1)")

    print()
    print("=== Send time (ms) ===")
    print(f"  samples: {[round(t,1) for t in send_times]}")
    print(f"  mean          : {statistics.fmean(send_times):8.2f}")
    print(f"  stdev         : {statistics.stdev(send_times) if runs > 1 else 0.0:8.2f}")
    if runs >= 4:
        b_t = sarle_bimodality(send_times)
        k_t = excess_kurtosis(send_times)
        print(f"  ex. kurtosis  : {k_t:8.3f}")
        print(f"  Sarle's b     : {b_t:8.3f}")

    # Per-stage perf stats are only present when the Pi has a PERF
    # build. Skip the section entirely if no trial returned them.
    perf_trials = [t for t in trials if "recv_ns" in t]
    if perf_trials:
        print()
        print(f"=== Per-stage cycle counts (PERF build, {len(perf_trials)}/{runs} trials) ===")
        print(f"  Pi 4 CNTVCT_EL0 = 54 MHz; ns = ticks * 18.52")
        print()
        _summarize("recv_ns",      [t["recv_ns"]      for t in perf_trials], "ns/frame")
        _summarize("dispatch_ns",  [t["dispatch_ns"]  for t in perf_trials], "ns/frame")
        _summarize("send_ns",      [t["send_ns"]      for t in perf_trials], "ns/frame")
        print()
        _summarize("recv_count",   [t["recv_count"]   for t in perf_trials])
        _summarize("recv_none",    [t["recv_none"]    for t in perf_trials])
        _summarize("dispatch_count",[t["dispatch_count"] for t in perf_trials])
        _summarize("drop_count",   [t["drop_count"]   for t in perf_trials])
        _summarize("send_count",   [t["send_count"]   for t in perf_trials])
        _summarize("send_fail",    [t["send_fail"]    for t in perf_trials])
        _summarize("rx_discards",  [t["rx_discards"]  for t in perf_trials])

        # Quick sanity: per-stage sum should be close to the
        # observed per-frame cost. If not, something's mis-probed.
        recv_mean = statistics.fmean(t["recv_ns"] for t in perf_trials)
        disp_mean = statistics.fmean(t["dispatch_ns"] for t in perf_trials)
        send_mean = statistics.fmean(t["send_ns"] for t in perf_trials)
        total = recv_mean + disp_mean + send_mean
        print()
        print(
            f"  per-frame total : {total:8.0f} ns "
            f"(recv {recv_mean/total*100:.0f}% / "
            f"disp {disp_mean/total*100:.0f}% / "
            f"send {send_mean/total*100:.0f}%)"
        )

    return 0


# --- L3 ICMP burst mode ---

def run_l3_icmp_burst(n_echoes: int, payload_size: int, runs: int,
                       iface_override: str | None) -> int:
    """Send n_echoes ICMP echo requests to the Pi, count replies,
    and report the L3 perf counter deltas.

    Repeats `runs` times so jitter and per-call overhead are
    averaged out. Each run resets the L3 counters via DUMP_L3_RESET
    before the burst so the delta captures exactly that burst's work.
    """
    # Deferred imports — modules only needed in L3 mode.
    import eth_frames
    import ip_frames
    import wire
    from conftest import PI4_IP, LAPTOP_IP, HW_TEST_IFACE
    from icmp_helpers import (
        icmp_bpf_from_pi,
        is_any_echo_reply_from_pi,
        parse_reply,
    )

    iface = iface_override or HW_TEST_IFACE
    laptop_mac_b = eth_frames.mac_str_to_bytes(
        open(f"/sys/class/net/{iface}/address").read().strip()
    )

    # Resolve the Pi's MAC via one ARP probe. Gives a clear error
    # message if the Pi is down.
    arp_req = eth_frames.build_arp_request(laptop_mac_b, LAPTOP_IP, PI4_IP)
    with wire.RawL2Socket(iface) as sock:
        sock.drain()
        sock.send(arp_req)
        arp_reply = sock.recv(
            timeout_ms=1000,
            predicate=lambda d: (
                len(d) >= 42 and d[12:14] == b"\x08\x06"
            ),
        )
    if arp_reply is None:
        print(f"ERROR: Pi at {PI4_IP} did not reply to ARP on {iface}",
              file=sys.stderr)
        return 2
    pi_mac_b = eth_frames.parse_arp(arp_reply)["sha"]

    # Verify the Pi is a PERF=l3 build up front.
    try:
        snap = wire.perf_query(iface, pi_mac_b, laptop_mac_b, block="l3")
    except wire.WireError as e:
        print(f"ERROR: perf_query(block='l3') failed — is the Pi a "
              f"PERF=l3 build?\n  {e}", file=sys.stderr)
        return 2
    print(f"pi_mac={eth_frames.mac_bytes_to_str(pi_mac_b)}  "
          f"magic={snap['magic']:#010x}")
    print(f"burst={n_echoes} echo(s) @ {payload_size}B payload, runs={runs}")
    print()

    bpf = icmp_bpf_from_pi(pi_mac_b, laptop_mac_b)
    payload = bytes((i & 0xFF) for i in range(payload_size))
    ident_base = 0xC000

    trial_stats: list[dict] = []
    for run in range(runs):
        # Reset counters so the delta = exactly this run's work.
        wire.perf_query(iface, pi_mac_b, laptop_mac_b, block="l3", reset=True)

        # Build the frames.
        frames = [
            ip_frames.build_icmp_echo_frame(
                laptop_mac_b, pi_mac_b, LAPTOP_IP, PI4_IP,
                ident=ident_base + i, seq=run, payload=payload,
            )
            for i in range(n_echoes)
        ]

        # Send + capture replies.
        expected_idents = set(range(ident_base, ident_base + n_echoes))
        def is_ours(data: bytes, _expected=expected_idents,
                    _pi=pi_mac_b, _lap=laptop_mac_b) -> bool:
            if not is_any_echo_reply_from_pi(
                data,
                pi_mac=_pi, laptop_mac=_lap,
                pi_ip=PI4_IP, laptop_ip=LAPTOP_IP,
            ):
                return False
            return parse_reply(data)["icmp"]["ident"] in _expected

        # Deadline: allow ~1ms per frame plus 500ms baseline.
        deadline_ms = 500 + int(1.0 * n_echoes)
        t0 = time.monotonic()
        with wire.WireCapture(iface, bpf=bpf) as cap:
            for f in frames:
                wire.send_frame(iface, f)
            send_ms = (time.monotonic() - t0) * 1000.0
            replies = wire.wait_for_frames(
                cap, is_ours,
                count=n_echoes,
                deadline_ms=deadline_ms,
            )
        total_ms = (time.monotonic() - t0) * 1000.0

        # Query L3 counters (no reset — we'll reset on the next run).
        post = wire.perf_query(iface, pi_mac_b, laptop_mac_b, block="l3")

        delivered = len(replies)
        icmp_ticks = post["icmp_ticks"]
        icmp_count = post["icmp_count"]
        ip_ticks   = post["ip_ticks"]
        ip_count   = post["ip_count"]

        per_frame_icmp_ns = (
            wire.perf_ticks_to_ns(icmp_ticks) / icmp_count
            if icmp_count else 0.0
        )
        per_frame_ip_ns = (
            wire.perf_ticks_to_ns(ip_ticks) / ip_count
            if ip_count else 0.0
        )

        trial = {
            "delivered":          delivered,
            "send_ms":            send_ms,
            "total_ms":           total_ms,
            "ip_count":           ip_count,
            "ip_ticks":           ip_ticks,
            "icmp_count":         icmp_count,
            "icmp_ticks":         icmp_ticks,
            "per_frame_icmp_ns":  per_frame_icmp_ns,
            "per_frame_ip_ns":    per_frame_ip_ns,
            "frag_reassembled":   post["frag_reassembled"],
            "frag_drops":         post["frag_drops"],
        }
        trial_stats.append(trial)
        print(
            f"  run {run+1:>2}/{runs}: {delivered:>4}/{n_echoes} delivered, "
            f"send_ms={send_ms:6.1f}  total_ms={total_ms:6.1f}  "
            f"ip_ns={per_frame_ip_ns:7.0f}  icmp_ns={per_frame_icmp_ns:7.0f}",
            flush=True,
        )

    print()
    print("=== L3 ICMP burst summary ===")
    delivered_s  = [t["delivered"] for t in trial_stats]
    send_ms_s    = [t["send_ms"] for t in trial_stats]
    ip_ns_s      = [t["per_frame_ip_ns"] for t in trial_stats if t["ip_count"]]
    icmp_ns_s    = [t["per_frame_icmp_ns"] for t in trial_stats if t["icmp_count"]]

    _summarize("delivered",       [float(x) for x in delivered_s],
               f"/{n_echoes}")
    _summarize("send_ms",         send_ms_s, "ms")
    _summarize("per_frame_ip_ns", ip_ns_s, "ns")
    _summarize("per_frame_icmp_ns", icmp_ns_s, "ns")

    total_delivered = sum(delivered_s)
    total_expected  = n_echoes * runs
    loss_pct = 100.0 * (1.0 - total_delivered / total_expected)
    print()
    print(f"  total delivered : {total_delivered}/{total_expected} "
          f"({loss_pct:.2f}% loss)")
    return 0


# --- Main ---

def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--icmp-burst", type=int, metavar="N",
        help="Send N ICMP echo requests and dump L3 perf counters "
             "(requires PERF=l3 Pi build). Overrides the default "
             "L2 ARP burst mode.",
    )
    parser.add_argument(
        "--size", type=int, default=64, metavar="B",
        help="L3 mode only: ICMP payload size in bytes (default 64)",
    )
    parser.add_argument(
        "--runs", type=int, default=4, metavar="R",
        help="Number of trials (default 4 in L3 mode; required >=4 "
             "for L2 mode — see positional usage)",
    )
    parser.add_argument(
        "--iface", type=str, default=None, metavar="IFACE",
        help="Interface to use (default: HW_TEST_IFACE env or "
             "conftest.HW_TEST_IFACE)",
    )
    parser.add_argument(
        "positional", nargs="*",
        help="L2 mode (default): <burst_size> <runs>",
    )
    args = parser.parse_args()

    if args.icmp_burst is not None:
        return run_l3_icmp_burst(
            n_echoes=args.icmp_burst,
            payload_size=args.size,
            runs=args.runs,
            iface_override=args.iface,
        )

    # L2 mode (positional args)
    if len(args.positional) != 2:
        parser.print_help(sys.stderr)
        return 2
    try:
        burst_size = int(args.positional[0])
        runs = int(args.positional[1])
    except ValueError:
        parser.print_help(sys.stderr)
        return 2
    return run_l2_mode(burst_size, runs)


if __name__ == "__main__":
    sys.exit(main())
