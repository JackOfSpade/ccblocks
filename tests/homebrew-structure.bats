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

@test "homebrew-structure: daemon installed without lib/ fails loudly" {
    # A packaging mistake that ships the daemon but not its lib directory
    # must fail at startup, not run half-initialised.
    local broken_libexec="${TEST_TEMP_DIR}/broken/libexec"
    mkdir -p "$broken_libexec"
    cp "${PROJECT_ROOT}/libexec/ccblocks-daemon.sh" "$broken_libexec/"

    run "${broken_libexec}/ccblocks-daemon.sh"
    assert_failure
    assert_output --partial "common.sh"
}

@test "homebrew-structure: daemon can actually execute with mocked claude" {
    simulate_homebrew_install

    # Mock claude CLI. ccusage must be mocked too: the daemon's
    # verify_block_active gate skips the .last-activity write whenever
    # ccusage reports no active block, so without this the assertion below
    # would depend on the developer's live Claude usage state.
    mock_claude_success
    mock_ccusage_active_block

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

    run bash "${cellar_dir}/libexec/lib/launchagent-helper.sh" create
    assert_success

    run cat "$HOME/Library/LaunchAgents/ccblocks.plist"
    assert_success
    # Must point at the version-independent opt/ symlink, never the
    # versioned Cellar path (which brew deletes on the next upgrade).
    assert_output --partial "${TEST_TEMP_DIR}/homebrew/opt/ccblocks/libexec/ccblocks-daemon.sh"
    refute_output --partial "/Cellar/ccblocks/9.9.9/"
}

@test "homebrew-structure: systemd helper writes an enableable timer unit" {
    simulate_homebrew_install

    # Sandbox HOME so the units this writes never touch the real user.
    # Only files are written, so this runs on macOS too.
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "$HOME"

    run bash "${BREW_PREFIX}/libexec/lib/systemd-helper.sh" create
    assert_success

    run cat "$HOME/.config/systemd/user/ccblocks@.timer"
    assert_success
    # Without [Install]/WantedBy the unit is 'static': `systemctl --user
    # enable` creates no wants symlink and the timer dies at logout.
    assert_output --partial "[Install]"
    assert_output --partial "WantedBy=timers.target"
}

@test "homebrew-structure: systemd service unit quotes PATH and uses the opt path" {
    # Same Cellar layout as the LaunchAgent test above: the versioned
    # install directory plus the opt/ symlink brew keeps across upgrades.
    local cellar_dir="${TEST_TEMP_DIR}/homebrew/Cellar/ccblocks/9.9.9"
    mkdir -p "${cellar_dir}/libexec/lib"
    cp "${PROJECT_ROOT}/libexec/lib/common.sh" "${cellar_dir}/libexec/lib/"
    cp "${PROJECT_ROOT}/libexec/lib/systemd-helper.sh" "${cellar_dir}/libexec/lib/"
    cp "${PROJECT_ROOT}/libexec/ccblocks-daemon.sh" "${cellar_dir}/libexec/"

    mkdir -p "${TEST_TEMP_DIR}/homebrew/opt"
    ln -s "$cellar_dir" "${TEST_TEMP_DIR}/homebrew/opt/ccblocks"

    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "$HOME"

    run bash "${cellar_dir}/libexec/lib/systemd-helper.sh" create
    assert_success

    run cat "$HOME/.config/systemd/user/ccblocks@.service"
    assert_success
    # An unquoted assignment splits on the first space in PATH
    assert_output --partial 'Environment="PATH='
    # ExecStart must survive a brew upgrade deleting the versioned keg, and
    # be quoted: systemd word-splits an unquoted value, so an install path
    # containing a space would otherwise truncate at the first space.
    assert_output --partial "ExecStart=\"${TEST_TEMP_DIR}/homebrew/opt/ccblocks/libexec/ccblocks-daemon.sh\""
    refute_output --partial "/Cellar/ccblocks/9.9.9/"
}

@test "homebrew-structure: LaunchAgent status warns when the installed interval is stale" {
    simulate_homebrew_install

    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "$HOME/Library/LaunchAgents"
    export CCBLOCKS_INTERVAL_SECONDS=300

    run bash "${BREW_PREFIX}/libexec/lib/launchagent-helper.sh" create
    assert_success

    # Simulate a plist written by a version with a different interval:
    # an upgrade does not rewrite an already-installed plist.
    sed -i.bak 's|<integer>[0-9][0-9]*</integer>|<integer>900</integer>|' \
        "$HOME/Library/LaunchAgents/ccblocks.plist"

    # Report the agent as loaded so status reaches the Schedule section
    mock_command "launchctl" 'exit 0'

    run bash "${BREW_PREFIX}/libexec/lib/launchagent-helper.sh" status
    assert_success
    assert_output --partial "Every 15 minutes"
    assert_output --partial "differs from this version's default"
}
