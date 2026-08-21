#!/usr/bin/env bats

# Tests for error scenarios and edge cases
# Tests error handling across ccblocks components

load test_helper

setup() {
    setup_test_dir
}

teardown() {
    teardown_test_dir
}

# Probe scripts source "$SCRIPT_DIR/../lib/common.sh". Generating them under
# ${TEST_TEMP_DIR}/work/ keeps that ".." inside the per-test sandbox, so the
# symlink below is created and torn down with the sandbox rather than in the
# shared system temp directory.
setup_probe_dir() {
    mkdir -p "${TEST_TEMP_DIR}/work"
    ln -s "${PROJECT_ROOT}/libexec/lib" "${TEST_TEMP_DIR}/lib"
}

# OS detection error tests
@test "common.sh detect_os fails on unsupported OS" {
    setup_probe_dir
    # Create a test script that sources common.sh
    cat > "${TEST_TEMP_DIR}/work/test_os_detect.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mock uname to return unsupported OS
uname() {
    echo "FreeBSD"
}
export -f uname

source "${SCRIPT_DIR}/../lib/common.sh"
detect_os
EOF
    chmod +x "${TEST_TEMP_DIR}/work/test_os_detect.sh"

    run "${TEST_TEMP_DIR}/work/test_os_detect.sh"
    assert_failure
    assert_output --partial "Unsupported OS"
}

# Helper initialization error tests
@test "common.sh init_os_vars fails when OS_TYPE not set" {
    setup_probe_dir
    cat > "${TEST_TEMP_DIR}/work/test_init_no_os.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Don't call detect_os, so OS_TYPE is not set
unset OS_TYPE
init_os_vars "$SCRIPT_DIR"
EOF
    chmod +x "${TEST_TEMP_DIR}/work/test_init_no_os.sh"

    run "${TEST_TEMP_DIR}/work/test_init_no_os.sh"
    assert_failure
    assert_output --partial "OS_TYPE not set"
}

@test "common.sh init_os_vars fails when script_dir parameter missing" {
    setup_probe_dir
    cat > "${TEST_TEMP_DIR}/work/test_init_no_param.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set OS_TYPE but don't pass script_dir parameter
export OS_TYPE="Darwin"
init_os_vars
EOF
    chmod +x "${TEST_TEMP_DIR}/work/test_init_no_param.sh"

    run "${TEST_TEMP_DIR}/work/test_init_no_param.sh"
    assert_failure
    assert_output --partial "script_dir parameter required"
}

# Timeout fallback tests
@test "common.sh run_with_timeout falls back to perl when timeout unavailable" {
    setup_probe_dir
    cat > "${TEST_TEMP_DIR}/work/test_timeout_perl.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Mock timeout/gtimeout as not available
command_exists() {
    case "$1" in
        timeout|gtimeout) return 1 ;;
        perl) return 0 ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}
export -f command_exists

# Test that perl fallback works
run_with_timeout 1 echo "perl fallback works"
EOF
    chmod +x "${TEST_TEMP_DIR}/work/test_timeout_perl.sh"

    run "${TEST_TEMP_DIR}/work/test_timeout_perl.sh"
    assert_success
    assert_output --partial "perl fallback works"
}

@test "common.sh run_with_timeout falls back to python3 when perl unavailable" {
    setup_probe_dir
    cat > "${TEST_TEMP_DIR}/work/test_timeout_python.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Mock timeout/gtimeout/perl as not available
command_exists() {
    case "$1" in
        timeout|gtimeout|perl) return 1 ;;
        python3) return 0 ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}
export -f command_exists

# Test that python3 fallback works
run_with_timeout 1 echo "python3 fallback works"
EOF
    chmod +x "${TEST_TEMP_DIR}/work/test_timeout_python.sh"

    run "${TEST_TEMP_DIR}/work/test_timeout_python.sh"
    assert_success
    assert_output --partial "python3 fallback works"
}

@test "common.sh run_with_timeout runs without timeout when no utility available" {
    setup_probe_dir
    cat > "${TEST_TEMP_DIR}/work/test_timeout_none.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Mock all timeout utilities as unavailable
command_exists() {
    case "$1" in
        timeout|gtimeout|perl|python3) return 1 ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}
export -f command_exists

# Test that command runs without timeout
run_with_timeout 1 echo "no timeout available"
EOF
    chmod +x "${TEST_TEMP_DIR}/work/test_timeout_none.sh"

    run "${TEST_TEMP_DIR}/work/test_timeout_none.sh"
    assert_success
    assert_output --partial "no timeout available"
    assert_output --partial "No timeout utility available"
}

@test "common.sh run_with_timeout perl fallback actually kills a hung command" {
    setup_probe_dir
    cat > "${TEST_TEMP_DIR}/work/test_timeout_perl_enforce.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

command_exists() {
    case "$1" in
        timeout|gtimeout) return 1 ;;
        perl) return 0 ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}
export -f command_exists

start=$(date +%s)
run_with_timeout 1 sleep 5
rc=$?
elapsed=$(( $(date +%s) - start ))

echo "rc=$rc elapsed=$elapsed"
[ "$rc" -ne 0 ] && [ "$elapsed" -lt 4 ]
EOF
    chmod +x "${TEST_TEMP_DIR}/work/test_timeout_perl_enforce.sh"

    run "${TEST_TEMP_DIR}/work/test_timeout_perl_enforce.sh"
    assert_success
}

@test "common.sh run_with_timeout python3 fallback actually kills a hung command" {
    setup_probe_dir
    cat > "${TEST_TEMP_DIR}/work/test_timeout_python_enforce.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

command_exists() {
    case "$1" in
        timeout|gtimeout|perl) return 1 ;;
        python3) return 0 ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}
export -f command_exists

start=$(date +%s)
run_with_timeout 1 sleep 5
rc=$?
elapsed=$(( $(date +%s) - start ))

echo "rc=$rc elapsed=$elapsed"
[ "$rc" -ne 0 ] && [ "$elapsed" -lt 4 ]
EOF
    chmod +x "${TEST_TEMP_DIR}/work/test_timeout_python_enforce.sh"

    run "${TEST_TEMP_DIR}/work/test_timeout_python_enforce.sh"
    assert_success
}

# Empty/missing file scenarios
@test "check-status handles empty .last-activity file" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"

    # Create empty activity file
    touch "$CCBLOCKS_CONFIG/.last-activity"

    # Create mock helper (in a sandboxed libexec copy, see
    # create_mock_helper_for_status)
    create_mock_helper_for_status

    run "${MOCK_LIBEXEC}/bin/status.sh"
    assert_success
    # The section still renders, but with no timestamp to report
    assert_output --partial "Last Activity"
    refute_line --regexp "Last triggered: .+"
}

# Command not found scenarios
@test "ccblocks-daemon provides helpful error when claude not found" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"

    # Override HOME to empty directory and restrict PATH
    export HOME="${TEST_TEMP_DIR}/fake_home"
    mkdir -p "$HOME"

    # Use test mode to simulate Claude not found
    export CCBLOCKS_TEST_NO_CLAUDE=1

    PATH="/usr/bin:/bin" run "${PROJECT_ROOT}/libexec/ccblocks-daemon.sh"
    assert_failure
    assert_output --partial "Claude CLI not found"
    assert_output --partial "Tried:"
}

@test "setup shows help with --help instead of running the installer" {
    run "${PROJECT_ROOT}/libexec/bin/setup.sh" --help </dev/null
    assert_success
    assert_output --partial "Usage: ccblocks setup"
    refute_output --partial "Claude CLI found"
}

# Any test that actually EXECUTES the installer must go through this.
# A pressed-Enter (empty) answer is the documented default-yes, so a real run
# with the developer's HOME and the real launchctl/systemctl on PATH could
# install a live LaunchAgent/timer on the machine running the suite. Sandbox
# HOME, neutralise the scheduler managers, and run a throwaway copy of
# libexec so mocking its helper never touches the repository.
sandbox_setup_script() {
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "$HOME"
    mock_command "launchctl" 'exit 0'
    mock_command "systemctl" 'exit 0'

    MOCK_LIBEXEC="${TEST_TEMP_DIR}/libexec"
    cp -r "${PROJECT_ROOT}/libexec" "$MOCK_LIBEXEC"
    SETUP_SCRIPT="${MOCK_LIBEXEC}/bin/setup.sh"
}

# Replace the sandboxed copy's platform helper with a stub that accepts the
# two commands install_scheduler issues, so a confirmed run can reach the end
# of the installer without touching any real scheduler.
#
# Pass a path as $1 to make the stub append every invocation to that file
# (mirroring mock_claude_call_recorder): the file's very absence is then proof
# the installer never ran, which output assertions alone cannot establish.
create_mock_setup_helper() {
    local helper_dir="${MOCK_LIBEXEC}/lib"
    local calls_file="${1:-}"
    local helper_name

    if [[ "$(uname)" == "Darwin" ]]; then
        helper_name="launchagent-helper.sh"
    else
        helper_name="systemd-helper.sh"
    fi

    cat > "${helper_dir}/${helper_name}" << EOF
#!/usr/bin/env bash
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "\$SCRIPT_DIR/common.sh"

HELPER_CALLS_FILE="${calls_file}"
if [ -n "\$HELPER_CALLS_FILE" ]; then
    printf '%s\n' "\$*" >> "\$HELPER_CALLS_FILE"
fi

case "\$1" in
    create)
        echo "Mock: Created scheduler config"
        exit 0
        ;;
    reload)
        echo "Mock: Reloaded scheduler"
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

@test "setup refuses API credentials before Claude test request" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    calls_file="${TEST_TEMP_DIR}/claude-calls.log"
    mock_claude_call_recorder "$calls_file"

    ANTHROPIC_API_KEY="sk-ant-test" run "$SETUP_SCRIPT" </dev/null
    assert_failure
    assert_output --partial "subscription auth"
    refute [ -f "$calls_file" ]
}

@test "setup continues with a warning when Claude reports the session limit" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    mock_claude_with_auth "$(claude_auth_json)" "
echo \"You've hit your session limit · resets 1:40am (Europe/London)\" >&2
exit 1"

    run bash -c "printf 'n\n' | '${SETUP_SCRIPT}'"
    assert_success
    assert_output --partial "Setup will continue"
    assert_output --partial "Setup cancelled"
}

@test "setup tests Claude with haiku print-mode trigger" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    args_file="${TEST_TEMP_DIR}/claude-args.log"
    export CCBLOCKS_CLAUDE_ARGS_LOG="$args_file"
    export CCBLOCKS_MODEL="sonnet"
    export CCBLOCKS_PROMPT="Write a detailed essay about block scheduling"
    mock_claude_success

    run bash -c "printf 'n\n' | '${SETUP_SCRIPT}'"
    assert_success
    assert_output --partial "Setup cancelled"

    run cat "$args_file"
    assert_line '<-p>'
    assert_line '<--safe-mode>'
    assert_line '<--model>'
    assert_line '<haiku>'
    assert_line '<--max-turns>'
    assert_line '<1>'
    assert_line '<--tools>'
    assert_line '<>'
    assert_line '<--output-format>'
    assert_line '<text>'
    assert_line '<Reply exactly: OK>'
    refute_line '<sonnet>'
    refute_output --partial "detailed essay"

    # Per-line assertions cannot see adjacency: swapping the model for
    # `--model opus --fallback-model haiku` would still satisfy every line
    # above. Collapse the log and pin the flag to its own value.
    run bash -c "tr -d '\n' < '$args_file'"
    assert_output --partial '<--model><haiku>'
}

@test "setup treats a closed stdin as a cancellation, not as consent" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    helper_calls="${TEST_TEMP_DIR}/setup-helper-calls.log"
    create_mock_setup_helper "$helper_calls"
    mock_claude_success

    # An immediate EOF means nobody was there to answer at all - the empty
    # string it leaves behind is the ABSENCE of an answer, not the pressed
    # Enter that the documented default-yes stands for. Consent has to come
    # from a human or from --yes, so this must cancel.
    run bash -c "'${SETUP_SCRIPT}' </dev/null"
    # And it must not report success: "nobody could answer" is an environment
    # condition, not a user decision, so a provisioning script that installed
    # nothing has to be able to see that in the exit status.
    assert_failure
    [ "$status" -eq 2 ]
    assert_output --partial "Setup cancelled (no answer on stdin - use --yes to install non-interactively)"
    refute_output --partial "Installing"
    refute_output --partial "Setup Complete"
    # The installer never even reached the scheduler helper.
    refute [ -f "$helper_calls" ]
}

@test "setup treats a bare newline as the documented default-yes and installs" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    helper_calls="${TEST_TEMP_DIR}/setup-helper-calls.log"
    create_mock_setup_helper "$helper_calls"
    mock_claude_success

    # The other half of the contract the EOF guard has to leave intact: a
    # pressed Enter IS an answer (`read` succeeds, leaving confirm empty) and
    # the prompt is documented [Y/n], so it must install. Collapsing the guard
    # to `[ -z "$confirm" ]` would silently turn Enter into a cancellation.
    run bash -c "printf '\n' | '${SETUP_SCRIPT}'"
    assert_success
    assert_output --partial "Installing"
    assert_output --partial "Setup Complete"
    refute_output --partial "no answer on stdin"
    # Output alone cannot prove the scheduler was really touched; the
    # recorder file existing does.
    assert [ -f "$helper_calls" ]
}

@test "setup installs non-interactively with --yes" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    helper_calls="${TEST_TEMP_DIR}/setup-helper-calls.log"
    create_mock_setup_helper "$helper_calls"
    mock_claude_success

    # --yes is the documented non-interactive path, and the closed-stdin guard
    # above names it in the exit-2 message it prints. So run it exactly the way
    # a provisioning script does - flag set, stdin detached - and require a real
    # install: a broken `-y | --yes)` arm would fall through to the prompt, hit
    # EOF, and tell someone who just passed --yes to use --yes, with rc 2.
    run "$SETUP_SCRIPT" --yes </dev/null
    assert_success
    assert_output --partial "Setup Complete"
    refute_output --partial "no answer on stdin"
    # Output alone cannot prove the scheduler was really touched; the recorder
    # file existing does.
    assert [ -f "$helper_calls" ]
}

@test "setup installs non-interactively with -y" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    helper_calls="${TEST_TEMP_DIR}/setup-helper-calls.log"
    create_mock_setup_helper "$helper_calls"
    mock_claude_success

    # The short form shares one case arm with --yes today, but it is what the
    # README tells scripts to type, so pin it independently.
    run "$SETUP_SCRIPT" -y </dev/null
    assert_success
    assert_output --partial "Setup Complete"
    refute_output --partial "no answer on stdin"
    assert [ -f "$helper_calls" ]
}

@test "setup honours an unterminated 'y' and installs" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    helper_calls="${TEST_TEMP_DIR}/setup-helper-calls.log"
    create_mock_setup_helper "$helper_calls"
    mock_claude_success

    # The mirror image of the unterminated 'n' test below: a TTY user who types
    # "y" and then Ctrl-D leaves `read` non-zero with confirm="y". A guard that
    # ignores the answer it was handed (e.g. `[[ ! "$confirm" =~ ^[Nn] ]]`
    # instead of `[ -z "$confirm" ]`) would cancel that explicit consent, and
    # the 'n' test would never notice.
    run bash -c "printf 'y' | '${SETUP_SCRIPT}'"
    assert_success
    assert_output --partial "Installing"
    assert_output --partial "Setup Complete"
    refute_output --partial "no answer on stdin"
    refute_output --partial "Setup cancelled"
    assert [ -f "$helper_calls" ]
}

@test "setup honours an unterminated 'n' rather than defaulting to yes" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    create_mock_setup_helper
    mock_claude_success

    # `printf 'n'` with no trailing newline: `read` returns non-zero at EOF
    # but has ALREADY assigned "n". Discarding that with `|| confirm=""`
    # would turn this explicit decline into the default-yes and install a
    # scheduler the user just refused; treating it as the no-answer EOF
    # above would cancel for the wrong reason.
    run bash -c "printf 'n' | '${SETUP_SCRIPT}'"
    assert_success
    assert_output --partial "Setup cancelled"
    refute_output --partial "no answer on stdin"
    refute_output --partial "Installing"
    refute_output --partial "Setup Complete"
}

@test "setup keeps its own stdin when the Claude pre-flight reads stdin" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"
    sandbox_setup_script
    helper_calls="${TEST_TEMP_DIR}/setup-helper-calls.log"
    create_mock_setup_helper "$helper_calls"

    # The real `claude` CLI reads stdin. This mock does too (`cat >/dev/null`
    # on every invocation, auth check included), which is exactly what the
    # other claude mocks never do - and why the suite could not catch the
    # live bug where the pre-flight ate the piped answer and the prompt then
    # saw EOF. common.sh redirects both claude calls from /dev/null, so the
    # "n" below must still reach the prompt.
    mock_command "claude" "
cat >/dev/null
if [ \"\$1\" = \"auth\" ] && [ \"\$2\" = \"status\" ]; then
    echo '$(claude_auth_json)'
    exit 0
fi
echo 'Claude mock: Success'
exit 0"

    run bash -c "printf 'n\n' | '${SETUP_SCRIPT}'"
    assert_success
    assert_output --partial "Setup cancelled"
    # A drained stdin would still cancel now, but for the wrong reason: the
    # no-answer EOF message proves the answer was eaten before the prompt.
    refute_output --partial "no answer on stdin"
    refute_output --partial "Installing"
    refute_output --partial "Setup Complete"
    refute [ -f "$helper_calls" ]
}

# Invalid input scenarios
@test "ccblocks shows usage for empty command" {
    run "${PROJECT_ROOT}/ccblocks" ""
    assert_success
    # Empty command should show help
    assert_output --partial "Usage:"
}

@test "schedule-blocks apply is no longer available" {
    run "${PROJECT_ROOT}/libexec/bin/schedule.sh" apply invalid-schedule-name
    assert_failure
    assert_output --partial "'ccblocks schedule apply' is no longer available."
    assert_output --partial "polls every 5 minutes"
}

# Helper function to create mock helper for check-status tests. Copies
# libexec into the sandbox first so mocking the OS helper never touches
# the real repository file (safe regardless of how the test ends).
create_mock_helper_for_status() {
    MOCK_LIBEXEC="${TEST_TEMP_DIR}/libexec"
    cp -r "${PROJECT_ROOT}/libexec" "$MOCK_LIBEXEC"

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
        echo "Mock status output"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "${helper_dir}/${helper_name}"
}

# Logger failure scenarios
@test "ccblocks-daemon continues when logger fails" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"

    # Create a simple mock claude in a new mock bin directory
    local mock_bin="${TEST_TEMP_DIR}/mock_bin"
    write_claude_mock_script "$mock_bin/claude"

    # Mock logger to fail
    cat > "$mock_bin/logger" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$mock_bin/logger"

    # Run with mocked commands in PATH
    PATH="$mock_bin:$PATH" run "${PROJECT_ROOT}/libexec/ccblocks-daemon.sh"
    # Should still succeed even if logger fails
    assert_success
}

# Filesystem edge cases
@test "uninstall handles config directory with special characters in filenames" {
    export CCBLOCKS_CONFIG="${TEST_TEMP_DIR}/.config/ccblocks"
    mkdir -p "$CCBLOCKS_CONFIG"

    # Sandbox HOME and the scheduler managers so uninstall.sh's
    # fallback_cleanup can never touch the developer's real scheduler.
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "$HOME"
    mock_command "launchctl" 'exit 0'
    mock_command "systemctl" 'exit 0'

    # Create files with special characters
    touch "$CCBLOCKS_CONFIG/file with spaces.conf"
    touch "$CCBLOCKS_CONFIG/file-with-dashes.conf"
    touch "$CCBLOCKS_CONFIG/.hidden-file"

    create_mock_helper_for_uninstall

    # Run with force mode to skip prompts. The explicit `</dev/null` keeps the
    # run deterministic: without it bats hands the script the developer's
    # terminal, so a --force regression would hang the suite on a TTY.
    run "${MOCK_LIBEXEC}/bin/uninstall.sh" --force </dev/null

    # Should complete successfully
    assert_success
}

# Copies libexec into the sandbox first so mocking the OS helper never
# touches the real repository file (safe regardless of how the test ends).
create_mock_helper_for_uninstall() {
    MOCK_LIBEXEC="${TEST_TEMP_DIR}/libexec"
    cp -r "${PROJECT_ROOT}/libexec" "$MOCK_LIBEXEC"

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
    remove)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "${helper_dir}/${helper_name}"
}
