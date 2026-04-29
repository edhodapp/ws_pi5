"""Test lint_network_conf against the shared TSV vector file.

The TSV at tests/func/network_conf_vectors.tsv is the executable
spec for the network.conf format (D012). Each row exercises one
input scenario and asserts:
  - PASS rows: lint() returns ok=True with no errors.
  - FAIL rows: lint() returns ok=False AND at least one error has
    the expected code (lets a single FAIL vector tolerate
    cascading errors as long as the *primary* code is what we
    expected — e.g. a missing-magic file naturally also lacks the
    required keys, but only E_MAGIC is the relevant diagnostic).

The same TSV will drive the asm parser test (I9). Any divergence
between the two implementations surfaces as an asm test failure.
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path

import pytest

# Make the scripts/ directory importable when pytest runs from repo
# root (which is the project's pytest configuration).
_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

import lint_network_conf as M  # noqa: E402  pylint: disable=wrong-import-position

VECTORS_PATH = Path(__file__).resolve().parent.parent \
    / "tests" / "func" / "network_conf_vectors.tsv"


def _load_vectors() -> list[dict[str, str]]:
    """Parse the TSV. The 'input' column escape grammar is documented
    in tests/func/network_conf_vectors.tsv.README.md and is the
    canonical reference for both this loader and the asm parser test.
    Escape sequences supported, in order: '\\\\n' → newline,
    '\\\\r' → CR. No other escapes (no '\\\\\\\\' for literal backslash —
    the format spec doesn't need it). Substitution is single-pass and
    does NOT re-process the result."""
    with VECTORS_PATH.open(encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        rows = []
        for row in reader:
            row["input"] = (
                row["input"].replace("\\n", "\n").replace("\\r", "\r")
            )
            rows.append(row)
        return rows


_VECTORS = _load_vectors()


@pytest.mark.parametrize(
    "vector",
    _VECTORS,
    ids=[v["name"] for v in _VECTORS],
)
def test_vector(vector: dict[str, str]) -> None:
    result = M.lint(vector["input"])
    if vector["expected"] == "PASS":
        assert result.ok, (
            f"vector {vector['name']!r} expected PASS but got errors: "
            f"{[(e.code, e.message) for e in result.errors]}"
        )
        return
    assert vector["expected"] == "FAIL", (
        f"vector {vector['name']!r} has unknown 'expected' value: "
        f"{vector['expected']!r}"
    )
    assert not result.ok, (
        f"vector {vector['name']!r} expected FAIL but linter passed; "
        f"parsed config: {result.config!r}"
    )
    expected_code = vector["code"]
    found_codes = {e.code for e in result.errors}
    assert expected_code in found_codes, (
        f"vector {vector['name']!r} expected error code "
        f"{expected_code!r} but got: {sorted(found_codes)}"
    )


def test_vectors_file_exists() -> None:
    """Smoke: the TSV file is in the expected place and has rows."""
    assert VECTORS_PATH.exists(), (
        f"missing vector file: {VECTORS_PATH}"
    )
    assert _VECTORS, "vector file is empty"


def test_vector_codes_are_known() -> None:
    """Every FAIL vector references a code the linter could emit."""
    known = {"E_MAGIC", "E_LINE", "E_KEY", "E_DUP",
             "E_REQ", "E_IP", "E_HOST", "E_MAC"}
    for v in _VECTORS:
        if v["expected"] == "FAIL":
            assert v["code"] in known, (
                f"vector {v['name']!r} has unknown error code "
                f"{v['code']!r}; expected one of {sorted(known)}"
            )
