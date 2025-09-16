# Simple Makefile to wrap Zig build/test/fuzz/bench/tools

ZIG ?= zig
ZIG_FLAGS ?=
ZIG_RELEASE_FLAGS ?= -Drelease-safe

.PHONY: all build release test go-test fuzz bench tools doccheck clean vendor-quic cert-gen fmt ci help

# Default target
all: build

# Help target
help:
	@echo "Geode Makefile targets:"
	@echo "  make build       - Build debug version"
	@echo "  make release     - Build release version"
	@echo "  make test        - Run all tests (Zig + Go)"
	@echo "  make go-test     - Run Go client tests only"
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

release:
	$(ZIG) build $(ZIG_RELEASE_FLAGS)

# Run Zig tests
test:
	$(ZIG) build test $(ZIG_FLAGS)
	$(MAKE) go-test

# Run Go client tests
go-test:
	@if [ -d "clients/go/gql" ]; then \
		echo "Running Go client tests..."; \
		cd clients/go/gql && go test -v; \
	else \
		echo "Go client directory not found, skipping Go tests"; \
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
	@if [ -d "clients/go/gql" ]; then \
		cd clients/go/gql && go clean; \
	fi

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
