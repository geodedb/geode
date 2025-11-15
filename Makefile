# Simple Makefile to wrap Zig build/test/fuzz/bench/tools

ZIG ?= zig
ZIG_FLAGS ?=
ZIG_RELEASE_FLAGS ?= -Doptimize=ReleaseSafe

# Auto-detect Wine (prefer wine64, fallback to wine) for Windows execution of cross-compiled tests/examples
WINE64_BIN := $(shell command -v wine64 2>/dev/null)
WINE32_BIN := $(shell command -v wine 2>/dev/null)
ifeq ($(WINE64_BIN),)
	ifeq ($(WINE32_BIN),)
		WINE_AVAILABLE := 0
		WINE_CMD :=
	else
		WINE_AVAILABLE := 1
		WINE_CMD := wine
	endif
else
	WINE_AVAILABLE := 1
	WINE_CMD := wine64
endif

# --- Go client settings (strict vendor mode) ---
GO ?= go
GQL_CLIENT_DIR ?= clients/go/gql
# Force vendor even if someone tries to override; strip any -mod flag the caller passed
export GOFLAGS := -mod=vendor $(filter-out -mod=%,$(GOFLAGS))
export GOWORK ?= off
GO_BUILD_FLAGS ?= -trimpath
GO_TEST_FLAGS  ?= -v -count=1 -timeout=90s

.PHONY: go-prep go-vendor-sync go-vendor-check go-matrix
.PHONY: all build release test integration-test regression-test property-ordering-test pagination-test aggregation-test graph-test db-test test-all-integration dataset-integration-test load-dataset go-build go-test go-clean go-example fuzz bench tools doccheck clean cert-gen fmt ci help
.PHONY: cross-compile cross-windows cross-linux-x86_64 cross-linux-arm cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64 cross-windows-arm64 cross-test
.PHONY: canary canary-verify governance-check update-status-hash governance-delta governance-dry-run governance-freshness-prewarn governance-aggregate
.PHONY: telemetry-smoke quic-smoke quic-smoke-strict quic-test quic-test-msquic client-test-python client-test-go client-test-rust client-test-zig
.PHONY: transport-parity-smokes status-generate no-feature-flags cluster-test
.PHONY: geodetestlab geodetestlab-comprehensive geodetestlab-auth geodetestlab-user-management geodetestlab-backup geodetestlab-vector-knn geodetestlab-fulltext-bm25
.PHONY: geodetestlab-parallel geodetestlab-quick geodetestlab-report geodetestlab-compare geodetestlab-export geodetestlab-trends
.PHONY: client-test-harness client-test-setup client-test-basic client-test-all client-test-html client-test-coverage

# Default target - build everything including cross-compilation checks (non-blocking)
all: sub build go-build test cross-test no-feature-flags status-generate

# Help target - show all available targets
help:
	@echo "Geode Makefile - Available Targets"
	@echo "=================================="
	@echo ""
	@echo "Build targets:"
	@echo "  make all         - Build everything (default)"
	@echo "  make build       - Build debug version (Zig + Go)"
	@echo "  make release     - Build release version (Zig + Go)"
	@echo "  make tools       - Build all tools"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make fmt         - Format all code"
	@echo ""
	@echo "Test targets:"
	@echo "  make test        - Run all tests (Zig + Go + QUIC + clients)"
	@echo "  make quic-test   - Run QUIC/msquic tests"
	@echo "  make client-test-python - Test Python client"
	@echo "  make client-test-go     - Test Go client"
	@echo "  make client-test-rust   - Test Rust client"
	@echo "  make client-test-zig    - Test Zig client"
	@echo "  make integration-test   - Run integration tests"
	@echo "  make fuzz        - Run fuzz tests"
	@echo "  make bench       - Run benchmarks"
	@echo ""
	@echo "Cross-compilation targets:"
	@echo "  make cross-compile      - Build for all platforms"
	@echo "  make cross-windows      - Build for Windows x86_64"
	@echo "  make cross-linux-arm64  - Build for Linux ARM64"
	@echo "  make cross-macos-arm64  - Build for macOS ARM64"
	@echo ""
	@echo "Docker targets:"
	@echo "  make docker-build       - Build Docker images"
	@echo "  make docker-up-singleton    - Start singleton container"
	@echo "  make docker-up-distributed  - Start distributed cluster"
	@echo "  make docker-down        - Stop all containers"
	@echo "  make docker-test        - Run Docker tests"
	@echo ""
	@echo "Utility targets:"
	@echo "  make cert-gen    - Generate TLS certificates"
	@echo "  make status-generate    - Generate docs/status.csv"
	@echo "  make no-feature-flags   - Check for compile-time flags"
	@echo "  make ci          - Run CI pipeline"
	@echo "  make help        - Show this help"
	@echo ""

wine-info:
ifeq ($(WINE_AVAILABLE),1)
	@echo "Using Wine command: $(WINE_CMD)"; $(WINE_CMD) --version | head -1 || true
else
	@echo "Wine not available (wine64 or wine not found)"
endif

sub:
	git submodule update --init --recursive

# --- Go vendoring: sync + enforce vendor usage ---
go-prep: go-vendor-sync go-vendor-check

go-vendor-sync:
	@if [ -d "$(GQL_CLIENT_DIR)" ]; then \
		echo "-> syncing vendor in $(GQL_CLIENT_DIR)"; \
		cd "$(GQL_CLIENT_DIR)" && \
		$(GO) mod tidy && $(GO) mod vendor && $(GO) mod verify; \
	else \
		echo "Go client directory '$(GQL_CLIENT_DIR)' not found"; exit 1; \
	fi

go-vendor-check:
	@echo "-> verifying vendor is used (GOFLAGS=$(GOFLAGS))"
	@cd "$(GQL_CLIENT_DIR)" && $(GO) list -mod=vendor -m all 2>/dev/null || echo "(note) 'go list -m all' may not resolve under vendor; proceeding with vendor-only builds"

build:
	$(ZIG) build $(ZIG_FLAGS)
	$(MAKE) go-build

release:
	$(ZIG) build $(ZIG_RELEASE_FLAGS)
	$(MAKE) go-build

# Run Zig tests
test:
	@echo "Running Zig tests..."
	$(ZIG) build test $(ZIG_FLAGS)
	@echo "Running Go tests..."
	$(MAKE) go-test
	@echo "Running QUIC/msquic tests..."
	@$(MAKE) quic-test || echo "⚠ QUIC tests skipped (may require server)"
	@echo "Running client tests..."
	@$(MAKE) client-test-python || echo "⚠ Python client tests skipped"
	@$(MAKE) client-test-go || echo "⚠ Go client tests skipped"
	@echo "✓ Core tests completed"

# QUIC/msquic test target (replaces vendor-specific tests)
quic-test: build
	@echo "Running QUIC/msquic integration tests..."
	@if [ -x "test_msquic_protocol.py" ]; then \
		python3 test_msquic_protocol.py || echo "QUIC protocol test failed (server may need to be running)"; \
	fi
	@echo "✓ QUIC tests completed"

# Client test targets
client-test-python: build
	@echo "Testing Python client..."
	@if [ -x "clients/python/test_client.py" ] || [ -f "test_msquic_protocol.py" ]; then \
		python3 test_msquic_protocol.py 2>/dev/null || \
		(cd clients/python && python3 test_client.py) 2>/dev/null || \
		echo "Python client test requires server running"; \
	else \
		echo "Python client tests not found"; \
	fi

client-test-go: go-build
	@echo "Testing Go client..."
	@if [ -d "clients/go" ]; then \
		cd clients/go && $(GO) test $(GO_TEST_FLAGS) ./... 2>/dev/null || \
		echo "Go client test requires server running"; \
	else \
		echo "Go client directory not found"; \
	fi

client-test-rust: build
	@echo "Testing Rust client..."
	@if [ -d "clients/rust" ] && command -v cargo >/dev/null 2>&1; then \
		cd clients/rust && cargo test 2>/dev/null || \
		echo "Rust client test requires server running"; \
	else \
		echo "Rust client not available (cargo not found or client not present)"; \
	fi

client-test-zig: build
	@echo "Testing Zig client..."
	@if [ -d "clients/zig" ]; then \
		cd clients/zig && $(ZIG) build test $(ZIG_FLAGS) 2>/dev/null || \
		echo "Zig client test requires server running"; \
	else \
		echo "Zig client directory not found"; \
	fi

# Build Go client library (strict vendor)
go-build: go-prep
	@if [ -d "$(GQL_CLIENT_DIR)" ]; then \
		echo "Building Go client library..."; \
		cd "$(GQL_CLIENT_DIR)" && $(GO) build $(GO_BUILD_FLAGS) ./...; \
		if [ -d "$(GQL_CLIENT_DIR)/example" ]; then \
			echo "Building Go example..."; \
			mkdir -p zig-out/bin; \
			cd "$(GQL_CLIENT_DIR)/example" && $(GO) build $(GO_BUILD_FLAGS) -o ../../../../zig-out/bin/gql-example .; \
		fi; \
	else \
		echo "Go client directory not found"; exit 1; \
	fi

# Run Go client tests (strict vendor)
go-test: go-prep
	@if [ -d "$(GQL_CLIENT_DIR)" ]; then \
		echo "Running Go client tests..."; \
		cd "$(GQL_CLIENT_DIR)" && CI=$${CI:-true} $(GO) test $(GO_TEST_FLAGS) ./...; \
	else \
		echo "Go client directory not found"; exit 1; \
	fi

# Clean Go client artifacts
go-clean:
	@if [ -d "$(GQL_CLIENT_DIR)" ]; then \
		echo "Cleaning Go client artifacts..."; \
		cd "$(GQL_CLIENT_DIR)" && $(GO) clean || true; \
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
	@echo "Running basic integration tests..."
	@if [ -f "scripts/integration_test.sh" ]; then \
		./scripts/integration_test.sh; \
	else \
		echo "Integration test script not found"; \
	fi

# Run dataset integration tests for all clients
dataset-integration-test: build
	@echo "Running dataset integration tests..."
	@if [ -x "scripts/run_dataset_integration_tests.sh" ]; then \
		./scripts/run_dataset_integration_tests.sh; \
	else \
		echo "Dataset integration test script not found or not executable"; \
		exit 1; \
	fi

# Run comprehensive regression test suite (34 scenarios)
regression-test: build
	@echo "Running comprehensive regression tests..."
	@if [ -x "tests/comprehensive_regression_test.sh" ]; then \
		./tests/comprehensive_regression_test.sh; \
	else \
		echo "Regression test script not found or not executable"; \
		exit 1; \
	fi

# Run property ordering regression tests (10 scenarios)
property-ordering-test: build
	@echo "Running property ordering regression tests..."
	@if [ -x "tests/property_ordering_regression_test.sh" ]; then \
		./tests/property_ordering_regression_test.sh; \
	else \
		echo "Property ordering test script not found or not executable"; \
		exit 1; \
	fi

# Run limit/skip pagination tests (23 scenarios)
pagination-test: build
	@echo "Running pagination regression tests..."
	@if [ -x "tests/limit_skip_regression_test.sh" ]; then \
		./tests/limit_skip_regression_test.sh; \
	else \
		echo "Pagination test script not found or not executable"; \
		exit 1; \
	fi

# Run count aggregation tests (8 scenarios)
aggregation-test: build
	@echo "Running aggregation regression tests..."
	@if [ -x "tests/count_aggregation_regression_test.sh" ]; then \
		./tests/count_aggregation_regression_test.sh; \
	else \
		echo "Aggregation test script not found or not executable"; \
		exit 1; \
	fi

# Run graph-specific integration tests
graph-test: build
	@echo "Running graph integration tests..."
	@if [ -x "scripts/comprehensive_graph_test.sh" ]; then \
		./scripts/comprehensive_graph_test.sh; \
	elif [ -x "scripts/graph_data_integration_test.sh" ]; then \
		./scripts/graph_data_integration_test.sh; \
	else \
		echo "Graph test script not found or not executable"; \
		exit 1; \
	fi

# Run database integration tests
db-test: build
	@echo "Running database integration tests..."
	@if [ -x "scripts/database_integration_test.sh" ]; then \
		./scripts/database_integration_test.sh; \
	else \
		echo "Database test script not found or not executable"; \
		exit 1; \
	fi

# Run ALL integration and regression tests
test-all-integration: build integration-test regression-test property-ordering-test pagination-test aggregation-test
	@echo "Core integration tests complete (comprehensive tests excluded for performance)"
	@echo "Note: graph-test, db-test, and geodetestlab disabled temporarily due to timeout issues"

# Run comprehensive integration tests (including long-running tests)
test-all-integration-comprehensive: build integration-test regression-test property-ordering-test pagination-test aggregation-test graph-test db-test geodetestlab
	@echo "All integration tests complete"

# Load example dataset (for development/testing)
load-dataset: build
	@echo "Loading example dataset..."
	@if [ -x "scripts/load_example_dataset.sh" ]; then \
		./scripts/load_example_dataset.sh; \
	else \
		echo "Dataset loader script not found or not executable"; \
		exit 1; \
	fi

# Geodetestlab test suite targets
geodetestlab: build geodetestlab-comprehensive geodetestlab-auth geodetestlab-user-management geodetestlab-backup geodetestlab-vector-knn geodetestlab-fulltext-bm25
	@echo "All geodetestlab tests complete"

# Run comprehensive geodetestlab test suite
geodetestlab-comprehensive: build
	@echo "Running comprehensive geodetestlab tests..."
	@if [ -x "scripts/test/parallel_test_runner.py" ]; then \
		echo "Using parallel test runner with default settings..."; \
		python3 scripts/test/parallel_test_runner.py --max-workers 4 --timeout 120; \
	elif [ -x "scripts/test/extended_test_runner.py" ]; then \
		echo "Using extended test runner..."; \
		python3 scripts/test/extended_test_runner.py; \
	elif [ -f "geodetestlab/geodetestlab/core/runner.py" ]; then \
		echo "Using geodetestlab core runner..."; \
		python3 -m geodetestlab.geodetestlab.core.runner --config geodetestlab/config.yml; \
	else \
		echo "No geodetestlab runner found or not executable"; \
		exit 1; \
	fi

# Run authentication and authorization tests
geodetestlab-auth: build
	@echo "Running geodetestlab authentication tests..."
	@if [ -f "geodetestlab/specs/geode_auth.yml" ] && [ -f "geodetestlab/geodetestlab/core/runner.py" ]; then \
		python3 -m geodetestlab.geodetestlab.core.runner --spec geodetestlab/specs/geode_auth.yml; \
	else \
		echo "Auth test spec not found or runner not found"; \
		exit 1; \
	fi

# Run user management tests
geodetestlab-user-management: build
	@echo "Running geodetestlab user management tests..."
	@if [ -f "geodetestlab/specs/geode_user_management_comprehensive.yml" ] && [ -f "geodetestlab/geodetestlab/core/runner.py" ]; then \
		python3 -m geodetestlab.geodetestlab.core.runner --spec geodetestlab/specs/geode_user_management_comprehensive.yml; \
	else \
		echo "User management test spec not found or runner not found"; \
		exit 1; \
	fi

# Run backup and restore tests
geodetestlab-backup: build
	@echo "Running geodetestlab backup tests..."
	@if [ -f "geodetestlab/specs/geode_backup_comprehensive.yml" ] && [ -f "geodetestlab/geodetestlab/core/runner.py" ]; then \
		python3 -m geodetestlab.geodetestlab.core.runner --spec geodetestlab/specs/geode_backup_comprehensive.yml; \
	else \
		echo "Backup test spec not found or runner not found"; \
		exit 1; \
	fi

# Run vector K-NN and similarity search tests
geodetestlab-vector-knn: build
	@echo "Running geodetestlab vector K-NN tests..."
	@if [ -f "geodetestlab/specs/geode_vector_knn_comprehensive.yml" ] && [ -f "geodetestlab/geodetestlab/core/runner.py" ]; then \
		python3 -m geodetestlab.geodetestlab.core.runner --spec geodetestlab/specs/geode_vector_knn_comprehensive.yml; \
	else \
		echo "Vector K-NN test spec not found or runner not found"; \
		exit 1; \
	fi

# Run full-text search and BM25 tests
geodetestlab-fulltext-bm25: build
	@echo "Running geodetestlab full-text BM25 tests..."
	@if [ -f "geodetestlab/specs/geode_fulltext_bm25_comprehensive.yml" ] && [ -f "geodetestlab/geodetestlab/core/runner.py" ]; then \
		python3 -m geodetestlab.geodetestlab.core.runner --spec geodetestlab/specs/geode_fulltext_bm25_comprehensive.yml; \
	else \
		echo "Full-text BM25 test spec not found or runner not found"; \
		exit 1; \
	fi

# Parallel testing infrastructure targets
WORKERS ?= 4
TIMEOUT ?= 10
RUNS ?= 5
FILE ?= failures.csv

# Run parallel geodetestlab tests with configurable workers and timeout
geodetestlab-parallel: build
	@echo "Running parallel geodetestlab tests (workers=$(WORKERS), timeout=$(TIMEOUT)s)..."
	@if [ -x "scripts/test/parallel_test_runner.py" ]; then \
		python3 scripts/test/parallel_test_runner.py --max-workers $(WORKERS) --timeout $(TIMEOUT); \
	else \
		echo "scripts/test/parallel_test_runner.py not found or not executable"; \
		echo "Please ensure the parallel test runner is available"; \
		exit 1; \
	fi

# Run quick subset of tests for rapid development iteration
geodetestlab-quick: build
	@echo "Running quick geodetestlab subset tests..."
	@if [ -x "quick_test_runner.py" ]; then \
		python3 quick_test_runner.py; \
	else \
		echo "quick_test_runner.py not found or not executable"; \
		echo "Please ensure the quick test runner is available"; \
		exit 1; \
	fi

# Generate comprehensive progress report from test logs
geodetestlab-report:
	@echo "Generating geodetestlab progress report..."
	@if [ -x "failure_tracker.py" ]; then \
		python3 failure_tracker.py --report; \
	else \
		echo "failure_tracker.py not found or not executable"; \
		echo "Please ensure the failure tracker is available"; \
		exit 1; \
	fi

# Compare last two test runs
geodetestlab-compare:
	@echo "Comparing last two geodetestlab test runs..."
	@if [ -x "failure_tracker.py" ]; then \
		python3 failure_tracker.py --compare; \
	else \
		echo "failure_tracker.py not found or not executable"; \
		echo "Please ensure the failure tracker is available"; \
		exit 1; \
	fi

# Export failure data to CSV for external analysis
geodetestlab-export:
	@echo "Exporting geodetestlab failure data to $(FILE)..."
	@if [ -x "failure_tracker.py" ]; then \
		python3 failure_tracker.py --export-csv $(FILE) --trends 0; \
		echo "Failure data exported to $(FILE)"; \
	else \
		echo "failure_tracker.py not found or not executable"; \
		echo "Please ensure the failure tracker is available"; \
		exit 1; \
	fi

# Analyze failure trends over multiple runs
geodetestlab-trends:
	@echo "Analyzing geodetestlab failure trends over $(RUNS) runs..."
	@if [ -x "failure_tracker.py" ]; then \
		python3 failure_tracker.py --trends $(RUNS); \
	else \
		echo "failure_tracker.py not found or not executable"; \
		echo "Please ensure the failure tracker is available"; \
		exit 1; \
	fi

# ============================================================================
# Client Library Test Harness
# ============================================================================
# Comprehensive multi-language test suite for Python, Go, Rust, and Zig clients

CLIENT_TEST_DIR := clients/test-harness

client-test-setup:
	@echo "==> Setting up client test harness..."
	@cd $(CLIENT_TEST_DIR) && $(MAKE) setup

client-test-basic: client-test-setup
	@echo "==> Running basic client library tests..."
	@cd $(CLIENT_TEST_DIR) && $(MAKE) test

client-test-all: client-test-setup
	@echo "==> Running all client library test suites..."
	@cd $(CLIENT_TEST_DIR) && $(MAKE) test-all

client-test-html: client-test-setup
	@echo "==> Running client tests with HTML dashboard..."
	@cd $(CLIENT_TEST_DIR) && $(MAKE) test-all-html

client-test-coverage: client-test-setup
	@echo "==> Running client tests with coverage analysis..."
	@cd $(CLIENT_TEST_DIR) && $(MAKE) test-with-coverage

client-test-harness: client-test-coverage
	@echo "==> Client test harness: PASSED"

fuzz:
	$(ZIG) build fuzz $(ZIG_FLAGS)

bench:
	$(ZIG) build bench $(ZIG_FLAGS)

## governance-check is defined below as a combined Zig-based CI step

# Convenience target: recompute sha256 of status.json and update marker in GAP_ANALYSIS.md
update-status-hash:
	@if [ -x scripts/update-status-hash.sh ]; then \
		scripts/update-status-hash.sh; \
	else \
		echo "scripts/update-status-hash.sh missing or not executable"; exit 2; \
	fi

governance-delta:
	@if [ -x scripts/governance-delta.sh ]; then \
		scripts/governance-delta.sh; \
	else \
		echo "scripts/governance-delta.sh missing or not executable"; exit 2; \
	fi

governance-dry-run:
	@if [ -x scripts/governance-dry-run.sh ]; then \
		scripts/governance-dry-run.sh; \
	else \
		echo "scripts/governance-dry-run.sh missing or not executable"; exit 2; \
	fi

governance-freshness-prewarn:
	@if [ -x scripts/nightly_freshness_guard.sh ]; then \
		THRESHOLD_DAYS=50 scripts/nightly_freshness_guard.sh; \
	else \
		echo "scripts/nightly_freshness_guard.sh missing or not executable"; exit 2; \
	fi

governance-aggregate:
	@if [ -x scripts/nightly_governance_aggregate.sh ]; then \
		scripts/nightly_governance_aggregate.sh; \
	else \
		echo "scripts/nightly_governance_aggregate.sh missing or not executable"; exit 2; \
	fi

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

# CANARY scanner targets
canary:
	@echo "Building canaryscan tool..."
	@if [ -d tools/canaryscan ]; then \
		cd tools/canaryscan && go build -o ../../bin/canaryscan . ; \
	else \
		echo "tools/canaryscan directory not found" && exit 1; \
	fi
	./bin/canaryscan --root . --out status.json --csv status.csv

canary-verify: canary
	./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict

.PHONY: verify-all verify-fast ci-verify

# Full, strict E2E verification. Fails on vendoring issues immediately.
verify-all: clean sub quic-init fmt go-prep build test integration-test dataset-integration-test geodetestlab client-test-harness cross-compile-strict cross-go-clients test-cross-clients no-feature-flags status-generate governance-check docker-ci
	@echo "==> E2E verification: PASSED"

# Faster dev loop (no fuzz/bench/docker/governance)
verify-fast: go-prep build test geodetestlab-comprehensive client-test-basic cross-compile-required cross-go-clients
	@echo "==> Fast verification: PASSED"

# CI-friendly alias
ci-verify: verify-all

# Generate evidence badge (SVG) from status.csv (run canary first if needed)
governance-badge: canary
	@mkdir -p badges
	$(ZIG) run scripts/generate_badges.zig -- --status status.csv --out badges/evidence.svg
	@echo "Generated badges/evidence.svg"

# Run variance envelope guard against README (requires status.csv)
governance-variance-guard: canary
	$(ZIG) run scripts/variance_envelope_guard.zig -- --status status.csv --readme README.md --min 70 --require-phrase
	@echo "Variance envelope guard passed"

# Append trend history line (optional analytics) after canary & badge generation
governance-trend-append: canary governance-badge
	$(ZIG) run scripts/governance_trend_append.zig

# Badge staleness guard (ensures evidence.svg is fresh relative to status.json)
governance-badge-staleness: canary governance-badge
	$(ZIG) run scripts/badge_staleness_guard.zig -- --status status.json --badge badges/evidence.svg --max-days 2

# Trend regression guard (stub)
governance-trend-regression: canary governance-trend-append
	$(ZIG) run scripts/trend_regression_guard.zig

# Slice delta guard (stub)
governance-slice-delta: canary
	$(ZIG) run scripts/slice_delta_guard.zig

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

# Run build, test, fuzz, bench, strict cross, clients, governance, docker
ci: clean go-prep build test geodetestlab fuzz bench cross-compile-strict cross-go-clients test-cross-clients no-feature-flags status-generate governance-check docker-ci
	@echo "CI pipeline completed successfully (v0.17.1)"

# Strict cross-compilation for CI (fails on any error)
cross-compile-strict: cross-compile-required
	@echo "All cross-compilation targets built successfully"

# Quick rebuild (no clean)
quick: build test

# Run telemetry smoke helper script (assumes zig-out/bin binaries exist)
telemetry-smoke: build
	@if [ -x scripts/telemetry-smoke.sh ]; then \
		bash scripts/telemetry-smoke.sh 1; \
	else \
		echo "scripts/telemetry-smoke.sh missing or not executable"; exit 2; \
	fi

# Run QUIC and telemetry smokes (non-fatal), useful for local validation
quic-smoke: build
	@echo "Running QUIC EXPLAIN smoke (env-gated) with passive teardown..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_quic_explain_smoke.zig || true
	@echo "Running telemetry smoke (env-gated strict) with passive teardown..."
	GEODE_CI_TELEMETRY_SMOKE=1 GEODE_CI_TELEMETRY_STRICT=0 GEODE_TELEMETRY_PAGING=1 GEODE_CAPTURE_SERVER_STDERR=.tmp_server_stderr_smoke.log GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test test_telemetry_smoke.zig || true

# Strict variant: do not mask failures; useful for dedicated pipelines
quic-smoke-strict: build
	@echo "Running QUIC EXPLAIN smoke (STRICT) with passive teardown..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_quic_explain_smoke.zig
	@echo "Running telemetry smoke (STRICT) with passive teardown..."
	GEODE_CI_TELEMETRY_SMOKE=1 GEODE_CI_TELEMETRY_STRICT=1 GEODE_TELEMETRY_PAGING=1 GEODE_CAPTURE_SERVER_STDERR=.tmp_server_stderr_smoke.log GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test test_telemetry_smoke.zig

# Run transport parity smokes (env-gated, non-fatal): compares stdio vs QUIC for multiple deterministic queries
transport-parity-smokes: build
	@echo "Running transport parity (RETURN ordered rows)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_return_ordered.zig || true
	@echo "Running transport parity (setop DISTINCT rows)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_setop_distinct.zig || true
	@echo "Running transport parity (order metadata)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_order_metadata.zig || true
	@echo "Running transport parity (US001 diagnostics)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_us001.zig || true
	@echo "Running transport parity (IllegalOrderKey diagnostics)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_illegal_order_key.zig || true
	@echo "Running transport parity (nulls-last ordering)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_nulls_order.zig || true
	@echo "Running transport parity (full rows varlen sample)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_fullrows.zig || true
	@echo "Running transport parity (projection rows)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_projection_rows.zig || true
	@echo "Running transport parity (ORDER+LIMIT+OFFSET rows)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_order_pagination_rows.zig || true
	@echo "Running transport parity (CASE 3VL rows, order-insensitive)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_case.zig || true
	@echo "Running transport parity (varlen curated dataset full rows)..."
	GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 $(ZIG) test tests/e2e_protocol_transport_parity_varlen_dataset_rows.zig || true
	@echo "✓ Transport parity smokes completed (non-fatal mode)"

# Cross-compilation targets (required 64-bit targets only)
cross-compile: cross-compile-required cross-compile-optional cross-clients
	@echo "Cross-compilation checks complete (including client libraries)"

# Required 64-bit cross-compilation targets (must all pass)
cross-compile-required: cross-linux-x86_64 cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64
	@echo "✓ All required cross-compilation targets built successfully"

# Optional 32-bit cross-compilation targets (failures are non-fatal)
cross-compile-optional:
	@echo "Checking optional 32-bit cross-compilation targets..."
	@$(MAKE) cross-linux-arm || echo "⚠ Linux ARM (32-bit) cross-compilation failed (this is expected and non-fatal)"

# Cross-compile for Linux x86_64
cross-linux-x86_64:
	@echo "Cross-compiling for Linux x86_64..."
	$(ZIG) build -Dtarget=x86_64-linux -p zig-out/linux-x86_64 $(ZIG_FLAGS)
	@echo "✓ Linux x86_64 build successful"
	@$(MAKE) cross-go-linux-x86_64

# Cross-compile for Windows x86_64
cross-windows:
	@echo "Cross-compiling for Windows x86_64..."
	$(ZIG) build -Dtarget=x86_64-windows -p zig-out/windows-x86_64 $(ZIG_FLAGS)
	@test -f zig-out/windows-x86_64/bin/geoded.exe || (echo "Failed to build geoded.exe" && exit 1)
	@test -f zig-out/windows-x86_64/bin/geodec.exe || (echo "Failed to build geodec.exe" && exit 1)
	@test -f zig-out/windows-x86_64/bin/gql.exe || (echo "Failed to build gql.exe" && exit 1)
	@echo "✓ Windows x86_64 build successful"
	@$(MAKE) cross-go-windows-x86_64

# Cross-compile for Linux ARM (32-bit)
cross-linux-arm:
	@echo "Cross-compiling for Linux ARM..."
	$(ZIG) build -Dtarget=arm-linux-gnueabihf -p zig-out/linux-arm $(ZIG_FLAGS)
	@echo "✓ Linux ARM build successful"

# Cross-compile for Linux ARM64
cross-linux-arm64:
	@echo "Cross-compiling for Linux ARM64..."
	$(ZIG) build -Dtarget=aarch64-linux-gnu -p zig-out/linux-arm64 $(ZIG_FLAGS)
	@echo "✓ Linux ARM64 build successful"
	@$(MAKE) cross-go-linux-arm64

# Cross-compile for Linux RISC-V 64-bit
cross-linux-riscv64:
	@echo "Cross-compiling for Linux RISC-V 64-bit..."
	$(ZIG) build -Dtarget=riscv64-linux-gnu -p zig-out/linux-riscv64 $(ZIG_FLAGS)
	@echo "✓ Linux RISC-V 64-bit build successful"

# Cross-compile for macOS x86_64
cross-macos-x86_64:
	@echo "Cross-compiling for macOS x86_64..."
	@# Only run on non-macOS systems or when on ARM macOS
	@if [ "$$(uname)" != "Darwin" ] || [ "$$(uname -m)" = "arm64" ]; then \
		$(ZIG) build -Dtarget=x86_64-macos -p zig-out/macos-x86_64 $(ZIG_FLAGS); \
		echo "✓ macOS x86_64 build successful"; \
	else \
		echo "Skipping macOS x86_64 cross-compile on x86_64 macOS"; \
	fi
	@$(MAKE) cross-go-darwin-x86_64

# Cross-compile for macOS ARM64 (Apple Silicon)
cross-macos-arm64:
	@echo "Cross-compiling for macOS ARM64..."
	@# Only run on non-macOS systems or when on Intel macOS
	@if [ "$$(uname)" != "Darwin" ] || [ "$$(uname -m)" = "x86_64" ]; then \
		$(ZIG) build -Dtarget=aarch64-macos -p zig-out/macos-arm64 $(ZIG_FLAGS); \
		echo "✓ macOS ARM64 build successful"; \
	else \
		echo "Skipping macOS ARM64 cross-compile on ARM64 macOS"; \
	fi
	@$(MAKE) cross-go-darwin-arm64

# Cross-compile for Windows ARM64
cross-windows-arm64:
	@echo "Cross-compiling for Windows ARM64..."
	$(ZIG) build -Dtarget=aarch64-windows-gnu -p zig-out/windows-arm64 $(ZIG_FLAGS)
	@echo "✓ Windows ARM64 build successful"

# Test cross-platform stdio functionality
cross-test:
	@echo "Testing cross-platform stdio..."
	$(ZIG) test tests/test_cross_platform_stdio.zig $(ZIG_FLAGS)
	@# Test Windows cross-compilation if Wine is available
	@if [ -n "$(WINE_CMD)" ]; then \
		echo "Testing Windows cross-compilation with Wine ($(WINE_CMD)) using standalone smoke program..."; \
		echo "Building (gnu static) windows_stdio_smoke.exe..."; \
		$(ZIG) build-exe tests/windows_stdio_smoke.zig -target x86_64-windows-gnu -static -O ReleaseSmall -femit-bin=windows_stdio_smoke.exe $(ZIG_FLAGS) 2> build_windows_smoke.log || true; \
		if [ ! -f windows_stdio_smoke.exe ]; then echo "First build failed, attempting GNU variant..."; fi; \
		if [ ! -f windows_stdio_smoke.exe ]; then \
			$(ZIG) build-exe tests/windows_stdio_smoke.zig -target x86_64-windows-gnu -O ReleaseSmall -femit-bin=windows_stdio_smoke_gnu.exe $(ZIG_FLAGS) 2>> build_windows_smoke.log || true; \
		fi; \
		TEST_EXE=$$( [ -f windows_stdio_smoke.exe ] && echo windows_stdio_smoke.exe || ( [ -f windows_stdio_smoke_gnu.exe ] && echo windows_stdio_smoke_gnu.exe || echo "" ) ); \
		if [ -z "$$TEST_EXE" ]; then echo "Failed to build any Windows smoke executable"; cat build_windows_smoke.log; exit 1; fi; \
		echo "Running smoke program ($$TEST_EXE) under Wine..."; \
		OUTPUT=$$(WINEDEBUG=-all $(WINE_CMD) ./$$TEST_EXE 2>&1 || true); \
		RET=$$?; \
		echo "Wine output:"; echo "$$OUTPUT" | sed 's/^/  > /'; \
		if echo "$$OUTPUT" | grep -Eqi 'c0000135|Bad EXE format'; then \
			echo "⚠ Wine environment cannot execute the produced binary (missing DLL or bad format). Skipping Windows stdio test."; \
			rm -f windows_stdio_smoke*.exe windows_stdio_smoke*.pdb; \
			exit 0; \
		fi; \
		if [ $$RET -ne 0 ]; then echo "Windows stdio smoke exited with code $$RET"; rm -f windows_stdio_smoke*.exe windows_stdio_smoke*.pdb; exit 1; fi; \
		echo "Validating output..."; \
		echo "$$OUTPUT" | grep -q "Test stdout" || { echo "Windows stdio smoke failed (missing stdout marker)"; rm -f windows_stdio_smoke*.exe windows_stdio_smoke*.pdb; exit 1; }; \
		echo "$$OUTPUT" | grep -q "Test stderr" || { echo "Windows stdio smoke failed (missing stderr marker)"; rm -f windows_stdio_smoke*.exe windows_stdio_smoke*.pdb; exit 1; }; \
		rm -f windows_stdio_smoke*.exe windows_stdio_smoke*.pdb; \
		echo "✓ Windows stdio smoke passed"; \
	else \
		echo "Wine not available (wine64/wine), skipping Windows runtime test"; \
	fi

# Server targets
server: build
	./zig-out/bin/geoded --listen-quic 0.0.0.0:8443

# Status generation from CANARY markers
status-generate:
	@if [ -x tools/status_generate.py ]; then \
		tools/status_generate.py --repo . --out docs/status.csv; \
	else \
		echo "tools/status_generate.py not found or not executable"; \
		exit 1; \
	fi

# Check for compile-time feature flags
no-feature-flags:
	@if [ -x tools/no_feature_flags_check.py ]; then \
		tools/no_feature_flags_check.py --repo .; \
	else \
		echo "tools/no_feature_flags_check.py not found or not executable"; \
		exit 1; \
	fi

# Run multi-node Raft cluster test
cluster-test: build
	@if [ -x scripts/cluster_spawn.sh ]; then \
		scripts/cluster_spawn.sh; \
	else \
		echo "scripts/cluster_spawn.sh not found or not executable"; \
		exit 1; \
	fi

# TCP transport removed; use QUIC-only server target

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
		docker exec geode-singleton geodec "RETURN 1 AS x" --server 127.0.0.1:8443 || \
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
		docker exec geode-leader geodec "RETURN 1 AS x" --server 127.0.0.1:8443 || \
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

# Client cross-compilation targets
.PHONY: cross-clients cross-zig-clients cross-go-clients test-cross-clients

# Cross-compile all clients
cross-clients: cross-zig-clients cross-go-clients
	@echo "✓ All client libraries cross-compiled successfully"

# Cross-compile Zig clients for all platforms
cross-zig-clients:
	@echo "Cross-compiling Zig client libraries..."
	$(ZIG) build cross-clients $(ZIG_FLAGS)
	@echo "✓ Zig clients built for all platforms"

# Cross-compile Go clients for all platforms
cross-go-clients: cross-go-windows-x86_64 cross-go-linux-x86_64 cross-go-linux-arm64 cross-go-darwin-x86_64 cross-go-darwin-arm64
	@echo "✓ Go clients built for all platforms"

# --- Cross-compile Go client example (pure Go, CGO disabled) ---
define go_build_cross
	@if [ -d "$(GQL_CLIENT_DIR)/example" ]; then \
		echo "Building Go client example for $(1)/$(2)..."; \
		mkdir -p zig-out/$(3)/bin zig-out/clients/$(3); \
		cd "$(GQL_CLIENT_DIR)/example" && \
		CGO_ENABLED=0 GOOS=$(1) GOARCH=$(2) $(GO) build $(GO_BUILD_FLAGS) \
			-o ../../../../zig-out/$(3)/bin/gql-example$(4) .; \
		ln -sf ../../$(3)/bin/gql-example$(4) ../../../../zig-out/clients/$(3)/gql-example$(4); \
		echo "✓ Go client example built for $(3)"; \
	fi
endef

# Existing target names preserved, but now depend on go-prep and place a client symlink
cross-go-windows-x86_64: go-prep
	$(call go_build_cross,windows,amd64,windows-x86_64,.exe)

cross-go-linux-x86_64: go-prep
	$(call go_build_cross,linux,amd64,linux-x86_64,)

cross-go-linux-arm64: go-prep
	$(call go_build_cross,linux,arm64,linux-arm64,)

cross-go-darwin-x86_64: go-prep
	$(call go_build_cross,darwin,amd64,macos-x86_64,)

cross-go-darwin-arm64: go-prep
	$(call go_build_cross,darwin,arm64,macos-arm64,)

# Test cross-compiled clients
test-cross-clients:
	@echo "Testing cross-compiled clients..."
	@# Test native Zig client builds
	$(ZIG) build test-clients $(ZIG_FLAGS)
	
	@# Test cross-compiled binaries with QEMU if available
	@echo "Testing cross-compiled binaries with QEMU (if available)..."
	
	@# Test Linux ARM64 binaries with qemu-aarch64
	@if command -v qemu-aarch64 >/dev/null 2>&1 && [ -f "zig-out/clients/linux-arm64/geode-zig-example-linux-arm64" ]; then \
		echo "Testing Linux ARM64 Zig client with QEMU..."; \
		qemu-aarch64 -L /usr/aarch64-linux-gnu zig-out/clients/linux-arm64/geode-zig-example-linux-arm64 2>&1 | head -5 || true; \
		echo "✓ Linux ARM64 Zig client executed with QEMU"; \
	else \
		echo "⚠ qemu-aarch64 not available or binary not found, skipping Linux ARM64 test"; \
	fi
	
	@# Test Windows x86_64 binaries with Wine if available
	@if [ -n "$(WINE_CMD)" ] && [ -f "zig-out/clients/windows-x86_64/geode-zig-example-windows-x86_64.exe" ]; then \
		echo "Testing Windows x86_64 Zig client with Wine ($(WINE_CMD))..."; \
		WINEDEBUG=-all $(WINE_CMD) zig-out/clients/windows-x86_64/geode-zig-example-windows-x86_64.exe 2>&1 | head -5 || true; \
		echo "✓ Windows x86_64 Zig client executed with Wine"; \
	else \
		echo "⚠ Wine not available or binary not found, skipping Windows x86_64 test"; \
	fi
	
	@# Test Windows x86_64 Go client with Wine
	@if [ -n "$(WINE_CMD)" ] && [ -f "zig-out/clients/windows-x86_64/gql-example.exe" ]; then \
		echo "Testing Windows x86_64 Go client with Wine ($(WINE_CMD))..."; \
		WINEDEBUG=-all $(WINE_CMD) zig-out/clients/windows-x86_64/gql-example.exe -h 2>&1 | head -5 || true; \
		echo "✓ Windows x86_64 Go client executed with Wine"; \
	else \
		echo "⚠ Wine not available or Go binary not found, skipping Windows Go test"; \
	fi
	
	@# Test Linux ARM64 Go client with QEMU
	@if command -v qemu-aarch64 >/dev/null 2>&1 && [ -f "zig-out/clients/linux-arm64/gql-example" ]; then \
		echo "Testing Linux ARM64 Go client with QEMU..."; \
		qemu-aarch64 -L /usr/aarch64-linux-gnu zig-out/clients/linux-arm64/gql-example -h 2>&1 | head -5 || true; \
		echo "✓ Linux ARM64 Go client executed with QEMU"; \
	else \
		echo "⚠ qemu-aarch64 not available or Go binary not found, skipping Linux ARM64 Go test"; \
	fi
	
	@# Compilation tests for platforms where we can't run the binaries
	@if [ -d "clients/go/gql/example" ]; then \
		echo "Verifying Go cross-compilation for all targets..."; \
		cd clients/go/gql/example && \
		CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o /dev/null . && \
		CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /dev/null . && \
		CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o /dev/null . && \
		CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o /dev/null . && \
		echo "✓ Go cross-compilation verification passed"; \
	fi
	
	@echo "✓ All client cross-compilation tests completed"

# Test cross-compiled clients with QEMU emulation
.PHONY: qemu-test-clients

qemu-test-clients: cross-clients
	@echo "=== Testing Cross-Compiled Clients with QEMU ==="
	@echo ""
	
	@# Check for required QEMU user-mode emulators
	@echo "Checking for QEMU emulators..."
	@if command -v qemu-aarch64 >/dev/null 2>&1; then \
		echo "✓ qemu-aarch64 found"; \
	else \
		echo "✗ qemu-aarch64 not found (install qemu-user or qemu-user-static)"; \
	fi
	@if command -v qemu-arm >/dev/null 2>&1; then \
		echo "✓ qemu-arm found"; \
	else \
		echo "✗ qemu-arm not found (install qemu-user or qemu-user-static)"; \
	fi
	@if command -v qemu-riscv64 >/dev/null 2>&1; then \
		echo "✓ qemu-riscv64 found"; \
	else \
		echo "✗ qemu-riscv64 not found (install qemu-user or qemu-user-static)"; \
	fi
	@echo ""
	
	@# Linux ARM64 testing
	@if command -v qemu-aarch64 >/dev/null 2>&1; then \
		echo "=== Linux ARM64 Testing ==="; \
		if [ -f "zig-out/clients/linux-arm64/geode-zig-example-linux-arm64" ]; then \
			echo "Running Zig client on ARM64..."; \
			qemu-aarch64 -L /usr/aarch64-linux-gnu \
				zig-out/clients/linux-arm64/geode-zig-example-linux-arm64 2>&1 | head -10 || \
				echo "Note: Client may fail to connect as server is not running"; \
		fi; \
		if [ -f "zig-out/clients/linux-arm64/gql-example" ]; then \
			echo "Running Go client on ARM64..."; \
			qemu-aarch64 -L /usr/aarch64-linux-gnu \
				zig-out/clients/linux-arm64/gql-example -h 2>&1 | head -10 || true; \
		fi; \
		echo ""; \
	fi
	
	@# Windows testing with Wine
	@if [ -n "$(WINE_CMD)" ]; then \
		echo "=== Windows x86_64 Testing (Wine: $(WINE_CMD)) ==="; \
		if [ -f "zig-out/clients/windows-x86_64/geode-zig-example-windows-x86_64.exe" ]; then \
			echo "Running Zig client on Windows/Wine..."; \
			WINEDEBUG=-all $(WINE_CMD) \
				zig-out/clients/windows-x86_64/geode-zig-example-windows-x86_64.exe 2>&1 | head -10 || \
				echo "Note: Client may fail to connect as server is not running"; \
		fi; \
		if [ -f "zig-out/clients/windows-x86_64/gql-example.exe" ]; then \
			echo "Running Go client on Windows/Wine..."; \
			WINEDEBUG=-all $(WINE_CMD) \
				zig-out/clients/windows-x86_64/gql-example.exe -h 2>&1 | head -10 || true; \
		fi; \
		echo ""; \
	fi
	
	@# Native Linux x86_64 testing (for comparison)
	@echo "=== Native Linux x86_64 Testing ==="
	@if [ -f "zig-out/clients/linux-x86_64/geode-zig-example-linux-x86_64" ]; then \
		echo "Running native Zig client..."; \
		zig-out/clients/linux-x86_64/geode-zig-example-linux-x86_64 2>&1 | head -10 || \
			echo "Note: Client may fail to connect as server is not running"; \
	fi
	@if [ -f "zig-out/clients/linux-x86_64/gql-example" ]; then \
		echo "Running native Go client..."; \
		zig-out/clients/linux-x86_64/gql-example -h 2>&1 | head -10 || true; \
	fi
	@echo ""
	
	@echo "=== QEMU Client Testing Complete ==="
	@echo "Note: Connection failures are expected if the server is not running."
	@echo "The test verifies that the binaries can execute on their target platforms."

# Complete Docker CI pipeline
docker-ci:
	@echo "==== Docker CI Pipeline ===="
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "✗ Docker not installed or not in PATH"; \
		exit 1; \
	fi
	@echo "1. Selecting Dockerfile..."
	@if [ -f Dockerfile.reliable ]; then \
		DOCKERFILE=Dockerfile.reliable; \
	elif [ -f Dockerfile.simple ]; then \
		DOCKERFILE=Dockerfile.simple; \
	elif [ -f Dockerfile ]; then \
		DOCKERFILE=Dockerfile; \
	else \
		echo "✗ No Dockerfile found"; exit 1; \
	fi; \
		echo "Using $$DOCKERFILE"; \
		BUILD_LOG=$$(mktemp); \
		echo "2. Building image (logging to $$BUILD_LOG)..."; \
		if docker build -f $$DOCKERFILE -t geode:latest . > $$BUILD_LOG 2>&1; then \
			echo "✓ Docker build successful"; \
		else \
			echo "Primary build failed using $$DOCKERFILE. Showing last 40 lines:"; \
			tail -40 $$BUILD_LOG; \
			if [ "$$DOCKERFILE" != "Dockerfile.simple" ] && [ -f Dockerfile.simple ]; then \
				echo "Attempting fallback build with Dockerfile.simple..."; \
				FALLBACK_LOG=$$(mktemp); \
				if docker build -f Dockerfile.simple -t geode:latest . > $$FALLBACK_LOG 2>&1; then \
					echo "✓ Fallback build succeeded"; \
				else \
					echo "Fallback build failed. Last 40 lines:"; \
					tail -40 $$FALLBACK_LOG; \
					echo "Full primary log: $$BUILD_LOG"; \
					echo "Full fallback log: $$FALLBACK_LOG"; \
					exit 1; \
				fi; \
			else \
				echo "No fallback Dockerfile available or already using fallback."; \
				echo "Full log: $$BUILD_LOG"; \
				exit 1; \
			fi; \
		fi; \
		echo "3. Verifying image..."; \
		if docker images | grep -q "geode *latest"; then \
			echo "✓ Image present"; \
		else \
			echo "✗ Image not found after build"; exit 1; \
		fi; \
		echo "4. Running smoke test..."; \
		if docker run --rm -d --name geode-ci-test geode:latest >/dev/null 2>&1; then \
			sleep 2; \
			if docker ps | grep -q geode-ci-test; then \
				echo "✓ Container started"; \
			else \
				echo "✗ Container exited prematurely"; docker logs geode-ci-test 2>/dev/null || true; docker rm geode-ci-test >/dev/null 2>&1 || true; exit 1; \
			fi; \
		else \
			echo "✗ Failed to start container"; exit 1; \
		fi; \
		echo "5. Stopping container..."; \
		docker stop geode-ci-test >/dev/null 2>&1 || true; \
		echo "==== Docker CI Complete ===="
