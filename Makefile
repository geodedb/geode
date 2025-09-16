# Simple Makefile to wrap Zig build/test/fuzz/bench/tools

ZIG ?= zig
ZIG_FLAGS ?=
ZIG_RELEASE_FLAGS ?= -Drelease-safe

.PHONY: all build release test integration-test go-build go-test go-clean go-example fuzz bench tools doccheck clean vendor-quic cert-gen fmt ci help

# Default target - build everything
all: build go-build

# Help target
help:
	@echo "Geode Makefile targets:"
	@echo "  make build       - Build debug version (Zig + Go)"
	@echo "  make release     - Build release version (Zig + Go)"
	@echo "  make test        - Run all tests (Zig + Go)"
	@echo "  make integration-test - Run comprehensive integration tests"
	@echo "  make go-build    - Build Go client library only"
	@echo "  make go-test     - Run Go client tests only"
	@echo "  make go-example  - Run Go client example program"
	@echo "  make go-clean    - Clean Go client artifacts"
	@echo "  make fuzz        - Run fuzz tests"
	@echo "  make bench       - Run benchmarks"
	@echo "  make tools       - Build all tools"
	@echo "  make doccheck    - Check documentation"
	@echo "  make vendor-quic - Vendor QUIC library from nix"
	@echo "  make cert-gen    - Generate TLS certificates"
	@echo "  make fmt         - Format all code"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make ci          - Run CI pipeline (build, test, fuzz, bench)"

build:
	$(ZIG) build $(ZIG_FLAGS)
	$(MAKE) go-build

release:
	$(ZIG) build $(ZIG_RELEASE_FLAGS)
	$(MAKE) go-build

# Run Zig tests
test:
	$(ZIG) build test $(ZIG_FLAGS)
	$(MAKE) go-test

# Build Go client library
go-build:
	@if [ -d "clients/go/gql" ]; then \
		echo "Building Go client library..."; \
		cd clients/go/gql && go build ./...; \
		if [ -d "example" ]; then \
			echo "Building Go example program..."; \
			cd example && go build -o ../../../zig-out/bin/gql-example . || echo "Failed to build example"; \
		fi; \
		echo "Go client library built successfully"; \
	else \
		echo "Go client directory not found, skipping Go build"; \
	fi

# Run Go client tests
go-test: go-build
	@if [ -d "clients/go/gql" ]; then \
		echo "Running Go client tests..."; \
		cd clients/go/gql && go test -v -timeout 30s; \
	else \
		echo "Go client directory not found, skipping Go tests"; \
	fi

# Clean Go client artifacts
go-clean:
	@if [ -d "clients/go/gql" ]; then \
		echo "Cleaning Go client artifacts..."; \
		cd clients/go/gql && go clean || true; \
	fi

# Run Go client example
go-example: build go-build
	@if [ -f "./zig-out/bin/gql-example" ]; then \
		echo "Running Go client example (process mode)..."; \
		./zig-out/bin/gql-example -mode process -v; \
	else \
		echo "Go example not found, run 'make go-build' first"; \
	fi

# Run comprehensive integration tests
integration-test: build
	@if [ -f "scripts/integration_test.sh" ]; then \
		./scripts/integration_test.sh; \
	else \
		echo "Integration test script not found"; \
	fi

fuzz:
	$(ZIG) build fuzz $(ZIG_FLAGS)

bench:
	$(ZIG) build bench $(ZIG_FLAGS)

tools:
	$(ZIG) build tools $(ZIG_FLAGS)

doccheck: tools
	@if [ -f "./zig-out/bin/doccheck" ]; then \
		./zig-out/bin/doccheck; \
	else \
		echo "doccheck not found, run 'make tools' first"; \
	fi

# Vendor QUIC library from nix
vendor-quic:
	@if [ -f "scripts/vendor_quic.sh" ]; then \
		./scripts/vendor_quic.sh; \
	else \
		echo "Vendor script not found at scripts/vendor_quic.sh"; \
	fi

# Generate TLS certificates
cert-gen: build
	@if [ -f "./zig-out/bin/cert_gen" ]; then \
		./zig-out/bin/cert_gen; \
	else \
		echo "cert_gen not found, building it..."; \
		$(ZIG) build $(ZIG_FLAGS); \
		if [ -f "./zig-out/bin/cert_gen" ]; then \
			./zig-out/bin/cert_gen; \
		else \
			echo "cert_gen build failed"; \
		fi \
	fi

# Format all code
fmt:
	@echo "Formatting Zig code..."
	@# Format only src/, tests/, and build.zig, excluding vendor/
	$(ZIG) fmt src/
	$(ZIG) fmt tests/
	$(ZIG) fmt build.zig
	@echo "Formatting Go code..."
	@if [ -d "clients/go/gql" ]; then \
		cd clients/go/gql && go fmt ./...; \
	fi

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf zig-out
	rm -rf .zig-cache
	rm -rf zig-cache
	$(MAKE) go-clean

# Run build, test, fuzz, bench sequentially for CI
ci: clean build test fuzz bench
	@echo "CI pipeline completed successfully"

# Quick rebuild (no clean)
quick: build test

# Server targets
server: build
	./zig-out/bin/geoded --listen-quic 0.0.0.0:7567

server-tcp: build
	./zig-out/bin/geoded --listen-tcp 127.0.0.1:7567

# Development setup
dev-setup: vendor-quic cert-gen
	@echo "Development environment setup complete"
