#!/usr/bin/env bats

# Tests for Homebrew installation structure
# Verifies that the daemon can find its dependencies when installed via Homebrew

load test_helper

setup() {
    setup_test_dir

    # Create a mock Homebrew prefix structure
    BREW_PREFIX="${TEST_TEMP_DIR}/homebrew/opt/ccblocks"
    mkdir -p "${BREW_PREFIX}/libexec"

    export BREW_PREFIX
}

teardown() {
    teardown_test_dir
}

# Simulate Homebrew installation structure
simulate_homebrew_install() {
    cp -R "${PROJECT_RUNTIME_DIR}/." "${BREW_PREFIX}/libexec/"
}

@test "homebrew-structure: daemon can source common.sh from ../lib" {
    simulate_homebrew_install

    # Verify lib is installed within libexec
    assert [ -f "${BREW_PREFIX}/libexec/lib/common.sh" ]

    # Verify daemon is in libexec
    assert [ -f "${BREW_PREFIX}/libexec/ccblocks-daemon.sh" ]

    # Test that daemon can find lib/common.sh relative to its location
    cd "${BREW_PREFIX}/libexec"
    run bash -c 'SCRIPT_DIR="$(pwd)"; source "$SCRIPT_DIR/lib/common.sh" && echo "success"'
    assert_success
    assert_output --partial "success"
}

@test "homebrew-structure: lib directory exists at correct location" {
    simulate_homebrew_install

    # lib should reside inside libexec
    assert [ -d "${BREW_PREFIX}/libexec/lib" ]
}

@test "homebrew-structure: all required lib files are accessible" {
    simulate_homebrew_install

    # Check all lib files exist relative to daemon
    local daemon_dir="${BREW_PREFIX}/libexec"
    assert [ -f "${daemon_dir}/lib/common.sh" ]
    assert [ -f "${daemon_dir}/lib/launchagent-helper.sh" ]
    assert [ -f "${daemon_dir}/lib/systemd-helper.sh" ]
}

@test "homebrew-structure: daemon script path resolution works" {
    simulate_homebrew_install

    # Simulate what daemon does: get SCRIPT_DIR and source common.sh
    cd "${BREW_PREFIX}/libexec"
    run bash -c '
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
            echo "found"
        else
            echo "not found: $SCRIPT_DIR/lib/common.sh"
            exit 1
        fi
    '
    assert_success
    assert_output "found"
}

@test "homebrew-structure: daemon can actually execute with mocked claude" {
    simulate_homebrew_install

    # Mock claude CLI
    mock_claude_success

    # Override config directory
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"

    # Run daemon from its installed location
    run "${BREW_PREFIX}/libexec/ccblocks-daemon.sh"
    assert_success

    # Verify it created activity file
    assert [ -f "$CCBLOCKS_CONFIG/.last-activity" ]
}

@test "homebrew-structure: LaunchAgent helper rewrites a Cellar path to the opt symlink" {
    # Build a real Homebrew Cellar layout: a versioned install directory
    # plus the version-independent opt/ symlink brew maintains across
    # upgrades. This is the one Homebrew-specific code path
    # (launchagent-helper.sh's BREW_PREFIX/RELATIVE_PATH rewrite) that
    # simulate_homebrew_install's flat layout never actually triggers.
    local cellar_dir="${TEST_TEMP_DIR}/homebrew/Cellar/ccblocks/9.9.9"
    mkdir -p "${cellar_dir}/libexec/lib"
    cp "${PROJECT_ROOT}/libexec/lib/common.sh" "${cellar_dir}/libexec/lib/"
    cp "${PROJECT_ROOT}/libexec/lib/launchagent-helper.sh" "${cellar_dir}/libexec/lib/"
    cp "${PROJECT_ROOT}/libexec/ccblocks-daemon.sh" "${cellar_dir}/libexec/"

    mkdir -p "${TEST_TEMP_DIR}/homebrew/opt"
    ln -s "$cellar_dir" "${TEST_TEMP_DIR}/homebrew/opt/ccblocks"

    # Sandbox HOME so the plist this writes never touches the real user
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "$HOME/Library/LaunchAgents"

    run bash "${cellar_dir}/libexec/lib/launchagent-helper.sh" create 247
    assert_success

    run cat "$HOME/Library/LaunchAgents/ccblocks.plist"
    assert_success
    # Must point at the version-independent opt/ symlink, never the
    # versioned Cellar path (which brew deletes on the next upgrade).
    assert_output --partial "${TEST_TEMP_DIR}/homebrew/opt/ccblocks/libexec/ccblocks-daemon.sh"
    refute_output --partial "/Cellar/ccblocks/9.9.9/"
}

@test "homebrew-structure: incorrect structure fails correctly" {
    # Create fresh test environment without calling simulate_homebrew_install
    # Deliberately install lib in wrong location (inside libexec)
    rm -rf "${BREW_PREFIX}/libexec/lib"  # Remove if exists from previous tests
    cp -r "${PROJECT_ROOT}/libexec/lib" "${BREW_PREFIX}/"
    cp "${PROJECT_ROOT}/libexec/ccblocks-daemon.sh" "${BREW_PREFIX}/libexec/"

    # lib should NOT be inside libexec in this test
    assert [ -d "${BREW_PREFIX}/lib" ]
    assert [ ! -d "${BREW_PREFIX}/libexec/lib" ]

    # daemon should fail to find lib/common.sh
    cd "${BREW_PREFIX}/libexec"
    run bash -c 'SCRIPT_DIR="$(pwd)"; source "$SCRIPT_DIR/lib/common.sh" 2>&1'
    assert_failure
    assert_output --partial "No such file or directory"
}
