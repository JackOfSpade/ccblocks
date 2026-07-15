#!/usr/bin/env bats

# Tests for schedule.sh fixed-interval schedule management

load test_helper

setup() {
    setup_test_dir

    MOCK_LIBEXEC="${TEST_TEMP_DIR}/libexec"
    cp -r "${PROJECT_ROOT}/libexec" "$MOCK_LIBEXEC"
    SCRIPT="${MOCK_LIBEXEC}/bin/schedule.sh"

    create_mock_helper

    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
}

teardown() {
    teardown_test_dir
}

create_mock_helper() {
    local helper_dir="${MOCK_LIBEXEC}/lib"
    local helper_name

    if [[ "$(uname)" == "Darwin" ]]; then
        helper_name="launchagent-helper.sh"
    else
        helper_name="systemd-helper.sh"
    fi

    cat > "${helper_dir}/${helper_name}" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

case "$1" in
    status)
        echo "Mock: fixed 5-minute scheduler active"
        exit 0
        ;;
    load)
        echo "Mock: loaded scheduler"
        exit 0
        ;;
    unload)
        echo "Mock: unloaded scheduler"
        exit 0
        ;;
    remove)
        echo "Mock: removed scheduler"
        exit 0
        ;;
    *)
        echo "Mock helper: Unknown command $1" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${helper_dir}/${helper_name}"
}

@test "schedule-blocks shows help" {
    run "$SCRIPT" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "Commands:"
    assert_output --partial "pause"
    assert_output --partial "resume"
    assert_output --partial "remove"
}

@test "schedule-blocks shows current status" {
    run "$SCRIPT" current
    assert_success
    assert_output --partial "Mock: fixed 5-minute scheduler active"
}

@test "schedule-blocks pause unloads scheduler" {
    run "$SCRIPT" pause
    assert_success
    assert_output --partial "Mock: unloaded scheduler"
    assert_output --partial "Paused ccblocks scheduling"
}

@test "schedule-blocks resume loads scheduler" {
    run "$SCRIPT" resume
    assert_success
    assert_output --partial "Mock: loaded scheduler"
    assert_output --partial "Resumed ccblocks scheduling"
}

@test "schedule-blocks remove removes scheduler" {
    run "$SCRIPT" remove
    assert_success
    assert_output --partial "Mock: removed scheduler"
    assert_output --partial "Removed all ccblocks schedules"
}

@test "schedule-blocks rejects removed list command" {
    run "$SCRIPT" list
    assert_failure
    assert_output --partial "'ccblocks schedule list' is no longer available."
    assert_output --partial "polls every 5 minutes"
}

@test "schedule-blocks rejects removed apply command" {
    run "$SCRIPT" apply 247
    assert_failure
    assert_output --partial "'ccblocks schedule apply' is no longer available."
    assert_output --partial "there is no schedule to configure"
}

@test "schedule-blocks shows error for unknown command" {
    run "$SCRIPT" invalid-command
    assert_failure
    assert_output --partial "Unknown command"
}
