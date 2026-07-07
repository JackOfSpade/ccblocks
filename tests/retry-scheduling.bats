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
	assert_file_contains "$calls_file" "ccblocks-daemon.sh"
}

@test "systemd-helper retry requires an epoch argument" {
	skip_if_not_linux

	run "${PROJECT_LIB_DIR}/systemd-helper.sh" retry
	assert_failure
	assert_output --partial "Epoch timestamp required"
}

@test "systemd-helper retry fails cleanly when systemd-run is unavailable" {
	skip_if_not_linux

	# No systemd-run on PATH at all (a bare, minimal PATH won't have it).
	PATH="/usr/bin:/bin" run "${PROJECT_LIB_DIR}/systemd-helper.sh" retry 1783471200
	assert_failure
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
	assert_file_contains "$plist" "CCBLOCKS_RETRY_ATTEMPT"

	# The job cleans up its own plist before risking self-termination via
	# bootout, so a killed process never leaves a refiring plist behind.
	run grep -n "rm -f\|bootout" "$plist"
	assert_success
	rm_line=$(echo "$output" | grep "rm -f" | cut -d: -f1)
	bootout_line=$(echo "$output" | grep "bootout" | cut -d: -f1)
	[ "$rm_line" -lt "$bootout_line" ]

	assert_file_contains "$calls_file" "bootstrap"
}

@test "launchagent-helper retry requires an epoch argument" {
	skip_if_not_macos

	run "${PROJECT_LIB_DIR}/launchagent-helper.sh" retry
	assert_failure
	assert_output --partial "Epoch timestamp required"
}
