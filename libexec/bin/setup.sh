#!/usr/bin/env bash

# ccblocks Setup Script
# Cross-platform installation using LaunchAgent (macOS) or systemd (Linux)

set -euo pipefail
set -E

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

install_err_trap "Common fixes: ensure the Claude CLI is installed, logged in, and reachable."

# Detect OS and initialise OS-specific variables
detect_os || exit 1
init_os_vars "$SCRIPT_DIR/.." || exit 1

# Check if Claude CLI is available
check_claude_cli() {
	if ! command_exists claude; then
		print_error "Claude CLI not found. Please install Claude Code first:"
		echo "  Visit: https://claude.ai/code"
		exit 1
	fi

	local claude_bin
	claude_bin="$(command -v claude)"
	print_status "Claude CLI found: $claude_bin"

	require_subscription_auth "$claude_bin"

	# Test Claude CLI (quick test)
	local test_output=""
	if ! test_output=$(run_claude_subscription_trigger "$claude_bin" 2>&1); then
		# Matches both "Session limit reached" (older CLI) and
		# "You've hit your session limit · resets ..." (current CLI)
		if echo "$test_output" | grep -qi "session limit"; then
			print_warning "Claude CLI responded with a session limit message. Setup will continue, but scheduled triggers will wait until the limit resets."
		else
			print_error "Claude CLI test failed. Please ensure you're authenticated:"
			echo "  The CLI might not be properly logged in"
			echo "  Try running claude manually first"
			echo "  Captured output:"
			while IFS= read -r line || [[ -n $line ]]; do
				echo "    $line"
			done <<<"$test_output"
			exit 1
		fi
	else
		print_status "Claude CLI test successful"
	fi
}

# Warn about potential block usage
check_current_block() {
	print_warning "Note: Running ccblocks will trigger Claude to start new blocks"
	echo "  If you currently have an active block with remaining time,"
	echo "  you may want to wait until it expires before setting up ccblocks."
	echo ""
}


# Install scheduler (LaunchAgent or systemd)
install_scheduler() {
	# shellcheck disable=SC2153  # SCHEDULER_NAME is set by detect_os() in common.sh
	print_status "Installing $SCHEDULER_NAME..."

	# Create scheduler config using helper
	if ! "$HELPER" create; then
		print_error "Failed to create $SCHEDULER_NAME"
		exit 1
	fi

	# Load/enable scheduler (LOAD_CMD is set by init_os_vars in common.sh)
	if ! "$HELPER" "$LOAD_CMD"; then
		print_error "Failed to ${LOAD_CMD} $SCHEDULER_NAME"
		exit 1
	fi

	print_status "$SCHEDULER_NAME installed and active"
}

# Show completion message
show_completion() {
	echo ""
	print_header "[CCBLOCKS] Setup Complete! 🚀"
	echo ""
	print_status "Schedule: every 15 minutes"
	print_status "Scheduler: $SCHEDULER_NAME"
	echo ""
	echo "Your Claude blocks will now be triggered automatically every 15 minutes!"
	echo "The $SCHEDULER_NAME runs in your user session with full authentication."
	echo ""
	echo "Next Steps:"
	echo "  • Check status: ccblocks status"
	echo "  • Test trigger: ccblocks trigger"
	echo ""
	print_status "Setup completed successfully"
}

# Show usage
show_usage() {
	echo "ccblocks Setup"
	echo ""
	echo "Usage: ccblocks setup"
	echo ""
	echo "Options:"
	echo "  -h, --help    # Show this help message"
	echo ""
	echo "Runs the interactive installer: checks the Claude CLI, lets you choose"
	echo "a schedule preset, and installs the LaunchAgent/systemd scheduler."
}

# Main setup flow
main() {
	case "${1:-}" in
	-h | --help)
		show_usage
		exit 0
		;;
	esac

	print_header "[CCBLOCKS] ccblocks Setup"
	show_logo
	echo ""

	# Pre-flight checks
	check_claude_cli
	check_current_block

	# Confirm before proceeding
	echo ""
	print_warning "Ready to install ccblocks (triggers every 15 minutes)"
	read -r -p "Proceed with installation? [Y/n]: " confirm

	# Default to yes if empty, or if user explicitly said no
	if [[ "$confirm" =~ ^[Nn]([Oo])?$ ]]; then
		print_status "Setup cancelled"
		exit 0
	fi

	# Installation
	install_scheduler
	show_completion
}

# Run main function
main "$@"
