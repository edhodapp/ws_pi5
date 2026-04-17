#!/usr/bin/env python3
"""Branch coverage analyzer for bare-metal AArch64 test kernels.

Compares the set of conditional branches in an ELF binary (via objdump)
against the set of translated-block entry PCs logged by QEMU's
``-d in_asm`` flag.  For each conditional branch, reports whether
the taken side (target) and the fall-through side (next instruction)
were both executed.

Usage::

    qemu-system-aarch64 -M raspi3b -kernel build/test_kernel8.img \\
        -serial file:/dev/null -display none \\
        -d in_asm -D build/qemu_trace.log &
    # ... wait for QEMU to finish ...
    python scripts/branch_coverage.py \\
        build/test_kernel8.elf build/qemu_trace.log

Requires ``aarch64-linux-gnu-objdump`` and
``aarch64-linux-gnu-addr2line`` on PATH.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


# AArch64 conditional branch mnemonics that create two-way control flow.
# Unconditional branches (b, bl, ret, br, blr) are excluded — they have
# only one successor and aren't "branches" in the coverage sense.
_COND_BRANCH_RE = re.compile(
    r"^"
    r"\s*([0-9a-f]+):\s+"     # address
    r"[0-9a-f]+\s+"           # raw hex encoding
    r"(b\.\w+|cbz|cbnz|tbz|tbnz)"  # mnemonic
    r"\s+(.+)"                # operands (includes target)
    r"$",
)

# QEMU ``-d in_asm`` guest PC: ``0x00080000:`` (possibly followed
# by disassembly on the same line in some QEMU versions).
_INASM_RE = re.compile(r"^0x([0-9a-f]+):")


@dataclass
class Branch:
    """A single conditional branch instruction."""

    addr: int
    mnemonic: str
    operands: str
    target: int
    fallthrough: int
    source_file: str = ""
    source_line: int = 0
    taken_hit: bool = False
    fallthrough_hit: bool = False


@dataclass
class FunctionCoverage:
    """Aggregated coverage for one function."""

    name: str
    branches: list[Branch] = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.branches)

    @property
    def fully_covered(self) -> int:
        return sum(
            1
            for b in self.branches
            if b.taken_hit and b.fallthrough_hit
        )

    @property
    def partial(self) -> int:
        return sum(
            1
            for b in self.branches
            if (b.taken_hit or b.fallthrough_hit)
            and not (b.taken_hit and b.fallthrough_hit)
        )

    @property
    def uncovered(self) -> int:
        return sum(
            1
            for b in self.branches
            if not b.taken_hit and not b.fallthrough_hit
        )


def _parse_target(operands: str, addr: int) -> int:
    """Extract the absolute branch target from the operand string.

    objdump formats vary::

        b.eq  80124 <func+0x10>
        cbz   x0, 8025c <_start+0x25c>
        tbz   w0, #5, 80300 <label>

    The target is a bare hex number (no 0x prefix) followed by
    optional ``<symbol+offset>``.  For tbz/tbnz it's the last
    such token.
    """
    # Strip angle-bracket annotations: "<func+0x10>"
    cleaned = re.sub(r"<[^>]+>", "", operands)
    tokens = cleaned.replace(",", " ").split()
    for token in reversed(tokens):
        bare = token.lstrip("#").strip()
        # objdump bare hex: "80124" (no 0x prefix)
        if re.fullmatch(r"[0-9a-fA-F]+", bare):
            return int(bare, 16)
    raise ValueError(
        f"cannot parse target: {operands!r} at 0x{addr:x}"
    )


def parse_objdump(elf_path: str) -> tuple[list[Branch], dict[int, str]]:
    """Run objdump and extract conditional branches + symbol map.

    Returns (branches, addr_to_symbol) where addr_to_symbol maps each
    function-entry address to its symbol name.
    """
    result = subprocess.run(
        ["aarch64-linux-gnu-objdump", "-d", elf_path],
        capture_output=True,
        text=True,
        check=True,
    )

    branches: list[Branch] = []
    addr_to_symbol: dict[int, str] = {}
    current_symbol = "<unknown>"

    # Symbol header: ``0000000000080000 <_start>:``
    sym_re = re.compile(r"^([0-9a-f]+)\s+<([^>]+)>:")

    for line in result.stdout.splitlines():
        sym_match = sym_re.match(line)
        if sym_match:
            sym_addr = int(sym_match.group(1), 16)
            current_symbol = sym_match.group(2)
            addr_to_symbol[sym_addr] = current_symbol
            continue

        branch_match = _COND_BRANCH_RE.match(line)
        if branch_match:
            addr = int(branch_match.group(1), 16)
            mnemonic = branch_match.group(2)
            operands = branch_match.group(3)
            target = _parse_target(operands, addr)
            branches.append(
                Branch(
                    addr=addr,
                    mnemonic=mnemonic,
                    operands=operands.strip(),
                    target=target,
                    fallthrough=addr + 4,
                )
            )

    return branches, addr_to_symbol


def parse_trace(trace_path: str) -> set[int]:
    """Parse QEMU ``-d in_asm`` log for translated-block entry PCs.

    Each ``IN:`` block header is followed by ``0xADDRESS:`` — the
    guest PC where a translated block starts.  The set of these PCs
    equals the set of code addresses executed at least once (QEMU
    translates a block on first execution).
    """
    executed: set[int] = set()
    with open(trace_path, encoding="ascii") as fh:
        for line in fh:
            match = _INASM_RE.match(line)
            if match:
                executed.add(int(match.group(1), 16))
    return executed


def resolve_sources(
    branches: list[Branch], elf_path: str,
) -> None:
    """Use addr2line to map branch addresses to source file:line."""
    if not branches:
        return
    addrs = [f"0x{b.addr:x}" for b in branches]
    result = subprocess.run(
        ["aarch64-linux-gnu-addr2line", "-e", elf_path, "-f"] + addrs,
        capture_output=True,
        text=True,
        check=False,
    )
    lines = result.stdout.splitlines()
    # addr2line -f outputs two lines per address: function name, then
    # file:line.
    for i, branch in enumerate(branches):
        idx = i * 2 + 1
        if idx < len(lines):
            loc = lines[idx]
            if ":" in loc and "?" not in loc:
                parts = loc.rsplit(":", 1)
                branch.source_file = parts[0]
                branch.source_line = int(parts[1]) if parts[1].isdigit() else 0


def assign_functions(
    branches: list[Branch], addr_to_symbol: dict[int, str],
) -> dict[str, FunctionCoverage]:
    """Group branches by their enclosing function."""
    # Sort symbol addresses so we can binary-search.
    sym_addrs = sorted(addr_to_symbol.keys())
    result: dict[str, FunctionCoverage] = {}

    for branch in branches:
        # Find the last symbol address <= branch.addr
        func_name = "<unknown>"
        for sa in reversed(sym_addrs):
            if sa <= branch.addr:
                func_name = addr_to_symbol[sa]
                break
        if func_name not in result:
            result[func_name] = FunctionCoverage(name=func_name)
        result[func_name].branches.append(branch)

    return result


def compute_coverage(
    branches: list[Branch], executed_pcs: set[int],
) -> None:
    """Mark each branch's taken/fallthrough as hit or not."""
    for branch in branches:
        branch.taken_hit = branch.target in executed_pcs
        branch.fallthrough_hit = branch.fallthrough in executed_pcs


def _source_loc(branch: Branch) -> str:
    """Format source location for display."""
    if branch.source_file:
        name = branch.source_file.rsplit("/", 1)[-1]
        return f"{name}:{branch.source_line}"
    return f"0x{branch.addr:x}"


def _branch_mark(branch: Branch) -> str:
    """Return a coverage marker string for one branch."""
    if branch.taken_hit and branch.fallthrough_hit:
        return "  ✓"
    if branch.taken_hit or branch.fallthrough_hit:
        side = "taken" if branch.taken_hit else "fallthrough"
        return f"  ✗ only {side}"
    return "  ✗ UNREACHED"


def _print_function(fc: FunctionCoverage) -> None:
    """Print coverage detail for one function."""
    status = "✓" if fc.fully_covered == fc.total else "✗"
    print(
        f"  {fc.name}: "
        f"{fc.fully_covered}/{fc.total} branches {status}"
    )
    for b in fc.branches:
        print(
            f"    {_source_loc(b):24s} "
            f"{b.mnemonic:6s} {b.operands:30s}"
            f" {_branch_mark(b)}"
        )


def _group_by_file(
    functions: dict[str, FunctionCoverage],
    source_filter: str | None,
) -> dict[str, list[FunctionCoverage]]:
    """Group functions by source file, applying filter.

    The filter matches against source file paths (from addr2line)
    AND against function/symbol names (from objdump).  This allows
    filtering even when debug info is absent.
    """
    result: dict[str, list[FunctionCoverage]] = {}
    for fc in sorted(functions.values(), key=lambda f: f.name):
        if not fc.branches:
            continue
        src = fc.branches[0].source_file or "<unknown>"
        if source_filter:
            if source_filter not in src and source_filter not in fc.name:
                continue
        result.setdefault(src, []).append(fc)
    return result


def report(
    functions: dict[str, FunctionCoverage],
    source_filter: str | None = None,
) -> tuple[int, int]:
    """Print coverage report.  Returns (total, fully_covered)."""
    total = 0
    covered = 0
    file_funcs = _group_by_file(functions, source_filter)

    for src_file, funcs in sorted(file_funcs.items()):
        short = src_file.rsplit("/", 1)[-1]
        print(f"\n{short}:")
        for fc in funcs:
            total += fc.total
            covered += fc.fully_covered
            _print_function(fc)

    print(f"\nSUMMARY: {covered}/{total} branches fully covered")
    if total > 0:
        print(f"         {100.0 * covered / total:.1f}%")
    return total, covered


def main() -> None:
    """Entry point."""
    if len(sys.argv) < 3:
        print(
            f"Usage: {sys.argv[0]} <elf_file> <qemu_trace_log>"
            " [source_filter]",
            file=sys.stderr,
        )
        sys.exit(1)

    elf_path = sys.argv[1]
    trace_path = sys.argv[2]
    source_filter = sys.argv[3] if len(sys.argv) > 3 else None

    for path in (elf_path, trace_path):
        if not Path(path).exists():
            print(f"Error: {path} not found", file=sys.stderr)
            sys.exit(1)

    branches, addr_to_symbol = parse_objdump(elf_path)
    executed_pcs = parse_trace(trace_path)
    compute_coverage(branches, executed_pcs)
    resolve_sources(branches, elf_path)
    functions = assign_functions(branches, addr_to_symbol)
    total, covered = report(functions, source_filter)

    if total > 0 and covered < total:
        sys.exit(1)


if __name__ == "__main__":
    main()
