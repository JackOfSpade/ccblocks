#!/usr/bin/env bash

# ccblocks Trigger
# Manually trigger a new Claude Code block right now

set -euo pipefail
set -E

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

install_err_trap "Common fixes: ensure the scheduler helper and its config directory are readable."

case "${1:-}" in
-h | --help)
	echo "ccblocks Trigger"
	echo ""
	echo "Usage: ccblocks trigger"
	echo ""
	echo "Manually triggers a new 5-hour Claude Code block right now by running"
	echo "the same trigger script scheduled runs execute, so its result and"
	echo "output are reported directly."
	exit 0
	;;
esac

detect_os || exit 1

# Run the daemon inline rather than asking the scheduler to start it:
# `launchctl start` is fire-and-forget, so going through the helper would
# always report success and hide a real trigger failure.
exec "$SCRIPT_DIR/../ccblocks-daemon.sh"
