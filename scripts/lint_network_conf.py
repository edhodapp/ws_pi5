#!/usr/bin/env python3
"""lint_network_conf.py — validate network.conf per D003/D006/D012.

The linter is the executable spec for ws_pi5's network.conf format.
Both this Python implementation (used as a flash-time gate by
``mk_sd.sh``) and the bare-metal asm parser are locked to the same
TSV vector file at ``tests/func/network_conf_vectors.tsv`` — a
divergence between the two surfaces immediately as a failing
parametrized test.

Invocation::

    lint_network_conf.py path/to/network.conf [--quiet]

Exit codes:
  0 — file is valid
  1 — file is invalid; per-error diagnostics on stderr
  2 — IO error reading the file
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable
from pathlib import Path

from pydantic import BaseModel

# --- Format constants --------------------------------------------------------

MAGIC = "# WSPI5CFG"
REQUIRED_KEYS: tuple[str, ...] = ("ip", "netmask", "gateway", "hostname")
OPTIONAL_KEYS: tuple[str, ...] = ("ntp_server", "mac")
ALL_KEYS: frozenset[str] = frozenset(REQUIRED_KEYS) | frozenset(OPTIONAL_KEYS)
HOSTNAME_MAX_LEN = 63

# Hostname character classes per D006 / RFC 1123 LDH:
_LDH = frozenset("abcdefghijklmnopqrstuvwxyz"
                 "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                 "0123456789-")
_LDH_FIRST = _LDH - {"-"}


# --- Result types (pydantic per project convention) -------------------------

class LintError(BaseModel):
    """One diagnostic from the linter.

    line is 1-indexed; line=0 means "applies to file as a whole."
    code is one of E_MAGIC, E_LINE, E_KEY, E_DUP, E_REQ, E_IP, E_HOST, E_MAC.
    """

    line: int
    code: str
    message: str


class LintResult(BaseModel):
    """Outcome of a single lint() call."""

    ok: bool
    config: dict[str, str]
    errors: list[LintError]


# --- Per-value validators ---------------------------------------------------

def _is_valid_octet(p: str) -> bool:
    if not p or not p.isdigit():
        return False
    # Reject leading-zero octets like "010" — different IP stacks
    # interpret them inconsistently (some as octal, e.g. CVE-2021-29921
    # class). Force unambiguous decimal: a single "0" is fine, but
    # "010" is not.
    if len(p) > 1 and p[0] == "0":
        return False
    return int(p) <= 255


def _validate_ip(s: str) -> bool:
    parts = s.split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not _is_valid_octet(p):
            return False
    return True


def _validate_hostname(s: str) -> bool:
    if not s or len(s) > HOSTNAME_MAX_LEN:
        return False
    if s[0] not in _LDH_FIRST:
        return False
    return all(c in _LDH for c in s)


def _is_valid_mac_byte(p: str) -> bool:
    if len(p) != 2:
        return False
    try:
        int(p, 16)
    except ValueError:
        return False
    return True


def _validate_mac(s: str) -> bool:
    parts = s.split(":")
    if len(parts) != 6:
        return False
    return all(_is_valid_mac_byte(p) for p in parts)


# Per-key validator dispatch. Each entry is
# (predicate, error-code, message-format-with-one-{!r}-slot).
# Six keys consumed uniformly — table is justified per
# feedback_no_premature_tables: this is not "size for future entries,"
# it's "every existing entry has identical shape."
_VALIDATORS: dict[str, tuple[Callable[[str], bool], str, str]] = {
    "ip": (_validate_ip, "E_IP",
           "malformed IPv4 dotted-decimal: {!r}"),
    "netmask": (_validate_ip, "E_IP",
                "malformed IPv4 dotted-decimal: {!r}"),
    "gateway": (_validate_ip, "E_IP",
                "malformed IPv4 dotted-decimal: {!r}"),
    "ntp_server": (_validate_ip, "E_IP",
                   "malformed IPv4 dotted-decimal: {!r}"),
    "hostname": (_validate_hostname, "E_HOST",
                 "hostname must be 1-63 LDH chars, first letter/digit; "
                 "got {!r}"),
    "mac": (_validate_mac, "E_MAC",
            "MAC must be six colon-separated 2-digit hex bytes; got {!r}"),
}


# --- Line-level helpers -----------------------------------------------------

def _strip_inline_comment(s: str) -> str:
    # Shell-style inline comment: '#' starts a comment ONLY when
    # preceded by whitespace, or when it's the first character of the
    # line. This way "hostname=my#name" stays "my#name" (and falls to
    # E_HOST validation rather than silently truncating to a valid
    # "my"), but "ip=10.0.0.2 # static IP" still strips properly.
    for i, c in enumerate(s):
        if c == "#" and (i == 0 or s[i - 1].isspace()):
            return s[:i]
    return s


def _check_magic(lines: list[str]) -> tuple[int, LintError | None]:
    """Return (1-indexed magic line, None) on success;
    (0, LintError) on failure (line=0 means "no magic anywhere")."""
    for i, raw in enumerate(lines, start=1):
        if not raw.strip():
            continue
        if raw.strip() == MAGIC:
            return i, None
        return 0, LintError(
            line=i, code="E_MAGIC",
            message=(f"first non-empty line must be {MAGIC!r}; "
                     f"got {raw.strip()!r}"),
        )
    return 0, LintError(
        line=0, code="E_MAGIC",
        message="empty file or no magic sentinel found",
    )


def _validate_value(lineno: int, key: str, value: str) -> LintError | None:
    validator, code, fmt = _VALIDATORS[key]
    if validator(value):
        return None
    return LintError(line=lineno, code=code, message=fmt.format(value))


def _classify_kv(
    lineno: int, key: str, value: str, config: dict[str, str],
) -> LintError | None:
    if key not in ALL_KEYS:
        return LintError(
            line=lineno, code="E_KEY",
            message=f"unknown key: {key!r}",
        )
    if key in config:
        return LintError(
            line=lineno, code="E_DUP",
            message=f"duplicate key: {key!r}",
        )
    return _validate_value(lineno, key, value)


def _parse_line(
    lineno: int, raw: str, config: dict[str, str],
) -> LintError | None:
    line = _strip_inline_comment(raw).strip()
    if not line:
        return None
    if "=" not in line:
        return LintError(
            line=lineno, code="E_LINE",
            message=f"line lacks '=': {line!r}",
        )
    key, _, value = line.partition("=")
    err = _classify_kv(lineno, key.strip(), value.strip(), config)
    if err is None:
        config[key.strip()] = value.strip()
    return err


def _check_required(config: dict[str, str]) -> list[LintError]:
    return [
        LintError(
            line=0, code="E_REQ",
            message=f"required key missing: {k!r}",
        )
        for k in REQUIRED_KEYS if k not in config
    ]


# --- Public lint entry point ------------------------------------------------

def lint(text: str) -> LintResult:
    """Lint a network.conf text. See module docstring for rules."""
    config: dict[str, str] = {}
    lines = text.split("\n")
    magic_lineno, magic_err = _check_magic(lines)
    if magic_err is not None:
        return LintResult(ok=False, config=config, errors=[magic_err])
    errors: list[LintError] = []
    for i, raw in enumerate(lines, start=1):
        if i <= magic_lineno:
            continue
        err = _parse_line(i, raw, config)
        if err is not None:
            errors.append(err)
    errors.extend(_check_required(config))
    return LintResult(ok=not errors, config=config, errors=errors)


# --- CLI --------------------------------------------------------------------

def _print_failure(path: Path, errors: list[LintError]) -> None:
    print(f"lint_network_conf: {path} INVALID", file=sys.stderr)
    for err in errors:
        line_str = f"line {err.line}" if err.line > 0 else "file"
        print(
            f"  {line_str}: {err.code}: {err.message}", file=sys.stderr,
        )


def _print_success(path: Path, config: dict[str, str]) -> None:
    print(f"lint_network_conf: {path} ok")
    for k in REQUIRED_KEYS + OPTIONAL_KEYS:
        if k in config:
            print(f"  {k}={config[k]}")


def main() -> int:
    # `__doc__ or ""` survives `python -OO` (which strips docstrings).
    ap = argparse.ArgumentParser(
        description=(__doc__ or "").split("\n", maxsplit=1)[0],
    )
    ap.add_argument("path", type=Path, help="network.conf to validate")
    ap.add_argument(
        "--quiet", action="store_true", help="no output on success",
    )
    args = ap.parse_args()
    try:
        # utf-8-sig silently strips a leading BOM (Windows Notepad
        # writes one by default). UnicodeDecodeError covers the
        # genuinely-not-UTF-8 case so the CLI exits 2 with a message
        # instead of crashing with a traceback.
        text = args.path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as e:
        print(
            f"lint_network_conf: cannot read {args.path}: {e}",
            file=sys.stderr,
        )
        return 2
    result = lint(text)
    if not result.ok:
        _print_failure(args.path, result.errors)
        return 1
    if not args.quiet:
        _print_success(args.path, result.config)
    return 0


if __name__ == "__main__":
    sys.exit(main())
