"""
test_link_unit.py — off-hardware unit tests for link.py parsers and helpers.

Exercises the bits of link.py that don't need caps or a NIC: the
ethtool output regex parsing in link_state, the MAC string parser, the
LinkError wrapping. The mutation paths (link_up/down/set_speed) and
the wait helpers are exercised by the live L2 tests, not here.

Run:
    .venv/bin/pytest hw_test/test_link_unit.py -v
"""

import re
from unittest.mock import patch

import pytest

import link


# A representative ethtool output we can hand to a mocked subprocess.
ETHTOOL_OUTPUT_1G_AUTONEG_ON = """\
Settings for enx00e04c0a2bed:
\tSupported ports: [ TP MII ]
\tSpeed: 1000Mb/s
\tDuplex: Full
\tAuto-negotiation: on
\tPort: Twisted Pair
\tLink detected: yes
"""

ETHTOOL_OUTPUT_100M_AUTONEG_OFF = """\
Settings for enx00e04c0a2bed:
\tSpeed: 100Mb/s
\tDuplex: Full
\tAuto-negotiation: off
"""

ETHTOOL_OUTPUT_NO_CARRIER = """\
Settings for enx00e04c0a2bed:
\tSpeed: Unknown!
\tDuplex: Unknown! (255)
\tAuto-negotiation: on
\tLink detected: no
"""


def _fake_run_factory(stdout: str, returncode: int = 0):
    """Build a fake subprocess.run that returns canned ethtool output."""
    def _fake_run(*args, **kwargs):
        from subprocess import CompletedProcess
        return CompletedProcess(args=args[0], returncode=returncode,
                                stdout=stdout, stderr="")
    return _fake_run


def _fake_run_raises(exc):
    def _fake_run(*args, **kwargs):
        raise exc
    return _fake_run


# --- link_state parser ---

class TestLinkStateParser:

    def setup_method(self):
        # All tests in this class need sysfs lookups stubbed too.
        self.sysfs_patches = patch.multiple(
            link,
            link_mac=lambda iface: b"\x00\xe0\x4c\x0a\x2b\xed",
            link_admin_up=lambda iface: True,
            link_carrier=lambda iface: True,
        )
        self.sysfs_patches.start()

    def teardown_method(self):
        self.sysfs_patches.stop()

    def test_parse_1g_autoneg_on(self):
        with patch("link.subprocess.run",
                   side_effect=_fake_run_factory(ETHTOOL_OUTPUT_1G_AUTONEG_ON)):
            state = link.link_state("enx00e04c0a2bed")
        assert state["speed_mbps"] == 1000
        assert state["duplex"] == "full"
        assert state["autoneg"] is True
        assert state["mac"] == b"\x00\xe0\x4c\x0a\x2b\xed"
        assert state["admin_up"] is True
        assert state["carrier"] is True

    def test_parse_100m_autoneg_off(self):
        with patch("link.subprocess.run",
                   side_effect=_fake_run_factory(ETHTOOL_OUTPUT_100M_AUTONEG_OFF)):
            state = link.link_state("enx00e04c0a2bed")
        assert state["speed_mbps"] == 100
        assert state["duplex"] == "full"
        assert state["autoneg"] is False

    def test_parse_unknown_speed_returns_none(self):
        with patch("link.subprocess.run",
                   side_effect=_fake_run_factory(ETHTOOL_OUTPUT_NO_CARRIER)):
            state = link.link_state("enx00e04c0a2bed")
        # "Speed: Unknown!" doesn't match \d+ Mb/s, so speed_mbps stays None
        assert state["speed_mbps"] is None
        assert state["autoneg"] is True

    def test_ethtool_failure_leaves_speed_none(self):
        from subprocess import CalledProcessError
        with patch("link.subprocess.run",
                   side_effect=_fake_run_raises(
                       CalledProcessError(1, ["ethtool"], "", "no perm"))):
            state = link.link_state("enx00e04c0a2bed")
        assert state["speed_mbps"] is None
        assert state["duplex"] is None
        assert state["autoneg"] is None
        # MAC and admin_up still come from sysfs (mocked)
        assert state["mac"] == b"\x00\xe0\x4c\x0a\x2b\xed"

    def test_ethtool_timeout_leaves_speed_none(self):
        from subprocess import TimeoutExpired
        with patch("link.subprocess.run",
                   side_effect=_fake_run_raises(
                       TimeoutExpired(["ethtool"], 5))):
            state = link.link_state("enx00e04c0a2bed")
        assert state["speed_mbps"] is None


# --- _run error wrapping ---

class TestRunWrapping:

    def test_called_process_error_wraps_to_LinkError(self):
        from subprocess import CalledProcessError
        with patch("link.subprocess.run",
                   side_effect=CalledProcessError(
                       2, ["ip", "link"], "", "Operation not permitted")):
            with pytest.raises(link.LinkError, match="Operation not permitted"):
                link._run(["ip", "link", "set", "x", "down"])

    def test_timeout_wraps_to_LinkError(self):
        from subprocess import TimeoutExpired
        with patch("link.subprocess.run",
                   side_effect=TimeoutExpired(["ip"], 5)):
            with pytest.raises(link.LinkError, match="timed out"):
                link._run(["ip", "link", "show"])


# --- link_set_speed validation ---

class TestSetSpeedValidation:

    def test_invalid_duplex_rejected(self):
        with pytest.raises(ValueError, match="duplex"):
            link.link_set_speed("eth0", 100, duplex="quarter")


# --- restore_link logic ---

class TestRestoreLink:

    def test_restore_autoneg_on_calls_autoneg_then_up(self):
        calls = []
        with patch("link.link_set_autoneg",
                   side_effect=lambda i: calls.append(("autoneg", i))), \
             patch("link.link_set_speed",
                   side_effect=lambda i, m, d: calls.append(("speed", i, m, d))), \
             patch("link.link_up",
                   side_effect=lambda i: calls.append(("up", i))), \
             patch("link.link_down",
                   side_effect=lambda i: calls.append(("down", i))):
            link.restore_link("eth0", {
                "iface": "eth0", "admin_up": True,
                "autoneg": True, "speed_mbps": 1000, "duplex": "full",
                "mac": b"\x00" * 6, "carrier": True,
            })
        # autoneg restored, then admin up — never speed, never down
        assert ("autoneg", "eth0") in calls
        assert ("up", "eth0") in calls
        assert not any(c[0] == "speed" for c in calls)
        assert not any(c[0] == "down" for c in calls)

    def test_restore_autoneg_off_with_speed_calls_set_speed(self):
        calls = []
        with patch("link.link_set_speed",
                   side_effect=lambda i, m, d: calls.append(("speed", i, m, d))), \
             patch("link.link_set_autoneg",
                   side_effect=lambda i: calls.append(("autoneg", i))), \
             patch("link.link_up",
                   side_effect=lambda i: calls.append(("up", i))), \
             patch("link.link_down",
                   side_effect=lambda i: calls.append(("down", i))):
            link.restore_link("eth0", {
                "iface": "eth0", "admin_up": True,
                "autoneg": False, "speed_mbps": 100, "duplex": "full",
                "mac": b"\x00" * 6, "carrier": True,
            })
        assert ("speed", "eth0", 100, "full") in calls
        assert ("up", "eth0") in calls
        assert not any(c[0] == "autoneg" for c in calls)

    def test_restore_admin_down_calls_down(self):
        calls = []
        with patch("link.link_set_speed",
                   side_effect=lambda *a: calls.append(("speed",))), \
             patch("link.link_set_autoneg",
                   side_effect=lambda *a: calls.append(("autoneg",))), \
             patch("link.link_up",
                   side_effect=lambda *a: calls.append(("up",))), \
             patch("link.link_down",
                   side_effect=lambda i: calls.append(("down", i))):
            link.restore_link("eth0", {
                "iface": "eth0", "admin_up": False,
                "autoneg": True, "speed_mbps": 1000, "duplex": "full",
                "mac": b"\x00" * 6, "carrier": False,
            })
        assert ("down", "eth0") in calls
        assert not any(c[0] == "up" for c in calls)


# --- temporary_link_down sanity (no actual link mutation) ---

class TestTemporaryLinkDownGuard:

    def test_refuses_if_link_already_down(self):
        with patch("link.link_admin_up", return_value=False):
            with pytest.raises(link.LinkError, match="already administratively down"):
                with link.temporary_link_down("eth0", down_ms=0):
                    pass


# --- wait_for_carrier polling ---

class TestWaitForCarrier:

    def test_returns_immediately_if_already_up(self):
        with patch("link.link_carrier", return_value=True):
            elapsed = link.wait_for_carrier("eth0", deadline_ms=1000)
        assert elapsed >= 0  # monotonic, never negative
        assert elapsed < 0.5  # should be ~instant

    def test_raises_on_timeout(self):
        with patch("link.link_carrier", return_value=False):
            with pytest.raises(link.LinkError, match="did not come up"):
                link.wait_for_carrier("eth0", deadline_ms=50, poll_ms=10)
