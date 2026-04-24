"""Cross-check tests/func/http_output_fsa_vectors.tsv against the
compiled transition table in the kernel ELF.

The .tsv file is the human-authored spec of what each (state, event)
cell of the output FSA's transition table should dispatch to. The
kernel's lib/http_output_fsa.S encodes the same information in a
32-entry .rodata block. This script reads both and fails loudly if
they diverge, so the spec doesn't rot silently under the assembly.

Usage::

    python3 scripts/verify_fsa_table.py <elf_path> <vectors_tsv>

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

# State / event constants mirror include/http.inc. Duplicated here so
# the script has no dependency on the assembler output — symbol values
# of .equ constants don't travel through ELF.
STATES = {
    "O_IDLE": 0,
    "O_SETUP": 1,
    "O_TX": 2,
    "O_DRAINING": 3,
}
EVENTS = {
    "E_RESP_READY": 0,
    "E_WIN_OPEN": 1,
    "E_CHUNK_SENT": 2,
    "E_ALL_QUEUED": 3,
    "E_ALL_DRAINED": 4,
    "E_TCP_CLOSED": 5,
    "E_DO_CLOSE": 6,
    "E_DO_KEEPALIVE": 7,
}
N_STATES = 4
N_EVENTS = 8
TRANS_SIZE = 16   # u32 next_state, u32 pad, u64 handler


def load_symbols(elf_path: str) -> dict[str, int]:
    """Return a {symbol_name: vma} map from an ELF file."""
    out = subprocess.check_output(
        ["aarch64-linux-gnu-objdump", "-t", elf_path], text=True,
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
        name = parts[-1]
        syms[name] = vma
    return syms


def load_rodata_bytes(elf_path: str) -> tuple[int, bytes]:
    """Return (section_vma, section_bytes) for .rodata."""
    # Get the section header for .rodata.
    hdr = subprocess.check_output(
        ["aarch64-linux-gnu-objdump", "-h", elf_path], text=True,
    )
    vma = size = offset = -1
    for line in hdr.splitlines():
        parts = line.split()
        if len(parts) < 7 or parts[1] != ".rodata":
            continue
        size = int(parts[2], 16)
        vma = int(parts[3], 16)
        offset = int(parts[5], 16)
        break
    if vma < 0:
        raise RuntimeError(".rodata section not found in ELF")

    data = Path(elf_path).read_bytes()[offset:offset + size]
    return vma, data


def read_table(elf_path: str) -> list[tuple[int, int]]:
    """Return [(next_state, handler_vma)] for each table entry."""
    syms = load_symbols(elf_path)
    if "http_fsa_trans_table" not in syms:
        raise RuntimeError("symbol http_fsa_trans_table missing — stale ELF?")
    table_vma = syms["http_fsa_trans_table"]
    rodata_vma, rodata = load_rodata_bytes(elf_path)
    offset = table_vma - rodata_vma
    if offset < 0 or offset + N_STATES * N_EVENTS * TRANS_SIZE > len(rodata):
        raise RuntimeError("table bounds outside .rodata — ELF layout drift")

    entries: list[tuple[int, int]] = []
    for i in range(N_STATES * N_EVENTS):
        base = offset + i * TRANS_SIZE
        next_state = struct.unpack_from("<I", rodata, base)[0]
        handler = struct.unpack_from("<Q", rodata, base + 8)[0]
        entries.append((next_state, handler))
    return entries


def parse_spec(tsv_path: str) -> list[tuple[str, str, str, str]]:
    """Yield (state, event, next_state, handler) tuples from the .tsv."""
    rows: list[tuple[str, str, str, str]] = []
    with open(tsv_path, encoding="ascii") as handle:
        header_seen = False
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if not header_seen:
                if parts[0].lower() != "state":
                    raise RuntimeError(f"expected TSV header, got {line!r}")
                header_seen = True
                continue
            if len(parts) != 4:
                raise RuntimeError(f"malformed row: {line!r}")
            rows.append(tuple(parts))  # type: ignore[arg-type]
    return rows


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"Usage: {sys.argv[0]} <elf_path> <vectors_tsv>",
            file=sys.stderr,
        )
        return 2
    elf_path, tsv_path = sys.argv[1], sys.argv[2]
    for path in (elf_path, tsv_path):
        if not Path(path).is_file():
            print(f"verify_fsa_table: {path} not found", file=sys.stderr)
            return 2

    try:
        rows = parse_spec(tsv_path)
        syms = load_symbols(elf_path)
        table = read_table(elf_path)
    except RuntimeError as exc:
        print(f"verify_fsa_table: {exc}", file=sys.stderr)
        return 2

    if len(rows) != N_STATES * N_EVENTS:
        print(
            f"verify_fsa_table: .tsv has {len(rows)} rows, "
            f"expected {N_STATES * N_EVENTS}",
            file=sys.stderr,
        )
        return 2

    mismatches = 0
    for state_name, event_name, expected_next, expected_handler in rows:
        if state_name not in STATES or event_name not in EVENTS:
            print(
                f"verify_fsa_table: unknown state/event "
                f"{state_name}/{event_name}",
                file=sys.stderr,
            )
            return 2
        idx = STATES[state_name] * N_EVENTS + EVENTS[event_name]
        actual_next, actual_handler = table[idx]

        if expected_handler == "NONE":
            exp_handler_vma = 0
        else:
            if expected_handler not in syms:
                print(
                    f"verify_fsa_table: handler {expected_handler} "
                    f"not exported from ELF",
                    file=sys.stderr,
                )
                return 2
            exp_handler_vma = syms[expected_handler]

        # "NONE" in the spec means the table cell is empty: the engine
        # reports STEP_NO_TRANS, and the next_state column is don't-
        # care. Any non-NONE value must match the compiled entry.
        if expected_next == "NONE":
            exp_next = 0
        else:
            exp_next = STATES[expected_next]

        next_ok = (expected_next == "NONE") or (actual_next == exp_next)
        handler_ok = actual_handler == exp_handler_vma
        if not (next_ok and handler_ok):
            print(
                f"  MISMATCH [{state_name}, {event_name}]"
                f" spec=(next={expected_next}, handler={expected_handler})"
                f" actual=(next={actual_next},"
                f" handler=0x{actual_handler:x})",
                file=sys.stderr,
            )
            mismatches += 1

    if mismatches > 0:
        print(
            f"verify_fsa_table: {mismatches} mismatch(es)",
            file=sys.stderr,
        )
        return 1
    print(f"verify_fsa_table: {len(rows)} cells match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
