# Entry points for working on this configuration.
#
# The validation targets deliberately use the same flags as the pipeline in
# .github/workflows/ci.yml, so a clean `make ci` here means a clean pipeline there. If one
# side changes, change the other in the same commit.

TERRAFORM ?= terraform
TFLINT    ?= tflint
PYTHON    ?= python3
PYTEST    ?= pytest

# Passed through to the plan and apply targets so a variables file stays out of the tree.
TF_VARS ?=

# Replay parameters. BUS names a key from event_buses; FROM and TO are UTC instants.
BUS  ?=
FROM ?=
TO   ?=

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

# --------------------------------------------------------------------------------------
# Validation. Every flag below matches .github/workflows/ci.yml.
# --------------------------------------------------------------------------------------

.PHONY: init
init: ## Initialize without configuring a backend
	$(TERRAFORM) init -backend=false -input=false

.PHONY: fmt
fmt: ## Rewrite every file into canonical form
	$(TERRAFORM) fmt -recursive

.PHONY: fmt-check
fmt-check: ## Fail if any file is not in canonical form
	$(TERRAFORM) fmt -check -diff -recursive

.PHONY: validate
validate: init ## Check the configuration is internally consistent
	$(TERRAFORM) validate

.PHONY: lint
lint: ## Run the Terraform linter at error severity
	$(TFLINT) --init
	$(TFLINT) --minimum-failure-severity=error

.PHONY: patterns
patterns: ## Lint every event pattern and contract in the tree
	$(PYTHON) tests/lint_event_patterns.py

.PHONY: test
test: ## Run the offline pattern and contract suite
	flake8 --select=E9,F63,F7,F82 --show-source .
	git ls-files '*.py' | xargs -r -n1 $(PYTHON) -m py_compile
	$(PYTHON) tests/lint_event_patterns.py
	$(PYTEST) tests -q

.PHONY: ci
ci: fmt-check validate lint test ## Run every gate the pipeline runs, in pipeline order

# --------------------------------------------------------------------------------------
# Deployment
# --------------------------------------------------------------------------------------

.PHONY: plan
plan: ## Show what would change
	$(TERRAFORM) init -input=false
	$(TERRAFORM) plan -input=false $(TF_VARS)

.PHONY: deploy
deploy: ## Apply the configuration
	$(TERRAFORM) init -input=false
	$(TERRAFORM) apply -input=false $(TF_VARS)

.PHONY: destroy
destroy: ## Tear the configuration down
	$(TERRAFORM) destroy -input=false $(TF_VARS)

# --------------------------------------------------------------------------------------
# Operations
# --------------------------------------------------------------------------------------

.PHONY: archives
archives: ## Show each bus archive and how long it retains events
	@$(TERRAFORM) output -json archive_retention_days

.PHONY: replay
replay: ## Replay an archive onto its bus: make replay BUS=<key> FROM=<utc> TO=<utc>
	@test -n "$(BUS)"  || { echo "BUS is required, e.g. BUS=platform-core";          exit 1; }
	@test -n "$(FROM)" || { echo "FROM is required, e.g. FROM=2026-01-01T00:00:00Z"; exit 1; }
	@test -n "$(TO)"   || { echo "TO is required, e.g. TO=2026-01-02T00:00:00Z";     exit 1; }
	@set -eu; \
		pick='import json,sys; print(json.load(sys.stdin)[sys.argv[1]])'; \
		archive=$$($(TERRAFORM) output -json archive_arns   | $(PYTHON) -c "$$pick" "$(BUS)"); \
		bus=$$($(TERRAFORM) output -json event_bus_arns     | $(PYTHON) -c "$$pick" "$(BUS)"); \
		aws events start-replay \
			--replay-name "$(BUS)-replay-$$(date -u +%Y%m%dT%H%M%SZ)" \
			--event-source-arn "$$archive" \
			--event-start-time "$(FROM)" \
			--event-end-time "$(TO)" \
			--destination "Arn=$$bus"

.PHONY: undelivered
undelivered: ## List routes and schedules with nowhere to send a failure
	@echo "Rule targets without a dead-letter queue:"
	@$(TERRAFORM) output -json targets_without_dead_letter_queue
	@echo "Schedules without a dead-letter queue:"
	@$(TERRAFORM) output -json schedules_without_dead_letter_queue
	@echo "Forwarding routes without a dead-letter queue:"
	@$(TERRAFORM) output -json cross_account_forwarding_without_dead_letter_queue

.PHONY: clean
clean: ## Remove local Terraform and Python working files
	rm -rf .terraform .terraform.lock.hcl tfplan .pytest_cache
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
