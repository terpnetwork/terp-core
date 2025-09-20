###############################################################################
###                                Linting                                  ###
###############################################################################

.PHONY: lint lint-help lint-all lint-format lint-markdown install-linter

# Help target
lint-help:
	@echo ""
	@echo "lint subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make linter-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  all         Run all linters"
	@echo "  format      Run linters with auto-fix"
	@echo "  markdown    Run markdown linter"
	@echo "  install     Install golangci-lint"
	@echo ""

lint: lint-help

# Install golangci-lint
lint-install:
	@echo "--> Installing golangci-lint"
	@curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $$GOPATH/bin v1.54.2

# Run all linters
lint-all:
	@echo "--> Running golangci-lint"
	@go run github.com/golangci/golangci-lint/cmd/golangci-lint run --timeout=10m
	@echo "--> Running markdownlint"
	@docker run -v $(PWD):/workdir ghcr.io/igorshubovych/markdownlint-cli:latest "**/*.md"

# Run linters with auto-fix
lint-format:
	@echo "--> Running golangci-lint with auto-fix"
	@go run github.com/golangci/golangci-lint/cmd/golangci-lint run ./... --fix
	@echo "--> Formatting Go files with gofumpt"
	@go run mvdan.cc/gofumpt -l -w x/ app/ ante/ tests/
	@echo "--> Fixing markdown files"
	@docker run -v $(PWD):/workdir ghcr.io/igorshubovych/markdownlint-cli:latest "**/*.md" --fix

# Run markdown linter only
lint-markdown:
	@echo "--> Running markdownlint"
	@docker run -v $(PWD):/workdir ghcr.io/igorshubovych/markdownlint-cli:latest "**/*.md"