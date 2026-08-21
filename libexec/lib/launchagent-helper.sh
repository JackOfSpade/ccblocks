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

TRIGGER_SCRIPT="$(resolve_trigger_script "$SCRIPT_DIR")"

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

# Escape the XML metacharacters a plist string can't carry literally. '&'
# must be substituted first, otherwise it would re-escape the ampersands
# introduced by the later entities.
xml_escape() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Write the LaunchAgent plist using a fixed StartInterval (fires every N
# seconds regardless of clock time). This replaces the old clock-calendar
# approach, which required guessing clock times and missed windows when a
# trigger hit a 100%-usage limit.
write_plist() {
	local escaped_path escaped_home escaped_trigger
	escaped_path="$(xml_escape "$PATH")"
	escaped_home="$(xml_escape "$HOME")"
	# The install path is just as capable of containing '&' as PATH or
	# HOME are; an unescaped one yields a plist launchctl cannot parse.
	escaped_trigger="$(xml_escape "$TRIGGER_SCRIPT")"

	cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$escaped_trigger</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$escaped_path</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$escaped_home/Library/Logs/ccblocks.log</string>
    <key>StandardErrorPath</key>
    <string>$escaped_home/Library/Logs/ccblocks.log</string>

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
		print_error "LaunchAgent plist not found. Run 'ccblocks setup' first."
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
		print_error "LaunchAgent not loaded. Run 'ccblocks setup' (or 'ccblocks resume') first."
		return 1
	fi

	# kickstart reports whether the job actually ran; `launchctl start`
	# succeeds even for a job launchd could not spawn.
	local uid
	uid=$(id -u)
	if ! launchctl kickstart "gui/$uid/$LABEL"; then
		print_error "Failed to start LaunchAgent"
		return 1
	fi

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
	else
		echo "Status: ❌ Not loaded"
	fi
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
