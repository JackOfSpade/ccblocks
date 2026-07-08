#!/usr/bin/env bats

# Tests for ccblocks-daemon
# Integration tests for Claude Code block triggering

load test_helper

setup() {
    setup_test_dir
    SCRIPT="${PROJECT_ROOT}/libexec/ccblocks-daemon.sh"

    # Override config directory to test directory
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
}

teardown() {
    teardown_test_dir
}

# Claude CLI discovery tests
@test "ccblocks-daemon finds claude in PATH and triggers successfully" {
    mock_claude_success

    run "$SCRIPT"
    assert_success
}

@test "ccblocks-daemon finds executable claude under HOME .local fallback" {
    export HOME="${TEST_TEMP_DIR}/home"
    write_claude_mock_script "$HOME/.local/bin/claude"

    PATH="/usr/bin:/bin" run "$SCRIPT"
    assert_success
}

@test "ccblocks-daemon finds owner-only-executable claude via recursive .local search" {
    export HOME="${TEST_TEMP_DIR}/home"
    write_claude_mock_script "$HOME/.local/share/claude-app/claude"
    chmod 700 "$HOME/.local/share/claude-app/claude"

    PATH="/usr/bin:/bin" run "$SCRIPT"
    assert_success
}

@test "ccblocks-daemon refuses to trigger when ANTHROPIC_API_KEY is set" {
    calls_file="${TEST_TEMP_DIR}/claude-calls.log"
    mock_claude_call_recorder "$calls_file"

    ANTHROPIC_API_KEY="sk-ant-test" run "$SCRIPT"
    assert_failure
    assert_output --partial "subscription auth"
    refute [ -f "$calls_file" ]
}

@test "ccblocks-daemon refuses all API/provider credential environment variables before auth status" {
    calls_file="${TEST_TEMP_DIR}/claude-calls.log"
    mock_claude_call_recorder "$calls_file"

    for var_name in \
        ANTHROPIC_API_KEY \
        ANTHROPIC_AUTH_TOKEN \
        ANTHROPIC_BASE_URL \
        CLAUDE_CODE_USE_BEDROCK \
        CLAUDE_CODE_USE_VERTEX \
        CLAUDE_CODE_USE_FOUNDRY; do
        rm -f "$calls_file"

        run env "$var_name=1" "$SCRIPT"
        assert_failure
        assert_output --partial "$var_name"
        assert_output --partial "subscription auth"
        refute [ -f "$calls_file" ]
    done
}

@test "ccblocks-daemon refuses console/API auth status" {
    mock_claude_auth_method "console"

    run "$SCRIPT"
    assert_failure
    assert_output --partial "subscription auth"
}

@test "ccblocks-daemon refuses non-first-party API provider status" {
    mock_claude_auth_method "subscription" "bedrock"

    run "$SCRIPT"
    assert_failure
    assert_output --partial "API provider"
    assert_output --partial "subscription auth"
}

@test "ccblocks-daemon refuses ambiguous oauth auth status" {
    mock_claude_auth_method "oauth" "firstParty"

    run "$SCRIPT"
    assert_failure
    assert_output --partial "auth method"
    assert_output --partial "subscription auth"
}

@test "ccblocks-daemon requires an authenticated subscription user" {
    mock_claude_logged_out

    run "$SCRIPT"
    assert_failure
    assert_output --partial "claude auth login"
}

@test "ccblocks-daemon triggers haiku in print mode by default" {
    args_file="${TEST_TEMP_DIR}/claude-args.log"
    export CCBLOCKS_CLAUDE_ARGS_LOG="$args_file"
    mock_claude_success

    run "$SCRIPT"
    assert_success
    run cat "$args_file"
    assert_output --partial "-p --safe-mode --model haiku"
    assert_output --partial "--max-turns 1"
    assert_output --partial "--output-format text"
    assert_output --partial "Reply exactly: OK"
}

@test "ccblocks-daemon runs auth status through timeout wrapper" {
    timeout_log="${TEST_TEMP_DIR}/timeout.log"
    export CCBLOCKS_TIMEOUT_LOG="$timeout_log"
    mock_claude_success
    mock_command "timeout" '
echo "$*" >> "$CCBLOCKS_TIMEOUT_LOG"
duration="$1"
shift
"$@"'

    run "$SCRIPT"
    assert_success
    run cat "$timeout_log"
    assert_output --partial "auth status --json"
}

@test "ccblocks-daemon ignores trigger overrides and always uses the cheap prompt" {
    args_file="${TEST_TEMP_DIR}/claude-args.log"
    export CCBLOCKS_CLAUDE_ARGS_LOG="$args_file"
    export CCBLOCKS_MODEL="sonnet"
    export CCBLOCKS_PROMPT="Write a detailed essay about block scheduling"
    mock_claude_success

    run "$SCRIPT"
    assert_success
    run cat "$args_file"
    assert_output --partial "--model haiku"
    assert_output --partial "Reply exactly: OK"
    refute_output --partial "--model sonnet"
    refute_output --partial "detailed essay"
}

# Activity file tests
@test "ccblocks-daemon creates .last-activity file on success" {
    mock_claude_success

    run "$SCRIPT"
    assert_success
    assert [ -f "$CCBLOCKS_CONFIG/.last-activity" ]
}

@test "ccblocks-daemon writes timestamp to .last-activity file" {
    mock_claude_success

    run "$SCRIPT"
    assert_success

    # Verify file contains a timestamp pattern
    run cat "$CCBLOCKS_CONFIG/.last-activity"
    assert_output --regexp "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"
}

@test "ccblocks-daemon overwrites existing .last-activity file" {
    mock_claude_success

    # Create existing activity file
    echo "2024-01-01 00:00:00" > "$CCBLOCKS_CONFIG/.last-activity"

    run "$SCRIPT"
    assert_success

    # Verify it was overwritten with new timestamp
    run cat "$CCBLOCKS_CONFIG/.last-activity"
    refute_output --partial "2024-01-01"
}

# Timeout tests
@test "ccblocks-daemon handles claude timeout" {
    mock_claude_trigger_timeout

    run "$SCRIPT"
    assert_failure
}

@test "ccblocks-daemon handles claude failure" {
    mock_claude_failure

    run "$SCRIPT"
    assert_failure
}

# Config directory tests
@test "ccblocks-daemon creates config directory if missing" {
    # Remove config directory
    rm -rf "$CCBLOCKS_CONFIG"

    mock_claude_success

    run "$SCRIPT"
    assert_success
    assert [ -d "$CCBLOCKS_CONFIG" ]
}

@test "ccblocks-daemon handles existing config directory" {
    # Config directory already exists from setup
    assert [ -d "$CCBLOCKS_CONFIG" ]

    mock_claude_success

    run "$SCRIPT"
    assert_success
}

# Edge cases
@test "ccblocks-daemon doesn't fail if .last-activity write fails" {
    mock_claude_success

    # Make config directory read-only to prevent file creation
    chmod 555 "$CCBLOCKS_CONFIG"

    run "$SCRIPT"
    # Should still succeed even if activity file can't be written
    assert_success

    # Restore permissions for cleanup
    chmod 755 "$CCBLOCKS_CONFIG"
}

# ccusage verification tests
@test "ccblocks-daemon succeeds with standard ccusage active block output" {
    mock_claude_success
    mock_ccusage_active_block

    run "$SCRIPT"
    assert_success
    refute_output --partial "inconclusive"
}

@test "ccblocks-daemon warns when ccusage shows no active block but doesn't fail" {
    mock_claude_success
    mock_ccusage_no_block

    run "$SCRIPT"
    # Should still succeed by default (non-strict mode)
    assert_success
}

@test "ccblocks-daemon handles alternative ccusage output formats" {
    mock_claude_success
    mock_ccusage_alternative_format

    run "$SCRIPT"
    assert_success
    # Should not show inconclusive warning for recognized alternative format
    refute_output --partial "inconclusive"
}

@test "ccblocks-daemon warns on empty ccusage output but continues" {
    mock_claude_success
    mock_ccusage_empty_output

    run "$SCRIPT"
    assert_success
    assert_output --partial "empty output"
}

@test "ccblocks-daemon warns when ccusage is not found" {
    mock_claude_success
    mock_ccusage_not_installed

    run "$SCRIPT"
    assert_success
    assert_output --partial "ccusage not found"
}

@test "ccblocks-daemon logs actual output in debug mode for unrecognised ccusage format" {
    mock_claude_success
    # Mock ccusage with completely unexpected format
    mock_command "ccusage" "echo 'Unexpected format here'; exit 0"

    export CCBLOCKS_DEBUG=1
    run "$SCRIPT"
    assert_success
    assert_output --partial "[DEBUG]"
    assert_output --partial "Unexpected format"
}

# Sandboxes a copy of libexec so the OS scheduler helper (systemd-helper.sh
# or launchagent-helper.sh) can be replaced with a call recorder, without
# ever touching the real repository file or a real scheduler. Returns the
# path to the sandboxed ccblocks-daemon.sh to run.
create_mock_helper_call_recorder() {
    local calls_file="$1"

    MOCK_LIBEXEC="${TEST_TEMP_DIR}/libexec"
    cp -r "${PROJECT_ROOT}/libexec" "$MOCK_LIBEXEC"

    local helper_dir="${MOCK_LIBEXEC}/lib"
    local helper_name
    if [[ "$(uname)" == "Darwin" ]]; then
        helper_name="launchagent-helper.sh"
    else
        helper_name="systemd-helper.sh"
    fi

    cat > "${helper_dir}/${helper_name}" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${calls_file}"
exit 0
EOF
    chmod +x "${helper_dir}/${helper_name}"

    echo "${MOCK_LIBEXEC}/ccblocks-daemon.sh"
}

@test "ccblocks-daemon does not schedule special retries after usage-limit failures" {
    calls_file="${TEST_TEMP_DIR}/helper-calls.log"
    daemon_script=$(create_mock_helper_call_recorder "$calls_file")

    mock_claude_with_auth "$(claude_auth_json)" '
echo "You'"'"'ve hit your session limit · resets 1:40am (Europe/London)" >&2
exit 1'

    run "$daemon_script"
    assert_failure
    refute [ -f "$calls_file" ]
}

@test "ccblocks-daemon does not call scheduler helper on successful trigger" {
    calls_file="${TEST_TEMP_DIR}/helper-calls.log"
    daemon_script=$(create_mock_helper_call_recorder "$calls_file")

    mock_claude_success

    run "$daemon_script"
    assert_success
    refute [ -f "$calls_file" ]
}

# Regression test: stdout is suppressed unless debug is enabled, but stderr
# should still pass through regardless of success/failure or debug mode.
@test "ccblocks-daemon still surfaces stray stderr output from claude on a successful run in non-debug mode" {
    mock_claude_with_auth "$(claude_auth_json)" '
echo "some non-fatal warning from claude" >&2
echo "Claude mock: Success"
exit 0'

    run "$SCRIPT"
    assert_success
    assert_output --partial "some non-fatal warning from claude"
}

@test "ccblocks-daemon suppresses claude's stdout on a successful run in non-debug mode" {
    mock_claude_with_auth "$(claude_auth_json)" '
echo "this stdout text should not appear"
exit 0'

    run "$SCRIPT"
    assert_success
    refute_output --partial "this stdout text should not appear"
}

@test "ccblocks-daemon shows claude's stdout on a successful run when CCBLOCKS_DEBUG=1" {
    mock_claude_with_auth "$(claude_auth_json)" '
echo "this stdout text should appear in debug mode"
exit 0'

    export CCBLOCKS_DEBUG=1
    run "$SCRIPT"
    assert_success
    assert_output --partial "this stdout text should appear in debug mode"
}
