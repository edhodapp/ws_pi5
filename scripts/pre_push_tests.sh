#!/usr/bin/env bash
# pre_push_tests.sh — A + B + C-functional + C-perf (THE FULL test suite).
#
# What "the full test suite" means per TESTING.md:
#   - Bucket A: local lints + unit + PICT-gen sanity
#   - Bucket B: QEMU unit + functional
#   - Bucket C: hardware functional (L2 L3 L4 L5) + perf (all flavors)
#
# Perf phases run with PERF=recv / PERF=dispatch / PERF=l3 / PERF=send,
# each with its own flash, and the run is rejected if wire_pps drops
# more than 10% vs the median of the last 10 runs (perf_check.py).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/local_tests.sh"
bash "$SCRIPT_DIR/qemu_tests.sh"
bash "$SCRIPT_DIR/hw_tests.sh" L2 L3 L4 L5 perf

echo "=== pre_push_tests: A + B + C + perf all passed ==="
