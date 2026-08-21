#!/usr/bin/env bats

# Meta-tests for the test harness itself.

load test_helper

setup() {
    setup_test_dir
}

teardown() {
    teardown_test_dir
}

@test "teardown_test_dir leaves a pre-existing user config directory alone" {
    fake_home="${TEST_TEMP_DIR}/fake-home"
    mkdir -p "${fake_home}/.config/ccblocks"
    echo "user data" > "${fake_home}/.config/ccblocks/config.json"

    inner_tmp="$(mktemp -d)"
    HOME="$fake_home" TEST_TEMP_DIR="$inner_tmp" teardown_test_dir

    assert [ -f "${fake_home}/.config/ccblocks/config.json" ]
    refute [ -d "$inner_tmp" ]
}

@test "every direct run of a prompting script supplies its own stdin" {
    # bats hands `run` the caller's terminal, so an unredirected invocation of
    # a script that prompts blocks forever on a developer TTY while passing in
    # CI (where stdin is already closed). Every such call must pipe an answer
    # or redirect from /dev/null. Calls wrapped in `bash -c "... | \"$SCRIPT\""`
    # already supply stdin through the pipe.
    local offenders=""
    local file line
    for file in "${BATS_TEST_DIRNAME}"/*.bats; do
        while IFS= read -r line; do
            case "$line" in
            *'bash -c'* | *'</dev/null'* | *'<<<'* | *'< "'*) continue ;;
            esac
            offenders="${offenders}$(basename "$file"): ${line}"$'\n'
        done < <(grep -nE '^[[:space:]]*run[[:space:]]+.*(setup|uninstall)\.sh' "$file" || true)
    done

    if [ -n "$offenders" ]; then
        echo "These runs inherit the terminal and can hang 'make test':"
        echo "$offenders"
        return 1
    fi
}

@test "setup_test_dir points CCBLOCKS_CONFIG into the test temp directory" {
    assert [ -n "${CCBLOCKS_CONFIG:-}" ]
    case "$CCBLOCKS_CONFIG" in
    "${TEST_TEMP_DIR}"/*) ;;
    *)
        echo "CCBLOCKS_CONFIG escapes the test sandbox: $CCBLOCKS_CONFIG"
        return 1
        ;;
    esac
}
