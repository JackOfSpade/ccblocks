#!/usr/bin/env bash

# ccblocks Test Coverage Analyzer
# Analyzes test coverage across shell scripts

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$PROJECT_ROOT/libexec"
BIN_DIR="$RUNTIME_DIR/bin"
LIB_DIR="$RUNTIME_DIR/lib"

# Detect OS for find compatibility
OS_TYPE="$(uname -s)"
if [ "$OS_TYPE" = "Darwin" ]; then
	PERM_FLAG="+111" # macOS BSD find
else
	PERM_FLAG="/111" # GNU find (Linux)
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
	echo -e "${BLUE}${BOLD}$1${NC}"
}

print_success() {
	echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
	echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
	echo -e "${RED}✗${NC} $1"
}

# Count total scripts
count_scripts() {
	local script_count=0
	# Count executables in bin/ (no extension) + helpers in lib/ (.sh extension)
	local bin_count lib_count
	bin_count=$(find "$BIN_DIR" -type f -perm "$PERM_FLAG" ! -name "*.log" | wc -l | tr -d ' ')
	lib_count=$(find "$LIB_DIR" -name "*.sh" -type f | wc -l | tr -d ' ')
	script_count=$((bin_count + lib_count))
	echo "$script_count"
}

# Count total lines of shell code
count_lines() {
	local line_count=0
	# Count lines in bin/ executables and lib/ helpers, excluding comments and blank lines
	line_count=$({
		find "$BIN_DIR" -type f -perm "$PERM_FLAG" ! -name "*.log" -exec cat {} \;
		find "$LIB_DIR" -name "*.sh" -type f -exec cat {} \;
	} | grep -v '^\s*#' | grep -v '^\s*$' | wc -l | tr -d ' ')
	echo "$line_count"
}

# Count total functions defined
count_functions() {
	local func_count=0
	# Find function definitions (name() { or function name {)
	func_count=$({
		find "$BIN_DIR" -type f -perm "$PERM_FLAG" ! -name "*.log" -exec grep -h '^\s*[a-z_][a-z0-9_]*\s*()' {} \;
		find "$LIB_DIR" -name "*.sh" -type f -exec grep -h '^\s*[a-z_][a-z0-9_]*\s*()' {} \;
	} | sed 's/\s*().*$//' | sed 's/^\s*//' | sort -u | wc -l | tr -d ' ')
	echo "$func_count"
}

# List all function names
list_functions() {
	{
		find "$BIN_DIR" -type f -perm "$PERM_FLAG" ! -name "*.log" -exec grep -h '^\s*[a-z_][a-z0-9_]*\s*()' {} \;
		find "$LIB_DIR" -name "*.sh" -type f -exec grep -h '^\s*[a-z_][a-z0-9_]*\s*()' {} \;
	} | sed 's/\s*().*$//' | sed 's/^\s*//' | sort -u
}

# Count test files
count_test_files() {
	local test_count=0
	test_count=$(find "$PROJECT_ROOT/tests" -name "*.bats" -type f | wc -l | tr -d ' ')
	echo "$test_count"
}

# Count total test cases
count_tests() {
	local test_count=0
	test_count=$(find "$PROJECT_ROOT/tests" -name "*.bats" -type f -exec grep -h '@test' {} \; | wc -l | tr -d ' ')
	echo "$test_count"
}

# Analyze which scripts have tests
analyze_script_coverage() {
	local script_name
	local covered=0
	local total=0

	echo ""
	print_header "Script Test Coverage"
	echo "===================="

	# Analyze bin/ executables (no extension)
	while IFS= read -r script; do
		script_name=$(basename "$script")
		total=$((total + 1))

		# A script is "covered" if some .bats file actually references it
		# by name - the test files here don't follow a 1:1 filename
		# convention (e.g. status.sh is tested by check-status.bats,
		# schedule.sh by schedule-blocks.bats), so matching on the test
		# file's own name would always miss. Built as a portable
		# while-loop rather than xargs/basename -a (which differ between
		# GNU and BSD, and can misbehave on zero matches) and explicitly
		# tolerates zero matches instead of letting a bare `grep -l`
		# "no match" exit status kill the script under `set -e`.
		local covering_tests="" match_file
		while IFS= read -r match_file; do
			[ -n "$match_file" ] || continue
			if [ -n "$covering_tests" ]; then
				covering_tests="${covering_tests},$(basename "$match_file")"
			else
				covering_tests="$(basename "$match_file")"
			fi
		done < <(grep -l "$script_name" "$PROJECT_ROOT"/tests/*.bats 2>/dev/null || true)

		if [ -n "$covering_tests" ]; then
			covered=$((covered + 1))
			print_success "$script_name ($covering_tests)"
		else
			print_warning "$script_name (no test file)"
		fi
	done < <(find "$BIN_DIR" -type f -perm "$PERM_FLAG" ! -name "*.log" | sort)

	echo ""
	local coverage_pct=0
	if [ "$total" -gt 0 ]; then
		coverage_pct=$((covered * 100 / total))
	fi

	if [ "$coverage_pct" -ge 80 ]; then
		print_success "Script coverage: $covered/$total ($coverage_pct%)"
	elif [ "$coverage_pct" -ge 60 ]; then
		print_warning "Script coverage: $covered/$total ($coverage_pct%)"
	else
		print_error "Script coverage: $covered/$total ($coverage_pct%)"
	fi
}

# Show coverage summary. Populates SUMMARY_SCRIPTS/SUMMARY_TESTS so
# main() can reuse them instead of re-running the same find/grep scans.
show_summary() {
	local lines
	local functions
	local test_files

	SUMMARY_SCRIPTS=$(count_scripts)
	lines=$(count_lines)
	functions=$(count_functions)
	test_files=$(count_test_files)
	SUMMARY_TESTS=$(count_tests)

	echo ""
	print_header "ccblocks Test Coverage Report"
	echo "=============================="
	echo ""

	print_header "Codebase Statistics"
	echo "  Shell scripts:    $SUMMARY_SCRIPTS files"
	echo "  Lines of code:    $lines (excluding comments/blanks)"
	echo "  Functions:        $functions unique functions"
	echo ""

	print_header "Test Statistics"
	echo "  Test files:       $test_files files"
	echo "  Test cases:       $SUMMARY_TESTS tests"
	echo ""

	# Show average tests per script
	local avg_tests_per_script=0
	if [ "$SUMMARY_SCRIPTS" -gt 0 ]; then
		avg_tests_per_script=$((SUMMARY_TESTS / SUMMARY_SCRIPTS))
	fi
	echo "  Avg tests/script: $avg_tests_per_script"
}

# Main coverage analysis
main() {
	show_summary
	analyze_script_coverage

	echo ""
	print_header "Coverage Goals"
	echo "=============="
	local current_tests="$SUMMARY_TESTS"
	local target_tests=$((SUMMARY_SCRIPTS * 10)) # Target: 10 tests per script

	if [ "$current_tests" -ge "$target_tests" ]; then
		print_success "Coverage goal achieved: $current_tests/$target_tests tests"
	else
		local needed=$((target_tests - current_tests))
		print_warning "Coverage goal: $current_tests/$target_tests tests ($needed needed)"
	fi

	echo ""
	print_header "Next Steps"
	echo "=========="
	echo "  1. Maintain >80% script coverage (all bin/* executables have tests)"
	echo "  2. Add integration tests for lib/*.sh helper functions"
	echo "  3. Increase test cases to >10 per script for complex scripts"
	echo "  4. Run 'make test' regularly to verify coverage"
	echo ""
}

# Run main
main
