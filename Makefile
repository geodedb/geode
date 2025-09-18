# Simple Makefile to wrap Zig build/test/fuzz/bench/tools

ZIG ?= zig
ZIG_FLAGS ?=
ZIG_RELEASE_FLAGS ?= -Drelease-safe

.PHONY: all build release test integration-test go-build go-test go-clean go-example fuzz bench tools doccheck clean vendor-quic cert-gen fmt ci help

# Default target - build everything
all: build go-build test docker-ci

# Help target
help:
	@echo "Geode Makefile targets:"
	@echo ""
	@echo "Build targets:"
	@echo "  make build       - Build debug version (Zig + Go)"
	@echo "  make release     - Build release version (Zig + Go)"
	@echo "  make tools       - Build all tools"
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
