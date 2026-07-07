#!/usr/bin/env bats

# Tests for the OS scheduler helpers' `retry <epoch>` command - the
# one-shot precise retry scheduled after a usage-limit rejection whose
# reset time parse_reset_epoch could parse. Platform-specific (each half
# only runs on its own OS) since these exercise the real systemd-run /
# launchctl call shape, not a faked-out helper script.

load test_helper

setup() {
	setup_test_dir
	export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
	mkdir -p "$CCBLOCKS_CONFIG"
}

teardown() {
	teardown_test_dir
}

# --- Linux: systemd-helper.sh ---------------------------------------------

@test "systemd-helper retry schedules a one-shot systemd-run timer at the given epoch" {
	skip_if_not_linux

	calls_file="${TEST_TEMP_DIR}/systemd-run-calls.log"
	mock_command "systemd-run" "printf '%s\n' \"\$*\" >> '${calls_file}'; exit 0"

	epoch=1783471200
	run "${PROJECT_LIB_DIR}/systemd-helper.sh" retry "$epoch"
	assert_success

	expected_when=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S')
	assert_file_contains "$calls_file" "on-calendar=$expected_when"
	assert_file_contains "$calls_file" "collect"
	assert_file_contains "$calls_file" "CCBLOCKS_RETRY_ATTEMPT=1"
	assert_file_contains "$calls_file" "PATH=$PATH"
	assert_file_contains "$calls_file" "ccblocks-daemon.sh"
}

@test "systemd-helper retry replaces a still-pending prior retry instead of colliding on the fixed unit name" {
	skip_if_not_linux

	# Stateful mocks that actually simulate the real systemd conflict: a
	# marker file stands in for "the ccblocks-retry unit is registered".
	# systemd-run refuses (like the real one would on a name collision) if
	# the marker is already there; systemctl stop clears it. This catches
	# an ordering bug (cancel not called, or called after systemd-run)
	# rather than merely checking "stop was invoked at some point".
	marker="${TEST_TEMP_DIR}/unit-registered"
	mock_command "systemd-run" "
if [ -e '${marker}' ]; then
    echo 'Unit ccblocks-retry.service already exists' >&2
    exit 1
fi
touch '${marker}'
exit 0"
	mock_command "systemctl" "
case \"\$*\" in
*ccblocks-retry*) rm -f '${marker}' ;;
esac
exit 0"

	run "${PROJECT_LIB_DIR}/systemd-helper.sh" retry 1783471200
	assert_success
	run "${PROJECT_LIB_DIR}/systemd-helper.sh" retry 1783474800
	assert_success
}

@test "systemd-helper cancel stops the pending retry's timer and service units" {
	skip_if_not_linux

	calls_file="${TEST_TEMP_DIR}/systemctl-calls.log"
	mock_command "systemctl" "printf '%s\n' \"\$*\" >> '${calls_file}'; exit 0"

	run "${PROJECT_LIB_DIR}/systemd-helper.sh" cancel
	assert_success
	assert_file_contains "$calls_file" "stop"
	assert_file_contains "$calls_file" "ccblocks-retry.timer"
	assert_file_contains "$calls_file" "ccblocks-retry.service"
}

@test "systemd-helper cancel is a harmless no-op when nothing is pending" {
	skip_if_not_linux

	# No mock at all: the real systemctl runs against a unit that doesn't
	# exist and must still report success (best-effort cleanup).
	run "${PROJECT_LIB_DIR}/systemd-helper.sh" cancel
	assert_success
}

@test "systemd-helper retry requires an epoch argument" {
	skip_if_not_linux

	run "${PROJECT_LIB_DIR}/systemd-helper.sh" retry
	assert_failure
	assert_output --partial "Epoch timestamp required"
}

@test "systemd-helper retry fails cleanly when systemd-run is unavailable" {
	skip_if_not_linux

	# A plain minimal PATH (e.g. "/usr/bin:/bin") does NOT reliably hide a
	# real systemd-run - it's genuinely installed there on any systemd-based
	# host, this sandbox included. Build a PATH that mirrors the real one
	# but excludes systemd-run specifically, so this test actually exercises
	# the "not found" branch instead of silently testing nothing.
	fake_path_dir="${TEST_TEMP_DIR}/no-systemd-run-path"
	mkdir -p "$fake_path_dir"
	for bin_dir in /usr/bin /bin /usr/local/bin; do
		[ -d "$bin_dir" ] || continue
		for bin in "$bin_dir"/*; do
			name="$(basename "$bin")"
			[ "$name" = "systemd-run" ] && continue
			[ -x "$bin" ] || continue
			ln -sf "$bin" "$fake_path_dir/$name" 2>/dev/null || true
		done
	done

	# Confirm the curated PATH really doesn't resolve systemd-run before
	# trusting the rest of the assertion.
	PATH="$fake_path_dir" run command -v systemd-run
	assert_failure

	PATH="$fake_path_dir" run "${PROJECT_LIB_DIR}/systemd-helper.sh" retry 1783471200
	assert_failure
	assert_output --partial "systemd-run not found"
}

# --- macOS: launchagent-helper.sh -----------------------------------------

@test "launchagent-helper retry writes a self-cleaning one-shot plist and bootstraps it" {
	skip_if_not_macos

	export HOME="${TEST_TEMP_DIR}/home"
	mkdir -p "$HOME/Library/LaunchAgents"

	calls_file="${TEST_TEMP_DIR}/launchctl-calls.log"
	mock_command "launchctl" "printf '%s\n' \"\$*\" >> '${calls_file}'; exit 0"

	epoch=1783471200
	run "${PROJECT_LIB_DIR}/launchagent-helper.sh" retry "$epoch"
	assert_success

	plist="$HOME/Library/LaunchAgents/ccblocks-retry.plist"
	[ -f "$plist" ]

	expected_month=$((10#$(date -r "$epoch" +%m)))
	expected_day=$((10#$(date -r "$epoch" +%d)))
	expected_hour=$((10#$(date -r "$epoch" +%H)))
	expected_minute=$((10#$(date -r "$epoch" +%M)))

	assert_file_contains "$plist" "<integer>${expected_month}</integer>"
	assert_file_contains "$plist" "<integer>${expected_day}</integer>"
	assert_file_contains "$plist" "<integer>${expected_hour}</integer>"
	assert_file_contains "$plist" "<integer>${expected_minute}</integer>"

	# Check the VALUE, not just that the key name appears somewhere - a
	# wrong or empty value would still pass a bare substring check on the
	# key alone.
	run grep -A1 "<key>CCBLOCKS_RETRY_ATTEMPT</key>" "$plist"
	assert_success
	assert_output --partial "<string>1</string>"

	# The job cleans up its own plist before risking self-termination via
	# bootout, so a killed process never leaves a refiring plist behind.
	run grep -n "rm -f\|bootout" "$plist"
	assert_success
	rm_line=$(echo "$output" | grep "rm -f" | cut -d: -f1)
	bootout_line=$(echo "$output" | grep "bootout" | cut -d: -f1)
	[ "$rm_line" -lt "$bootout_line" ]

	assert_file_contains "$calls_file" "bootstrap"
}

@test "launchagent-helper retry shell-escapes paths embedded in the self-cleanup command" {
	skip_if_not_macos

	export HOME="${TEST_TEMP_DIR}/home with spaces"
	mkdir -p "$HOME/Library/LaunchAgents"

	mock_command "launchctl" "exit 0"

	run "${PROJECT_LIB_DIR}/launchagent-helper.sh" retry 1783471200
	assert_success

	plist="$HOME/Library/LaunchAgents/ccblocks-retry.plist"
	[ -f "$plist" ]

	# Extract the embedded bash -c body (the fourth <string> in
	# ProgramArguments) and confirm it actually parses as valid shell -
	# an unescaped space in $HOME would otherwise split the path into two
	# separate words and break the self-cleanup step.
	body=$(grep -A1 '<string>-c</string>' "$plist" | tail -1 | sed -e 's/^ *<string>//' -e 's/<\/string>$//')
	run bash -n -c "$body"
	assert_success
	[[ "$body" == *"home\\ with\\ spaces"* ]] || [[ "$body" == *"'home with spaces'"* ]]
}

@test "launchagent-helper retry replaces a still-pending prior retry instead of leaving a stale plist" {
	skip_if_not_macos

	export HOME="${TEST_TEMP_DIR}/home"
	mkdir -p "$HOME/Library/LaunchAgents"

	calls_file="${TEST_TEMP_DIR}/launchctl-calls.log"
	mock_command "launchctl" "printf '%s\n' \"\$*\" >> '${calls_file}'; exit 0"

	run "${PROJECT_LIB_DIR}/launchagent-helper.sh" retry 1783471200
	assert_success
	run "${PROJECT_LIB_DIR}/launchagent-helper.sh" retry 1783474800
	assert_success

	# The second call must have bootout'd the first before bootstrapping
	# the replacement - not merely bootstrapped over it.
	bootout_count=$(grep -c "bootout" "$calls_file")
	bootstrap_count=$(grep -c "bootstrap" "$calls_file")
	[ "$bootout_count" -ge 2 ]
	[ "$bootstrap_count" -eq 2 ]

	plist="$HOME/Library/LaunchAgents/ccblocks-retry.plist"
	expected_minute=$((10#$(date -r 1783474800 +%M)))
	assert_file_contains "$plist" "<integer>${expected_minute}</integer>"
}

@test "launchagent-helper cancel bootouts the pending retry and removes its plist" {
	skip_if_not_macos

	export HOME="${TEST_TEMP_DIR}/home"
	mkdir -p "$HOME/Library/LaunchAgents"
	plist="$HOME/Library/LaunchAgents/ccblocks-retry.plist"
	echo "placeholder" >"$plist"

	calls_file="${TEST_TEMP_DIR}/launchctl-calls.log"
	mock_command "launchctl" "printf '%s\n' \"\$*\" >> '${calls_file}'; exit 0"

	run "${PROJECT_LIB_DIR}/launchagent-helper.sh" cancel
	assert_success
	assert_file_contains "$calls_file" "bootout"
	[ ! -f "$plist" ]
}

@test "launchagent-helper cancel is a harmless no-op when nothing is pending" {
	skip_if_not_macos

	export HOME="${TEST_TEMP_DIR}/home"
	mkdir -p "$HOME/Library/LaunchAgents"
	mock_command "launchctl" "exit 1"

	run "${PROJECT_LIB_DIR}/launchagent-helper.sh" cancel
	assert_success
}

@test "launchagent-helper retry requires an epoch argument" {
	skip_if_not_macos

	run "${PROJECT_LIB_DIR}/launchagent-helper.sh" retry
	assert_failure
	assert_output --partial "Epoch timestamp required"
}
