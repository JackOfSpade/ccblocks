#!/usr/bin/env bash

# ccblocks Systemd Helper (Internal)
# Platform-specific Linux systemd service/timer management
# Note: This is an internal helper script called by main CLI commands

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

SERVICE_NAME="ccblocks"
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}@.service"
TIMER_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}@.timer"
TRIGGER_SCRIPT="$SCRIPT_DIR/../ccblocks-daemon.sh"
if [ ! -f "$TRIGGER_SCRIPT" ]; then
	TRIGGER_SCRIPT="$SCRIPT_DIR/../libexec/ccblocks-daemon.sh"
fi

# Check if service exists
service_exists() {
	[ -f "$SERVICE_FILE" ]
}

# Read the OnUnitActiveSec value currently written into the installed
# timer unit (e.g. "5" from "OnUnitActiveSec=5min"). Prints nothing if the
# timer file is missing or the key can't be parsed - this can differ from
# CCBLOCKS_INTERVAL_MINUTES when the timer predates a version that changed
# the interval and 'ccblocks setup' hasn't re-run yet.
installed_interval_minutes() {
	service_exists || return 1
	sed -n 's/^OnUnitActiveSec=\([0-9][0-9]*\)min$/\1/p' "$TIMER_FILE"
}

# Write the systemd service unit file.
write_service_file() {
	# Create systemd user directory if it doesn't exist
	mkdir -p "$HOME/.config/systemd/user"

	cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=ccblocks Claude Code Block Trigger (%i)
After=network.target

[Service]
Type=oneshot
ExecStart=$TRIGGER_SCRIPT
SyslogIdentifier=ccblocks
Environment=PATH=$PATH
EOF
}

# Write the systemd timer unit file using a fixed repeating interval.
# There is no schedule to configure - the timer fires at a fixed interval
# (CCBLOCKS_INTERVAL_MINUTES) after activation.
write_timer_file() {
	cat >"$TIMER_FILE" <<EOF
[Unit]
Description=ccblocks Scheduling Timer (%i)

[Timer]
OnBootSec=${CCBLOCKS_INTERVAL_MINUTES}min
OnUnitActiveSec=${CCBLOCKS_INTERVAL_MINUTES}min
Persistent=true
EOF
}

# Create systemd service and timer files (fixed-interval polling; see
# CCBLOCKS_INTERVAL_SECONDS in common.sh)
create_service() {
	write_service_file
	write_timer_file
	print_status "Created systemd service and timer files"
}

# Enable and start timer
enable_timer() {
	if ! service_exists; then
		print_error "Service files not found. Run 'create' first."
		return 1
	fi

	# Reload systemd to pick up new files
	systemctl --user daemon-reload

	# Enable and start timer
	systemctl --user enable "${SERVICE_NAME}@default.timer"
	systemctl --user start "${SERVICE_NAME}@default.timer"

	print_status "Timer enabled and started"
}

# Disable and stop timer
disable_timer() {
	if systemctl --user is-enabled "${SERVICE_NAME}@default.timer" &>/dev/null; then
		systemctl --user stop "${SERVICE_NAME}@default.timer"
		systemctl --user disable "${SERVICE_NAME}@default.timer"
		print_status "Timer disabled and stopped"
	else
		print_warning "Timer not enabled"
	fi
}

# Start service immediately
start_service() {
	if ! service_exists; then
		print_error "Service files not found. Run 'create' first."
		return 1
	fi

	systemctl --user start "${SERVICE_NAME}@manual.service"
	print_status "Service started (triggered manually)"
}

# Check service/timer status
status_service() {
	echo "ccblocks Systemd Status"
	echo "======================="
	echo ""

	if service_exists; then
		echo "Service: ✅ Found at $SERVICE_FILE"
		echo "Timer:   ✅ Found at $TIMER_FILE"
	else
		echo "Service: ❌ Not found"
		return 1
	fi

	echo ""
	if systemctl --user is-active "${SERVICE_NAME}@default.timer" &>/dev/null; then
		echo "Status: ✅ Timer active"
		echo ""

		# Show schedule - read the interval actually written into the
		# installed timer unit rather than assuming it matches this
		# script version's default, since an upgrade doesn't rewrite an
		# already-installed timer until 'ccblocks setup' is re-run.
		echo "Schedule:"
		local installed_minutes
		installed_minutes="$(installed_interval_minutes)"
		if [ -n "$installed_minutes" ]; then
			echo "  Every $installed_minutes minutes"
			if [ "$installed_minutes" -ne "$CCBLOCKS_INTERVAL_MINUTES" ]; then
				echo ""
				print_warning "Installed schedule differs from this version's default (${CCBLOCKS_INTERVAL_MINUTES} min). Run 'ccblocks setup' again to apply it."
			fi
		else
			echo "  Unknown (could not read OnUnitActiveSec from timer unit)"
		fi
		echo ""

		# Show next trigger
		echo "Next Trigger:"
		systemctl --user list-timers "${SERVICE_NAME}@default.timer" --no-pager | grep -v "^NEXT" | grep "${SERVICE_NAME}" | sed 's/^/  /' || echo "  (calculating...)"
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
		echo "Status: ❌ Timer not active"
	fi

	echo ""
	echo "View Logs:"
	echo "  journalctl --user -t ccblocks -n 50"
}

# Remove service/timer completely
remove_service() {
	if systemctl --user is-active "${SERVICE_NAME}@default.timer" &>/dev/null; then
		disable_timer
	fi

	if service_exists; then
		rm "$SERVICE_FILE" "$TIMER_FILE"
		systemctl --user daemon-reload
		print_status "Removed systemd service and timer files"
	fi
}

# Show usage
show_usage() {
	echo "ccblocks Systemd Helper (internal)"
	echo ""
	echo "Usage: $0 <command> [options]"
	echo "Note: This is an internal helper. Use 'ccblocks' command instead."
	echo ""
	echo "Commands:"
	echo "  create             - Create systemd service/timer (fires every ${CCBLOCKS_INTERVAL_MINUTES} minutes)"
	echo "  enable             - Enable and start timer"
	echo "  disable            - Disable and stop timer"
	echo "  reload             - Reload systemd (after manual edits)"
	echo "  start              - Trigger service manually"
	echo "  status             - Show service/timer status"
	echo "  remove             - Remove service/timer completely"
	echo "  logs               - Show recent logs"
	echo ""
	echo "Examples:"
	echo "  $0 create          # Create with ${CCBLOCKS_INTERVAL_MINUTES}-minute polling"
	echo "  $0 enable          # Enable the timer"
	echo "  $0 status          # Check status"
	echo "  $0 start           # Trigger immediately"
}

# Main command handler
main() {
	local command="${1:-}"

	case "$command" in
	create)
		create_service
		;;
	enable)
		enable_timer
		;;
	disable)
		disable_timer
		;;
	load)
		enable_timer
		;;
	unload)
		disable_timer
		;;
	reload)
		systemctl --user daemon-reload
		print_status "Systemd user daemon reloaded"

		# Restart an already-enabled timer to apply changes (e.g. a new
		# interval); enable it if this is a fresh install instead.
		if systemctl --user is-enabled "${SERVICE_NAME}@default.timer" &>/dev/null; then
			systemctl --user restart "${SERVICE_NAME}@default.timer"
			print_status "Timer restarted with new schedule"
		else
			enable_timer
		fi
		;;
	start)
		start_service
		;;
	status)
		status_service
		;;
	remove)
		remove_service
		;;
	logs)
		echo "Showing ccblocks logs from journald (last 50 entries):"
		journalctl --user -t ccblocks -n 50 --no-pager
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
