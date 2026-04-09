#!/usr/bin/env python3
"""One-off measurement harness for the martian filter cost.

Sends N=500 64-byte ICMP echoes to the Pi, queries PERF_L3 counters
before and after (reset before), and records ip_ticks/ip_count and
icmp_ticks/icmp_count per trial. 10 trials per invocation.

Usage:
  measure_martian.py WITH    # label the output file
  measure_martian.py WITHOUT

Output: /tmp/martian_<label>.json with a list of per-trial dicts.
"""
import json
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "hw_test"))
sys.path.insert(0, "/home/ed/ws_pi5/hw_test")

from conftest import PI4_IP, HW_TEST_IFACE, LAPTOP_IP
import eth_frames
import ip_frames
import wire
from icmp_helpers import (
    icmp_bpf_from_pi,
    is_any_echo_reply_from_pi,
    parse_reply,
)


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("WITH", "WITHOUT"):
        print(__doc__, file=sys.stderr)
        return 2
    label = sys.argv[1]

    iface = HW_TEST_IFACE
    laptop_mac_b = eth_frames.mac_str_to_bytes(
        open(f"/sys/class/net/{iface}/address").read().strip()
    )

    # ARP probe
    with wire.RawL2Socket(iface) as sock:
        sock.drain()
        sock.send(eth_frames.build_arp_request(laptop_mac_b, LAPTOP_IP, PI4_IP))
        arp = sock.recv(
            timeout_ms=1000,
            predicate=lambda d: len(d) >= 42 and d[12:14] == b"\x08\x06",
        )
    if arp is None:
        print(f"ERROR: Pi at {PI4_IP} not ARP-reachable on {iface}",
              file=sys.stderr)
        return 2
    pi_mac_b = eth_frames.parse_arp(arp)["sha"]

    # Check PERF=l3
    try:
        snap = wire.perf_query(iface, pi_mac_b, laptop_mac_b, block="l3")
    except wire.WireError as e:
        print(f"ERROR: not a PERF=l3 build: {e}", file=sys.stderr)
        return 2
    print(f"label={label} magic={snap['magic']:#010x} iface={iface}",
          flush=True)

    N = 500
    payload = bytes(64)
    bpf = icmp_bpf_from_pi(pi_mac_b, laptop_mac_b)

    # WARM-UP: send a proper burst AND wait for all the replies,
    # so the Pi's icache / dcache / branch predictor are in
    # post-hot-loop steady state by the time we measure.
    #
    # Prior runs showed a 2x cost transition across the first
    # ~2500 processed echoes on a freshly-flashed kernel — the
    # ip_handle cost is ~265 ns when the code is still in L1
    # from boot, and climbs to a ~555-575 ns plateau once
    # net_loop's polling spinner has displaced it into L2.
    # The WITHOUT build's state stabilised at 555.41 ns after
    # about 5 trials × 500 frames = 2500 echoes without any
    # warm-up, so send 3000 warm-up echoes here (6 trials' worth)
    # and actually wait for every reply to be sure.
    WARMUP_N = 3000
    print(f"  warming up ({WARMUP_N} echoes, waiting for all replies)...",
          flush=True)
    ident_warmup_base = 0x9000
    warm_frames = [
        ip_frames.build_icmp_echo_frame(
            laptop_mac_b, pi_mac_b, LAPTOP_IP, PI4_IP,
            ident=ident_warmup_base + (i & 0xFFF), seq=0xBB,
            payload=payload,
        )
        for i in range(WARMUP_N)
    ]
    with wire.WireCapture(iface, bpf=bpf) as cap:
        for f in warm_frames:
            wire.send_frame(iface, f)
        # Actually wait for (almost) all of them to come back
        # before starting measurement. Use a loose predicate that
        # accepts any echo reply from the Pi with seq==0xBB.
        def is_warm_reply(data):
            if not is_any_echo_reply_from_pi(
                data, pi_mac=pi_mac_b, laptop_mac=laptop_mac_b,
                pi_ip=PI4_IP, laptop_ip=LAPTOP_IP,
            ):
                return False
            return parse_reply(data)["icmp"]["seq"] == 0xBB
        # Budget ~20 ms per frame on the Python send path; settle
        # for whatever we get within the generous deadline.
        got = wire.wait_for_frames(
            cap, is_warm_reply,
            count=WARMUP_N,
            deadline_ms=int(WARMUP_N * 25),
        )
    print(f"  warm-up drained {len(got)}/{WARMUP_N} replies",
          flush=True)

    trials = []
    for trial in range(10):
        # Reset before each trial
        wire.perf_query(iface, pi_mac_b, laptop_mac_b,
                        block="l3", reset=True)

        # Use seq to distinguish trials, ident to distinguish
        # frames within a trial — keeps everything in uint16 range
        # even at N=500 × 10 trials.
        ident_base = 0x8000
        seq = trial + 1
        frames = [
            ip_frames.build_icmp_echo_frame(
                laptop_mac_b, pi_mac_b, LAPTOP_IP, PI4_IP,
                ident=ident_base + i, seq=seq, payload=payload,
            )
            for i in range(N)
        ]
        expected = set(range(ident_base, ident_base + N))

        def is_ours(data, _exp=expected, _seq=seq):
            if not is_any_echo_reply_from_pi(
                data, pi_mac=pi_mac_b, laptop_mac=laptop_mac_b,
                pi_ip=PI4_IP, laptop_ip=LAPTOP_IP,
            ):
                return False
            icmp = parse_reply(data)["icmp"]
            return icmp["ident"] in _exp and icmp["seq"] == _seq

        t0 = time.monotonic()
        with wire.WireCapture(iface, bpf=bpf) as cap:
            for f in frames:
                wire.send_frame(iface, f)
            replies = wire.wait_for_frames(
                cap, is_ours, count=N, deadline_ms=10000,
            )
        elapsed_ms = (time.monotonic() - t0) * 1000.0

        snap = wire.perf_query(iface, pi_mac_b, laptop_mac_b, block="l3")

        delivered = len(replies)
        ip_ns_per = (wire.perf_ticks_to_ns(snap["ip_ticks"])
                     / snap["ip_count"]) if snap["ip_count"] else 0.0
        icmp_ns_per = (wire.perf_ticks_to_ns(snap["icmp_ticks"])
                       / snap["icmp_count"]) if snap["icmp_count"] else 0.0

        t = {
            "trial": trial,
            "delivered": delivered,
            "elapsed_ms": elapsed_ms,
            "ip_ticks": snap["ip_ticks"],
            "ip_count": snap["ip_count"],
            "ip_ns_per_frame": ip_ns_per,
            "icmp_ticks": snap["icmp_ticks"],
            "icmp_count": snap["icmp_count"],
            "icmp_ns_per_frame": icmp_ns_per,
        }
        trials.append(t)
        print(
            f"  trial {trial+1:>2}/10: delivered={delivered}/{N}  "
            f"ip_ns={ip_ns_per:7.2f}  icmp_ns={icmp_ns_per:7.2f}  "
            f"elapsed={elapsed_ms:.0f}ms",
            flush=True,
        )

    out_path = f"/tmp/martian_{label}.json"
    with open(out_path, "w") as fobj:
        json.dump({"label": label, "N": N, "trials": trials}, fobj, indent=2)
    print(f"\nWrote {out_path}")

    # Quick summary
    ip_ns = [t["ip_ns_per_frame"] for t in trials]
    icmp_ns = [t["icmp_ns_per_frame"] for t in trials]
    print(f"  ip_ns   median={statistics.median(ip_ns):.2f}  "
          f"mean={statistics.fmean(ip_ns):.2f}  "
          f"stdev={statistics.stdev(ip_ns):.2f}  "
          f"min={min(ip_ns):.2f}  max={max(ip_ns):.2f}")
    print(f"  icmp_ns median={statistics.median(icmp_ns):.2f}  "
          f"mean={statistics.fmean(icmp_ns):.2f}  "
          f"stdev={statistics.stdev(icmp_ns):.2f}  "
          f"min={min(icmp_ns):.2f}  max={max(icmp_ns):.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
