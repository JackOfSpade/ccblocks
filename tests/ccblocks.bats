#!/usr/bin/env bats

# Tests for ccblocks main CLI

load test_helper

setup() {
    setup_test_dir

    # Copy the CLI + libexec into the sandbox so mocking bin/*.sh below
    # never touches the real repository files - this is safe regardless
    # of how the test ends (pass, fail, or killed mid-run), unlike
    # mutating the real files in place and restoring them afterwards.
    MOCK_ROOT="${TEST_TEMP_DIR}/repo"
    mkdir -p "$MOCK_ROOT"
    cp "${PROJECT_ROOT}/ccblocks" "$MOCK_ROOT/"
    cp "${PROJECT_ROOT}/VERSION" "$MOCK_ROOT/"
    cp -r "${PROJECT_ROOT}/libexec" "$MOCK_ROOT/"
    SCRIPT="${MOCK_ROOT}/ccblocks"
    BIN_DIR="${MOCK_ROOT}/libexec/bin"
}

teardown() {
    teardown_test_dir
}

# Help and usage tests
@test "ccblocks shows help" {
    run "$SCRIPT" --help
    assert_success
    assert_output --partial "Usage: ccblocks <command>"
    assert_output --partial "Commands:"
}

# Version tests
@test "ccblocks shows version with --version" {
    run "$SCRIPT" --version
    assert_success
    assert_output --partial "ccblocks"
    assert_output --regexp "[0-9]+\.[0-9]+\.[0-9]+"
}

@test "ccblocks shows version with -v" {
    run "$SCRIPT" -v
    assert_success
    assert_output --regexp "[0-9]+\.[0-9]+\.[0-9]+"
}

# Unknown command tests
@test "ccblocks shows error for unknown command" {
    run "$SCRIPT" invalid-command
    assert_failure
    assert_output --partial "Unknown command"
}

@test "ccblocks shows usage after unknown command error" {
    run "$SCRIPT" foobar
    assert_failure
    assert_output --partial "Unknown command: foobar"
    assert_output --partial "Usage:"
}

# Command routing tests - setup
@test "ccblocks routes setup command to setup" {
    # Create a mock setup in bin/ (teardown will restore)
    cat > "${BIN_DIR}/setup.sh" << 'EOF'
#!/bin/bash
echo "setup was called with: $@"
exit 0
EOF
    chmod +x "${BIN_DIR}/setup.sh"

    run "$SCRIPT" setup --test-arg
    assert_success
    assert_output --partial "setup was called"
}

# Command routing tests - status
@test "ccblocks routes status command to check-status" {
    # Create a mock status in bin/ (teardown will restore)
    cat > "${BIN_DIR}/status.sh" << 'EOF'
#!/bin/bash
echo "check-status was called"
exit 0
EOF
    chmod +x "${BIN_DIR}/status.sh"

    run "$SCRIPT" status
    assert_success
    assert_output --partial "check-status was called"
}

# Command routing tests - schedule
@test "ccblocks routes schedule command to schedule-blocks" {
    # Create a mock schedule in bin/ (teardown will restore)
    cat > "${BIN_DIR}/schedule.sh" << 'EOF'
#!/bin/bash
echo "schedule-blocks was called with: $@"
exit 0
EOF
    chmod +x "${BIN_DIR}/schedule.sh"

    run "$SCRIPT" schedule list
    assert_success
    assert_output --partial "schedule-blocks was called"
}

# Command tests - pause
@test "ccblocks pause routes to schedule-blocks pause" {
    # Create a mock schedule in bin/ (teardown will restore)
    cat > "${BIN_DIR}/schedule.sh" << 'EOF'
#!/bin/bash
echo "Received: $1"
exit 0
EOF
    chmod +x "${BIN_DIR}/schedule.sh"

    run "$SCRIPT" pause
    assert_success
    assert_output "Received: pause"
}

# Command alias tests - resume/unpause
@test "ccblocks resume routes to schedule-blocks resume" {
    # Create a mock schedule in bin/ (teardown will restore)
    cat > "${BIN_DIR}/schedule.sh" << 'EOF'
#!/bin/bash
echo "Received: $1"
exit 0
EOF
    chmod +x "${BIN_DIR}/schedule.sh"

    run "$SCRIPT" resume
    assert_success
    assert_output "Received: resume"
}

@test "ccblocks unpause routes to schedule-blocks resume" {
    # Create a mock schedule in bin/ (teardown will restore)
    cat > "${BIN_DIR}/schedule.sh" << 'EOF'
#!/bin/bash
echo "Received: $1"
exit 0
EOF
    chmod +x "${BIN_DIR}/schedule.sh"

    run "$SCRIPT" unpause
    assert_success
    assert_output "Received: resume"
}

# Command routing tests - trigger
@test "ccblocks routes trigger command to trigger.sh" {
    # Create a mock trigger in bin/ (sandboxed copy, see setup())
    cat > "${BIN_DIR}/trigger.sh" << 'EOF'
#!/bin/bash
echo "trigger was called with: $@"
exit 0
EOF
    chmod +x "${BIN_DIR}/trigger.sh"

    run "$SCRIPT" trigger --test-arg
    assert_success
    assert_output --partial "trigger was called"
}

# Command routing tests - uninstall
@test "ccblocks routes uninstall command to uninstall" {
    # Create a mock uninstall in bin/ (teardown will restore)
    cat > "${BIN_DIR}/uninstall.sh" << 'EOF'
#!/bin/bash
echo "uninstall was called"
exit 0
EOF
    chmod +x "${BIN_DIR}/uninstall.sh"

    run "$SCRIPT" uninstall
    assert_success
    assert_output --partial "uninstall was called"
}

# Help content validation
@test "ccblocks help shows all main commands" {
    run "$SCRIPT" help
    assert_success
    assert_output --partial "setup"
    assert_output --partial "status"
    assert_output --partial "schedule"
    assert_output --partial "pause"
    assert_output --partial "resume"
    assert_output --partial "uninstall"
}

@test "ccblocks help shows examples" {
    run "$SCRIPT" help
    assert_success
    assert_output --partial "Examples:"
}

@test "ccblocks help shows schedule actions" {
    run "$SCRIPT" help
    assert_success
    assert_output --partial "Schedule actions:"
}
