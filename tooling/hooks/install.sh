#!/usr/bin/env bash
# install.sh — idempotent git-hook installer for ws_pi5.
#
# Wires .git/hooks/{pre-commit,pre-push} as symlinks to the canonical
# in-repo hook scripts. Run once after a fresh clone; re-runnable
# safely if hooks need to be re-installed (e.g. after a manual rm or
# a git/hooks reset).
#
# Pre-commit fires .claude/hooks/commit-gates.sh which runs:
#   1. Python quality gates  (flake8 / pylint / mypy / pytest)  blocking
#   2. Gemini independent review  on staged .py and .S files     advisory
#   3. make test  (QEMU assembly unit tests)                      blocking
#
# Pre-push fires scripts/pre-push-integration.sh which delegates to
# scripts/pre_push_tests.sh and runs the full A+B+C bucket suite
# (local lint/unit, QEMU, Pi 4 hardware integration + perf).
#
# Both hooks are also fired by the Claude Code harness via the
# PreToolUse / PostToolUse settings in .claude/settings.local.json.
# That path runs the SAME scripts via .claude/hooks/validate-before-commit.sh
# so behaviour is identical inside and outside Claude Code sessions.
#
# Re-running this script is a no-op when symlinks already point to
# the right targets. If a non-symlink hook is in the way (e.g. a stale
# script from a prior workflow), it gets renamed with a .pre-install
# suffix instead of being deleted — manual cleanup if you really want
# the old one gone.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_DIR="$REPO_DIR/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "install.sh: $HOOKS_DIR does not exist — is this a git checkout?" >&2
    exit 1
fi

# Serialize concurrent invocations. Without this, two parallel runs
# could race between the -L/-e check and the mv/ln below and clobber
# each other's just-installed symlinks. The lock file lives inside
# .git/hooks so we don't pollute the working tree.
exec 200>"$HOOKS_DIR/.install.lock"
flock -n 200 || {
    echo "install.sh: another install is in progress (lock held)" >&2
    exit 1
}

install_hook() {
    # install_hook <git-hook-name> <repo-relative-target>
    local hook_name="$1"
    local rel_target="$2"
    local target_abs="$REPO_DIR/$rel_target"
    local link_path="$HOOKS_DIR/$hook_name"

    if [ ! -x "$target_abs" ]; then
        echo "install.sh: target $rel_target is not executable — fix mode bits first" >&2
        exit 1
    fi

    if [ -L "$link_path" ]; then
        local current
        current="$(readlink "$link_path")"
        # Compare resolved absolute paths so a relative-vs-absolute
        # symlink to the same script counts as already-correct.
        local current_abs
        if [[ "$current" = /* ]]; then
            current_abs="$current"
        else
            current_abs="$(cd "$HOOKS_DIR" && readlink -f "$current" 2>/dev/null || echo "")"
        fi
        if [ "$current_abs" = "$target_abs" ]; then
            echo "  $hook_name → $rel_target  (already correct)"
            return 0
        fi
    elif [ -e "$link_path" ]; then
        # mktemp avoids the (rare) sub-second collision possible with
        # date +%s when two installs land back-to-back.
        local backup
        backup="$(mktemp "${link_path}.pre-install.XXXXXX")"
        mv "$link_path" "$backup"
        echo "  $hook_name had a non-symlink hook; moved to $(basename "$backup")"
    fi

    ln -sfn "$target_abs" "$link_path"
    echo "  $hook_name → $rel_target  (installed)"
}

echo "Installing ws_pi5 git hooks (repo: $REPO_DIR)"
install_hook pre-commit ".claude/hooks/commit-gates.sh"
install_hook pre-push   "scripts/pre-push-integration.sh"
echo "Done. Hooks are idempotent — safe to re-run."
