#!/usr/bin/env bash
# qemu_tests.sh — Bucket B: QEMU-based test runner.
#
# Runs the full QEMU test suite with the discipline of a clean build
# per phase, since Pi 4 vs raspi3b builds aren't binary-compatible and
# stale objects from the wrong target produce silent corruption.
#
# Phases:
#   1. make test            — unit tests on QEMU raspi3b
#   2. make test-functional — PICT vectors executed against QEMU kernel
#
# Each phase does its own `make clean` first.
#
# Usage:
#   scripts/qemu_tests.sh                # all phases
#   scripts/qemu_tests.sh unit           # only the unit suite
#   scripts/qemu_tests.sh functional     # only PICT functional
#
# See TESTING.md for the full bucket taxonomy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PHASES=("$@")
if [ "${#PHASES[@]}" -eq 0 ]; then
    PHASES=(unit functional)
fi

run_unit() {
    echo "=== Bucket B / unit tests (QEMU raspi3b) ==="
    make clean
    make test
}

run_functional() {
    echo "=== Bucket B / functional tests (PICT on QEMU raspi3b) ==="
    make clean
    make test-functional
}

for phase in "${PHASES[@]}"; do
    case "$phase" in
        unit)        run_unit ;;
        functional)  run_functional ;;
        *)
            echo "ERROR: unknown phase '$phase' (valid: unit, functional)" >&2
            exit 1
            ;;
    esac
done

echo "=== Bucket B: all requested phases passed ==="
