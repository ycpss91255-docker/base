.PHONY: test lint coverage migrate migrate-list migrate-dry-run clean help

test: ## Run full CI (ShellCheck + Bats + Kcov) via docker compose
	./scripts/ci.sh

lint: ## Run ShellCheck only
	./scripts/ci.sh --lint-only

coverage: ## Run tests with Kcov coverage
	./scripts/ci.sh --coverage

migrate: ## Migrate all repos to docker_template
	./scripts/migrate.sh --all

migrate-list: ## List repos and their migration status
	./scripts/migrate.sh --list

migrate-dry-run: ## Dry-run migration for all repos
	./scripts/migrate.sh --dry-run --all

clean: ## Remove coverage reports
	rm -rf coverage/

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
