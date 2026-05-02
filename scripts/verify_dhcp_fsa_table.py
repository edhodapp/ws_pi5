"""Cross-check tests/func/dhcp_fsa_vectors.tsv against the compiled
DHCP transition table in the kernel ELF.

The .tsv file is the human-authored spec of what each (state, event)
cell of the DHCP client FSA should encode (D017, RFC 2131 §4.4 +
Figure 5). lib/dhcp_fsa.S compiles a 54-entry .rodata table; this
script reads both and fails loudly if they diverge so the spec
doesn't rot silently under the assembly.

Key encoding detail: lib/dhcp_fsa.S marks "no state transition"
with the sentinel ``DHCP_NEXT_NONE = 0xFFFFFFFF`` in the next_state
slot (NOT zero — zero is a valid state ordinal, S_INIT). The TSV
spelling is the literal string ``NONE``.

Usage::

    python3 scripts/verify_dhcp_fsa_table.py <elf_path> <vectors_tsv>

Exit codes::

    0 — every vector matches the compiled table
    1 — one or more mismatches (printed to stderr)
    2 — setup error (missing file, malformed input, missing symbol)
"""

from __future__ import annotations

import struct
import subprocess
import sys
from pathlib import Path

# State / event ordinals MUST mirror include/dhcp.inc. Duplicated
# here so this script has no asm dependency — .equ values don't
# travel through ELF.
STATES = {
    "S_INIT": 0,
    "S_SELECTING": 1,
    "S_REQUESTING": 2,
    "S_BOUND": 3,
    "S_RENEWING": 4,
    "S_REBINDING": 5,
}
EVENTS = {
    "E_START": 0,
    "E_TIMER_RETRANS_RETRY": 1,
    "E_TIMER_RETRANS_GIVEUP": 2,
    "E_TIMER_T1": 3,
    "E_TIMER_T2": 4,
    "E_TIMER_LEASE": 5,
    "E_RX_OFFER_VALID": 6,
    "E_RX_ACK_VALID": 7,
    "E_RX_NAK_VALID": 8,
}
N_STATES = len(STATES)
N_EVENTS = len(EVENTS)
TRANS_SIZE = 16
NEXT_NONE = 0xFFFFFFFF

OBJDUMP = "aarch64-linux-gnu-objdump"


def load_symbols(elf_path: str) -> dict[str, int]:
    out = subprocess.check_output(
        [OBJDUMP, "-t", elf_path], text=True,
    )
    syms: dict[str, int] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        try:
            vma = int(parts[0], 16)
        except ValueError:
            continue
        syms[parts[-1]] = vma
    return syms


def load_rodata_bytes(elf_path: str) -> tuple[int, bytes]:
    hdr = subprocess.check_output(
        [OBJDUMP, "-h", elf_path], text=True,
    )
    for line in hdr.splitlines():
        parts = line.split()
        if len(parts) < 7 or parts[1] != ".rodata":
            continue
        size = int(parts[2], 16)
        vma = int(parts[3], 16)
        offset = int(parts[5], 16)
        data = Path(elf_path).read_bytes()[offset:offset + size]
        return vma, data
    raise RuntimeError(".rodata section not found in ELF")


def read_table(elf_path: str) -> list[tuple[int, int]]:
    syms = load_symbols(elf_path)
    if "dhcp_fsa_trans_table" not in syms:
        raise RuntimeError(
            "symbol dhcp_fsa_trans_table missing — stale ELF?"
        )
    table_vma = syms["dhcp_fsa_trans_table"]
    rodata_vma, rodata = load_rodata_bytes(elf_path)
    offset = table_vma - rodata_vma
    expected = N_STATES * N_EVENTS * TRANS_SIZE
    if offset < 0 or offset + expected > len(rodata):
        raise RuntimeError(
            "dhcp_fsa_trans_table bounds outside .rodata — ELF drift"
        )
    entries: list[tuple[int, int]] = []
    for i in range(N_STATES * N_EVENTS):
        base = offset + i * TRANS_SIZE
        next_state = struct.unpack_from("<I", rodata, base)[0]
        handler = struct.unpack_from("<Q", rodata, base + 8)[0]
        entries.append((next_state, handler))
    return entries


def _significant_lines(tsv_path: str) -> list[str]:
    out: list[str] = []
    with open(tsv_path, encoding="ascii") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if line.strip() and not line.startswith("#"):
                out.append(line)
    return out


def parse_spec(tsv_path: str) -> list[tuple[str, str, str, str]]:
    lines = _significant_lines(tsv_path)
    if not lines:
        raise RuntimeError(f"empty TSV: {tsv_path}")
    header = lines[0].split("\t")
    if header[0].lower() != "state":
        raise RuntimeError(f"expected TSV header, got {lines[0]!r}")
    rows: list[tuple[str, str, str, str]] = []
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) != 4:
            raise RuntimeError(f"malformed row: {line!r}")
        rows.append((parts[0], parts[1], parts[2], parts[3]))
    return rows


def _check_next(
    idx: int, spec: tuple[str, str, str, str], next_actual: int,
) -> str | None:
    state, event, next_name, _ = spec
    expected = NEXT_NONE if next_name == "NONE" else STATES[next_name]
    if next_actual == expected:
        return None
    return (
        f"cell {idx} ({state}, {event}): NextState mismatch — "
        f"TSV={next_name} ({expected:#x}), ELF={next_actual:#x}"
    )


def _check_handler(
    idx: int,
    spec: tuple[str, str, str, str],
    handler_actual: int,
    syms: dict[str, int],
) -> str | None:
    state, event, _, handler_name = spec
    if handler_name == "NONE":
        expected = 0
    elif handler_name in syms:
        expected = syms[handler_name]
    else:
        return (
            f"cell {idx} ({state}, {event}): handler symbol "
            f"{handler_name!r} not found in ELF"
        )
    if handler_actual == expected:
        return None
    return (
        f"cell {idx} ({state}, {event}): Handler mismatch — "
        f"TSV={handler_name} ({expected:#x}), ELF={handler_actual:#x}"
    )


def _check_one(
    idx: int,
    spec: tuple[str, str, str, str],
    entry: tuple[int, int],
    syms: dict[str, int],
) -> str | None:
    next_actual, handler_actual = entry
    msg = _check_next(idx, spec, next_actual)
    if msg is not None:
        return msg
    return _check_handler(idx, spec, handler_actual, syms)


def _row_index(
    spec: tuple[str, str, str, str],
) -> tuple[int | None, str | None]:
    state, event = spec[0], spec[1]
    if state not in STATES:
        return (None, f"unknown TSV State {state!r}")
    if event not in EVENTS:
        return (None, f"unknown TSV Event {event!r}")
    return (STATES[state] * N_EVENTS + EVENTS[event], None)


def _validate_row(
    spec: tuple[str, str, str, str],
    entries: list[tuple[int, int]],
    syms: dict[str, int],
) -> str | None:
    idx, err = _row_index(spec)
    if err is not None:
        return err
    if idx is None:
        return None
    return _check_one(idx, spec, entries[idx], syms)


def _validate(
    rows: list[tuple[str, str, str, str]],
    entries: list[tuple[int, int]],
    syms: dict[str, int],
) -> list[str]:
    if len(rows) != N_STATES * N_EVENTS:
        return [
            f"TSV has {len(rows)} rows; expected {N_STATES*N_EVENTS}"
        ]
    findings: list[str] = []
    for spec in rows:
        msg = _validate_row(spec, entries, syms)
        if msg is not None:
            findings.append(msg)
    return findings


def _check_paths(elf_path: str, tsv_path: str) -> int:
    for path in (elf_path, tsv_path):
        if not Path(path).is_file():
            print(
                f"verify_dhcp_fsa_table: {path} not found",
                file=sys.stderr,
            )
            return 2
    return 0


def _run(elf_path: str, tsv_path: str) -> int:
    try:
        rows = parse_spec(tsv_path)
        syms = load_symbols(elf_path)
        entries = read_table(elf_path)
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"verify_dhcp_fsa_table: {exc}", file=sys.stderr)
        return 2
    findings = _validate(rows, entries, syms)
    if findings:
        for msg in findings:
            print(f"verify_dhcp_fsa_table: {msg}", file=sys.stderr)
        return 1
    print(
        f"verify_dhcp_fsa_table: ELF and {tsv_path} agree on "
        f"{N_STATES*N_EVENTS} cells"
    )
    return 0


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"Usage: {sys.argv[0]} <elf_path> <vectors_tsv>",
            file=sys.stderr,
        )
        return 2
    elf_path, tsv_path = sys.argv[1], sys.argv[2]
    rc = _check_paths(elf_path, tsv_path)
    if rc != 0:
        return rc
    return _run(elf_path, tsv_path)


if __name__ == "__main__":
    sys.exit(main())
