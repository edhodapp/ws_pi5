#!/usr/bin/env bash
# pre-push-integration.sh — backward-compat alias for pre_push_tests.sh.
#
# This script used to be the pre-push runner directly, but it embedded
# `-m l2` and silently deselected 297 tests for weeks. The new implementation
# runs the FULL test suite (Bucket A + B + C, including all perf phases)
# per TESTING.md.
#
# If you have a git hook installed that invokes this path:
#   ln -sf scripts/pre-push-integration.sh .git/hooks/pre-push
# the symlink keeps working — this file just delegates to the new driver.
#
# For new installs, prefer:
#   ln -sf scripts/pre_push_tests.sh .git/hooks/pre-push
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/pre_push_tests.sh" "$@"
