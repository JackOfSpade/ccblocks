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
    else
        [ "$HELPER" = "$PROJECT_RUNTIME_DIR/lib/systemd-helper.sh" ]
        [ "$CONFIG_PATH" = "$HOME/.config/systemd/user/ccblocks@.service" ]
        [ "$TIMER_PATH" = "$HOME/.config/systemd/user/ccblocks@.timer" ]
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

@test "require_subscription_auth rejects truthy provider flag variants" {
    for flag_value in 1 true TRUE True; do
        export CLAUDE_CODE_USE_BEDROCK="$flag_value"
        mock_claude_success

        run require_subscription_auth claude
        assert_failure
        assert_output --partial "CLAUDE_CODE_USE_BEDROCK"
    done
}

@test "require_subscription_auth fails when claude auth status errors" {
    mock_command "claude" '
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 1
fi
exit 0'

    run require_subscription_auth claude
    assert_failure
    assert_output --partial "claude auth login"
}

@test "require_subscription_auth accepts subscription auth-method aliases" {
    for auth_method in subscription claudeai claudeAi claude.ai oauth_subscription; do
        mock_claude_auth_method "$auth_method"

        run require_subscription_auth claude
        assert_success
    done
}
