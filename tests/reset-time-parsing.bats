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

# parse_reset_epoch adds a 1-minute safety margin on top of the parsed
# clock time (see its own header comment), so assertions about the time a
# message actually STATED compare against epoch-60, not the raw epoch.
stated_hm() {
	epoch_hm "$(($1 - 60))" "${2:-}"
}

@test "parse_reset_epoch: extracts time with minutes and am/pm" {
	run parse_reset_epoch "You've hit your session limit · resets 1:40am"
	assert_success
	[ "$(stated_hm "$output")" = "01:40" ]
}

@test "parse_reset_epoch: extracts time without minutes" {
	run parse_reset_epoch "Claude usage limit reached. Your limit will reset at 4pm."
	assert_success
	[ "$(stated_hm "$output")" = "16:00" ]
}

@test "parse_reset_epoch: handles noon correctly" {
	run parse_reset_epoch "resets 12:00pm"
	assert_success
	[ "$(stated_hm "$output")" = "12:00" ]
}

@test "parse_reset_epoch: handles midnight correctly" {
	run parse_reset_epoch "resets 12:00am"
	assert_success
	[ "$(stated_hm "$output")" = "00:00" ]
}

@test "parse_reset_epoch: is case-insensitive on am/pm" {
	run parse_reset_epoch "resets 1:40AM"
	assert_success
	[ "$(stated_hm "$output")" = "01:40" ]
}

@test "parse_reset_epoch: honours an explicit IANA timezone" {
	run parse_reset_epoch "You've hit your session limit · resets 1:40am (Europe/London)"
	assert_success
	[ "$(stated_hm "$output" "Europe/London")" = "01:40" ]
}

@test "parse_reset_epoch: honours a three-segment IANA timezone" {
	run parse_reset_epoch "resets 1:40am (America/Indiana/Indianapolis)"
	assert_success
	[ "$(stated_hm "$output" "America/Indiana/Indianapolis")" = "01:40" ]
}

@test "parse_reset_epoch: falls back to local time for an unrecognised timezone rather than silently misinterpreting it" {
	run parse_reset_epoch "resets 1:40am (Mars/Colony)"
	assert_success
	# A bogus zone must not be treated as UTC (or anything else) - it
	# should be ignored entirely, leaving local-time interpretation.
	[ "$(stated_hm "$output")" = "01:40" ]
}

@test "parse_reset_epoch: ignores an unrelated parenthetical and finds the real timezone next to the time token" {
	run parse_reset_epoch "(auto/retry) resets 1:40am (Europe/London)"
	assert_success
	[ "$(stated_hm "$output" "Europe/London")" = "01:40" ]
}

@test "parse_reset_epoch: resolves a weekday abbreviation to that day of the week" {
	run parse_reset_epoch "Weekly limit reached. Resets Sat 2:00 AM."
	assert_success
	[ "$(date -d "@$output" +%u)" = "6" ]
	[ "$(stated_hm "$output")" = "02:00" ]
}

@test "parse_reset_epoch: resolves a full weekday name" {
	run parse_reset_epoch "Resets Monday at 9:00am"
	assert_success
	[ "$(date -d "@$output" +%u)" = "1" ]
	[ "$(stated_hm "$output")" = "09:00" ]
}

@test "parse_reset_epoch: is tolerant of an entirely different sentence around the same time token" {
	run parse_reset_epoch "Rate limited. Come back after 1:40am and try again."
	assert_success
	[ "$(stated_hm "$output")" = "01:40" ]
}

@test "parse_reset_epoch: picks the time after 'resets', not an unrelated earlier clock time in the same message" {
	run parse_reset_epoch "As of 11:59pm, your account resets 1:40am (Europe/London)"
	assert_success
	[ "$(stated_hm "$output" "Europe/London")" = "01:40" ]
}

@test "parse_reset_epoch: fails when no time token is present" {
	run parse_reset_epoch "Something went wrong, please try again later."
	assert_failure
	[ -z "$output" ]
}

@test "parse_reset_epoch: fails cleanly when 'reset' appears but no time follows it" {
	run parse_reset_epoch "Your limit will reset soon, check back later."
	assert_failure
	[ -z "$output" ]
}

@test "parse_reset_epoch: always resolves to a moment in the future" {
	run parse_reset_epoch "resets 1:40am"
	assert_success
	now=$(date +%s)
	[ "$output" -gt "$now" ]
}

@test "parse_reset_epoch: adds a 1-minute safety margin rather than firing at the exact parsed instant" {
	run parse_reset_epoch "resets 1:40am"
	assert_success
	# The returned epoch itself must read 01:41 (not 01:40) - the margin
	# is added, not just theoretically available - and subtracting it
	# back out must land exactly on the message's stated 01:40.
	[ "$(epoch_hm "$output")" = "01:41" ]
	[ "$(epoch_hm "$((output - 60))")" = "01:40" ]
}

@test "parse_reset_epoch: does not mistake 'month' for the Monday weekday token" {
	run parse_reset_epoch "resets 1:40am next month"
	assert_success
	[ "$(stated_hm "$output")" = "01:40" ]

	# A bogus weekday match could push the target up to 6 days out; with
	# no real weekday named, it should only ever roll to tomorrow at most.
	now=$(date +%s)
	days_ahead=$(((output - now) / 86400))
	[ "$days_ahead" -le 1 ]
}

@test "parse_reset_epoch: a reset time in the current minute retries imminently, not a full day later" {
	# Construct a message whose stated reset time is "right now" (to the
	# minute) - this used to overshoot to tomorrow/next week because the
	# rollover check compared against the exact current second rather
	# than the start of the current minute.
	now_h=$(date +%-I)
	now_m=$(date +%M)
	now_ampm=$(date +%P)
	run parse_reset_epoch "resets ${now_h}:${now_m}${now_ampm}"
	assert_success

	now=$(date +%s)
	diff=$((output - now))
	# Must be imminent (within a couple of minutes), not overshot by
	# roughly a day (86400s) or a week (604800s).
	[ "$diff" -ge 0 ]
	[ "$diff" -le 150 ]
}
