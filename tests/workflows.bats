#!/usr/bin/env bats

# Static checks for GitHub Actions workflow security invariants.

load test_helper

setup() {
	setup_test_dir
	TEST_WORKFLOW="${PROJECT_ROOT}/.github/workflows/test.yml"
	PUBLISH_WORKFLOW="${PROJECT_ROOT}/.github/workflows/publish.yml"
}

teardown() {
	teardown_test_dir
}

@test "test workflow uses least-privilege read permissions" {
	run grep -Eq '^permissions:[[:space:]]*\{\}[[:space:]]*$|^permissions:[[:space:]]*$' "$TEST_WORKFLOW"
	assert_success

	run grep -Eq '^[[:space:]]+contents:[[:space:]]+read[[:space:]]*$' "$TEST_WORKFLOW"
	assert_success
}

@test "workflows do not expose untrusted event text in run names" {
	run grep -R "github.event.*message\\|github.event.*title" "${PROJECT_ROOT}/.github/workflows"
	assert_failure
}

@test "workflow actions are pinned to commit SHAs" {
	# Match on `uses:` alone, not on `uses: ...@...`: a reference with no `@` at
	# all (implicitly the action's default branch) is the most mutable form
	# there is, and an @-anchored pattern would skip it entirely.
	run grep -RhoE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+[^[:space:]]+' "${PROJECT_ROOT}/.github/workflows"
	assert_success

	while IFS= read -r uses_line; do
		spec="${uses_line##* }"

		# Local composite actions live in this repo and move with it.
		case "$spec" in
		./*) continue ;;
		esac

		ref="${spec##*@}"
		if [ "$ref" = "$spec" ]; then
			echo "Unpinned action (no @ref at all): $uses_line"
			return 1
		fi
		[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || {
			echo "Mutable action ref: $uses_line"
			return 1
		}
	done <<<"$output"
}

@test "test workflow pins and verifies the Homebrew installer" {
	run grep -Eq 'raw.githubusercontent.com/Homebrew/install/[0-9a-f]{40}/install\.sh' "$TEST_WORKFLOW"
	assert_success

	run grep -Eq 'sha256sum[[:space:]]+-c' "$TEST_WORKFLOW"
	assert_success
}

@test "publish workflow only runs for successful push or dispatched test runs" {
	run grep -F "github.event.workflow_run.conclusion == 'success'" "$PUBLISH_WORKFLOW"
	assert_success

	# The parentheses are the assertion, not decoration: `&&` binds tighter
	# than `||`, so dropping them turns the condition into
	# `(success && push) || workflow_dispatch` and ANY dispatched run
	# publishes, green or not. Match the parenthesised group itself.
	run grep -F "(github.event.workflow_run.event == 'push' || github.event.workflow_run.event == 'workflow_dispatch')" "$PUBLISH_WORKFLOW"
	assert_success
}

@test "publish workflow checks out the tested commit in privileged jobs" {
	# Order-independent: every checkout in this workflow must pin the tested
	# SHA, so the two counts have to agree no matter where the steps sit.
	run grep -cE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+actions/checkout@' "$PUBLISH_WORKFLOW"
	assert_success
	checkout_count="$output"

	run grep -cF 'ref: ${{ github.event.workflow_run.head_sha }}' "$PUBLISH_WORKFLOW"
	assert_success
	assert_output "$checkout_count"

	[ "$checkout_count" -ge 2 ]
}

@test "publish workflow releases only when the version tag is missing" {
	run grep -F "if: needs.validate.outputs.tag_exists == 'false'" "$PUBLISH_WORKFLOW"
	assert_success
}

@test "publish workflow validates VERSION before publishing" {
	run grep -Eq '^[[:space:]]+VERSION_REGEX=' "$PUBLISH_WORKFLOW"
	assert_success

	run grep -Eq 'Version must match' "$PUBLISH_WORKFLOW"
	assert_success
}

@test "publish workflow does not inline template expressions inside run blocks" {
	# Sanity check: the scan below is only meaningful while the workflow still
	# has block-scalar run steps to walk.
	run grep -Eq '^[[:space:]]*run:[[:space:]]*[|>]' "$PUBLISH_WORKFLOW"
	assert_success

	# Track the run block itself rather than peeking a fixed number of lines
	# back: a `${{ }}` far enough down a long run block would otherwise slip
	# past unnoticed. A block starts at `run: |` / `run: >` and ends as soon as
	# indentation returns to the step's own level.
	in_run=0
	run_indent=0
	line_no=0
	violations=""

	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))

		leading="${line%%[![:space:]]*}"
		content="${line#"$leading"}"
		# Blank lines carry no indentation and must not close a run block.
		[ -n "$content" ] || continue
		indent=${#leading}

		if [ "$in_run" -eq 1 ] && [ "$indent" -le "$run_indent" ]; then
			in_run=0
		fi

		if [ "$in_run" -eq 1 ]; then
			case "$content" in
			*'${{'*) violations="${violations}line ${line_no}: ${content}"$'\n' ;;
			esac
			continue
		fi

		if [[ "$content" =~ ^run:[[:space:]]*[\|\>] ]]; then
			in_run=1
			run_indent=$indent
		fi
	done <"$PUBLISH_WORKFLOW"

	if [ -n "$violations" ]; then
		echo "Template expressions inlined in run blocks (use step-level env: instead):"
		echo "$violations"
		return 1
	fi
}
