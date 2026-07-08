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

RETRY_LABEL="ccblocks-retry"
RETRY_PLIST_PATH="$HOME/Library/LaunchAgents/${RETRY_LABEL}.plist"

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

# Write the LaunchAgent plist using a fixed StartInterval (fires every N
# seconds regardless of clock time). This replaces the old
# StartCalendarInterval approach, which required guessing slot times and
# missed windows when a trigger hit a 100%-usage limit mid-slot.
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
    <integer>900</integer>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
}

# Create LaunchAgent plist (no preset argument needed - always 15-minute polling)
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

# Schedule a one-shot retry of the trigger at the given Unix epoch (used
# when a failed trigger's usage-limit message told us exactly when it'll
# next succeed). Writes a second, distinct LaunchAgent plist so the
# persistent schedule's own plist is untouched. StartCalendarInterval has
# no "year" key, so a plist left in place would silently refire on the
# same month/day/hour/minute next year - the job therefore deletes its
# own plist (and best-effort unloads itself) immediately after running,
# success or failure, so nothing lingers. Because ~/Library/LaunchAgents
# is rescanned by launchd on every login, this survives a reboot between
# now and the target time the same way the regular schedule does.
schedule_retry() {
	local epoch="$1"
	local month_raw day_raw hour_raw minute_raw

	month_raw=$(date -r "$epoch" +%m 2>/dev/null) || return 1
	day_raw=$(date -r "$epoch" +%d 2>/dev/null) || return 1
	hour_raw=$(date -r "$epoch" +%H 2>/dev/null) || return 1
	minute_raw=$(date -r "$epoch" +%M 2>/dev/null) || return 1
	if [ -z "$month_raw" ] || [ -z "$day_raw" ] || [ -z "$hour_raw" ] || [ -z "$minute_raw" ]; then
		return 1
	fi

	local month day hour minute
	month=$((10#$month_raw))
	day=$((10#$day_raw))
	hour=$((10#$hour_raw))
	minute=$((10#$minute_raw))

	# Shell-escape the paths before embedding them in the ProgramArguments
	# bash -c string below - wrapping them in literal double quotes isn't
	# enough if either path ever contained a shell-special character (e.g.
	# a space, "$", or a literal quote), which would corrupt or break the
	# job's own self-cleanup step.
	local trigger_script_q retry_plist_path_q
	printf -v trigger_script_q '%q' "$TRIGGER_SCRIPT"
	printf -v retry_plist_path_q '%q' "$RETRY_PLIST_PATH"

	# Replace any still-pending retry from an earlier failed attempt
	# BEFORE writing the new plist below - cancel_retry also removes
	# RETRY_PLIST_PATH, which would otherwise delete the file this
	# function is about to write if called afterwards.
	cancel_retry

	cat >"$RETRY_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$RETRY_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>$trigger_script_q; rm -f $retry_plist_path_q; launchctl bootout "gui/\$(id -u)/$RETRY_LABEL" 2>/dev/null</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH</string>
        <key>CCBLOCKS_RETRY_ATTEMPT</key>
        <string>1</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/ccblocks.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/ccblocks.log</string>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Month</key>
        <integer>$month</integer>
        <key>Day</key>
        <integer>$day</integer>
        <key>Hour</key>
        <integer>$hour</integer>
        <key>Minute</key>
        <integer>$minute</integer>
    </dict>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

	local uid
	uid=$(id -u)

	if launchctl bootstrap "gui/$uid" "$RETRY_PLIST_PATH" 2>&1; then
		print_status "Scheduled retry for $(date -r "$epoch")"
		log_to_system "Scheduled precise retry at $(date -r "$epoch") after usage-limit rejection"
		return 0
	else
		print_warning "Failed to schedule retry via launchd"
		rm -f "$RETRY_PLIST_PATH"
		return 1
	fi
}

# Cancel any still-pending precise retry (used both to replace a stale one
# before scheduling a new one, and to clean up after a later trigger - the
# regular schedule or a manual `ccblocks trigger` - already succeeded, so a
# still-armed retry doesn't fire needlessly). Safe to call when none exists.
cancel_retry() {
	local uid
	uid=$(id -u)
	launchctl bootout "gui/$uid/$RETRY_LABEL" >/dev/null 2>&1 || true
	rm -f "$RETRY_PLIST_PATH"
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
		echo "  Every 15 minutes"
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
	echo "  create             - Create LaunchAgent plist (fires every 15 minutes)"
	echo "  load               - Load LaunchAgent"
	echo "  unload             - Unload LaunchAgent"
	echo "  reload             - Reload LaunchAgent (unload + load)"
	echo "  start              - Trigger LaunchAgent manually"
	echo "  status             - Show LaunchAgent status"
	echo "  remove             - Remove LaunchAgent completely"
	echo "  logs               - Show recent logs"
	echo "  retry <epoch>      - Schedule a one-shot retry at the given Unix epoch"
	echo "  cancel             - Cancel a still-pending precise retry, if any"
	echo ""
	echo "Examples:"
	echo "  $0 create          # Create plist (15-minute polling)"
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
	retry)
		local epoch="${2:-}"
		if [ -z "$epoch" ]; then
			print_error "Epoch timestamp required"
			return 1
		fi
		schedule_retry "$epoch"
		;;
	cancel)
		cancel_retry
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
