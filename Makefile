.PHONY: test lint format format-check validate install-deps help

# Single source of truth for the shell files lint/format/format-check cover, so
# the three targets (and .githooks/pre-commit, which mirrors them) cannot drift.
# tests/*.bats are excluded on purpose: shfmt cannot parse bats syntax.
SHELL_SOURCES = ccblocks libexec/ccblocks libexec/bin/*.sh libexec/lib/*.sh libexec/ccblocks-daemon.sh dev/*.sh scripts/*.sh .githooks/* tests/test_helper.bash

help:
	@echo "ccblocks development targets:"
	@echo ""
	@echo "  make test          - Run all bats tests"
	@echo "  make lint          - Run shellcheck on all scripts"
	@echo "  make format        - Format all scripts with shfmt"
	@echo "  make format-check  - Check formatting without modifying"
	@echo "  make validate      - Run lint + format-check + tests (pre-commit validation)"
	@echo "  make install-deps  - Install development dependencies"
	@echo "  make help          - Show this help message"

test:
	bats tests/*.bats

lint:
	@shellcheck $(SHELL_SOURCES)

format:
	@shfmt -w -i 0 $(SHELL_SOURCES)

format-check:
	@shfmt -d -i 0 $(SHELL_SOURCES)

validate: lint format-check test

install-deps:
	@command -v brew >/dev/null 2>&1 || { echo "Error: Homebrew not found. Install from https://brew.sh"; exit 1; }
	brew tap bats-core/bats-core
	brew trust bats-core/bats-core 2>/dev/null || true
	brew install bats-core bats-support bats-assert shellcheck shfmt
