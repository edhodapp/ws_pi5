#!/home/ed/ws_pi5/.venv/bin/python3
"""Send an ARP-request burst at a deterministic rate via tcpreplay.

Why tcpreplay instead of an AF_PACKET raw socket?

Python raw socket `send()` is dominated by interpreter + syscall
overhead (~3-5us/pkt), and the kernel's AF_PACKET TX path then
re-batches sends into bulk USB transfers with driver-visible variance.
On the r8152 USB gigabit NIC we empirically saw the send time for a
1024-frame ARP burst oscillate bimodally between ~2ms and ~12ms
across back-to-back runs, dominating the measurement of the Pi's
drain rate.

tcpreplay uses PACKET_MMAP, so the frames land in a shared ring with
the kernel and are dispatched without a syscall per frame. With
`--pps N` we get deterministic pacing; with `--topspeed` we get wire
rate. Either way, variance drops sharply vs. the Python loop.

Usage:
    arp_burst_send.py <iface> <src_mac> <src_ip> <target_ip> \
        <count> [--pps N | --topspeed] [--loop N]

Exits with tcpreplay's exit code. On success, prints the 'Actual'
line from tcpreplay's summary so callers can parse the observed rate.

This script is ONLY used from the hw_test framework. It writes the
pcap to a temp file and unlinks it on exit.
"""
import argparse
import os
import pathlib
import subprocess
import sys
import tempfile

from scapy.all import Ether, ARP, wrpcap


def build_arp_pcap(
    path: pathlib.Path,
    src_mac: str,
    src_ip: str,
    target_ip: str,
    count: int,
) -> None:
    """Write `count` identical ARP request frames to path as a pcap.

    Writing all frames up front (instead of a 1-frame pcap + tcpreplay
    --loop count) avoids per-loop pcap-rewind overhead, which otherwise
    caps the effective rate around ~66k pps on this test bench."""
    # ff:ff:ff:ff:ff:ff broadcast; opcode 1 = request.
    frame = Ether(src=src_mac, dst="ff:ff:ff:ff:ff:ff") / ARP(
        op=1,
        hwsrc=src_mac,
        psrc=src_ip,
        hwdst="00:00:00:00:00:00",
        pdst=target_ip,
    )
    wrpcap(str(path), [frame] * count)


def main() -> int:
    p = argparse.ArgumentParser(description="Deterministic ARP burst via tcpreplay")
    p.add_argument("iface")
    p.add_argument("src_mac")
    p.add_argument("src_ip")
    p.add_argument("target_ip")
    p.add_argument("count", type=int, help="Number of frames to send (via --loop)")
    rate = p.add_mutually_exclusive_group()
    rate.add_argument("--pps", type=int, help="Target packets per second")
    rate.add_argument(
        "--topspeed",
        action="store_true",
        help="Send as fast as the NIC accepts (default)",
    )
    args = p.parse_args()

    if args.count < 1:
        print("count must be >= 1", file=sys.stderr)
        return 2

    with tempfile.NamedTemporaryFile(suffix=".pcap", delete=False) as fh:
        pcap_path = pathlib.Path(fh.name)
    try:
        build_arp_pcap(
            pcap_path,
            args.src_mac,
            args.src_ip,
            args.target_ip,
            args.count,
        )

        cmd = [
            "tcpreplay",
            "--intf1", args.iface,
            "--quiet",
            "--stats", "0",  # Summary only, no periodic stats
        ]
        if args.pps is not None:
            cmd += ["--pps", str(args.pps)]
        elif args.topspeed:
            cmd += ["--topspeed"]
        # else: tcpreplay default (1Mbps) — do NOT rely on this for the
        # test; callers should pass --pps or --topspeed explicitly.
        cmd.append(str(pcap_path))

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
        )
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        return result.returncode
    finally:
        try:
            pcap_path.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
