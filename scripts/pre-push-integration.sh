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

# When this script is invoked via the .git/hooks/pre-push symlink,
# BASH_SOURCE[0] points at the symlink, not the real file. Resolve
# the symlink so SCRIPT_DIR lands in scripts/ where pre_push_tests.sh
# actually lives.
REAL_SOURCE="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SOURCE")" && pwd)"
exec bash "$SCRIPT_DIR/pre_push_tests.sh" "$@"
