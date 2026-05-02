"""test_lint_dhcp_fsa_vectors.py — pytest cases for the DHCP FSA linter.

Each test seeds a small TSV (positive or negative) and asserts the
linter's exit status + finding count. The committed
tests/func/dhcp_fsa_vectors.tsv is also tested as a positive case
to catch regressions in the spec itself.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=line-too-long,inconsistent-quotes
# mypy: ignore-errors

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LINTER = REPO / "scripts" / "lint_dhcp_fsa_vectors.py"
COMMITTED_TSV = REPO / "tests" / "func" / "dhcp_fsa_vectors.tsv"

sys.path.insert(0, str(REPO / "scripts"))
# pylint: disable=wrong-import-position
from lint_dhcp_fsa_vectors import EVENTS as _EVENTS  # noqa: E402
from lint_dhcp_fsa_vectors import STATES as _STATES  # noqa: E402

VENV_PY = REPO / ".venv" / "bin" / "python3"
PY = str(VENV_PY) if VENV_PY.exists() else sys.executable

HEADER = "State\tEvent\tNextState\tHandler"

# Ordered lists for stable grid construction. A separate test
# (`test_lists_agree_with_linter_sets`) enforces that these lists
# stay in sync with the linter's authoritative sets.
STATES = [
    "S_INIT", "S_SELECTING", "S_REQUESTING",
    "S_BOUND", "S_RENEWING", "S_REBINDING",
]
EVENTS = [
    "E_START", "E_TIMER_RETRANS_RETRY", "E_TIMER_RETRANS_GIVEUP",
    "E_TIMER_T1", "E_TIMER_T2", "E_TIMER_LEASE",
    "E_RX_OFFER_VALID", "E_RX_ACK_VALID", "E_RX_NAK_VALID",
]


def _full_grid() -> list[str]:
    """Build a 54-row valid grid (every cell NONE/NONE)."""
    return [HEADER] + [
        f"{s}\t{e}\tNONE\tNONE" for s in STATES for e in EVENTS
    ]


def _run_linter(tsv_text: str, tmp_path: Path) -> subprocess.CompletedProcess:
    target = tmp_path / "test_vectors.tsv"
    target.write_text(tsv_text, encoding="utf-8")
    return subprocess.run(
        [PY, str(LINTER), str(target)],
        capture_output=True, text=True, check=False,
    )


def test_committed_spec_passes():
    """The committed dhcp_fsa_vectors.tsv must lint clean."""
    result = subprocess.run(
        [PY, str(LINTER), str(COMMITTED_TSV)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, (
        "committed spec failed lint:\n"
        f"STDOUT:{result.stdout}\nSTDERR:{result.stderr}"
    )


def test_lists_agree_with_linter_sets():
    """Local ordered lists must contain exactly the linter's sets."""
    assert set(STATES) == set(_STATES), (
        f"test STATES {set(STATES)} != linter STATES {set(_STATES)}"
    )
    assert set(EVENTS) == set(_EVENTS), (
        f"test EVENTS {set(EVENTS)} != linter EVENTS {set(_EVENTS)}"
    )


def test_full_valid_grid(tmp_path):
    result = _run_linter("\n".join(_full_grid()) + "\n", tmp_path)
    assert result.returncode == 0


def test_bad_header(tmp_path):
    bad = "State\tEvent\tNext\tHandler\n"
    result = _run_linter(bad, tmp_path)
    assert result.returncode == 1
    assert "header" in result.stderr


def test_unknown_state(tmp_path):
    rows = _full_grid()
    rows[1] = "S_BOGUS\tE_START\tNONE\tNONE"
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 1
    assert "unknown State" in result.stderr


def test_unknown_event(tmp_path):
    rows = _full_grid()
    rows[1] = "S_INIT\tE_BOGUS\tNONE\tNONE"
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 1
    assert "unknown Event" in result.stderr


def test_missing_cell(tmp_path):
    rows = _full_grid()
    # Drop the (S_INIT, E_START) cell
    drop = "S_INIT\tE_START"
    rows = [rows[0]] + [r for r in rows[1:] if not r.startswith(drop)]
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 1
    assert "missing cell" in result.stderr


def test_duplicate_pair(tmp_path):
    rows = _full_grid()
    rows.append("S_INIT\tE_START\tNONE\tNONE")
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 1
    assert "duplicate" in result.stderr


def test_bad_handler_prefix(tmp_path):
    rows = _full_grid()
    rows[1] = "S_INIT\tE_START\tS_SELECTING\twrong_prefix"
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 1
    assert "Handler" in result.stderr


def test_none_next_with_non_panic_handler(tmp_path):
    """NextState=NONE must pair with NONE or h_panic_d."""
    rows = _full_grid()
    rows[1] = "S_INIT\tE_START\tNONE\th_some_action"
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 1
    assert "h_panic_d" in result.stderr


def test_none_next_with_h_panic_d_allowed(tmp_path):
    """NextState=NONE with Handler=h_panic_d is allowed."""
    rows = _full_grid()
    rows[1] = "S_INIT\tE_START\tNONE\th_panic_d"
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 0


def test_non_none_next_with_no_handler(tmp_path):
    """NextState!=NONE must have a handler."""
    rows = _full_grid()
    rows[1] = "S_INIT\tE_START\tS_SELECTING\tNONE"
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 1


def test_missing_file():
    result = subprocess.run(
        [PY, str(LINTER), "/tmp/does-not-exist-xyzzy.tsv"],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 2


def test_blank_lines_skipped(tmp_path):
    """Stray blank lines in the middle/end must not produce false errors."""
    rows = _full_grid()
    rows.insert(5, "")
    rows.append("")
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 0


def test_panic_d_with_non_none_next_rejected(tmp_path):
    """h_panic_d never returns; pairing it with a NextState is a spec bug."""
    rows = _full_grid()
    rows[1] = "S_INIT\tE_START\tS_SELECTING\th_panic_d"
    result = _run_linter("\n".join(rows) + "\n", tmp_path)
    assert result.returncode == 1
    assert "never returns" in result.stderr
