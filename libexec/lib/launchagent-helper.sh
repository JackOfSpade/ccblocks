#!/usr/bin/env bash

# ccblocks LaunchAgent Helper (Internal)
# Platform-specific macOS LaunchAgent management
# Note: This is an internal helper script called by main CLI commands

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LABEL="ccblocks"
PLIST_PATH="$HOME/Library/LaunchAgents/ccblocks.plist"

# Resolve TRIGGER_SCRIPT path - use version-independent path for Homebrew
# If installed via Homebrew, paths contain /Cellar/ccblocks/VERSION/ which breaks on upgrade
# Replace with /opt/ccblocks/ symlink which always points to current version
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIGGER_SCRIPT="$BASE_DIR/ccblocks-daemon.sh"
if [ ! -f "$TRIGGER_SCRIPT" ]; then
	TRIGGER_SCRIPT="$BASE_DIR/libexec/ccblocks-daemon.sh"
fi
if [[ "$TRIGGER_SCRIPT" == */Cellar/ccblocks/* ]]; then
	# Extract brew prefix (everything before /Cellar/)
	BREW_PREFIX="${TRIGGER_SCRIPT%%/Cellar/ccblocks/*}"
	# Preserve relative path after the versioned Cellar segment
	RELATIVE_PATH="${TRIGGER_SCRIPT#"${BREW_PREFIX}"/Cellar/ccblocks/}"
	RELATIVE_PATH="${RELATIVE_PATH#*/}" # drop version component
	# Use opt symlink instead of versioned Cellar path
	TRIGGER_SCRIPT="$BREW_PREFIX/opt/ccblocks/${RELATIVE_PATH}"
fi

# Check if LaunchAgent exists
agent_exists() {
	[ -f "$PLIST_PATH" ]
}

# Check if LaunchAgent is loaded
agent_loaded() {
	local uid
	uid=$(id -u)
	launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1
}

# Read the StartInterval currently written into the installed plist.
# Prints nothing if the plist is missing or the key can't be parsed - this
# can differ from CCBLOCKS_INTERVAL_SECONDS when the plist predates a
# version that changed the interval and 'ccblocks setup' hasn't re-run yet.
installed_interval_seconds() {
	agent_exists || return 1
	sed -n '/<key>StartInterval<\/key>/{n;s/[^0-9]//g;p;}' "$PLIST_PATH"
}

# Write the LaunchAgent plist using a fixed StartInterval (fires every N
# seconds regardless of clock time). This replaces the old clock-calendar
# approach, which required guessing clock times and missed windows when a
# trigger hit a 100%-usage limit.
write_plist() {
	cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$TRIGGER_SCRIPT</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/ccblocks.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/ccblocks.log</string>

    <key>StartInterval</key>
    <integer>$CCBLOCKS_INTERVAL_SECONDS</integer>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
}

# Create LaunchAgent plist (fixed-interval polling; see
# CCBLOCKS_INTERVAL_SECONDS in common.sh)
create_plist() {
	write_plist
	print_status "Created LaunchAgent plist at: $PLIST_PATH"
}

# Load LaunchAgent
load_agent() {
	if ! agent_exists; then
		print_error "LaunchAgent plist not found. Run 'setup' first."
		return 1
	fi

	if agent_loaded; then
		print_warning "LaunchAgent already loaded"
		return 0
	fi

	# Use bootstrap for modern macOS (bootout/bootstrap is more reliable than load/unload)
	local uid
	uid=$(id -u)
	if launchctl bootstrap "gui/$uid" "$PLIST_PATH" 2>&1; then
		print_status "LaunchAgent loaded"
	else
		print_error "Failed to load LaunchAgent"
		return 1
	fi
}

# Unload LaunchAgent
unload_agent() {
	if ! agent_loaded; then
		print_warning "LaunchAgent not loaded"
		return 0
	fi

	# Use bootout for modern macOS (bootout/bootstrap is more reliable than load/unload)
	local uid
	uid=$(id -u)
	if launchctl bootout "gui/$uid/$LABEL" 2>&1; then
		print_status "LaunchAgent unloaded"
	else
		print_error "Failed to unload LaunchAgent"
		return 1
	fi
}

# Start LaunchAgent immediately
start_agent() {
	if ! agent_loaded; then
		print_error "LaunchAgent not loaded. Run 'load' first."
		return 1
	fi

	launchctl start "$LABEL"
	print_status "LaunchAgent started (triggered manually)"
}

# Check LaunchAgent status
status_agent() {
	echo "ccblocks LaunchAgent Status"
	echo "============================"
	echo ""

	if agent_exists; then
		echo "Plist: ✅ Found at $PLIST_PATH"
	else
		echo "Plist: ❌ Not found"
		return 1
	fi

	if agent_loaded; then
		echo "Status: ✅ Loaded and active"
		echo ""

		# Show schedule - read the interval actually written into the
		# installed plist rather than assuming it matches this script
		# version's default, since an upgrade doesn't rewrite an
		# already-installed plist until 'ccblocks setup' is re-run.
		echo "Schedule:"
		local installed_seconds
		installed_seconds="$(installed_interval_seconds)"
		if [ -n "$installed_seconds" ]; then
			echo "  Every $((installed_seconds / 60)) minutes"
			if [ "$installed_seconds" -ne "$CCBLOCKS_INTERVAL_SECONDS" ]; then
				echo ""
				print_warning "Installed schedule differs from this version's default (${CCBLOCKS_INTERVAL_MINUTES} min). Run 'ccblocks setup' again to apply it."
			fi
		else
			echo "  Unknown (could not read StartInterval from plist)"
		fi
		echo ""

		# Show recent activity from state file
		local last_activity="$CCBLOCKS_CONFIG/.last-activity"
		if [ -f "$last_activity" ]; then
			echo "Recent Activity:"
			echo "  Last trigger: $(cat "$last_activity" 2>/dev/null || echo "unknown")"
		else
			echo "Recent Activity: None yet"
		fi
	else
		echo "Status: ❌ Not loaded"
	fi

	echo ""
	echo "View Logs:"
	echo "  log show --last 1d --info --predicate 'eventMessage CONTAINS[c] \"ccblocks\"'"
}

# Remove LaunchAgent completely
remove_agent() {
	if agent_loaded; then
		unload_agent
	fi

	if agent_exists; then
		rm "$PLIST_PATH"
		print_status "Removed LaunchAgent plist"
	fi
}

# Show usage
show_usage() {
	echo "ccblocks LaunchAgent Helper (internal)"
	echo ""
	echo "Usage: $0 <command> [options]"
	echo "Note: This is an internal helper. Use 'ccblocks' command instead."
	echo ""
	echo "Commands:"
	echo "  create             - Create LaunchAgent plist (fires every ${CCBLOCKS_INTERVAL_MINUTES} minutes)"
	echo "  load               - Load LaunchAgent"
	echo "  unload             - Unload LaunchAgent"
	echo "  reload             - Reload LaunchAgent (unload + load)"
	echo "  start              - Trigger LaunchAgent manually"
	echo "  status             - Show LaunchAgent status"
	echo "  remove             - Remove LaunchAgent completely"
	echo "  logs               - Show recent logs"
	echo ""
	echo "Examples:"
	echo "  $0 create          # Create plist (${CCBLOCKS_INTERVAL_MINUTES}-minute polling)"
	echo "  $0 load            # Load the LaunchAgent"
	echo "  $0 status          # Check status"
	echo "  $0 start           # Trigger immediately"
}

# Main command handler
main() {
	local command="${1:-}"

	case "$command" in
	create)
		create_plist
		;;
	load)
		load_agent
		;;
	unload)
		unload_agent
		;;
	reload)
		unload_agent
		load_agent
		;;
	start)
		start_agent
		;;
	status)
		status_agent
		;;
	remove)
		remove_agent
		;;
	logs)
		echo "Showing ccblocks logs from system log (last 24 hours):"
		log show --last 1d --info --predicate 'eventMessage CONTAINS[c] "ccblocks"' --style compact
		;;
	-h | --help | help | "")
		show_usage
		;;
	*)
		print_error "Unknown command: $command"
		show_usage
		exit 1
		;;
	esac
}

main "$@"
