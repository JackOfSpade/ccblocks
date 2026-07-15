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

# Fixed polling interval for the LaunchAgent/systemd scheduler. Single
# source of truth: the plist/timer writers and all help/status text
# derive from this instead of each hardcoding the value separately.
: "${CCBLOCKS_INTERVAL_SECONDS:=300}"
CCBLOCKS_INTERVAL_MINUTES=$((CCBLOCKS_INTERVAL_SECONDS / 60))
export CCBLOCKS_INTERVAL_SECONDS CCBLOCKS_INTERVAL_MINUTES

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
