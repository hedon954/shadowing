.DEFAULT_GOAL := help

.PHONY: help setup env generate build upgrade test format format-check lint check clean

help:
	@echo "Shadowing development commands:"
	@echo "  make setup         Install tools, hooks, and generate the project"
	@echo "  make generate      Generate the Xcode project"
	@echo "  make build         Build the macOS app without signing"
	@echo "  make upgrade       Rebuild, restart, and open the macOS app"
	@echo "  make test          Run macOS unit tests"
	@echo "  make format        Format Swift sources"
	@echo "  make lint          Run SwiftLint, actionlint, and architecture checks"
	@echo "  make check         Run the complete local/CI quality gate"
	@echo "  make clean         Remove generated build artifacts"

setup:
	@command -v brew >/dev/null 2>&1 || (echo "Homebrew is required: https://brew.sh" >&2; exit 1)
	brew bundle
	pre-commit install
	$(MAKE) generate
	@echo "Ready. Open Shadowing/Shadowing.xcodeproj or run make build."

env:
	./scripts/check-env.sh

generate:
	xcodegen generate --spec Shadowing/project.yml

build: generate
	./scripts/xcodebuild.sh build

upgrade: build
	./scripts/upgrade.sh

test: generate
	./scripts/xcodebuild.sh test

format:
	swiftformat Shadowing

format-check:
	swiftformat --lint Shadowing

lint:
	swiftlint lint --strict --config .swiftlint.yml
	actionlint
	./scripts/validate-architecture.sh

check:
	@$(MAKE) env
	@$(MAKE) format-check
	@$(MAKE) lint
	@$(MAKE) build
	@$(MAKE) test

clean:
	rm -rf Shadowing/Shadowing.xcodeproj build
