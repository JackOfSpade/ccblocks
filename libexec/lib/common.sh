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
# a Unix epoch on stdout, a minute after the parsed reset moment (the
# message only ever gives whole minutes, so the true server-side reset
# could land anywhere inside that minute or lag it slightly - firing right
# at/before it risks racing the actual reset). Returns 1 with no output if
# no clock-time token is found (caller should fall back to the regular
# scheduled trigger).
parse_reset_epoch() {
	local text="$1"

	# Prefer to look for the reset time near the word "reset(s)" when
	# present, since every known message variant has used it so far and it
	# disambiguates which of several clock-time-shaped substrings in a
	# longer message (e.g. "As of 11:59pm, your account resets 1:40am") is
	# the actual reset time. Falls back to scanning the whole text when
	# it's absent, to stay tolerant of a wording change that drops it.
	local text_lower search_text="$text"
	text_lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
	if [[ "$text_lower" == *reset* ]]; then
		local prefix="${text_lower%%reset*}"
		search_text="${text:${#prefix}}"
	fi

	# Clock time, with or without minutes: "1:40am", "1:40 AM", "4pm".
	local time_token time_token_raw hh mm ampm
	time_token_raw=$(printf '%s' "$search_text" | grep -Eio '[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' | head -1)
	if [ -n "$time_token_raw" ]; then
		time_token=$(printf '%s' "$time_token_raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
		ampm="${time_token: -2}"
		local hhmm="${time_token%??}"
		hh="${hhmm%%:*}"
		mm="${hhmm#*:}"
	else
		time_token_raw=$(printf '%s' "$search_text" |
			grep -Eio '(^|[^0-9])[0-9]{1,2}[[:space:]]*[ap]m([^a-zA-Z]|$)' |
			grep -Eio '[0-9]{1,2}[[:space:]]*[ap]m' | head -1)
		if [ -z "$time_token_raw" ]; then
			return 1
		fi
		time_token=$(printf '%s' "$time_token_raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
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

	# Optional parenthesised IANA timezone, e.g. "(Europe/London)". Only
	# looked for in a short window right after the matched time token (not
	# the first parenthetical anywhere in the text) so an unrelated
	# parenthetical elsewhere in the message can't be mistaken for it, and
	# validated against the system's own zoneinfo database so a bogus or
	# decoy zone name falls back to local-time interpretation instead of
	# silently producing a wrong epoch (GNU/BSD date both accept an
	# unrecognised TZ value and silently treat it as UTC rather than
	# erroring, so an unvalidated match would fail open, not closed).
	local tz="" tz_tail
	tz_tail="${search_text#*"$time_token_raw"}"
	tz_tail="${tz_tail:0:40}"
	tz=$(printf '%s' "$tz_tail" | grep -Eo '\([A-Za-z_]+(/[A-Za-z_]+)+\)' | head -1 | tr -d '()')
	if [ -n "$tz" ] && [ ! -e "/usr/share/zoneinfo/$tz" ]; then
		tz=""
	fi

	# Optional weekday name anywhere in the (reset-anchored) text. Boundary-
	# guarded on both sides with an exhaustive list of full/abbreviated
	# spellings (rather than a day-prefix plus a wildcard suffix) so an
	# incidental substring like "month" or "satisfy" can't be mistaken for
	# one.
	local weekday_alts='monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun'
	local weekday_name weekday_target=""
	weekday_name=$(printf '%s' "$search_text" |
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

	local target_date epoch now_epoch now_minute_epoch
	target_date=$(_ccblocks_date_plus_days "$today_date" "$delta_days") || return 1
	[ -z "$target_date" ] && return 1

	epoch=$(_ccblocks_epoch_for_datetime "$(printf '%s %02d:%02d' "$target_date" "$hh" "$mm")" "$tz") || return 1
	[ -z "$epoch" ] && return 1

	now_epoch=$(date +%s)
	# Truncate to the start of the current minute before comparing: the
	# parsed time is always :00 seconds (messages only ever give HH:MM),
	# so comparing against the exact current second would treat a target
	# equal to "this very minute" as already hours/days in the past -
	# rolling a full day/week forward - purely because of the seconds
	# already elapsed within that same minute.
	now_minute_epoch=$((now_epoch - (now_epoch % 60)))

	# An already-past moment means "the next occurrence": roll forward a
	# day (no weekday named) or a week (weekday named).
	if [ "$epoch" -lt "$now_minute_epoch" ]; then
		local roll_days=1
		[ -n "$weekday_target" ] && roll_days=7
		target_date=$(_ccblocks_date_plus_days "$today_date" "$((delta_days + roll_days))") || return 1
		epoch=$(_ccblocks_epoch_for_datetime "$(printf '%s %02d:%02d' "$target_date" "$hh" "$mm")" "$tz") || return 1
		[ -z "$epoch" ] && return 1
	fi

	printf '%s\n' "$((epoch + 60))"
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


# Export functions so they can be used in subshells if needed
export -f print_status print_error print_warning print_header show_logo run_with_timeout log_to_system command_exists
export -f install_err_trap handle_ccblocks_error
export -f json_string_value json_bool_value require_subscription_auth run_claude_subscription_trigger
export -f _ccblocks_date_plus_days _ccblocks_epoch_for_datetime parse_reset_epoch
