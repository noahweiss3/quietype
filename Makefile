# Shortcuts for common tasks. Run `make` to list them.

.DEFAULT_GOAL := help
.PHONY: help build test test-model cli app run bench evals evals-check evals-test lint format clean

help: ## List the targets
	@echo "Usage: make <target>"
	@echo
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z_-]+:.*## / { printf "  %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## Debug build of every product
	swift build

# Without QUIETYPE_TEST_MODEL only the model-backed QuietypeKit tests skip, as in CI.
test: ## Run every test that needs no model
	swift test

# Fails rather than letting the model-backed tests skip when no model is given.
test-model: ## Run every test, including the model-backed ones (needs QUIETYPE_TEST_MODEL=/path/to/model.gguf)
	@test -n "$$QUIETYPE_TEST_MODEL" || { echo "set QUIETYPE_TEST_MODEL to a cleanup model GGUF"; exit 2; }
	swift test

cli: ## Build quietype-cli (debug), which the evals call
	swift build --product quietype-cli

app: ## Build and sign build/Quietype.app (see scripts/build-app.sh for options)
	scripts/build-app.sh

run: app ## Build Quietype.app and open it
	open build/Quietype.app

bench: ## Build quietype-bench (release)
	swift build -c release --product quietype-bench

# Both suites run even when the first fails, so one run shows every result.
evals: cli ## Score every cleanup suite and the meetings (needs llama-server on :8080, see evals/README.md)
	@status=0; python3 evals/run_evals.py --all || status=1; \
	python3 evals/run_meeting_notes.py || status=1; exit $$status

evals-check: cli ## The CI gate: fail only on cases that aren't known failures in evals/baselines.json
	@status=0; python3 evals/run_evals.py --all --check-baseline || status=1; \
	python3 evals/run_meeting_notes.py --check-baseline || status=1; exit $$status

# Builds quietype-cli first so the contract tests run the real binary instead of skipping.
evals-test: cli ## Test the eval harness itself (no model needed)
	python3 -m unittest discover -s evals/tests

# swift format comes with the toolchain and reads .swift-format. Ruff is the version CI pins
# (ci.yml), run through pipx so a different installed ruff can't disagree.
lint: ## Check Swift formatting and lint the eval scripts with ruff (needs pipx)
	swift format lint --strict -r Sources Tests Package.swift
	pipx run ruff==0.17.1 check evals

format: ## Format the Swift code in place, as `make lint` expects it
	swift format format -i -r Sources Tests Package.swift

clean: ## Remove .build and build
	rm -rf .build build
