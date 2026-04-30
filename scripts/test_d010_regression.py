"""D010 regression guard — production code must not read NET_MASK_NBO.

Per D010 in docs/DECISIONS.md, the IP stack uses always-via-gateway
routing with no subnet-mask-based decision; NET_MASK_NBO is dead
code today and is deleted in I13. This test asserts the invariant
going forward: any production code (lib/, platform/, chainload/)
that introduces a reference to NET_MASK_NBO will fail this test
loudly, regardless of whether the constant is reintroduced via a
local .equ, a #define, or any other mechanism.

Sibling NET_*_NBO macros (NET_IP_NBO, NET_GW_NBO) are alive — they
are QEMU defaults consumed by lib/net_cfg.S — so the guard targets
NET_MASK_NBO specifically, not the family.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROD_DIRS = ("lib", "platform", "chainload")
BANNED_SYMBOL = "NET_MASK_NBO"
SCAN_GLOBS = ("*.S", "*.inc")


def _scan_dir(root: Path) -> list[str]:
    """Return diagnostic strings for any line containing BANNED_SYMBOL
    under root (recursive)."""
    matches: list[str] = []
    paths: list[Path] = []
    for pattern in SCAN_GLOBS:
        paths.extend(root.rglob(pattern))
    for path in paths:
        text = path.read_text(encoding="utf-8")
        for line_no, line in enumerate(text.splitlines(), start=1):
            if BANNED_SYMBOL in line:
                matches.append(
                    f"{path.relative_to(REPO_ROOT)}:{line_no}: "
                    f"{line.strip()}"
                )
    return matches


def test_no_net_mask_nbo_in_production_code() -> None:
    """No production .S or .inc file references NET_MASK_NBO."""
    matches: list[str] = []
    for prod_dir in PROD_DIRS:
        root = REPO_ROOT / prod_dir
        if root.is_dir():
            matches.extend(_scan_dir(root))
    assert not matches, (
        f"D010 regression — {len(matches)} production reference(s) "
        f"to {BANNED_SYMBOL}:\n"
        + "\n".join(f"  {m}" for m in matches)
    )
