# Simple Makefile to wrap Zig build/test/fuzz/bench/tools

ZIG ?= zig
ZIG_FLAGS ?=
ZIG_RELEASE_FLAGS ?= -Drelease-safe

.PHONY: all build release test integration-test go-build go-test go-clean go-example fuzz bench tools doccheck clean vendor-quic cert-gen fmt ci help
.PHONY: cross-compile cross-windows cross-linux-arm cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-windows-arm64 cross-test

# Default target - build everything including cross-compilation checks (non-blocking)
all: build go-build test
	@echo "Running cross-compilation checks..."
	@$(MAKE) cross-compile || echo "Warning: Some cross-compilation targets failed (see above for details)"
	@$(MAKE) docker-ci || echo "Warning: Docker CI failed"

# Help target
help:
	@echo "Geode Makefile targets:"
	@echo ""
	@echo "Build targets:"
	@echo "  make build       - Build debug version (Zig + Go)"
	@echo "  make release     - Build release version (Zig + Go)"
	@echo "  make tools       - Build all tools"
	@echo "  make cross-compile - Build for all cross-compilation targets"
	@echo ""
	@echo "Cross-compilation targets:"
	@echo "  make cross-windows      - Build for Windows x86_64"
	@echo "  make cross-linux-arm    - Build for Linux ARM (32-bit)"
	@echo "  make cross-linux-arm64  - Build for Linux ARM64"
	@echo "  make cross-linux-riscv64 - Build for Linux RISC-V 64-bit"
	@echo "  make cross-macos-x86_64 - Build for macOS x86_64"
	@echo "  make cross-windows-arm64 - Build for Windows ARM64"
	@echo "  make cross-test         - Test cross-platform functionality"
	@echo ""
	@echo "Test targets:"
	@echo "  make test        - Run all tests (Zig + Go)"
	@echo "  make integration-test - Run comprehensive integration tests"
	@echo "  make fuzz        - Run fuzz tests"
	@echo "  make bench       - Run benchmarks"
	@echo ""
	@echo "Go client targets:"
	@echo "  make go-build    - Build Go client library only"
	@echo "  make go-test     - Run Go client tests only"
	@echo "  make go-example  - Run Go client example program"
	@echo "  make go-clean    - Clean Go client artifacts"
	@echo ""
	@echo "Docker targets:"
	@echo "  make docker-build     - Build Docker images"
	@echo "  make docker-up-singleton    - Start singleton container"
	@echo "  make docker-up-distributed  - Start distributed cluster"
	@echo "  make docker-down      - Stop all containers"
	@echo "  make docker-test      - Run Docker tests"
	@echo "  make docker-ci        - Run Docker CI pipeline"
	@echo "  make docker-clean     - Clean Docker artifacts"
	@echo ""
	@echo "Utility targets:"
	@echo "  make doccheck    - Check documentation"
	@echo "  make quic-status - Check QUIC submodule status"
	@echo "  make quic-init   - Initialize QUIC submodule"
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

# Check QUIC submodule status
quic-status:
	@echo "QUIC library is managed as a git submodule"
	@if [ -e "vendor/quic/.git" ]; then \
		echo "✓ QUIC submodule is initialized"; \
		cd vendor/quic && git log -1 --oneline; \
	else \
		echo "✗ QUIC submodule not initialized"; \
		echo "Run: git submodule update --init --recursive"; \
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
ci: clean build test fuzz bench cross-compile-strict
	@echo "CI pipeline completed successfully"

# Strict cross-compilation for CI (fails on any error)
cross-compile-strict: cross-windows cross-linux-arm cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-windows-arm64
	@echo "All cross-compilation targets built successfully"

# Quick rebuild (no clean)
quick: build test

# Cross-compilation targets (required 64-bit targets only)
cross-compile: cross-compile-required cross-compile-optional
	@echo "Cross-compilation checks complete"

# Required 64-bit cross-compilation targets (must all pass)
cross-compile-required: cross-windows cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-windows-arm64
	@echo "✓ All required cross-compilation targets built successfully"

# Optional 32-bit cross-compilation targets (failures are non-fatal)
cross-compile-optional:
	@echo "Checking optional 32-bit cross-compilation targets..."
	@$(MAKE) cross-linux-arm || echo "⚠ Linux ARM (32-bit) cross-compilation failed (this is expected and non-fatal)"

# Cross-compile for Windows x86_64
cross-windows:
	@echo "Cross-compiling for Windows x86_64..."
	$(ZIG) build -Dtarget=x86_64-windows $(ZIG_FLAGS)
	@test -f zig-out/bin/geoded.exe || (echo "Failed to build geoded.exe" && exit 1)
	@test -f zig-out/bin/geodec.exe || (echo "Failed to build geodec.exe" && exit 1)
	@test -f zig-out/bin/gql.exe || (echo "Failed to build gql.exe" && exit 1)
	@echo "✓ Windows x86_64 build successful"

# Cross-compile for Linux ARM (32-bit)
cross-linux-arm:
	@echo "Cross-compiling for Linux ARM..."
	$(ZIG) build -Dtarget=arm-linux-gnueabihf $(ZIG_FLAGS)
	@echo "✓ Linux ARM build successful"

# Cross-compile for Linux ARM64
cross-linux-arm64:
	@echo "Cross-compiling for Linux ARM64..."
	$(ZIG) build -Dtarget=aarch64-linux-gnu $(ZIG_FLAGS)
	@echo "✓ Linux ARM64 build successful"

# Cross-compile for Linux RISC-V 64-bit
cross-linux-riscv64:
	@echo "Cross-compiling for Linux RISC-V 64-bit..."
	$(ZIG) build -Dtarget=riscv64-linux-gnu $(ZIG_FLAGS)
	@echo "✓ Linux RISC-V 64-bit build successful"

# Cross-compile for macOS x86_64
cross-macos-x86_64:
	@echo "Cross-compiling for macOS x86_64..."
	@# Only run on non-macOS systems or when on ARM macOS
	@if [ "$$(uname)" != "Darwin" ] || [ "$$(uname -m)" = "arm64" ]; then \
		$(ZIG) build -Dtarget=x86_64-macos $(ZIG_FLAGS); \
		echo "✓ macOS x86_64 build successful"; \
	else \
		echo "Skipping macOS x86_64 cross-compile on x86_64 macOS"; \
	fi

# Cross-compile for Windows ARM64
cross-windows-arm64:
	@echo "Cross-compiling for Windows ARM64..."
	$(ZIG) build -Dtarget=aarch64-windows-msvc $(ZIG_FLAGS)
	@echo "✓ Windows ARM64 build successful"

# Test cross-platform stdio functionality
cross-test:
	@echo "Testing cross-platform stdio..."
	$(ZIG) test tests/test_cross_platform_stdio.zig $(ZIG_FLAGS)
	@# Test Windows cross-compilation if Wine is available
	@if command -v wine64 >/dev/null 2>&1; then \
		echo "Testing Windows cross-compilation with Wine..."; \
		$(ZIG) test tests/test_cross_platform_stdio.zig -target x86_64-windows -femit-bin=test_stdio_windows.exe $(ZIG_FLAGS); \
		wine64 test_stdio_windows.exe 2>&1 | grep -q "Test stdout" || (echo "Windows stdio test failed" && exit 1); \
		wine64 test_stdio_windows.exe 2>&1 | grep -q "Test stderr" || (echo "Windows stdio test failed" && exit 1); \
		rm -f test_stdio_windows.exe test_stdio_windows.pdb; \
		echo "✓ Windows stdio test passed"; \
	else \
		echo "Wine not available, skipping Windows runtime test"; \
	fi

# Server targets
server: build
	./zig-out/bin/geoded --listen-quic 0.0.0.0:7567

server-tcp: build
	./zig-out/bin/geoded --listen-tcp 127.0.0.1:7567

# Development setup
dev-setup: quic-init cert-gen
	@echo "Development environment setup complete"

# Initialize QUIC submodule
quic-init:
	@echo "Initializing QUIC submodule..."
	@git submodule update --init --recursive
	@echo "QUIC submodule initialized"

# Docker operations
.PHONY: docker-build docker-up-singleton docker-up-distributed docker-down docker-test-singleton docker-test-distributed docker-test docker-logs-singleton docker-logs-distributed docker-ci docker-clean

docker-build:
	@echo "Building Docker images..."
	@# Try reliable Dockerfile first, then fallbacks
	@if [ -f "Dockerfile.reliable" ]; then \
		echo "Building with reliable Dockerfile..."; \
		docker build -t geode:latest -f Dockerfile.reliable . || \
			(echo "Reliable build failed, trying alternatives..." && \
			 docker build -t geode:latest -f Dockerfile.simple . 2>/dev/null || \
			 docker build -t geode:latest . 2>/dev/null || \
			 (echo "All Docker builds failed" && exit 1)); \
	elif [ -f "Dockerfile.simple" ] && docker build -t geode:latest -f Dockerfile.simple . 2>/dev/null; then \
		echo "Successfully built with simple Dockerfile"; \
	elif docker build -t geode:latest . 2>/dev/null; then \
		echo "Successfully built with main Dockerfile"; \
	else \
		echo "Failed to build Docker image" && exit 1; \
	fi
	@echo "Docker images built successfully"

docker-build-prod:
	@echo "Building production Docker image..."
	@if [ -f "Dockerfile.prod" ]; then \
		docker build -t geode:prod -f Dockerfile.prod .; \
	else \
		echo "Dockerfile.prod not found, skipping production build"; \
	fi

docker-up-singleton: docker-build
	@echo "Starting Geode singleton container..."
	@if [ -x "./scripts/docker/deploy.sh" ]; then \
		./scripts/docker/deploy.sh -m singleton -a up; \
	else \
		docker-compose up -d; \
	fi

docker-up-distributed: docker-build
	@echo "Starting Geode distributed cluster..."
	@if [ -x "./scripts/docker/deploy.sh" ]; then \
		./scripts/docker/deploy.sh -m distributed -a up; \
	else \
		docker-compose -f docker-compose.distributed.yml up -d; \
	fi

docker-down:
	@echo "Stopping Docker containers..."
	@if [ -x "./scripts/docker/deploy.sh" ]; then \
		./scripts/docker/deploy.sh -m singleton -a down 2>/dev/null || true; \
		./scripts/docker/deploy.sh -m distributed -a down 2>/dev/null || true; \
	else \
		docker-compose down 2>/dev/null || true; \
		docker-compose -f docker-compose.distributed.yml down 2>/dev/null || true; \
	fi
	@echo "Docker containers stopped"

docker-test-singleton:
	@echo "Testing Geode singleton deployment..."
	@# Ensure singleton is up
	@$(MAKE) docker-up-singleton
	@sleep 5
	@if [ -x "./scripts/docker/test-ci.sh" ]; then \
		./scripts/docker/test-ci.sh singleton || ($(MAKE) docker-down && exit 1); \
	elif [ -x "./scripts/docker/test.sh" ]; then \
		./scripts/docker/test.sh singleton || ($(MAKE) docker-down && exit 1); \
	else \
		echo "Test script not found, running basic test..."; \
		docker exec geode-singleton geodec "RETURN 1 AS x" --server 127.0.0.1:7567 || \
			(echo "Basic test failed" && $(MAKE) docker-down && exit 1); \
	fi
	@echo "Singleton tests passed"

docker-test-distributed:
	@echo "Testing Geode distributed deployment..."
	@# Stop singleton first to avoid port conflicts
	@docker-compose down 2>/dev/null || true
	@$(MAKE) docker-up-distributed
	@sleep 10
	@if [ -x "./scripts/docker/test-ci.sh" ]; then \
		./scripts/docker/test-ci.sh distributed || ($(MAKE) docker-down && exit 1); \
	elif [ -x "./scripts/docker/test.sh" ]; then \
		./scripts/docker/test.sh distributed || ($(MAKE) docker-down && exit 1); \
	else \
		echo "Test script not found, running basic test..."; \
		docker exec geode-leader geodec "RETURN 1 AS x" --server 127.0.0.1:7567 || \
			(echo "Basic test failed" && $(MAKE) docker-down && exit 1); \
	fi
	@echo "Distributed tests passed"

docker-test: docker-build
	@echo "Running all Docker tests..."
	@$(MAKE) docker-test-singleton
	@$(MAKE) docker-down
	@$(MAKE) docker-test-distributed
	@$(MAKE) docker-down
	@echo "All Docker tests passed"

docker-logs-singleton:
	docker-compose logs -f geode

docker-logs-distributed:
	docker-compose -f docker-compose.distributed.yml logs -f

# Clean Docker artifacts
docker-clean:
	@echo "Cleaning Docker artifacts..."
	@$(MAKE) docker-down
	@docker rmi geode:latest geode:prod 2>/dev/null || true
	@docker volume rm geode_geode-data geode_geode-certs 2>/dev/null || true
	@docker volume rm geode_geode-leader-data geode_geode-follower-1-data geode_geode-follower-2-data 2>/dev/null || true
	@echo "Docker cleanup complete"

# Quick Docker test with minimal setup
docker-quick-test:
	@echo "Running quick Docker test..."
	@docker-compose -f docker-compose.test.yml up -d --build
	@sleep 5
	@docker exec geode-test geodec "RETURN 1 AS x" --server 127.0.0.1:7567 || \
		(docker-compose -f docker-compose.test.yml down && exit 1)
	@echo "Quick test passed!"
	@docker-compose -f docker-compose.test.yml down

# Complete Docker CI pipeline
docker-ci:
	@echo "==== Docker CI Pipeline ===="
	@echo "1. Building Docker image with Zig 0.15.1..."
	@if docker build -f Dockerfile.reliable -t geode:latest . >/dev/null 2>&1; then \
		echo "✓ Docker build successful"; \
	else \
		echo "✗ Docker build failed"; \
		exit 1; \
	fi
	@echo "2. Verifying image..."
	@if docker images | grep -q "geode.*latest"; then \
		echo "✓ Image created successfully"; \
	else \
		echo "✗ Image not found"; \
		exit 1; \
	fi
	@echo "3. Running smoke test..."
	@docker run --rm -d --name geode-ci-test geode:latest >/dev/null 2>&1 && \
		sleep 2 && \
		echo "✓ Container started" || \
		(echo "✗ Container failed to start" && exit 1)
	@docker stop geode-ci-test >/dev/null 2>&1 || true
	@echo "==== Docker CI Complete ===="
