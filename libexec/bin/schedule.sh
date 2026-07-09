#!/usr/bin/env bash

# ccblocks Schedule Management
# Manage scheduling patterns for block triggers

set -euo pipefail
set -E

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

install_err_trap "Common fixes: ensure the scheduler helper and its config directory are readable."

# Initialize OS-specific variables
detect_os || exit 1
init_os_vars "$SCRIPT_DIR/.." || exit 1


# Pause scheduling
pause_schedule() {
	"$HELPER" unload
	print_status "Paused ccblocks scheduling"
	echo ""
	echo "To resume: ccblocks resume"
}

# Resume scheduling
resume_schedule() {
	"$HELPER" load
	print_status "Resumed ccblocks scheduling"
}

# Remove all schedules
remove_schedule() {
	"$HELPER" remove
	print_status "Removed all ccblocks schedules"
}

# Show help
show_help() {
	echo "ccblocks Schedule Management"
	echo "============================"
	echo ""
	echo "Usage: ccblocks schedule <action>"
	echo ""
	echo "Commands:"
	echo "  current   # Show current scheduler status"
	echo "  pause     # Pause ccblocks (disable scheduler)"
	echo "  resume    # Resume after pause"
	echo "  remove    # Remove all ccblocks schedules"
	echo ""
	echo "Note: ccblocks now polls every 10 minutes. There is no schedule to"
	echo "configure — use 'pause' and 'resume' to control it entirely."
	echo ""
	echo "Examples:"
	echo "  ccblocks schedule current   # Show scheduler status"
	echo "  ccblocks schedule pause     # Pause for vacation"
	echo "  ccblocks schedule resume    # Resume after pause"
	echo ""
}

# Main command dispatcher
main() {
	local action="${1:-help}"
	shift || true

	case "$action" in
	current)
		"$HELPER" status
		;;
	pause)
		pause_schedule
		;;
	resume)
		resume_schedule
		;;
	remove)
		remove_schedule
		;;
	help | -h | --help)
		show_help
		;;
	# Friendly error for removed commands
	list | apply)
		print_error "'ccblocks schedule $action' is no longer available."
		echo "ccblocks now polls every 10 minutes — there is no schedule to configure."
		echo "Use 'ccblocks schedule pause/resume' to control it."
		return 1
		;;
	*)
		print_error "Unknown command: $action"
		echo ""
		show_help
		return 1
		;;
	esac
}

main "$@"
