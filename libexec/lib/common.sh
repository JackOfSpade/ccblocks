#!/usr/bin/env bash

# ccblocks Common Library
# Shared utilities used across all ccblocks scripts

# Colour definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# Project paths
: "${CCBLOCKS_INSTALL:=${SCRIPT_DIR:-$(pwd)}}"
: "${CCBLOCKS_CONFIG:=${HOME}/.config/ccblocks}"

# No PATH bootstrap: we rely on the launcher to pass PATH through.

# Utility helpers
command_exists() {
	command -v "$1" >/dev/null 2>&1
}

# Timeout handling. Prefers timeout/gtimeout (GNU coreutils); falls back to
# perl or python3 (both enforce the timeout, unlike the last-resort branch).
run_with_timeout() {
	local duration="$1"
	shift

	if command_exists timeout; then
		timeout "$duration" "$@"
	elif command_exists gtimeout; then
		gtimeout "$duration" "$@"
	elif command_exists perl; then
		# alarm() survives exec(), so SIGALRM still fires against the
		# replaced process image if it outlives the timeout.
		perl -e '
			alarm(shift @ARGV);
			exec @ARGV or exit 127;
		' "$duration" "$@"
	elif command_exists python3; then
		python3 - "$duration" "$@" <<'PY'
import subprocess
import sys

duration = float(sys.argv[1])
cmd = sys.argv[2:]

proc = subprocess.Popen(cmd)
try:
    sys.exit(proc.wait(timeout=duration))
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
    sys.exit(124)
PY
	else
		# No timeout utility available at all - run without timeout
		# control. Unlike the perl/python3 fallbacks above, this path
		# enforces nothing, so make the gap visible instead of silent.
		print_warning "No timeout utility available (install coreutils, perl, or python3); running '$1' without an enforced timeout"
		log_to_system "run_with_timeout: no timeout utility available; ran '$1' without an enforced timeout"
		"$@"
	fi
}

# Print functions
print_status() {
	echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
	echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_header() {
	echo -e "${BLUE}${BOLD}$1${NC}"
}

# Install a friendly ERR trap so an unhandled failure under `set -e`
# reports which command failed instead of the script dying silently.
# Caller must also `set -E` beforehand so the trap fires inside
# functions. Pass an optional one-line hint shown alongside the error.
# Usage: set -E; install_err_trap "Common fixes: ..."
install_err_trap() {
	CCBLOCKS_ERR_HINT="${1:-}"
	trap 'handle_ccblocks_error' ERR
}

handle_ccblocks_error() {
	local exit_code=$?
	local failed_command=${BASH_COMMAND:-unknown}

	trap - ERR

	print_error "Exited early while running: ${failed_command}"
	if [ -n "${CCBLOCKS_ERR_HINT:-}" ]; then
		print_warning "$CCBLOCKS_ERR_HINT"
	fi

	exit "$exit_code"
}

show_logo() {
	echo "░░      ░░░      ░░       ░░  ░░░░░░░      ░░░      ░░  ░░░░  ░░      ░░"
	echo "▒  ▒▒▒▒  ▒  ▒▒▒▒  ▒  ▒▒▒▒  ▒  ▒▒▒▒▒▒  ▒▒▒▒  ▒  ▒▒▒▒  ▒  ▒▒▒  ▒▒  ▒▒▒▒▒▒▒"
	echo "▓  ▓▓▓▓▓▓▓  ▓▓▓▓▓▓▓       ▓▓  ▓▓▓▓▓▓  ▓▓▓▓  ▓  ▓▓▓▓▓▓▓     ▓▓▓▓▓      ▓▓"
	echo "█  ████  █  ████  █  ████  █  ██████  ████  █  ████  █  ███  ████████  █"
	echo "██      ███      ██       ██       ██      ███      ██  ████  ██      ██"
	echo "                                                         by @designorant"
	echo ""
	echo "Time-shift Claude sessions to match your working hours"
}

# Get script directory (must be set by calling script before sourcing this)
# Usage: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#        source "$SCRIPT_DIR/lib/common.sh"

# Detect OS and set appropriate helper script
detect_os() {
	OS_TYPE="$(uname)"

	if [[ "$OS_TYPE" == "Darwin" ]]; then
		SCHEDULER_NAME="LaunchAgent"
		export OS_TYPE SCHEDULER_NAME
		return 0
	elif [[ "$OS_TYPE" == "Linux" ]]; then
		SCHEDULER_NAME="systemd user service"
		export OS_TYPE SCHEDULER_NAME
		return 0
	else
		print_error "Unsupported OS: $OS_TYPE"
		echo "ccblocks supports macOS (Darwin) and Linux only"
		return 1
	fi
}

# Constants
export BLOCK_DURATION_SECONDS=18000 # 5 hours in seconds

# Canonical preset schedule definitions - the one place that encodes each
# preset's trigger hours and (for weekday-restricted presets) which ISO
# weekdays it applies to. launchagent-helper.sh and systemd-helper.sh both
# derive their platform-specific schedule syntax from this, so a future
# preset change can't drift between platforms the way the "work" preset's
# weekday encoding once did (macOS and Linux disagreed on which days
# "Mon-Fri" actually landed on).
#
# Usage: preset_hours <name>    -> space-separated hours, e.g. "0 6 12 18"
#        preset_weekdays <name> -> space-separated ISO weekday numbers
#                                  (1=Monday..7=Sunday), or empty for a
#                                  daily (every day) preset
# Both return 1 silently (no print_error) on an unknown name: callers
# invoke these via command substitution, so writing an error message to
# stdout here would get captured into the result instead of shown to the
# user - the caller reports the "Unknown schedule" error itself.
preset_hours() {
	case "$1" in
	247) echo "0 6 12 18" ;;
	work) echo "9 14" ;;
	night) echo "18 23" ;;
	*) return 1 ;;
	esac
}

preset_weekdays() {
	case "$1" in
	work) echo "1 2 3 4 5" ;; # Monday-Friday, ISO weekday numbering
	247 | night) echo "" ;;   # every day
	*) return 1 ;;
	esac
}

# Logging helpers
log_to_system() {
	local message="$1"
	logger -t ccblocks "$message" 2>/dev/null || true
}

json_string_value() {
	local json="$1"
	local key="$2"

	printf '%s' "$json" | tr -d '\n\r' | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

json_bool_value() {
	local json="$1"
	local key="$2"

	printf '%s' "$json" | tr -d '\n\r' | sed -n \
		-e "s/.*\"$key\"[[:space:]]*:[[:space:]]*\(true\).*/\1/p" \
		-e "s/.*\"$key\"[[:space:]]*:[[:space:]]*\(false\).*/\1/p"
}

require_subscription_auth() {
	local claude_bin="${1:-claude}"
	local forbidden_var

	# Credential-shaped vars: any non-empty value means an API/provider
	# credential is in use.
	for forbidden_var in \
		ANTHROPIC_API_KEY \
		ANTHROPIC_AUTH_TOKEN \
		ANTHROPIC_BASE_URL; do
		if [ -n "${!forbidden_var:-}" ]; then
			print_error "Refusing to trigger: $forbidden_var is set"
			print_error "ccblocks only triggers Claude subscription auth users."
			echo "Unset API/provider credentials before running ccblocks."
			log_to_system "Refused trigger because $forbidden_var is set"
			return 1
		fi
	done

	# Boolean-shaped provider flags: only a truthy value means the
	# provider is actually enabled (Claude Code documents "set to 1 or
	# true"); a merely-set-but-falsy value like "0" is not in use.
	local forbidden_flag
	for forbidden_flag in \
		CLAUDE_CODE_USE_BEDROCK \
		CLAUDE_CODE_USE_VERTEX \
		CLAUDE_CODE_USE_FOUNDRY; do
		case "${!forbidden_flag:-}" in
		1 | true | TRUE | True)
			print_error "Refusing to trigger: $forbidden_flag is enabled"
			print_error "ccblocks only triggers Claude subscription auth users."
			echo "Unset API/provider credentials before running ccblocks."
			log_to_system "Refused trigger because $forbidden_flag is enabled"
			return 1
			;;
		esac
	done

	local auth_status=""
	local auth_rc=0
	auth_status=$(run_with_timeout 15 "$claude_bin" auth status --json 2>/dev/null) || auth_rc=$?
	if [ "$auth_rc" -ne 0 ]; then
		print_error "Claude subscription auth not available"
		echo "Run: claude auth login"
		log_to_system "Refused trigger because Claude auth status failed"
		return 1
	fi

	local logged_in auth_method api_provider
	logged_in=$(json_bool_value "$auth_status" "loggedIn")
	auth_method=$(json_string_value "$auth_status" "authMethod")
	api_provider=$(json_string_value "$auth_status" "apiProvider")

	if [ "$logged_in" != "true" ]; then
		print_error "Claude subscription auth not available"
		echo "Run: claude auth login"
		log_to_system "Refused trigger because Claude is not logged in"
		return 1
	fi

	case "$api_provider" in
	"firstParty") ;;
	*)
		print_error "Refusing to trigger: Claude API provider is '$api_provider'"
		print_error "ccblocks only triggers Claude subscription auth users."
		log_to_system "Refused trigger because apiProvider=$api_provider"
		return 1
		;;
	esac

	case "$auth_method" in
	"subscription" | "claudeai" | "claudeAi" | "claude.ai" | "oauth_subscription")
		return 0
		;;
	*)
		print_error "Refusing to trigger: Claude auth method is '$auth_method'"
		print_error "ccblocks only triggers Claude subscription auth users."
		log_to_system "Refused trigger because authMethod=$auth_method"
		return 1
		;;
	esac
}

run_claude_subscription_trigger() {
	local claude_bin="${1:-claude}"

	run_with_timeout 15 "$claude_bin" \
		-p \
		--safe-mode \
		--model haiku \
		--max-turns 1 \
		--tools "" \
		--output-format text \
		"Reply exactly: OK"
}

# --- Usage-limit reset time parsing -------------------------------------
#
# When a trigger is rejected for hitting a usage limit, Claude's own error
# text includes a human-readable reset time, e.g.:
#   "You've hit your session limit · resets 1:40am (Europe/London)"
#   "Claude usage limit reached. Your limit will reset at 4pm."
# The surrounding sentence has already changed once between CLI versions
# (see setup.sh's "session limit" comment), so parse_reset_epoch only
# anchors on parts unlikely to change: a clock-time token, an optional
# weekday name, and an optional parenthesised IANA timezone. This lets a
# failed trigger be retried once, precisely when it'll actually work,
# instead of either waiting for the next scheduled slot or polling blindly.

# Internal: add N days to a YYYY-MM-DD date, bridging GNU vs BSD date(1).
_ccblocks_date_plus_days() {
	local base_date="$1" days="$2"

	if [ "$days" -eq 0 ]; then
		printf '%s\n' "$base_date"
		return 0
	fi

	if [ "$(uname)" = "Darwin" ]; then
		date -j -v "+${days}d" -f "%Y-%m-%d" "$base_date" +%Y-%m-%d 2>/dev/null
	else
		date -d "$base_date +${days} days" +%Y-%m-%d 2>/dev/null
	fi
}

# Internal: convert a "YYYY-MM-DD HH:MM" wall-clock string to a Unix epoch,
# optionally interpreted in the given IANA timezone. Bridges GNU (`date -d`)
# vs BSD/macOS (`date -j -f`) date(1).
_ccblocks_epoch_for_datetime() {
	local datetime="$1" tz="${2:-}"

	if [ "$(uname)" = "Darwin" ]; then
		if [ -n "$tz" ]; then
			TZ="$tz" date -j -f "%Y-%m-%d %H:%M" "$datetime" +%s 2>/dev/null
		else
			date -j -f "%Y-%m-%d %H:%M" "$datetime" +%s 2>/dev/null
		fi
	else
		if [ -n "$tz" ]; then
			TZ="$tz" date -d "$datetime" +%s 2>/dev/null
		else
			date -d "$datetime" +%s 2>/dev/null
		fi
	fi
}

# Extract a usage-limit reset time from Claude's error text and print it as
# a Unix epoch on stdout. Returns 1 with no output if no clock-time token
# is found (caller should fall back to the regular scheduled trigger).
parse_reset_epoch() {
	local text="$1"

	# Clock time, with or without minutes: "1:40am", "1:40 AM", "4pm".
	local time_token hh mm ampm
	time_token=$(printf '%s' "$text" | grep -Eio '[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' | head -1)
	if [ -n "$time_token" ]; then
		time_token=$(printf '%s' "$time_token" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
		ampm="${time_token: -2}"
		local hhmm="${time_token%??}"
		hh="${hhmm%%:*}"
		mm="${hhmm#*:}"
	else
		time_token=$(printf '%s' "$text" |
			grep -Eio '(^|[^0-9])[0-9]{1,2}[[:space:]]*[ap]m([^a-zA-Z]|$)' |
			grep -Eio '[0-9]{1,2}[[:space:]]*[ap]m' | head -1)
		if [ -z "$time_token" ]; then
			return 1
		fi
		time_token=$(printf '%s' "$time_token" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
		ampm="${time_token: -2}"
		hh="${time_token%??}"
		mm=0
	fi

	hh=$((10#$hh))
	mm=$((10#$mm))
	if [ "$hh" -lt 1 ] || [ "$hh" -gt 12 ] || [ "$mm" -gt 59 ]; then
		return 1
	fi
	if [ "$ampm" = "am" ]; then
		[ "$hh" -eq 12 ] && hh=0
	else
		[ "$hh" -ne 12 ] && hh=$((hh + 12))
	fi

	# Optional parenthesised IANA timezone, e.g. "(Europe/London)".
	local tz
	tz=$(printf '%s' "$text" | grep -Eo '\([A-Za-z_]+/[A-Za-z_]+\)' | head -1 | tr -d '()')

	# Optional weekday name anywhere in the text. Boundary-guarded on both
	# sides with an exhaustive list of full/abbreviated spellings (rather
	# than a day-prefix plus a wildcard suffix) so an incidental substring
	# like "month" or "satisfy" can't be mistaken for one.
	local weekday_alts='monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun'
	local weekday_name weekday_target=""
	weekday_name=$(printf '%s' "$text" |
		grep -Eio "(^|[^a-zA-Z])(${weekday_alts})([^a-zA-Z]|\$)" |
		grep -Eio "${weekday_alts}" |
		head -1 | tr '[:upper:]' '[:lower:]')
	case "$weekday_name" in
	mon*) weekday_target=1 ;;
	tue*) weekday_target=2 ;;
	wed*) weekday_target=3 ;;
	thu*) weekday_target=4 ;;
	fri*) weekday_target=5 ;;
	sat*) weekday_target=6 ;;
	sun*) weekday_target=7 ;;
	esac

	local today_date today_wd
	if [ -n "$tz" ]; then
		today_date=$(TZ="$tz" date +%Y-%m-%d 2>/dev/null) || return 1
		today_wd=$(TZ="$tz" date +%u 2>/dev/null) || return 1
	else
		today_date=$(date +%Y-%m-%d)
		today_wd=$(date +%u)
	fi
	[ -z "$today_date" ] && return 1

	local delta_days=0
	if [ -n "$weekday_target" ]; then
		delta_days=$(((weekday_target - today_wd + 7) % 7))
	fi

	local target_date epoch now_epoch
	target_date=$(_ccblocks_date_plus_days "$today_date" "$delta_days") || return 1
	[ -z "$target_date" ] && return 1

	epoch=$(_ccblocks_epoch_for_datetime "$(printf '%s %02d:%02d' "$target_date" "$hh" "$mm")" "$tz") || return 1
	[ -z "$epoch" ] && return 1

	now_epoch=$(date +%s)

	# An already-past moment means "the next occurrence": roll forward a
	# day (no weekday named) or a week (weekday named).
	if [ "$epoch" -le "$now_epoch" ]; then
		local roll_days=1
		[ -n "$weekday_target" ] && roll_days=7
		target_date=$(_ccblocks_date_plus_days "$today_date" "$((delta_days + roll_days))") || return 1
		epoch=$(_ccblocks_epoch_for_datetime "$(printf '%s %02d:%02d' "$target_date" "$hh" "$mm")" "$tz") || return 1
		[ -z "$epoch" ] && return 1
	fi

	printf '%s\n' "$epoch"
}

# Get helper script path based on OS
get_helper_script() {
	local script_dir="${1:-}"

	if [[ -z "$script_dir" ]]; then
		print_error "get_helper_script: script_dir parameter required"
		return 1
	fi

	if [[ "$OS_TYPE" == "Darwin" ]]; then
		echo "$script_dir/lib/launchagent-helper.sh"
	elif [[ "$OS_TYPE" == "Linux" ]]; then
		echo "$script_dir/lib/systemd-helper.sh"
	else
		return 1
	fi
}

# Initialize OS-specific variables (sets HELPER, CONFIG_PATH, etc.)
# Usage: init_os_vars "$SCRIPT_DIR"
init_os_vars() {
	local script_dir="${1:-}"

	if [[ -z "$script_dir" ]]; then
		print_error "init_os_vars: script_dir parameter required"
		return 1
	fi

	# Ensure OS is detected
	if [[ -z "$OS_TYPE" ]]; then
		print_error "init_os_vars: OS_TYPE not set. Call detect_os first."
		return 1
	fi

	# Ensure config directory exists
	mkdir -p "$CCBLOCKS_CONFIG" 2>/dev/null || true

	# Set common variables based on OS
	if [[ "$OS_TYPE" == "Darwin" ]]; then
		export HELPER="$script_dir/lib/launchagent-helper.sh"
		export CONFIG_PATH="$HOME/Library/LaunchAgents/ccblocks.plist"
		export TIMER_PATH="" # no separate timer file on macOS
		export LOAD_CMD="load"
		export UNLOAD_CMD="unload"
	elif [[ "$OS_TYPE" == "Linux" ]]; then
		export HELPER="$script_dir/lib/systemd-helper.sh"
		export CONFIG_PATH="$HOME/.config/systemd/user/ccblocks@.service"
		export TIMER_PATH="$HOME/.config/systemd/user/ccblocks@.timer"
		export LOAD_CMD="enable"
		export UNLOAD_CMD="disable"
	else
		return 1
	fi

	return 0
}

# Config file paths
CONFIG_FILE="$CCBLOCKS_CONFIG/config.json"

# Config schema management
read_schedule_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		return 1
	fi

	# Read config using python3 for JSON parsing
	if command_exists python3; then
		python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], 'r') as f:
        config = json.load(f)
        if 'schedule' in config:
            sched = config['schedule']
            print(f"type={sched.get('type', 'preset')}")
            print(f"preset={sched.get('preset', '247')}")
            if 'custom_hours' in sched:
                print(f"custom_hours={','.join(map(str, sched['custom_hours']))}")
            if 'coverage_hours' in sched:
                print(f"coverage_hours={sched['coverage_hours']}")
except Exception as e:
    sys.exit(1)
PY
	else
		print_error "python3 required for config management"
		return 1
	fi
}

write_schedule_config() {
	local schedule_type="$1"
	local preset="${2:-}"
	local custom_hours="${3:-}"

	mkdir -p "$CCBLOCKS_CONFIG" 2>/dev/null || true

	if command_exists python3; then
		python3 - "$CONFIG_FILE" "$schedule_type" "$preset" "$custom_hours" <<'PY'
import json
import sys
from pathlib import Path

config_file = sys.argv[1]
schedule_type = sys.argv[2]
preset = sys.argv[3] if len(sys.argv) > 3 else ""
custom_hours = sys.argv[4] if len(sys.argv) > 4 else ""

config = {}
if Path(config_file).exists():
    try:
        with open(config_file, 'r') as f:
            config = json.load(f)
    except:
        config = {}

config['schedule'] = {'type': schedule_type}

if schedule_type == 'preset' and preset:
    config['schedule']['preset'] = preset
elif schedule_type == 'custom' and custom_hours:
    hours = [int(h.strip()) for h in custom_hours.split(',') if h.strip()]
    config['schedule']['custom_hours'] = sorted(hours)
    # Calculate coverage
    coverage = len(hours) * 5
    config['schedule']['coverage_hours'] = coverage

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)
PY
	else
		print_error "python3 required for config management"
		return 1
	fi
}

# Validate custom schedule hours
# Returns 0 if valid, 1 if invalid
validate_custom_hours() {
	local hours_str="$1"
	local hours

	# Convert comma-separated string to array
	IFS=',' read -ra hours <<<"$hours_str"

	# Remove whitespace and validate each hour
	local cleaned_hours=()
	for h in "${hours[@]}"; do
		h=$(echo "$h" | tr -d ' ')
		if ! [[ "$h" =~ ^[0-9]+$ ]]; then
			print_error "Invalid hour: '$h' (must be a number)"
			return 1
		fi
		# Force base-10 interpretation: bash arithmetic/comparison treats a
		# leading zero (e.g. "08") as octal, which is invalid for 8/9.
		h=$((10#$h))
		if [[ "$h" -lt 0 || "$h" -gt 23 ]]; then
			print_error "Invalid hour: $h (must be 0-23)"
			return 1
		fi
		cleaned_hours+=("$h")
	done

	# Check minimum triggers
	if [[ ${#cleaned_hours[@]} -lt 2 ]]; then
		print_error "At least 2 triggers required"
		return 1
	fi

	# Check maximum triggers (4 per day for 5-hour blocks)
	if [[ ${#cleaned_hours[@]} -gt 4 ]]; then
		print_error "Maximum 4 triggers allowed (24h ÷ 5h = 4.8)"
		echo "  More triggers don't increase coverage - they overlap existing 5-hour windows"
		return 1
	fi

	# Sort hours (bash 3.2 compatible)
	sorted_hours=()
	while IFS= read -r hour; do
		sorted_hours+=("$hour")
	done < <(printf '%s\n' "${cleaned_hours[@]}" | sort -n)

	# Check for duplicates
	for ((i = 0; i < ${#sorted_hours[@]} - 1; i++)); do
		if [[ "${sorted_hours[$i]}" -eq "${sorted_hours[$((i + 1))]}" ]]; then
			print_error "Duplicate hour: ${sorted_hours[$i]}"
			return 1
		fi
	done

	# Check minimum 5-hour spacing
	for ((i = 0; i < ${#sorted_hours[@]} - 1; i++)); do
		local current="${sorted_hours[$i]}"
		local next="${sorted_hours[$((i + 1))]}"
		local spacing=$((next - current))

		if [[ $spacing -lt 5 ]]; then
			print_error "Insufficient spacing: ${current}:00 to ${next}:00 is only ${spacing}h (minimum 5h required)"
			echo "  Claude blocks are 5 hours long - triggers must be ≥5h apart"
			return 1
		fi
	done

	# Check wraparound (last to first)
	local first="${sorted_hours[0]}"
	local last="${sorted_hours[$((${#sorted_hours[@]} - 1))]}"
	local wraparound_spacing=$((24 - last + first))

	if [[ $wraparound_spacing -lt 5 ]]; then
		print_error "Insufficient spacing: ${last}:00 to ${first}:00 (next day) is only ${wraparound_spacing}h (minimum 5h required)"
		echo "  Claude blocks are 5 hours long - triggers must be ≥5h apart"
		return 1
	fi

	return 0
}

# Calculate coverage hours and gaps
calculate_coverage() {
	local hours_str="$1"

	IFS=',' read -ra hours <<<"$hours_str"
	local coverage=$((${#hours[@]} * 5))
	local gaps=$((24 - coverage))

	echo "coverage=$coverage"
	echo "gaps=$gaps"
}

# Export functions so they can be used in subshells if needed
export -f print_status print_error print_warning print_header show_logo run_with_timeout log_to_system command_exists
export -f install_err_trap handle_ccblocks_error
export -f preset_hours preset_weekdays
export -f json_string_value json_bool_value require_subscription_auth run_claude_subscription_trigger
export -f read_schedule_config write_schedule_config validate_custom_hours calculate_coverage
export -f _ccblocks_date_plus_days _ccblocks_epoch_for_datetime parse_reset_epoch
