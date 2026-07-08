#!/usr/bin/env bats

# Tests for lib/common.sh shared helpers

load test_helper

setup() {
    setup_test_dir
    export SCRIPT_DIR="$PROJECT_ROOT"
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"

    source "$PROJECT_LIB_DIR/common.sh"
}

teardown() {
    teardown_test_dir
}

@test "detect_os sets scheduler name on supported platforms" {
    detect_os

    if [[ "$(uname)" == "Darwin" ]]; then
        [ "$OS_TYPE" = "Darwin" ]
        [ "$SCHEDULER_NAME" = "LaunchAgent" ]
    else
        [ "$OS_TYPE" = "Linux" ]
        [ "$SCHEDULER_NAME" = "systemd user service" ]
    fi
}

@test "init_os_vars exports helper and config paths for the current OS" {
    detect_os

    init_os_vars "$PROJECT_RUNTIME_DIR"

    if [[ "$(uname)" == "Darwin" ]]; then
        [ "$HELPER" = "$PROJECT_RUNTIME_DIR/lib/launchagent-helper.sh" ]
        [ "$CONFIG_PATH" = "$HOME/Library/LaunchAgents/ccblocks.plist" ]
        [ "$LOAD_CMD" = "load" ]
        [ "$UNLOAD_CMD" = "unload" ]
    else
        [ "$HELPER" = "$PROJECT_RUNTIME_DIR/lib/systemd-helper.sh" ]
        [ "$CONFIG_PATH" = "$HOME/.config/systemd/user/ccblocks@.service" ]
        [ "$TIMER_PATH" = "$HOME/.config/systemd/user/ccblocks@.timer" ]
        [ "$LOAD_CMD" = "enable" ]
        [ "$UNLOAD_CMD" = "disable" ]
    fi
}

@test "get_helper_script returns the platform helper" {
    detect_os

    run get_helper_script "$PROJECT_RUNTIME_DIR"
    assert_success

    if [[ "$(uname)" == "Darwin" ]]; then
        assert_output "$PROJECT_RUNTIME_DIR/lib/launchagent-helper.sh"
    else
        assert_output "$PROJECT_RUNTIME_DIR/lib/systemd-helper.sh"
    fi
}

@test "json helpers extract string and boolean values" {
    local json='{"loggedIn":true,"authMethod":"subscription","apiProvider":"firstParty"}'

    run json_bool_value "$json" "loggedIn"
    assert_success
    assert_output "true"

    run json_string_value "$json" "authMethod"
    assert_success
    assert_output "subscription"
}

@test "require_subscription_auth rejects API key credentials" {
    export ANTHROPIC_API_KEY="test-key"

    run require_subscription_auth claude
    assert_failure
    assert_output --partial "Refusing to trigger: ANTHROPIC_API_KEY is set"
}

@test "require_subscription_auth allows falsy provider flags" {
    export CLAUDE_CODE_USE_BEDROCK=0
    mock_claude_success

    run require_subscription_auth claude
    assert_success
}
