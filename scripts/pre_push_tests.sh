#!/usr/bin/env bash
# pre_push_tests.sh — A + B + C-functional + C-perf (THE FULL test suite).
#
# What "the full test suite" means per TESTING.md:
#   - Bucket A: local lints + unit + PICT-gen sanity
#   - Bucket B: QEMU unit + functional
#   - Bucket C: hardware functional (L2 L3 L4 L5) + loose perf gate
#
# Perf phases run with PERF=recv / PERF=dispatch / PERF=l3 / PERF=send,
# each with its own flash. The pre-push gate is intentionally LOOSE
# (perf_push.sh: 1 run, 75% tolerance) so single-run host-side
# scheduling jitter doesn't block a push that's otherwise clean. The
# strict best-of-3 / 50% gate runs nightly via perf_nightly.sh when
# the host is quiet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/local_tests.sh"
bash "$SCRIPT_DIR/qemu_tests.sh"
bash "$SCRIPT_DIR/hw_tests.sh" L2 L3 L4 L5
bash "$SCRIPT_DIR/perf_push.sh"

echo "=== pre_push_tests: A + B + C + perf all passed ==="
