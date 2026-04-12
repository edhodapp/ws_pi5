"""Tests for scripts/branch_coverage.py."""
# pylint: disable=wrong-import-position

from __future__ import annotations

import sys
import textwrap
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from branch_coverage import (  # noqa: E402
    Branch,
    FunctionCoverage,
    _parse_target,
    compute_coverage,
    parse_trace,
)


class TestParseTarget:
    """Tests for _parse_target operand parsing."""

    def test_bare_hex_with_symbol(self) -> None:
        """objdump: ``cbz x0, 8025c <_start+0x25c>``."""
        operands = "x0, 8025c <_start+0x25c>"
        assert _parse_target(operands, 0x80008) == 0x8025C

    def test_bare_hex_branch(self) -> None:
        """objdump: ``b.eq 80124 <func+0x10>``."""
        operands = "80124 <func+0x10>"
        assert _parse_target(operands, 0x80100) == 0x80124

    def test_tbz_three_operands(self) -> None:
        """objdump: ``tbz w0, #5, 80300 <label>``."""
        operands = "w0, #5, 80300 <label>"
        assert _parse_target(operands, 0x802F0) == 0x80300

    def test_bare_hex_no_symbol(self) -> None:
        """Target without symbol annotation."""
        operands = "x1, 80400"
        assert _parse_target(operands, 0x803F0) == 0x80400

    def test_unparseable_raises(self) -> None:
        """Garbage operands raise ValueError."""
        with pytest.raises(ValueError, match="cannot parse target"):
            _parse_target("completely invalid", 0x0)


class TestParseTrace:
    """Tests for QEMU in_asm trace parsing."""

    def test_extracts_guest_pcs(self, tmp_path: Path) -> None:
        """Parses ``0xADDRESS:`` lines from in_asm output."""
        trace = tmp_path / "trace.log"
        trace.write_text(textwrap.dedent("""\
            ----------------
            IN:
            0x00080000:
            OBJD-T: a00038d500044092

            ----------------
            IN:
            0x00080100:
            OBJD-T: ff4300d1

        """))
        pcs = parse_trace(str(trace))
        assert pcs == {0x80000, 0x80100}

    def test_inline_disasm(self, tmp_path: Path) -> None:
        """Some QEMU versions put disasm on the same line."""
        trace = tmp_path / "trace.log"
        trace.write_text(
            "0x00080000: d53800a0 mrs x0, mpidr_el1\n"
        )
        pcs = parse_trace(str(trace))
        assert pcs == {0x80000}

    def test_ignores_non_pc_lines(self, tmp_path: Path) -> None:
        """Non-address lines are skipped."""
        trace = tmp_path / "trace.log"
        trace.write_text("IN:\nOBJD-T: deadbeef\n")
        pcs = parse_trace(str(trace))
        assert pcs == set()


class TestComputeCoverage:
    """Tests for compute_coverage hit marking."""

    def test_both_sides_hit(self) -> None:
        """Branch with both target and fallthrough executed."""
        branch = Branch(
            addr=0x100, mnemonic="b.eq", operands="",
            target=0x200, fallthrough=0x104,
        )
        compute_coverage([branch], {0x200, 0x104})
        assert branch.taken_hit is True
        assert branch.fallthrough_hit is True

    def test_only_taken(self) -> None:
        """Branch where only the target was executed."""
        branch = Branch(
            addr=0x100, mnemonic="cbz", operands="",
            target=0x200, fallthrough=0x104,
        )
        compute_coverage([branch], {0x200})
        assert branch.taken_hit is True
        assert branch.fallthrough_hit is False

    def test_unreached(self) -> None:
        """Branch that was never executed."""
        branch = Branch(
            addr=0x100, mnemonic="b.ne", operands="",
            target=0x200, fallthrough=0x104,
        )
        compute_coverage([branch], set())
        assert branch.taken_hit is False
        assert branch.fallthrough_hit is False


class TestFunctionCoverage:
    """Tests for FunctionCoverage aggregation."""

    def test_counts(self) -> None:
        """Verify total/fully_covered/partial/uncovered counts."""
        full = Branch(
            addr=0, mnemonic="", operands="",
            target=0, fallthrough=0,
            taken_hit=True, fallthrough_hit=True,
        )
        partial = Branch(
            addr=0, mnemonic="", operands="",
            target=0, fallthrough=0,
            taken_hit=True, fallthrough_hit=False,
        )
        none = Branch(
            addr=0, mnemonic="", operands="",
            target=0, fallthrough=0,
        )
        fc = FunctionCoverage(
            name="test", branches=[full, partial, none],
        )
        assert fc.total == 3
        assert fc.fully_covered == 1
        assert fc.partial == 1
        assert fc.uncovered == 1
