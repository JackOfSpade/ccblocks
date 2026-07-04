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

# Show custom schedule details if configured
if [ -f "$CONFIG_FILE" ]; then
	if config_output=$(read_schedule_config 2>/dev/null); then
		schedule_type=$(echo "$config_output" | grep "^type=" | cut -d'=' -f2)

		if [ "$schedule_type" = "custom" ]; then
			echo ""
			print_header "Custom Schedule Details"
			echo "=========================="

			custom_hours=$(echo "$config_output" | grep "^custom_hours=" | cut -d'=' -f2)

			if [ -n "$custom_hours" ]; then
				echo "  Triggers: $custom_hours"

				coverage_output=$(calculate_coverage "$custom_hours")
				coverage_hours=$(echo "$coverage_output" | grep "^coverage=" | cut -d'=' -f2)
				gap_hours=$(echo "$coverage_output" | grep "^gaps=" | cut -d'=' -f2)

				echo "  Coverage: ${coverage_hours}h/day"
				echo "  Gaps: ${gap_hours}h/day"

				# Show optimality
				if [ "$coverage_hours" -eq 20 ]; then
					echo "  Status: ✓ Optimal coverage"
				elif [ "$coverage_hours" -ge 15 ]; then
					echo "  Status: Good coverage"
				else
					echo "  Status: Light coverage"
				fi
			fi
		fi
	fi
fi

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
