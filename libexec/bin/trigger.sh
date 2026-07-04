#!/usr/bin/env bash

# ccblocks Trigger
# Manually trigger a new Claude Code block right now

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

case "${1:-}" in
-h | --help)
	echo "ccblocks Trigger"
	echo ""
	echo "Usage: ccblocks trigger"
	echo ""
	echo "Manually triggers a new 5-hour Claude Code block right now, the same"
	echo "way a scheduled LaunchAgent/systemd run would."
	exit 0
	;;
esac

# Detect OS and initialise OS-specific variables
detect_os || exit 1
init_os_vars "$SCRIPT_DIR/.." || exit 1

exec "$HELPER" start
