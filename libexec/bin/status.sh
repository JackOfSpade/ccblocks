#!/usr/bin/env bash

# ccblocks Status Checker
# Shows scheduler status (LaunchAgent/systemd) and block information

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
	echo "ccblocks Status Checker"
	echo ""
	echo "Usage: ccblocks status"
	echo ""
	echo "Shows the current scheduler status (LaunchAgent/systemd), the custom"
	echo "schedule details if configured, and recent trigger activity."
	exit 0
	;;
esac

# Detect OS and initialise OS-specific variables
detect_os || exit 1
init_os_vars "$SCRIPT_DIR/.." || exit 1

# Show scheduler status
echo ""
print_header "ccblocks Status Dashboard"
echo "=========================="
echo ""

# Use helper for basic status (may exit non-zero if nothing is installed
# yet - that's not fatal, the rest of this dashboard should still print)
"$HELPER" status || true

echo ""
LAST_ACTIVITY_FILE="$CCBLOCKS_CONFIG/.last-activity"
if [ -f "$LAST_ACTIVITY_FILE" ]; then
	print_header "Last Activity"
	echo "=========================="
	LAST_TRIGGER=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "unknown")
	echo "  Last triggered: $LAST_TRIGGER"
	echo ""
fi

print_header "Quick Commands"
echo "=========================="
if [ "$OS_TYPE" = "Darwin" ]; then
	echo "  View logs:       log show --last 1d --info --predicate 'eventMessage CONTAINS[c] \"ccblocks\"'"
else
	echo "  View logs:       journalctl --user -t ccblocks -n 50"
fi
echo "  Trigger now:     ccblocks trigger"
echo "  Change schedule: ccblocks schedule"
echo "  Uninstall:       ccblocks uninstall"
echo ""
