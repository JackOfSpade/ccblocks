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

# Write the systemd service unit file. Shared by create_service (presets)
# and create_service_custom so the template only needs to be kept
# correct in one place.
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

# Write the systemd timer unit file for the given OnCalendar expression.
# Shared by create_service (presets) and create_service_custom.
write_timer_file() {
	local oncalendar="$1"

	cat >"$TIMER_FILE" <<EOF
[Unit]
Description=ccblocks Scheduling Timer (%i)

[Timer]
OnCalendar=$oncalendar
Persistent=true
EOF
}

# Zero-pad and comma-join hours for systemd OnCalendar syntax. Accepts
# either space-separated (e.g. "9 14", from preset_hours) or
# comma-separated (e.g. "9,14", from user input) input -> "09,14".
# Shared by create_service and create_service_custom.
format_oncalendar_hours() {
	echo "$1" | tr ',' ' ' | awk '{for(i=1;i<=NF;i++) printf "%02d,", $i}' | sed 's/,$//'
}

# Map space-separated ISO weekday numbers (1=Monday..7=Sunday, matching
# preset_weekdays' numbering) to a systemd OnCalendar day-of-week list,
# e.g. "1 2 3 4 5" -> "Mon,Tue,Wed,Thu,Fri" (systemd itself normalizes a
# contiguous list like that to "Mon..Fri"). Keeps systemd-helper.sh in
# sync with launchagent-helper.sh, which already derives its Weekday
# entries from the same preset_weekdays values instead of hardcoding a
# day range - see the common.sh comment on preset_weekdays for why.
weekdays_to_oncalendar() {
	local -a names=(Sun Mon Tue Wed Thu Fri Sat) # index 0..6; ISO 7 (Sun) -> 0
	local day list=""
	for day in $1; do
		list+="${list:+,}${names[$((day % 7))]}"
	done
	echo "$list"
}

# Create systemd service and timer files
create_service() {
	local schedule="${1:-247}"

	write_service_file

	local hours weekdays
	if ! hours=$(preset_hours "$schedule"); then
		print_error "Unknown schedule: $schedule"
		return 1
	fi
	if ! weekdays=$(preset_weekdays "$schedule"); then
		print_error "Unknown schedule: $schedule"
		return 1
	fi

	local formatted_hours
	formatted_hours=$(format_oncalendar_hours "$hours")

	local oncalendar
	if [ -z "$weekdays" ]; then
		oncalendar="*-*-* ${formatted_hours}:00:00"
	else
		oncalendar="$(weekdays_to_oncalendar "$weekdays") *-*-* ${formatted_hours}:00:00"
	fi

	write_timer_file "$oncalendar"

	print_status "Created systemd service and timer files"
}

# Create systemd service and timer files with custom hours
create_service_custom() {
	local hours_str="$1"

	write_service_file

	local formatted_hours
	formatted_hours=$(format_oncalendar_hours "$hours_str")
	local oncalendar="*-*-* ${formatted_hours}:00:00"

	write_timer_file "$oncalendar"

	print_status "Created custom systemd service and timer files"
	print_status "Triggers at: ${hours_str}"
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

# Cancel any still-pending precise retry (used both to replace a stale one
# before scheduling a new one, and to clean up after a later trigger - the
# regular schedule or a manual `ccblocks trigger` - already succeeded, so a
# still-armed retry doesn't fire needlessly). Safe to call when none exists.
cancel_retry() {
	systemctl --user stop "${SERVICE_NAME}-retry.timer" "${SERVICE_NAME}-retry.service" >/dev/null 2>&1 || true
}

# Schedule a one-shot retry of the trigger at the given Unix epoch (used
# when a failed trigger's usage-limit message told us exactly when it'll
# next succeed). Runs as a transient systemd-run timer rather than
# touching the persistent @default timer/service, so the regular schedule
# is untouched. --collect garbage-collects the transient unit once it has
# run, so a rejected or successful retry never lingers, and the fixed unit
# name (replaced via cancel_retry before each new schedule, the same way
# launchagent-helper.sh bootouts its own stale retry plist) means at most
# one precise retry can be pending at a time.
schedule_retry() {
	local epoch="$1"

	if ! command_exists systemd-run; then
		print_warning "systemd-run not found; cannot schedule a precise retry"
		return 1
	fi

	local when
	when=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S') || return 1

	# Replace any still-pending retry from an earlier failed attempt.
	cancel_retry

	if systemd-run --user \
		--unit="${SERVICE_NAME}-retry" \
		--collect \
		--on-calendar="$when" \
		--setenv="CCBLOCKS_RETRY_ATTEMPT=1" \
		--setenv="PATH=$PATH" \
		"$TRIGGER_SCRIPT" >/dev/null 2>&1; then
		print_status "Scheduled retry for $when"
		log_to_system "Scheduled precise retry at $when after usage-limit rejection"
		return 0
	else
		print_warning "Failed to schedule retry via systemd-run"
		return 1
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

		# Show timer schedule
		echo "Schedule:"
		systemctl --user cat "${SERVICE_NAME}@default.timer" | grep "OnCalendar" | sed 's/^/  /'
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
	echo "  create [schedule]  - Create systemd service/timer (schedules: 247, work, night)"
	echo "  enable             - Enable and start timer"
	echo "  disable            - Disable and stop timer"
	echo "  reload             - Reload systemd (after manual edits)"
	echo "  start              - Trigger service manually"
	echo "  status             - Show service/timer status"
	echo "  remove             - Remove service/timer completely"
	echo "  logs               - Show recent logs"
	echo "  retry <epoch>      - Schedule a one-shot retry at the given Unix epoch"
	echo "  cancel             - Cancel a still-pending precise retry, if any"
	echo ""
	echo "Examples:"
	echo "  $0 create 247     # Create with 24/7 schedule"
	echo "  $0 enable          # Enable the timer"
	echo "  $0 status          # Check status"
	echo "  $0 start           # Trigger immediately"
}

# Main command handler
main() {
	local command="${1:-}"

	case "$command" in
	create)
		local schedule="${2:-247}"
		create_service "$schedule"
		;;
	create_custom)
		local hours="${2:-}"
		if [ -z "$hours" ]; then
			print_error "Custom hours required"
			return 1
		fi
		create_service_custom "$hours"
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

		# Restart timer if it's enabled to apply changes
		if systemctl --user is-enabled "${SERVICE_NAME}@default.timer" &>/dev/null; then
			systemctl --user restart "${SERVICE_NAME}@default.timer"
			print_status "Timer restarted with new schedule"
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
