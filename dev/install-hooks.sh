#!/usr/bin/env bash
# Install git hooks for ccblocks development

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Installing git hooks..."

# Point git at the checked-in .githooks/ instead of copying anything into
# .git/hooks: one source of truth that cannot drift, and it works in worktrees
# and submodules where .git is a file rather than a directory.
git -C "$PROJECT_ROOT" config core.hooksPath .githooks

echo "✓ Hooks installed (core.hooksPath → .githooks)"

# core.hooksPath shadows .git/hooks completely - git stops looking there for
# EVERY hook, not just the ones .githooks/ provides. Anything already
# installed locally (a machine-wide CI gate, a secret scanner) would go quiet
# with no error, so name each one. .githooks/pre-push chains through to a
# local pre-push, which is why a matching name here is not a problem.
#
# `--git-path hooks` cannot be used to find them: it honours core.hooksPath,
# which was just set, so it would report .githooks and every hook would look
# like it had a counterpart. --git-common-dir ignores core.hooksPath.
git_common_dir="$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir)"
case "$git_common_dir" in
/*) ;;
*) git_common_dir="$(cd "$PROJECT_ROOT/$git_common_dir" && pwd)" ;;
esac
git_hooks_dir="$git_common_dir/hooks"
if [ -d "$git_hooks_dir" ]; then
	for local_hook in "$git_hooks_dir"/*; do
		if [ ! -f "$local_hook" ] || [ ! -x "$local_hook" ]; then
			continue
		fi

		hook_name="$(basename "$local_hook")"
		case "$hook_name" in
		*.sample) continue ;;
		esac

		if [ ! -e "$PROJECT_ROOT/.githooks/$hook_name" ]; then
			echo ""
			echo "!!! WARNING: $hook_name exists in .git/hooks but core.hooksPath now shadows it; it will NOT run"
			echo "!!!   Local hook: $local_hook"
			echo "!!!   To keep it, add a .githooks/$hook_name that chains to it (see .githooks/pre-push)."
		fi
	done
fi
echo ""
echo "To skip hooks on commit (not recommended):"
echo "  git commit --no-verify"
