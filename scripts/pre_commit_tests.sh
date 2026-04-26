#!/usr/bin/env bash
# pre_commit_tests.sh — A + B + C-functional (no perf).
#
# What "running the pre-commit suite" means per TESTING.md:
#   - Bucket A: local lints + unit + PICT-gen sanity
#   - Bucket B: QEMU unit + functional
#   - Bucket C: hardware functional (L2 L3 L4 L5), no perf phases
#
# Pre-push runs the same plus C-perf. See pre_push_tests.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/local_tests.sh"
bash "$SCRIPT_DIR/qemu_tests.sh"
bash "$SCRIPT_DIR/hw_tests.sh" L2 L3 L4 L5

echo "=== pre_commit_tests: A + B + C-functional all passed ==="
