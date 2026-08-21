#!/usr/bin/env bats

# Tests for uninstall
# Tests for safe removal of LaunchAgent/systemd and ccblocks components

load test_helper

setup() {
    setup_test_dir

    # Sandbox HOME so uninstall.sh's CONFIG_PATH and fallback_cleanup can
    # never see or delete the developer's real LaunchAgent plist / systemd
    # units. Also neutralise the real scheduler managers: fallback_cleanup
    # shells out to launchctl/systemctl, and tests must never touch the
    # live user session.
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "$HOME"
    mock_command "launchctl" 'exit 0'
    mock_command "systemctl" 'exit 0'

    # Copy libexec into the sandbox so mocking the OS helper below never
    # touches the real repository file - this is safe regardless of how
    # the test ends (pass, fail, or killed mid-run), unlike mutating the
    # real file in place and restoring it afterwards.
    MOCK_LIBEXEC="${TEST_TEMP_DIR}/libexec"
    cp -r "${PROJECT_ROOT}/libexec" "$MOCK_LIBEXEC"
    SCRIPT="${MOCK_LIBEXEC}/bin/uninstall.sh"

    # Override config directory to test directory
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"

    # Every mock-helper invocation is appended here, so a test can prove the
    # scheduler was never asked to remove anything by the file's absence.
    HELPER_CALLS="${TEST_TEMP_DIR}/helper-calls.log"

    # Create mock helper script (inside the sandboxed copy only)
    create_mock_helper
}

teardown() {
    teardown_test_dir
}

# Helper function to create mock helper script (inside the sandboxed copy)
create_mock_helper() {
    local helper_dir="${MOCK_LIBEXEC}/lib"
    local helper_name

    # Determine which helper based on OS
    if [[ "$(uname)" == "Darwin" ]]; then
        helper_name="launchagent-helper.sh"
    else
        helper_name="systemd-helper.sh"
    fi

    # Create mock helper
    cat > "${helper_dir}/${helper_name}" << EOF
#!/usr/bin/env bash
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "\$SCRIPT_DIR/common.sh"

printf '%s\n' "\$*" >> "${HELPER_CALLS}"

case "\$1" in
    remove)
        echo "Mock: Removing scheduler"
        exit 0
        ;;
    status)
        echo "Mock: Showing status"
        exit 0
        ;;
    *)
        echo "Mock helper: Unknown command \$1" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${helper_dir}/${helper_name}"
}

# Help and usage tests
@test "uninstall shows usage" {
    run "$SCRIPT" --help </dev/null
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "Options:"
    assert_output --partial "--force"
}

@test "uninstall shows error for unknown option" {
    run "$SCRIPT" --invalid-option </dev/null
    assert_failure
    assert_output --partial "Unknown option"
}

# Interactive mode tests
@test "uninstall prompts for confirmation in interactive mode" {
    # Simulate user saying "N" (cancel)
    run bash -c "echo 'N' | \"$SCRIPT\""
    assert_success
    # Check for warning message (appears before prompt) and cancellation
    assert_output --partial "This will remove"
    assert_output --partial "cancelled"
}

@test "uninstall proceeds when user confirms" {
    # Simulate user saying "y" then "N" for config removal
    run bash -c "echo -e 'y\nN' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Uninstallation Complete"
}

@test "uninstall cancels when user declines" {
    # Simulate user saying "n"
    run bash -c "echo 'n' | \"$SCRIPT\""
    assert_success
    assert_output --partial "cancelled"
    refute_output --partial "Complete"
}

@test "uninstall treats a closed stdin as a cancellation, not as consent" {
    # An immediate EOF is the absence of an answer, not a pressed Enter, so
    # it must never be read as consent to tear down the user's scheduler.
    run bash -c "\"$SCRIPT\" </dev/null"
    # Exit 2, not 0: a CI step or provisioning script that uninstalled
    # nothing must not be told the uninstall succeeded.
    assert_failure
    [ "$status" -eq 2 ]
    assert_output --partial "Uninstallation cancelled (no answer on stdin - use --force to uninstall non-interactively)"
    refute_output --partial "Complete"

    # Nothing was removed: the helper was never invoked at all.
    refute [ -f "$HELPER_CALLS" ]
}

@test "uninstall treats a bare newline at the main prompt as the default-yes" {
    # A pressed Enter is an answer, not the absence of one: `read` succeeds
    # and leaves confirm empty, and [Y/n] documents that as yes. A guard that
    # cancelled on any empty answer would break this without breaking the
    # closed-stdin test above.
    run bash -c "printf '\n' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Uninstallation Complete"
    refute_output --partial "no answer on stdin"
}

@test "uninstall removes the config directory on Enter at both prompts" {
    echo "test" > "$CCBLOCKS_CONFIG/config.json"

    # Enter at the uninstall prompt and Enter again at the config prompt: both
    # default to yes, so the configuration directory is removed.
    run bash -c "printf '\n\n' | \"$SCRIPT\""
    assert_success
    refute_output --partial "no answer on stdin"

    assert [ ! -d "$CCBLOCKS_CONFIG" ]
}

@test "uninstall honours an unterminated 'n' at the main prompt" {
    # `printf 'n'` with no trailing newline: `read` returns non-zero at EOF
    # having ALREADY assigned "n". A defensive `|| { confirm=""; answered=false; }`
    # would discard that answer and cancel for the wrong reason - which is
    # also what a TTY user typing "y" then Ctrl-D would hit.
    run bash -c "printf 'n' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Uninstallation cancelled"
    refute_output --partial "no answer on stdin"
    refute_output --partial "Complete"

    refute [ -f "$HELPER_CALLS" ]
}

@test "uninstall honours an unterminated 'y' at the main prompt" {
    # The other half of the unterminated-answer contract: a TTY user who types
    # "y" and then Ctrl-D leaves `read` non-zero with confirm="y". Widening the
    # EOF guard to anything that ignores the assigned answer (e.g.
    # `[[ ! "$confirm" =~ ^[Nn] ]]` instead of `[ -z "$confirm" ]`) would turn
    # that explicit consent into a cancellation - invisible to the unterminated
    # "n" test above, which such a guard still passes.
    #
    # The sandboxed config directory is empty, so the config prompt is skipped
    # and this single answer carries the whole run.
    run bash -c "printf 'y' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Uninstallation Complete"
    refute_output --partial "no answer on stdin"
    refute_output --partial "Uninstallation cancelled"
}

@test "uninstall honours an unterminated 'n' at the config prompt" {
    echo "test" > "$CCBLOCKS_CONFIG/config.json"

    # "y" proceeds, then an unterminated "n" declines config removal. Losing
    # that partial answer would delete the configuration the user just
    # refused to delete.
    run bash -c "printf 'y\nn' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Uninstallation Complete"
    assert_output --partial "Configuration preserved"
    refute_output --partial "no answer on stdin"

    assert [ -f "$CCBLOCKS_CONFIG/config.json" ]
}

@test "uninstall prompts before removing a config directory holding only symlinks" {
    # Counting with `-type f` made this directory look empty, so the
    # "empty directory, just remove it" short-circuit rm -rf'd a directory
    # full of the user's symlinked configuration with no prompt at all.
    ln -s "${TEST_TEMP_DIR}/elsewhere.json" "$CCBLOCKS_CONFIG/linked.json"

    run bash -c "echo -e 'y\nN' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Configuration Directory"
    assert_output --partial "linked.json"
    assert_output --partial "Configuration preserved"
    refute_output --partial "Removing empty config directory"

    assert [ -d "$CCBLOCKS_CONFIG" ]
    assert [ -L "$CCBLOCKS_CONFIG/linked.json" ]
}

@test "uninstall prompts before removing a config directory holding only subdirectories" {
    # Same class as the symlink case above: counting entries with `! -type d`
    # excluded directories, so a config tree whose contents are nested one
    # level down still looked empty and was rm -rf'd without a prompt.
    mkdir -p "$CCBLOCKS_CONFIG/state"

    run bash -c "echo -e 'y\nN' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Configuration Directory"
    assert_output --partial "Configuration preserved"
    refute_output --partial "Removing empty config directory"

    assert [ -d "$CCBLOCKS_CONFIG/state" ]
}

@test "uninstall preserves the config directory when stdin closes at the config prompt" {
    echo "test" > "$CCBLOCKS_CONFIG/config.json"

    # The single "y" answers the uninstallation prompt; the config prompt
    # that follows then hits EOF. Deleting a user's configuration is the
    # destructive outcome, so no-answer must resolve to preserving it.
    run bash -c "printf 'y\n' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Configuration preserved"
    assert_output --partial "no answer on stdin"

    # Preserving the config is a non-fatal outcome, so the uninstall must still
    # FINISH: `return 0` from that branch, not `exit 0`. An `exit 0` here would
    # leave the exit status and the two assertions above untouched while
    # silently skipping the completion summary and the uninstall log.
    assert_output --partial "Uninstallation Complete"
    assert_output --partial "uninstall log"

    assert [ -f "$CCBLOCKS_CONFIG/config.json" ]
}

# Force mode tests
#
# Every invocation below gets an explicit `</dev/null`. Without one, bats hands
# the script the developer's terminal, so a --force regression that fell through
# to `read` would HANG `make test` on a TTY instead of failing - and would pass
# silently in CI, where stdin is already closed.
@test "uninstall --force skips confirmation prompts" {
    run "$SCRIPT" --force </dev/null
    assert_success
    # Assert on the warning that PRECEDES the prompt, not on the prompt string
    # itself: bash only writes a `read -p` prompt when stdin is a TTY, so
    # refuting "Proceed with uninstallation?" under bats can never fail and
    # proves nothing. This line is a plain print_warning that is always on the
    # captured output when the confirmation block runs.
    refute_output --partial "This will remove the ccblocks"
    assert_output --partial "Complete"
}

@test "uninstall --force removes config automatically" {
    # Create config files
    echo "test" > "$CCBLOCKS_CONFIG/test.conf"

    run "$SCRIPT" --force </dev/null
    assert_success

    # Config should be removed in force mode
    assert [ ! -d "$CCBLOCKS_CONFIG" ]
}

# Config removal tests
@test "uninstall shows config directory contents before removal" {
    # Create test config files
    echo "test" > "$CCBLOCKS_CONFIG/config.json"
    echo "test2" > "$CCBLOCKS_CONFIG/data.txt"

    # Run with "y" to proceed, then "y" to remove config
    run bash -c "echo -e 'y\ny' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Configuration Directory"
    assert_output --partial "2 files"
}

@test "uninstall preserves config when user declines removal" {
    # Create test config file
    echo "test" > "$CCBLOCKS_CONFIG/config.json"

    # Run with "y" to proceed, then "N" to preserve config
    run bash -c "echo -e 'y\nN' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Configuration preserved"

    # Verify config still exists
    assert [ -f "$CCBLOCKS_CONFIG/config.json" ]
}

@test "uninstall removes config when user confirms removal" {
    # Create test config file
    echo "test" > "$CCBLOCKS_CONFIG/config.json"

    # Run with "y" to proceed, then "y" to remove config
    run bash -c "echo -e 'y\ny' | \"$SCRIPT\""
    assert_success

    # Verify config was removed
    assert [ ! -d "$CCBLOCKS_CONFIG" ]
}

@test "uninstall auto-removes empty config directory" {
    # Config directory exists but is empty (from setup)
    assert [ -d "$CCBLOCKS_CONFIG" ]

    # Should not prompt for empty directory
    run bash -c "echo 'y' | \"$SCRIPT\""
    assert_success

    # Empty directory should be removed without prompting
    assert [ ! -d "$CCBLOCKS_CONFIG" ]
}

# Scheduler removal tests
@test "uninstall calls helper remove command" {
    # Create platform-specific config file so the helper remove command gets
    # called (HOME is sandboxed in setup, so this never touches the real one)
    if [[ "$(uname)" == "Darwin" ]]; then
        mkdir -p "$HOME/Library/LaunchAgents"
        touch "$HOME/Library/LaunchAgents/ccblocks.plist"
    else
        mkdir -p "$HOME/.config/systemd/user"
        touch "$HOME/.config/systemd/user/ccblocks@.service"
    fi

    run bash -c "echo 'y' | \"$SCRIPT\""
    assert_success
    # Check that scheduler removal was successful (helper was called)
    assert_output --partial "successfully removed"
}

@test "uninstall handles missing scheduler gracefully" {
    # The helper is called even when no scheduler file exists, so runtime
    # state (a bootstrapped agent, an enabled timer) still gets cleaned up
    run bash -c "echo 'y' | \"$SCRIPT\""
    assert_success
    assert_output --partial "No "
    assert_output --partial "found"
}

# Log creation tests
@test "uninstall creates uninstall log file" {
    run bash -c "echo 'y' | \"$SCRIPT\""
    assert_success

    # Check that log file reference appears in output
    assert_output --partial "uninstall log"
}

# Completion tests
@test "uninstall shows completion summary" {
    run bash -c "echo 'y' | \"$SCRIPT\""
    assert_success
    assert_output --partial "Uninstallation Complete"
    assert_output --partial "Summary:"
}

@test "uninstall shows verification commands in summary" {
    run bash -c "echo 'y' | \"$SCRIPT\""
    assert_success
    assert_output --partial "To verify removal:"
}

@test "uninstall shows platform-specific commands" {
    run bash -c "echo 'y' | \"$SCRIPT\""
    assert_success

    if [[ "$(uname)" == "Darwin" ]]; then
        assert_output --partial "launchctl"
        assert_output --partial "Library/LaunchAgents"
    else
        assert_output --partial "systemctl"
        assert_output --partial "systemd/user"
    fi
}

# File size display tests
@test "uninstall shows human-readable file sizes" {
    # Create files of different sizes
    dd if=/dev/zero of="$CCBLOCKS_CONFIG/small.txt" bs=100 count=1 2>/dev/null
    dd if=/dev/zero of="$CCBLOCKS_CONFIG/medium.txt" bs=1024 count=5 2>/dev/null

    run bash -c "echo -e 'y\ny' | \"$SCRIPT\""
    assert_success

    # Should show file sizes (KB or B)
    assert_output --partial "small.txt"
    assert_output --partial "medium.txt"
}
