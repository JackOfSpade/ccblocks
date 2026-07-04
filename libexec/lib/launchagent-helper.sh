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
	launchctl list | grep -w "$LABEL" >/dev/null
}

# Write the LaunchAgent plist with the given <dict>...</dict> interval
# entries. Shared by create_plist (presets) and create_plist_custom so
# the plist template only needs to be kept correct in one place.
write_plist() {
	local intervals="$1"

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

    <key>StartCalendarInterval</key>
    <array>$intervals
    </array>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
}

# Create LaunchAgent plist
create_plist() {
	local schedule="${1:-247}"
	local hours weekdays

	if ! hours=$(preset_hours "$schedule"); then
		print_error "Unknown schedule: $schedule"
		return 1
	fi
	if ! weekdays=$(preset_weekdays "$schedule"); then
		print_error "Unknown schedule: $schedule"
		return 1
	fi

	local intervals=""
	if [ -z "$weekdays" ]; then
		for hour in $hours; do
			intervals+="
        <dict>
            <key>Hour</key>
            <integer>$hour</integer>
            <key>Minute</key>
            <integer>0</integer>
        </dict>"
		done
	else
		# launchd's Weekday key: 0 and 7 both mean Sunday, 1=Monday, ...,
		# 6=Saturday (see launchd.plist(5)) - the same numbering
		# preset_weekdays uses, so no translation is needed here.
		for weekday in $weekdays; do
			for hour in $hours; do
				intervals+="
        <dict>
            <key>Hour</key>
            <integer>$hour</integer>
            <key>Minute</key>
            <integer>0</integer>
            <key>Weekday</key>
            <integer>$weekday</integer>
        </dict>"
			done
		done
	fi

	write_plist "$intervals"

	print_status "Created LaunchAgent plist at: $PLIST_PATH"
}

# Create LaunchAgent plist with custom hours
create_plist_custom() {
	local hours_str="$1"

	# Convert comma-separated hours to array
	IFS=',' read -ra hours_array <<<"$hours_str"

	# Build intervals XML
	local intervals=""
	for hour in "${hours_array[@]}"; do
		hour=$(echo "$hour" | tr -d ' ')
		intervals+="
        <dict>
            <key>Hour</key>
            <integer>$hour</integer>
            <key>Minute</key>
            <integer>0</integer>
        </dict>"
	done

	write_plist "$intervals"

	print_status "Created custom LaunchAgent plist at: $PLIST_PATH"
	print_status "Triggers at: ${hours_str}"
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

		# Show schedule
		echo "Schedule:"
		if [ -f "$PLIST_PATH" ]; then
			plutil -p "$PLIST_PATH" | awk '
                /"Hour" =>/ { h = $NF }
                /"Minute" =>/ { m = $NF }
                /"Weekday" =>/ { w = $NF }
                /}/ && h != "" && m != "" {
                    wd = ""
                    if (w == "0" || w == "7") wd = " (Sun)"
                    else if (w == "1") wd = " (Mon)"
                    else if (w == "2") wd = " (Tue)"
                    else if (w == "3") wd = " (Wed)"
                    else if (w == "4") wd = " (Thu)"
                    else if (w == "5") wd = " (Fri)"
                    else if (w == "6") wd = " (Sat)"
                    printf "  %02d:%02d%s\n", h, m, wd
                    h = m = w = ""
                }
            '
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
	echo "  create [schedule]  - Create LaunchAgent plist (schedules: 247, work, night)"
	echo "  load              - Load LaunchAgent"
	echo "  unload            - Unload LaunchAgent"
	echo "  reload            - Reload LaunchAgent (unload + load)"
	echo "  start             - Trigger LaunchAgent manually"
	echo "  status            - Show LaunchAgent status"
	echo "  remove            - Remove LaunchAgent completely"
	echo "  logs              - Show recent logs"
	echo ""
	echo "Examples:"
	echo "  $0 create 247    # Create with 24/7 schedule"
	echo "  $0 load           # Load the LaunchAgent"
	echo "  $0 status         # Check status"
	echo "  $0 start          # Trigger immediately"
}

# Main command handler
main() {
	local command="${1:-}"

	case "$command" in
	create)
		local schedule="${2:-247}"
		create_plist "$schedule"
		;;
	create_custom)
		local hours="${2:-}"
		if [ -z "$hours" ]; then
			print_error "Custom hours required"
			return 1
		fi
		create_plist_custom "$hours"
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
