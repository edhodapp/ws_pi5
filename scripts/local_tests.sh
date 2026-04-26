#!/usr/bin/env bash
# local_tests.sh — Bucket A: local-only test runner (no QEMU, no Pi).
#
# Phases:
#   1. Python lints (flake8, pylint, mypy --strict) on staged or all .py
#   2. Python unit tests (hw_test/test_*_unit.py)
#   3. PICT vector-generation sanity (verify pict produces non-empty .tsv)
#
# Gemini review is invoked separately via the pre-commit hook
# (~/tools/code-review/claude-precommit-review.sh).
#
# Usage:
#   scripts/local_tests.sh         # all phases
#   scripts/local_tests.sh lints   # only lints
#   scripts/local_tests.sh unit    # only Python unit tests
#   scripts/local_tests.sh pict    # only PICT vector sanity
#
# See TESTING.md for the bucket taxonomy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

VENV="$PROJECT_DIR/.venv/bin/python"
if [ ! -x "$VENV" ]; then
    echo "ERROR: .venv not found" >&2
    exit 1
fi

PHASES=("$@")
if [ "${#PHASES[@]}" -eq 0 ]; then
    PHASES=(lints unit pict)
fi

run_lints() {
    echo "=== Bucket A / Python lints ==="
    bash "$HOME/tools/code-review/run-python-gates.sh"
}

run_unit() {
    echo "=== Bucket A / Python unit tests ==="
    HW_TEST=0 "$VENV" -m pytest \
        hw_test/test_eth_frames_unit.py \
        hw_test/test_ip_frames_unit.py \
        hw_test/test_link_unit.py \
        hw_test/test_wire_unit.py \
        --tb=short -q
}

run_pict() {
    echo "=== Bucket A / PICT vector-generation sanity ==="
    if ! command -v pict >/dev/null 2>&1; then
        echo "WARN: pict not installed; skipping PICT sanity check"
        return 0
    fi
    mkdir -p build
    local fail=0
    for model in tests/func/*.pict; do
        [ -f "$model" ] || continue
        local out
        out="build/$(basename "$model" .pict)_sanity.tsv"
        if ! timeout 60 pict "$model" /o:max > "$out" 2>/dev/null; then
            echo "  FAIL: pict failed on $model"
            fail=1
            continue
        fi
        local lines
        lines=$(wc -l < "$out")
        if [ "$lines" -lt 2 ]; then
            echo "  FAIL: $model produced $lines lines (expected >= 2: header + ≥1 vector)"
            fail=1
            continue
        fi
        echo "  ok: $model → $lines lines"
    done
    if [ "$fail" -eq 1 ]; then
        echo "FAIL: PICT vector-generation sanity failed"
        return 1
    fi
}

for phase in "${PHASES[@]}"; do
    case "$phase" in
        lints) run_lints ;;
        unit)  run_unit ;;
        pict)  run_pict ;;
        *) echo "ERROR: unknown phase '$phase'" >&2; exit 1 ;;
    esac
done

echo "=== Bucket A: all requested phases passed ==="
