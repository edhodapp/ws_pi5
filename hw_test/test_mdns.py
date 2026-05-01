"""
test_mdns.py — mDNS responder integration tests (D008)

Verifies the Pi 4 answers an A query for its configured hostname via
avahi-resolve. Assumes:
  - The Pi has booted with a network.conf whose `hostname=` matches
    the value of PI4_HOSTNAME below (default "wspi5").
  - The host machine has `avahi-resolve` installed (apt: avahi-utils).
  - avahi-daemon is running on the host so the local side does
    advertise/listen on 224.0.0.251.

Run with:
    HW_TEST=1 pytest hw_test/test_mdns.py -v
"""

# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=unused-import,inconsistent-quotes,line-too-long
# mypy: ignore-errors

import os
import shutil
import subprocess

import pytest

from conftest import (  # noqa: F401
    requires_hardware, PI4_IP, TEST_TIMEOUT,
)

PI4_HOSTNAME = os.environ.get("PI4_HOSTNAME", "wspi5")
PI4_FQDN = f"{PI4_HOSTNAME}.local"

pytestmark = pytest.mark.l5


def _avahi_available() -> bool:
    return shutil.which("avahi-resolve") is not None


@requires_hardware
@pytest.mark.skipif(not _avahi_available(), reason="avahi-resolve not installed")
class TestMDNS:

    def test_resolve_hostname_returns_pi_ip(self):
        """avahi-resolve -n <hostname>.local returns PI4_IP.

        avahi-resolve prints `<fqdn>\\t<ip>` on a single line on
        success; non-zero exit on miss/timeout.
        """
        proc = subprocess.run(
            ["avahi-resolve", "-4", "-n", PI4_FQDN],
            capture_output=True, text=True, timeout=TEST_TIMEOUT + 2,
            check=False,
        )
        assert proc.returncode == 0, (
            f"avahi-resolve failed: rc={proc.returncode} "
            f"stderr={proc.stderr.strip()!r}"
        )
        # Expected format: "<fqdn>\t<ip>\n"
        parts = proc.stdout.strip().split()
        assert len(parts) == 2, f"unexpected avahi output: {proc.stdout!r}"
        resolved_name, resolved_ip = parts
        assert resolved_name == PI4_FQDN, (
            f"resolved name {resolved_name!r} != expected {PI4_FQDN!r}"
        )
        assert resolved_ip == PI4_IP, (
            f"resolved {PI4_FQDN} → {resolved_ip}, expected {PI4_IP}"
        )

    def test_resolve_unknown_hostname_fails(self):
        """A query for a clearly-unrelated name on .local must NOT
        resolve to PI4_IP. Sanity check that the responder isn't
        answering for arbitrary names."""
        bogus = "definitely-not-our-hostname-9f8e7d.local"
        proc = subprocess.run(
            ["avahi-resolve", "-4", "-n", bogus],
            capture_output=True, text=True, timeout=TEST_TIMEOUT + 2,
            check=False,
        )
        # Either non-zero exit (no responder) or stdout doesn't contain
        # PI4_IP — we just need to confirm we didn't claim the name.
        assert PI4_IP not in proc.stdout, (
            f"Pi answered for {bogus!r}: {proc.stdout!r}"
        )
