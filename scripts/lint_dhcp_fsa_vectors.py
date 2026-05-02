#!/usr/bin/env python3
"""lint_dhcp_fsa_vectors.py — validate the DHCP FSA transition TSV.

The TSV at tests/func/dhcp_fsa_vectors.tsv is the human-authored spec
for the DHCP client state machine (per D017, RFC 2131 §4.4 + Figure
5). The asm step function in lib/dhcp_fsa.S will be locked to this
table via `make verify-dhcp-fsa-table`; this lint runs first, in
isolation, so spec-level typos surface before any asm referencing
the same state/event constants is touched.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from pydantic import BaseModel

STATES = frozenset({
    "S_INIT",
    "S_SELECTING",
    "S_REQUESTING",
    "S_BOUND",
    "S_RENEWING",
    "S_REBINDING",
})
EVENTS = frozenset({
    "E_START",
    "E_TIMER_RETRANS_RETRY",
    "E_TIMER_RETRANS_GIVEUP",
    "E_TIMER_T1",
    "E_TIMER_T2",
    "E_TIMER_LEASE",
    "E_RX_OFFER_VALID",
    "E_RX_ACK_VALID",
    "E_RX_NAK_VALID",
})
HEADER = ("State", "Event", "NextState", "Handler")
PANIC_HANDLER = "h_panic_d"


class LintFinding(BaseModel):
    line: int
    message: str


def _check_header(rows: list[str]) -> list[LintFinding]:
    if not rows:
        return [LintFinding(line=0, message="empty file")]
    header = tuple(rows[0].split("\t"))
    if header != HEADER:
        return [LintFinding(
            line=1,
            message=f"header {header!r} != expected {HEADER!r}",
        )]
    return []


def _check_state_event(line: int, state: str, event: str) -> list[LintFinding]:
    findings: list[LintFinding] = []
    if state not in STATES:
        findings.append(LintFinding(
            line=line, message=f"unknown State {state!r}",
        ))
    if event not in EVENTS:
        findings.append(LintFinding(
            line=line, message=f"unknown Event {event!r}",
        ))
    return findings


def _check_shape(
    line: int, next_state: str, handler: str,
) -> list[LintFinding]:
    findings: list[LintFinding] = []
    if next_state != "NONE" and next_state not in STATES:
        findings.append(LintFinding(
            line=line,
            message=(
                f"NextState {next_state!r} is neither NONE "
                "nor a known State"
            ),
        ))
    if handler != "NONE" and not handler.startswith("h_"):
        findings.append(LintFinding(
            line=line,
            message=f"Handler {handler!r} must be NONE or start with 'h_'",
        ))
    return findings


def _check_consistency(
    line: int, next_state: str, handler: str,
) -> list[LintFinding]:
    findings: list[LintFinding] = []
    if next_state == "NONE" and handler not in ("NONE", PANIC_HANDLER):
        findings.append(LintFinding(
            line=line,
            message=(
                f"NextState=NONE with Handler={handler!r}; only "
                f"{PANIC_HANDLER} is allowed as a non-returning handler"
            ),
        ))
    if next_state != "NONE" and handler == "NONE":
        findings.append(LintFinding(
            line=line,
            message=(
                f"NextState={next_state} with Handler=NONE — a non-NONE "
                "transition must execute a handler"
            ),
        ))
    if handler == PANIC_HANDLER and next_state != "NONE":
        findings.append(LintFinding(
            line=line,
            message=(
                f"Handler={PANIC_HANDLER} (never returns) requires "
                f"NextState=NONE, got {next_state!r}"
            ),
        ))
    return findings


def _check_transition(
    line: int, next_state: str, handler: str,
) -> list[LintFinding]:
    findings = _check_shape(line, next_state, handler)
    findings.extend(_check_consistency(line, next_state, handler))
    return findings


def _parse_row(
    line: int, row: str,
) -> tuple[list[LintFinding], tuple[str, str] | None]:
    cells = row.split("\t")
    if len(cells) != 4:
        return ([LintFinding(
            line=line,
            message=f"expected 4 tab-separated cells, got {len(cells)}",
        )], None)
    state, event, next_state, handler = cells
    findings = _check_state_event(line, state, event)
    findings.extend(_check_transition(line, next_state, handler))
    return (findings, (state, event))


def _check_completeness(seen: set[tuple[str, str]]) -> list[LintFinding]:
    expected = {(s, e) for s in STATES for e in EVENTS}
    return [
        LintFinding(line=0, message=f"missing cell ({s}, {e})")
        for s, e in sorted(expected - seen)
    ]


def _lint(path: Path) -> list[LintFinding]:
    text = path.read_text(encoding="utf-8")
    rows = [r for r in text.split("\n") if r.strip()]
    findings = _check_header(rows)
    if findings:
        return findings
    seen: set[tuple[str, str]] = set()
    for idx, row in enumerate(rows[1:], start=2):
        row_findings, key = _parse_row(idx, row)
        findings.extend(row_findings)
        if key is not None:
            if key in seen:
                findings.append(LintFinding(
                    line=idx,
                    message=f"duplicate (State, Event) pair {key}",
                ))
            seen.add(key)
    findings.extend(_check_completeness(seen))
    return findings


def _run_lint(target: Path) -> tuple[int, list[LintFinding]]:
    if not target.is_file():
        print(
            f"lint_dhcp_fsa_vectors: {target} not found",
            file=sys.stderr,
        )
        return (2, [])
    try:
        return (0, _lint(target))
    except (OSError, UnicodeDecodeError) as exc:
        print(
            f"lint_dhcp_fsa_vectors: cannot read {target}: {exc}",
            file=sys.stderr,
        )
        return (2, [])


def _report(target: Path, findings: list[LintFinding], quiet: bool) -> int:
    if findings:
        for finding in findings:
            print(
                "lint_dhcp_fsa_vectors: "
                f"{target}:{finding.line}: {finding.message}",
                file=sys.stderr,
            )
        return 1
    if not quiet:
        cells = len(STATES) * len(EVENTS)
        print(f"lint_dhcp_fsa_vectors: {target} ok ({cells} cells)")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("path")
    args = parser.parse_args(argv)
    target = Path(args.path)
    setup_rc, findings = _run_lint(target)
    if setup_rc != 0:
        return setup_rc
    return _report(target, findings, args.quiet)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
