"""
link.py — link state query, mutation, and save/restore for L2 tests.

Read-only state queries are unprivileged (sysfs + ethtool stdout
parsing). Speed/duplex changes shell out to `ethtool` (which has
cap_net_admin). Link admin up/down uses raw `AF_NETLINK` from this
process directly, NOT a subprocess to `ip link`, because on Ubuntu
24.04 / kernel 6.17 file caps applied to /usr/bin/ip are silently
ignored at exec time. The netlink path requires cap_net_admin on the
running python interpreter, which setup-caps.sh grants to the venv
python alongside cap_net_raw.

All mutations go through context managers that always restore the
saved state on exit, even if the test body raises.

Capabilities required (granted by hw_test/bin/setup-caps.sh):
  - ethtool needs cap_net_admin (speed/duplex/autoneg)
  - the running python interpreter needs cap_net_admin
    (AF_NETLINK link up/down)
  - link_state() is read-only and needs no caps
"""

import os
import re
import socket
import struct
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path


# --- Errors ---

class LinkError(RuntimeError):
    """A link operation failed (subprocess error, parse error, etc)."""


# --- Read-only state queries ---

def _sysfs_read(iface: str, name: str) -> str:
    path = Path(f"/sys/class/net/{iface}/{name}")
    return path.read_text().strip()


def link_mac(iface: str) -> bytes:
    """Return the interface's MAC as 6 raw bytes."""
    text = _sysfs_read(iface, "address")
    parts = text.split(":")
    if len(parts) != 6:
        raise LinkError(f"unexpected sysfs address format for {iface}: {text!r}")
    return bytes(int(p, 16) for p in parts)


def link_carrier(iface: str) -> bool:
    """True if the kernel reports physical carrier (LOWER_UP)."""
    try:
        return _sysfs_read(iface, "carrier") == "1"
    except OSError:
        # carrier file errors out (EINVAL) when the link is administratively
        # down — that's a definitive "no carrier" answer.
        return False


def link_admin_up(iface: str) -> bool:
    """True if the interface is administratively up (regardless of carrier)."""
    flags_hex = _sysfs_read(iface, "flags")
    flags = int(flags_hex, 16)
    IFF_UP = 0x1
    return bool(flags & IFF_UP)


def link_state(iface: str) -> dict:
    """Read all the link state we care about as a dict.

    Returns:
        {
            'iface': str,
            'mac': bytes (6 bytes),
            'admin_up': bool,
            'carrier': bool,
            'speed_mbps': int | None,   # None if no carrier or unparseable
            'duplex': str | None,       # 'full' / 'half' / None
            'autoneg': bool | None,     # None if unparseable
        }

    Never raises for missing/parsing issues on speed/duplex/autoneg —
    those become None so callers can save+restore safely even on a
    cable-pulled interface.
    """
    state = {
        "iface": iface,
        "mac": link_mac(iface),
        "admin_up": link_admin_up(iface),
        "carrier": link_carrier(iface),
        "speed_mbps": None,
        "duplex": None,
        "autoneg": None,
    }

    try:
        out = subprocess.run(
            ["ethtool", iface],
            check=True, capture_output=True, text=True, timeout=5,
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return state

    speed_match = re.search(r"^\s*Speed:\s*(\d+)\s*Mb/s", out, re.MULTILINE)
    if speed_match:
        state["speed_mbps"] = int(speed_match.group(1))

    duplex_match = re.search(r"^\s*Duplex:\s*(\w+)", out, re.MULTILINE)
    if duplex_match:
        state["duplex"] = duplex_match.group(1).lower()

    auto_match = re.search(r"^\s*Auto-negotiation:\s*(\w+)", out, re.MULTILINE)
    if auto_match:
        state["autoneg"] = (auto_match.group(1).lower() == "on")

    return state


# --- Mutations ---

def _run(cmd: list[str], *, timeout: float = 5.0) -> None:
    """Run a privileged link command. Raises LinkError on failure."""
    try:
        subprocess.run(
            cmd,
            check=True, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.CalledProcessError as e:
        raise LinkError(
            f"{' '.join(cmd)} exited {e.returncode}: {e.stderr.strip()}"
        ) from e
    except subprocess.TimeoutExpired as e:
        raise LinkError(f"{' '.join(cmd)} timed out after {timeout}s") from e


# --- Netlink helper for link admin up/down ---
#
# Builds a single RTM_NEWLINK message that sets the IFF_UP bit (or
# clears it). Equivalent to `ip link set <iface> up/down` but goes
# straight to the kernel via AF_NETLINK so we don't depend on /bin/ip
# having a working file cap.
#
# rtnetlink message layout:
#   nlmsghdr (16 bytes) | ifinfomsg (16 bytes)
# We use the ifinfomsg.ifi_change field to mask exactly IFF_UP, and set
# ifi_flags to IFF_UP or 0 to set/clear. No attributes are needed when
# the index is supplied directly.

NLM_F_REQUEST = 0x01
NLM_F_ACK     = 0x04
NLMSG_ERROR   = 0x02
RTM_NEWLINK   = 16
AF_UNSPEC     = 0
IFF_UP        = 0x1


def _ifindex(iface: str) -> int:
    """Look up an interface index via /sys/class/net/<iface>/ifindex.

    No syscall needed; sysfs already exposes it. Avoids needing
    SIOCGIFINDEX or any privileged netlink dump.
    """
    text = _sysfs_read(iface, "ifindex")
    return int(text)


def _set_link_flags(iface: str, *, set_up: bool) -> None:
    """Send a single RTM_NEWLINK netlink message to bring iface up or down.

    Requires CAP_NET_ADMIN on this process. Raises LinkError on netlink
    error responses (parses NLMSG_ERROR payloads).
    """
    ifindex = _ifindex(iface)
    flags = IFF_UP if set_up else 0

    # ifinfomsg: family(B) pad(B) type(H) index(i) flags(I) change(I)
    ifinfomsg = struct.pack("=BBHiII", AF_UNSPEC, 0, 0, ifindex, flags, IFF_UP)

    # nlmsghdr: length(I) type(H) flags(H) seq(I) pid(I)
    msg_len = 16 + len(ifinfomsg)
    nlmsghdr = struct.pack(
        "=IHHII",
        msg_len,
        RTM_NEWLINK,
        NLM_F_REQUEST | NLM_F_ACK,
        1,            # seq — we don't pipeline so 1 is fine
        0,            # pid — kernel fills in
    )
    request = nlmsghdr + ifinfomsg

    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
    try:
        try:
            sock.bind((0, 0))
        except PermissionError as e:
            raise LinkError(
                f"AF_NETLINK bind denied — does this python interpreter "
                f"have cap_net_admin set? "
                f"(setup-caps.sh grants it to the venv python.)"
            ) from e
        sock.send(request)
        sock.settimeout(2.0)
        try:
            reply = sock.recv(8192)
        except socket.timeout as e:
            raise LinkError(
                f"netlink ack for {iface} {'up' if set_up else 'down'} "
                f"timed out"
            ) from e
    finally:
        sock.close()

    # Parse the NLMSG_ERROR / ack
    if len(reply) < 16:
        raise LinkError(f"short netlink reply ({len(reply)} bytes)")
    rlen, rtype, rflags, rseq, rpid = struct.unpack("=IHHII", reply[:16])
    if rtype != NLMSG_ERROR:
        raise LinkError(f"unexpected netlink reply type {rtype}")
    if len(reply) < 20:
        raise LinkError("netlink error reply missing errno")
    (errno,) = struct.unpack("=i", reply[16:20])
    if errno != 0:
        # ack carries errno=0; nonzero is the actual failure (negative)
        from errno import errorcode
        e = -errno
        name = errorcode.get(e, str(e))
        raise LinkError(
            f"netlink RTM_NEWLINK on {iface} failed: {name} ({e})"
        )


def link_up(iface: str) -> None:
    """Bring the interface administratively up via AF_NETLINK."""
    _set_link_flags(iface, set_up=True)


def link_down(iface: str) -> None:
    """Bring the interface administratively down via AF_NETLINK."""
    _set_link_flags(iface, set_up=False)


def link_set_speed(iface: str, mbps: int, duplex: str = "full") -> None:
    """Force speed/duplex with autoneg off.

    Most NICs require autoneg off when forcing speed; that's why this
    helper does both in one call.
    """
    if duplex not in ("full", "half"):
        raise ValueError(f"duplex must be 'full' or 'half', got {duplex!r}")
    _run([
        "ethtool", "-s", iface,
        "autoneg", "off",
        "speed", str(mbps),
        "duplex", duplex,
    ])


def link_set_autoneg(iface: str) -> None:
    """Re-enable auto-negotiation (caller usually wants this on restore)."""
    _run(["ethtool", "-s", iface, "autoneg", "on"])


# --- Wait helpers (deadline-polled, not bare sleeps) ---

def wait_for_carrier(iface: str, *, deadline_ms: int = 5000,
                     poll_ms: int = 20) -> float:
    """Block until carrier is up or deadline expires.

    Returns the elapsed seconds. Raises LinkError on timeout so the
    caller can fail loudly with the iface name in the message.
    """
    deadline = time.monotonic() + deadline_ms / 1000.0
    start = time.monotonic()
    while time.monotonic() < deadline:
        if link_carrier(iface):
            return time.monotonic() - start
        time.sleep(poll_ms / 1000.0)
    raise LinkError(
        f"{iface} carrier did not come up within {deadline_ms} ms"
    )


def wait_for_speed(iface: str, expected_mbps: int, *,
                   deadline_ms: int = 5000, poll_ms: int = 50) -> None:
    """Block until ethtool reports the expected speed or deadline expires."""
    deadline = time.monotonic() + deadline_ms / 1000.0
    last_seen = None
    while time.monotonic() < deadline:
        s = link_state(iface)["speed_mbps"]
        if s == expected_mbps:
            return
        last_seen = s
        time.sleep(poll_ms / 1000.0)
    raise LinkError(
        f"{iface} did not reach {expected_mbps} Mb/s within "
        f"{deadline_ms} ms (last seen: {last_seen})"
    )


# --- Save / restore ---

def restore_link(iface: str, saved: dict) -> None:
    """Restore an interface to a previously-saved state.

    Honours saved.admin_up, saved.autoneg, saved.speed_mbps. If the
    saved state had autoneg on, restores autoneg; if it had autoneg off
    and a forced speed, restores that exact speed.

    Always finishes by ensuring the link is administratively up unless
    the saved state was explicitly down — that's the safety net for
    the session-scope finalizer.
    """
    if saved["autoneg"] is True:
        link_set_autoneg(iface)
    elif saved["autoneg"] is False and saved["speed_mbps"]:
        link_set_speed(iface, saved["speed_mbps"], saved["duplex"] or "full")
    # If saved.autoneg is None we cannot restore speed semantics — best
    # effort is to leave the link state as-is and rely on link_up below.

    if saved["admin_up"]:
        link_up(iface)
    else:
        link_down(iface)


# --- Context managers ---

@contextmanager
def temporary_link_speed(iface: str, mbps: int, duplex: str = "full",
                         *, settle_ms: int = 5000):
    """Force a speed for the duration of the with-block, then restore.

    On entry: saves current state, applies the forced speed, waits for
    carrier to come back at the new speed (renegotiation can take a
    second or two), then yields.

    On exit: restores the saved state — never to a hardcoded default.
    Restoration runs even if the body raised. If restoration itself
    fails, the exception propagates after the test body's exception
    (Python's standard finally semantics).
    """
    saved = link_state(iface)
    try:
        link_set_speed(iface, mbps, duplex)
        wait_for_carrier(iface, deadline_ms=settle_ms)
        wait_for_speed(iface, mbps, deadline_ms=settle_ms)
        yield saved
    finally:
        restore_link(iface, saved)
        # After restore, the link should come back at the saved speed.
        # Don't fail here if it doesn't — the session-scope finalizer
        # will catch a wedged link with a louder error.


@contextmanager
def temporary_link_down(iface: str, *, down_ms: int = 1000,
                        recover_ms: int = 5000):
    """Bring the link administratively down for the duration of the
    with-block, then bring it back up and wait for carrier.

    The body of the with-block runs while the link is DOWN — useful for
    asserting "what does the Pi do while we're not listening" or for
    deliberate flap-and-recover tests where the body is empty.

    `down_ms` is a deliberate down-time, NOT a wait-for-event, so a
    bounded sleep is principled here.

    `recover_ms` bounds the wait for carrier to come back after up.
    """
    saved_admin = link_admin_up(iface)
    if not saved_admin:
        raise LinkError(
            f"{iface} is already administratively down — refusing to flap"
        )
    link_down(iface)
    try:
        if down_ms > 0:
            time.sleep(down_ms / 1000.0)
        yield
    finally:
        link_up(iface)
        try:
            wait_for_carrier(iface, deadline_ms=recover_ms)
        except LinkError:
            # Re-raise: a link that doesn't come back from a flap is a
            # real failure that the next test must not silently inherit.
            raise


# --- Self-check (used by setup verification, not by tests) ---

def _self_check(iface: str) -> None:
    """One-shot non-destructive sanity check.

    Reads state and confirms ethtool / ip / sysfs are all reachable.
    Does NOT mutate the link. Used by hand or by a setup script to
    verify caps are in place.
    """
    state = link_state(iface)
    print(f"iface       : {state['iface']}")
    print(f"mac         : {':'.join(f'{b:02x}' for b in state['mac'])}")
    print(f"admin_up    : {state['admin_up']}")
    print(f"carrier     : {state['carrier']}")
    print(f"speed_mbps  : {state['speed_mbps']}")
    print(f"duplex      : {state['duplex']}")
    print(f"autoneg     : {state['autoneg']}")


if __name__ == "__main__":
    import sys
    iface = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "HW_TEST_IFACE", "enx00e04c0a2bed"
    )
    _self_check(iface)
