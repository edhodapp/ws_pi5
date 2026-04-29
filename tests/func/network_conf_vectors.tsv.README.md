# network_conf_vectors.tsv — format spec

This README is the canonical reference for the vector file format.
It binds two consumers:

1. The Python loader in `scripts/test_lint_network_conf.py`
   (drives the `lint()` function).
2. The asm parser test (I9, future) — must produce byte-identical
   results to the linter on every PASS vector and must reject every
   FAIL vector with the documented panic-pattern code.

Per D012, divergence between the two consumers surfaces as a failing
test. That works only if both follow this spec exactly.

## Columns

Tab-separated, four columns, header row required:

| Column     | Meaning                                                      |
|------------|--------------------------------------------------------------|
| `name`     | Short identifier; used as the pytest parametrize id.         |
|            | Convention: `p_*` for PASS vectors, `f_*` for FAIL.          |
| `expected` | Either `PASS` or `FAIL`. No other values.                    |
| `code`     | Linter error code expected when `expected=FAIL`. `NONE` for  |
|            | PASS vectors.                                                |
| `input`    | The literal `network.conf` text, with escape sequences as    |
|            | documented below.                                            |

## Escape sequences in the `input` column

TSV cells cannot contain literal newlines or carriage returns
without breaking the line-based parser. Two escape sequences are
defined:

| Escape | Substitution     |
|--------|------------------|
| `\n`   | newline (`\n`)   |
| `\r`   | carriage return  |

**No other escapes are defined.** In particular:

- There is no escape for a literal backslash (`\\` is NOT
  special). A literal backslash in the cell stays a literal
  backslash. None of the network.conf format fields per D003 admit
  backslashes, so this isn't a real loss.
- There is no `\t` escape — TSV's own delimiter is the tab, so
  embedding a tab in the input column is structurally impossible.
- There is no `\\n` (literal-backslash-n) escape — `\n` in a cell
  always becomes newline. A vector that needs a literal `\n` cannot
  be written; no such vector exists today.

**Substitution is single-pass.** A vector containing the literal
sequence `\\n` (two characters, backslash-backslash-n) has its
first `\n` substituted, yielding `\` followed by newline. Don't
write vectors that depend on multi-pass substitution.

## Error codes

The `code` column for FAIL vectors must be one of:

| Code      | Meaning                                                  |
|-----------|----------------------------------------------------------|
| `E_MAGIC` | Magic sentinel missing, malformed, or not on first non- |
|           | empty line.                                              |
| `E_LINE`  | Line lacks `=` and is not a comment / blank line.        |
| `E_KEY`   | Key not in the known set.                                |
| `E_DUP`   | Same key appears twice.                                  |
| `E_REQ`   | A required key is missing from the file.                 |
| `E_IP`    | A value bound to ip / netmask / gateway / ntp_server is  |
|           | not a valid IPv4 dotted-decimal.                         |
| `E_HOST`  | Hostname does not satisfy D006 (LDH, length 1–63,        |
|           | first char letter or digit).                             |
| `E_MAC`   | MAC is not six colon-separated 2-digit hex bytes.        |

The pytest assertion checks **set membership**: a FAIL vector
passes if its expected `code` is present in `result.errors`,
regardless of order or co-occurrence with other errors. This is
deliberate — a single malformed line can naturally cascade into
other errors (e.g. missing magic also implies missing required
keys), and we only want to pin the *primary* diagnostic code.

## Philosophy: syntactic, not semantic

The linter validates **syntax only**. It does not check whether
network configuration values make logical sense. Specifically:

- `ip=0.0.0.0` is a valid IPv4 address syntactically; the linter
  accepts it. At runtime the stack will fail to communicate
  (no addressed interface), but that is a runtime concern.
- `gateway=0.0.0.0` likewise — it's syntactically valid but
  semantically a "no route" sentinel. Runtime will fail to ARP and
  the appliance will halt with panic pattern G (gateway
  unreachable, see D013).
- `gateway=255.255.255.255` (broadcast) and `gateway` set to a
  multicast or otherwise non-unicast address are likewise
  syntactically accepted; runtime catches them.

If the runtime checks ever move into the linter, document the
shift in a new D-entry and add the corresponding FAIL vectors.

## Adding a vector

1. Pick a name (`p_foo` or `f_foo`).
2. Decide PASS or FAIL.
3. For FAIL: pick the *primary* error code the linter should emit.
4. Construct the `input` cell with `\n` for newlines.
5. Run `pytest scripts/test_lint_network_conf.py::test_vector` —
   the new row appears as its own parametrized case.

Once the asm parser test (I9) lands, every new vector is
automatically exercised against both implementations.
