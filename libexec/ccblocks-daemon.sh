#!/usr/bin/env bash

# ccblocks Trigger Script
# Triggers a new Claude Code block via LaunchAgent (macOS) or systemd (Linux)
# Runs in user session with full authentication access

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Ensure config directory exists
mkdir -p "$CCBLOCKS_CONFIG" 2>/dev/null || true

# No runtime PATH bootstrap. The scheduler injects PATH at start time.

# Find Claude CLI (prefer PATH, then user-local installs, then system locations).
# Prints the path on stdout, or nothing when no CLI is found.
find_claude_bin() {
	local claude_bin=""
	local candidate

	# Support test mode to simulate Claude not found
	if is_flag_enabled "${CCBLOCKS_TEST_NO_CLAUDE:-}"; then
		return 0
	fi

	claude_bin=$(command -v claude 2>/dev/null || true)
	if [ -z "$claude_bin" ]; then
		for candidate in \
			"$HOME/.local/share/mise/shims/claude" \
			"$HOME/.local/bin/claude"; do
			if [ -x "$candidate" ]; then
				claude_bin="$candidate"
				break
			fi
		done
	fi

	# System-wide install locations (cheap, fixed paths - check these
	# before the recursive find below, which can be slow on a large or
	# network-mounted $HOME/.local)
	if [ -z "$claude_bin" ]; then
		for candidate in \
			"/opt/homebrew/bin/claude" \
			"/usr/local/bin/claude" \
			"/home/linuxbrew/.linuxbrew/bin/claude"; do
			if [ -x "$candidate" ]; then
				claude_bin="$candidate"
				break
			fi
		done
	fi

	# Last-resort recursive search under ~/.local (may be a shim). Bounded
	# in depth and wall-clock time so a huge or slow $HOME/.local can't
	# stall a scheduled trigger. Depth 8 covers deeper layouts like mise's
	# non-shim installs tree (~/.local/share/mise/installs/<tool>/<ver>/bin/)
	# with margin to spare, at negligible extra cost given the timeout.
	if [ -z "$claude_bin" ]; then
		claude_bin=$(run_with_timeout 5 find "$HOME/.local" -maxdepth 8 -name claude -type f -perm -100 2>/dev/null | head -1 || true)
	fi

	printf '%s' "$claude_bin"
}

# Optional post-trigger verification using ccusage. Returns 1 only when
# ccusage definitely reports no active block; an inconclusive, empty or
# missing result is not treated as a failure.
verify_block_active() {
	if ! command_exists ccusage; then
		print_warning "ccusage not found; skipping trigger verification"
		return 0
	fi

	# Give Claude a brief moment to update backend state
	sleep 1
	local usage_out usage_out_trimmed
	usage_out="$(ccusage blocks --active 2>/dev/null || true)"

	# Trim whitespace for more robust matching
	usage_out_trimmed="$(printf '%s\n' "$usage_out" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

	# Debug logging when CCBLOCKS_DEBUG is enabled
	if is_flag_enabled "${CCBLOCKS_DEBUG:-}"; then
		echo "[DEBUG] ccusage output: '$usage_out_trimmed'"
	fi

	# Check for empty output
	if [ -z "$usage_out_trimmed" ]; then
		print_warning "Trigger verification inconclusive (ccusage returned empty output)"
		if is_flag_enabled "${CCBLOCKS_DEBUG:-}"; then
			echo "[DEBUG] Empty output may indicate ccusage command succeeded but no data available"
		fi
		return 0
	fi

	# Check for failure indicators
	if grep -qiE "No active blocks|Session expired|No active session" <<<"$usage_out_trimmed"; then
		return 1
	fi

	# Check for success indicators (more flexible patterns)
	if grep -qiE "Time remaining|Current session|Block [0-9]+ \(Current\)|[0-9]+h [0-9]+m|Active block" <<<"$usage_out_trimmed"; then
		return 0
	fi

	# Unknown output; do not fail hard, just warn with details
	print_warning "Trigger verification inconclusive (ccusage output unrecognised)"
	if is_flag_enabled "${CCBLOCKS_DEBUG:-}"; then
		echo "[DEBUG] Unrecognised output: '$usage_out_trimmed'"
	else
		# In non-debug mode, log to system for troubleshooting
		log_to_system "ccusage verification inconclusive. Output: ${usage_out_trimmed:0:100}"
	fi
	return 0
}

CLAUDE_BIN="$(find_claude_bin)"

if [ -z "$CLAUDE_BIN" ]; then
	print_error "Claude CLI not found"
	# print_error writes to stderr; keep its continuation lines on the
	# same stream so a redirect never shows half the diagnostic.
	{
		echo "Tried:"
		echo "  - PATH ($PATH)"
		echo "  - $HOME/.local/ (recursive search)"
		echo ""
		echo "To install Claude CLI, visit: https://claude.ai"
	} >&2
	log_to_system "Failed to locate Claude CLI"
	exit 1
fi

require_subscription_auth "$CLAUDE_BIN"

# Trigger new 5-hour block
timestamp=$(date '+%Y-%m-%d %H:%M:%S')

# Run claude, capturing stdout and stderr separately so this preserves the
# pre-existing behaviour exactly: stdout is suppressed unless
# CCBLOCKS_DEBUG=1, but stderr is always shown regardless of success or failure.
# This is the scheduled entry point, so clean the captures up on any exit
# path rather than only the happy one.
stdout_tmp=$(mktemp "${TMPDIR:-/tmp}/ccblocks-trigger-out.XXXXXX")
stderr_tmp=$(mktemp "${TMPDIR:-/tmp}/ccblocks-trigger-err.XXXXXX")
trap 'rm -f "$stdout_tmp" "$stderr_tmp"' EXIT
rc=0
run_claude_subscription_trigger "$CLAUDE_BIN" >"$stdout_tmp" 2>"$stderr_tmp" || rc=$?
claude_stdout=$(cat "$stdout_tmp")
claude_stderr=$(cat "$stderr_tmp")

if is_flag_enabled "${CCBLOCKS_DEBUG:-}" && [ -n "$claude_stdout" ]; then
	printf '%s\n' "$claude_stdout"
fi
if [ -n "$claude_stderr" ]; then
	printf '%s\n' "$claude_stderr" >&2
fi

if [ $rc -eq 0 ]; then
	verify_fail=0
	verify_block_active || verify_fail=$?

	if [ "$verify_fail" -ne 0 ]; then
		# ccusage is definite that nothing is running: say so instead of
		# claiming success, and leave .last-activity untouched so status
		# does not report a trigger that did not take effect.
		print_warning "Trigger completed but ccusage reports no active block"
		log_to_system "Trigger completed at $timestamp but ccusage reports no active block"
		if is_flag_enabled "${CCBLOCKS_STRICT_VERIFY:-}"; then
			exit 1
		fi
		exit 0
	fi

	# Save last activity timestamp
	echo "$timestamp" >"$CCBLOCKS_CONFIG/.last-activity" 2>/dev/null || true

	# Log to system
	log_to_system "Successfully triggered new 5-hour block at $timestamp"
	exit 0
else
	# Log failure to system
	log_to_system "Failed to trigger block at $timestamp"
	exit 1
fi
