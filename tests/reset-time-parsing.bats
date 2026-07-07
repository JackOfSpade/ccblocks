#!/usr/bin/env bats

# Tests for parse_reset_epoch (lib/common.sh) - extracting a usage-limit
# reset time out of Claude's rejection text. The wording of that text has
# already changed once between CLI versions (see setup.sh's "session
# limit" comment), so these tests deliberately exercise several different
# sentences around the same clock-time token rather than one fixed string.

load test_helper

setup() {
	setup_test_dir
	source "$PROJECT_LIB_DIR/common.sh"
}

teardown() {
	teardown_test_dir
}

# Converts an epoch back to "HH:MM" in the given TZ (or local if omitted),
# so assertions don't have to hardcode which calendar day it resolved to.
epoch_hm() {
	local epoch="$1" tz="${2:-}"
	if [ -n "$tz" ]; then
		TZ="$tz" date -d "@$epoch" +%H:%M
	else
		date -d "@$epoch" +%H:%M
	fi
}

@test "parse_reset_epoch: extracts time with minutes and am/pm" {
	run parse_reset_epoch "You've hit your session limit · resets 1:40am"
	assert_success
	[ "$(epoch_hm "$output")" = "01:40" ]
}

@test "parse_reset_epoch: extracts time without minutes" {
	run parse_reset_epoch "Claude usage limit reached. Your limit will reset at 4pm."
	assert_success
	[ "$(epoch_hm "$output")" = "16:00" ]
}

@test "parse_reset_epoch: handles noon correctly" {
	run parse_reset_epoch "resets 12:00pm"
	assert_success
	[ "$(epoch_hm "$output")" = "12:00" ]
}

@test "parse_reset_epoch: handles midnight correctly" {
	run parse_reset_epoch "resets 12:00am"
	assert_success
	[ "$(epoch_hm "$output")" = "00:00" ]
}

@test "parse_reset_epoch: is case-insensitive on am/pm" {
	run parse_reset_epoch "resets 1:40AM"
	assert_success
	[ "$(epoch_hm "$output")" = "01:40" ]
}

@test "parse_reset_epoch: honours an explicit IANA timezone" {
	run parse_reset_epoch "You've hit your session limit · resets 1:40am (Europe/London)"
	assert_success
	[ "$(epoch_hm "$output" "Europe/London")" = "01:40" ]
}

@test "parse_reset_epoch: resolves a weekday abbreviation to that day of the week" {
	run parse_reset_epoch "Weekly limit reached. Resets Sat 2:00 AM."
	assert_success
	[ "$(date -d "@$output" +%u)" = "6" ]
	[ "$(epoch_hm "$output")" = "02:00" ]
}

@test "parse_reset_epoch: resolves a full weekday name" {
	run parse_reset_epoch "Resets Monday at 9:00am"
	assert_success
	[ "$(date -d "@$output" +%u)" = "1" ]
	[ "$(epoch_hm "$output")" = "09:00" ]
}

@test "parse_reset_epoch: is tolerant of an entirely different sentence around the same time token" {
	run parse_reset_epoch "Rate limited. Come back after 1:40am and try again."
	assert_success
	[ "$(epoch_hm "$output")" = "01:40" ]
}

@test "parse_reset_epoch: fails when no time token is present" {
	run parse_reset_epoch "Something went wrong, please try again later."
	assert_failure
	[ -z "$output" ]
}

@test "parse_reset_epoch: always resolves to a moment in the future" {
	run parse_reset_epoch "resets 1:40am"
	assert_success
	now=$(date +%s)
	[ "$output" -gt "$now" ]
}

@test "parse_reset_epoch: does not mistake 'month' for the Monday weekday token" {
	run parse_reset_epoch "resets 1:40am next month"
	assert_success
	[ "$(epoch_hm "$output")" = "01:40" ]

	# A bogus weekday match could push the target up to 6 days out; with
	# no real weekday named, it should only ever roll to tomorrow at most.
	now=$(date +%s)
	days_ahead=$(((output - now) / 86400))
	[ "$days_ahead" -le 1 ]
}
