#!/usr/bin/env python3
"""Oracle for HTTP FSA transition table verification.

Reads PICT vectors (state, char_class) and outputs expected
(next_state, action) based on the authoritative transition table.

Usage::

    pict tests/func/http_fsa.pict /o:max |
        python3 scripts/http_fsa_oracle.py >
        tests/func/http_fsa_vectors.tsv
"""

import sys

# State constants
STATES = [
    "S_METHOD", "S_M_SP", "S_URI", "S_U_SP",
    "S_VH", "S_VT1", "S_VT2", "S_VP",
    "S_VSLASH", "S_VMAJ", "S_VDOT", "S_VMIN",
    "S_RL_CR", "S_HDR_ST", "S_HDR_NM", "S_HDR_VL",
    "S_HDR_CR", "S_END_CR", "S_DONE", "S_ERROR",
]

CLASSES = [
    "CC_ALPHA", "CC_DIGIT", "CC_SP", "CC_CR", "CC_LF",
    "CC_COLON", "CC_SLASH", "CC_DOT", "CC_OTHER",
]

S = {n: i for i, n in enumerate(STATES)}
C = {n: i for i, n in enumerate(CLASSES)}
ERR = S["S_ERROR"]

# Authoritative transition table: table[state][class] = (action, next_state)
# Actions: 0=none, 1=uri_start, 2=uri_end, 3=ver_minor,
#          4=hdr_name_start, 5=hdr_check_host, 6=req_done
T: dict[int, dict[int, tuple[int, int]]] = {}


def row(
    state: int,
    transitions: dict[int, tuple[int, int]],
) -> None:
    """Define transitions for a state. Unspecified → ERROR."""
    T[state] = {c: (0, ERR) for c in range(len(CLASSES))}
    for cc, (a, n) in transitions.items():
        T[state][cc] = (a, n)


# Build the table
A, D, SP, CR, LF, CO, SL, DT, OT = range(9)

row(S["S_METHOD"],  {A: (0, S["S_METHOD"]), SP: (0, S["S_M_SP"])})
row(S["S_M_SP"],    {A: (1, S["S_URI"]), D: (1, S["S_URI"]),
                     CO: (1, S["S_URI"]), SL: (1, S["S_URI"]),
                     DT: (1, S["S_URI"]), OT: (1, S["S_URI"])})
row(S["S_URI"],     {A: (0, S["S_URI"]), D: (0, S["S_URI"]),
                     SP: (2, S["S_U_SP"]), CO: (0, S["S_URI"]),
                     SL: (0, S["S_URI"]), DT: (0, S["S_URI"]),
                     OT: (0, S["S_URI"])})
row(S["S_U_SP"],    {A: (0, S["S_VH"])})
row(S["S_VH"],      {A: (0, S["S_VT1"])})
row(S["S_VT1"],     {A: (0, S["S_VT2"])})
row(S["S_VT2"],     {A: (0, S["S_VP"])})
row(S["S_VP"],      {SL: (0, S["S_VSLASH"])})
row(S["S_VSLASH"],  {D: (0, S["S_VMAJ"])})
row(S["S_VMAJ"],    {DT: (0, S["S_VDOT"])})
row(S["S_VDOT"],    {D: (3, S["S_VMIN"])})
row(S["S_VMIN"],    {CR: (0, S["S_RL_CR"])})
row(S["S_RL_CR"],   {LF: (0, S["S_HDR_ST"])})
row(S["S_HDR_ST"],  {A: (4, S["S_HDR_NM"]), CR: (0, S["S_END_CR"])})
row(S["S_HDR_NM"],  {A: (0, S["S_HDR_NM"]), D: (0, S["S_HDR_NM"]),
                     CO: (5, S["S_HDR_VL"]), SL: (0, S["S_HDR_NM"]),
                     DT: (0, S["S_HDR_NM"]), OT: (0, S["S_HDR_NM"])})
row(S["S_HDR_VL"],  {A: (0, S["S_HDR_VL"]), D: (0, S["S_HDR_VL"]),
                     SP: (0, S["S_HDR_VL"]), CR: (0, S["S_HDR_CR"]),
                     CO: (0, S["S_HDR_VL"]), SL: (0, S["S_HDR_VL"]),
                     DT: (0, S["S_HDR_VL"]), OT: (0, S["S_HDR_VL"])})
row(S["S_HDR_CR"],  {LF: (0, S["S_HDR_ST"])})
row(S["S_END_CR"],  {LF: (6, S["S_DONE"])})
row(S["S_DONE"],    {c: (0, S["S_DONE"]) for c in range(9)})
row(S["S_ERROR"],   {c: (0, S["S_ERROR"]) for c in range(9)})

# Verify completeness
assert len(T) == 20, f"Expected 20 states, got {len(T)}"
for s in range(20):
    assert s in T, f"Missing state {s}"
    assert len(T[s]) == 9, f"State {s}: expected 9 classes, got {len(T[s])}"


def encode(action: int, state: int) -> int:
    """Encode (action, state) as a single byte."""
    return (action << 5) | state


# Read PICT vectors from stdin, produce TSV
header = sys.stdin.readline().strip()
print("State\tCharClass\tExpNextState\tExpAction\tEncoded")

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    state_name, cc_name = line.split("\t")
    si = S[state_name]
    ci = C[cc_name]
    act, ns = T[si][ci]
    enc = encode(act, ns)
    print(f"{state_name}\t{cc_name}\t{STATES[ns]}\t{act}\t0x{enc:02X}")
