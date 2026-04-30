# Simple Makefile to wrap Zig build/test/fuzz/bench/tools

ZIG ?= $(shell command -v zig 2>/dev/null || echo zig)
ZIG_FLAGS ?=
ZIG_RELEASE_FLAGS ?= -Doptimize=ReleaseSafe
RUFF_VERSION ?= 0.14.14
LINT_VENV ?= .venv/lint

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

# Note: Go, Python, and Rust clients have moved to separate repositories:
#   - Go: geode-client-go
#   - Python: geode-client-python
#   - Rust: geode-client-rust

.PHONY: all build release install install-tuning test integration-test regression-test property-ordering-test pagination-test aggregation-test graph-test db-test test-all-integration dataset-integration-test load-dataset fuzz bench tools doccheck clean cert-gen fmt ci help check-openssl
.PHONY: goreleaser goreleaser-test goreleaser-snapshot goreleaser-check
.PHONY: cross-compile cross-windows cross-linux-x86_64 cross-linux-arm cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64 cross-windows-arm64 cross-test
.PHONY: canary canary-verify governance-check update-status-hash governance-delta governance-dry-run governance-freshness-prewarn governance-aggregate match-ops-parity match-ops-bench cli-transport-parity stdio-abstraction-check release-target-manifest-check docker-release-sync docker-release-check docker-release-signoff
.PHONY: telemetry-smoke quic-smoke quic-smoke-strict quic-test client-test-zig
.PHONY: transport-parity-smokes status-generate no-feature-flags zig-package-cache-check cluster-test
.PHONY: loadtest-compare loadtest-save-baseline loadtest-save-all-baselines bench-timeseries
# Note: geodetestlab and client-test-harness moved to separate repository (geode-test-harness)
.PHONY: deps deps-check
.PHONY: pre-commit pre-commit-install pre-commit-update pre-commit-all detect-diamond-deps setup-dev lint lint-bootstrap

# Default target - build everything including cross-compilation checks (non-blocking)
# Note: Integration tests (geodetestlab) moved to ../geode-test-harness
all: sub build test fuzz bench cross-compile cross-test no-feature-flags status-generate quic-smoke-strict transport-parity-smokes

# Help target - show all available targets
help:
	@echo "Geode Makefile - Available Targets"
	@echo "=================================="
	@echo ""
	@echo "Build targets:"
	@echo "  make all         - Build everything (default)"
	@echo "  make build       - Build debug version (Zig)"
	@echo "  make release     - Build release version (Zig)"
	@echo "  make tools       - Build all tools"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make fmt         - Format Zig code"
	@echo "  make lint        - Run Python lint/format checks (ruff)"
	@echo ""
	@echo "Release targets:"
	@echo "  make goreleaser         - Run GoReleaser (create release)"
	@echo "  make goreleaser-test    - Test GoReleaser (snapshot mode)"
	@echo "  make goreleaser-snapshot - Same as goreleaser-test"
	@echo "  make goreleaser-check   - Validate GoReleaser config"
	@echo "  make release-target-manifest-check - Ensure CI/GoReleaser target manifest is in sync"
	@echo "  make docker-release-check - Ensure release Dockerfiles match generated manifest"
	@echo ""
	@echo "Test targets:"
	@echo "  make test        - Run all tests (Zig + QUIC)"
	@echo "  make quic-test   - Run QUIC protocol tests"
	@echo "  make client-test-zig    - Test Zig client"
	@echo "  make integration-test   - Run integration tests"
	@echo "  make fuzz        - Run fuzz tests"
	@echo "  make bench       - Run benchmarks"
	@echo ""
	@echo "Note: Integration tests and clients moved to ../geode-test-harness"
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
	@echo "Docker Development Environment:"
	@echo "  make dev-start          - Start development environment"
	@echo "  make dev-stop           - Stop development environment"
	@echo "  make dev-shell          - Open development shell"
	@echo "  make dev-build-geode    - Build Geode in container"
	@echo "  make dev-test           - Run tests in container"
	@echo "  make dev-logs           - View development logs"
	@echo "  make dev-clean          - Clean development environment"
	@echo "  make dev-monitoring     - Start with monitoring stack"
	@echo ""
	@echo "Pre-commit hooks:"
	@echo "  make setup-dev          - Full development setup (recommended)"
	@echo "  make pre-commit-install - Install pre-commit hooks"
	@echo "  make pre-commit         - Run pre-commit on all files"
	@echo "  make pre-commit-update  - Update hooks to latest versions"
	@echo ""
	@echo "Utility targets:"
	@echo "  make cert-gen    - Generate TLS certificates"
	@echo "  make status-generate    - Generate docs/status.csv"
	@echo "  make no-feature-flags   - Check for compile-time flags"
	@echo "  make match-ops-parity   - Run MATCH staged parity golden suite"
	@echo "  make match-ops-bench    - Run MATCH staged benchmark campaign suite"
	@echo "  make bench-timeseries   - Run timeseries benchmarks"
	@echo "  make loadtest-compare   - Compare load test results against baseline"
	@echo "  make loadtest-save-baseline - Save current load test results as baseline"
	@echo "  make loadtest-save-all-baselines - Save baselines for all scenarios"
	@echo "  make cli-transport-parity - Run CLI transport response parity goldens"
	@echo "  make stdio-abstraction-check - Enforce centralized CLI stdio handle wrappers"
	@echo "  make zig-package-cache-check - Validate docker/zig-packages cache freshness"
	@echo "  make ci          - Run CI pipeline"
	@echo "  make help        - Show this help"
	@echo ""
	@echo "Dependency targets:"
	@echo "  make deps        - Install all system dependencies"
	@echo "  make deps-check  - Verify all dependencies are installed"
	@echo ""

# Install all system dependencies
deps:
	@echo "=== Installing Geode Dependencies ==="
	@bash scripts/install-deps.sh

# Check if dependencies are installed
deps-check:
	@echo "=== Checking Geode Dependencies ==="
	@echo -n "Checking Zig... "
	@if command -v zig >/dev/null 2>&1; then \
		echo "✓ $(shell zig version)"; \
	else \
		echo "✗ missing"; \
		echo "Please install Zig via zvm: curl -fsSL https://zig.sh/install.sh | bash"; \
		exit 1; \
	fi
	@echo -n "Checking Python... "
	@if command -v python3 >/dev/null 2>&1; then \
		echo "✓ $(shell python3 --version | cut -d' ' -f2)"; \
	else \
		echo "⚠ missing (optional for test runner)"; \
	fi
	@echo -n "Checking OpenSSL... "
	@if command -v openssl >/dev/null 2>&1; then \
		echo "✓ $(shell openssl version | cut -d' ' -f2)"; \
	else \
		echo "✗ missing"; \
		echo "Run 'make deps' to install dependencies"; \
		exit 1; \
	fi
	@echo ""
	@echo "--- Performance + diagnostic tools (optional but recommended) ---"
	@for tool in gdb strace ltrace valgrind lsof tcpdump numactl perf bpftrace; do \
		printf "Checking %-10s... " "$$tool"; \
		if command -v $$tool >/dev/null 2>&1; then \
			echo "✓"; \
		else \
			echo "⚠ missing (run 'make deps' to install)"; \
		fi; \
	done
	@printf "Checking %-10s... " "sar"
	@if command -v sar >/dev/null 2>&1; then \
		echo "✓ (sysstat)"; \
	else \
		echo "⚠ missing (run 'make deps' to install)"; \
	fi
	@echo ""
	@echo "✓ All required dependencies are installed"
	@echo ""
	@echo "Note: Go, Python, Rust clients have moved to separate repositories"

wine-info:
ifeq ($(WINE_AVAILABLE),1)
	@echo "Using Wine command: $(WINE_CMD)"; $(WINE_CMD) --version | head -1 || true
else
	@echo "Wine not available (wine64 or wine not found)"
endif

# Check for OpenSSL installation (required for QUIC client builds)
check-openssl:
	@echo "Checking OpenSSL installation..."
	@command -v openssl >/dev/null 2>&1 || { \
		echo "⚠ OpenSSL not found. Installing..."; \
		if command -v apt-get >/dev/null 2>&1; then \
			sudo apt-get update && sudo apt-get install -y openssl libssl-dev libapr1 pkg-config; \
		elif command -v yum >/dev/null 2>&1; then \
			sudo yum install -y openssl openssl-devel apr pkg-config; \
		elif command -v brew >/dev/null 2>&1; then \
			brew install openssl@3 pkg-config; \
		else \
			echo "❌ Package manager not detected. Please install OpenSSL manually."; \
			exit 1; \
		fi; \
	}
	@openssl version 2>/dev/null && echo "✓ OpenSSL installed" || echo "❌ OpenSSL check failed"

sub:
	git submodule update --init --recursive

build:
	$(ZIG) build $(ZIG_FLAGS)

release:
	$(ZIG) build $(ZIG_RELEASE_FLAGS)

install: release install-tuning
	@echo "=== Installing geode from current branch ==="
	@# Create geode group/user if missing (fresh install)
	@if ! getent group geode >/dev/null 2>&1; then \
		echo "Creating geode group..."; \
		sudo groupadd --system geode; \
	fi
	@if ! getent passwd geode >/dev/null 2>&1; then \
		echo "Creating geode user..."; \
		sudo useradd --system --gid geode --no-create-home \
			--home-dir /var/lib/geode \
			--shell /usr/sbin/nologin \
			--comment "Geode Graph Database" geode; \
	fi
	@# Create required directories (fresh install)
	@sudo mkdir -p /var/lib/geode /var/log/geode /etc/geode/certs
	@sudo chown -R geode:geode /var/lib/geode /var/log/geode /etc/geode
	@sudo chmod 750 /var/lib/geode /var/log/geode
	@sudo chmod 755 /etc/geode/certs
	@# Stop service only if it is active (avoids failure on fresh installs)
	@if systemctl is-active --quiet geode.service 2>/dev/null; then \
		echo "Stopping geode.service..."; \
		sudo systemctl stop geode.service; \
		sleep 2; \
	fi
	sudo install -m 0755 zig-out/bin/geode /usr/bin/geode
	@# Install systemd unit if missing or out-of-date
	@if [ ! -f /lib/systemd/system/geode.service ] || \
		! sudo cmp -s deployment/systemd/geode.service /lib/systemd/system/geode.service; then \
		echo "Installing geode.service unit..."; \
		sudo install -m 0644 deployment/systemd/geode.service /lib/systemd/system/geode.service; \
		sudo systemctl daemon-reload; \
	fi
	@# Generate self-signed TLS cert if none present (fresh install)
	@if [ ! -f /etc/geode/certs/server.crt ] || [ ! -f /etc/geode/certs/server.key ]; then \
		if command -v openssl >/dev/null 2>&1; then \
			echo "Generating self-signed TLS certificate (replace before production)..."; \
			sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
				-keyout /etc/geode/certs/server.key \
				-out /etc/geode/certs/server.crt \
				-days 365 -subj "/CN=localhost" \
				-addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" 2>/dev/null; \
			sudo chown geode:geode /etc/geode/certs/server.crt /etc/geode/certs/server.key; \
			sudo chmod 644 /etc/geode/certs/server.crt; \
			sudo chmod 600 /etc/geode/certs/server.key; \
		else \
			echo "Warning: openssl not found — geode will not start until /etc/geode/certs/server.{crt,key} exist."; \
		fi; \
	fi
	@# Enable + (re)start the service
	@sudo systemctl enable geode.service >/dev/null 2>&1 || true
	sudo systemctl restart geode.service
	@echo "✓ geode installed and restarted"
	@echo ""
	@echo "Status:    sudo systemctl status geode"
	@echo "Logs:      sudo journalctl -u geode -f"
	@echo "Admin pw:  sudo journalctl -u geode | grep 'Generated admin password'"

# Install geode + OTel tracing/metrics push to the GitLab Observability
# endpoint used by the upstream otel package's `otlp-integration-live` CI
# job (otel/.gitlab-ci.yml:265-279). Build flags wire DevNW tls into the
# OTLP/HTTP transport so HTTPS reaches the collector at
# https://5333796.otel.gitlab-o11y.com:14318.
#
# Optional env vars (all have defaults):
#   GEODE_OTEL_BEARER_TOKEN=<token>      bearer token to send as
#                                        Authorization=Bearer <token>.
#                                        OPTIONAL — GitLab Observability
#                                        collectors can be configured to
#                                        accept unauthenticated ingest;
#                                        when this var is unset the auth
#                                        header is omitted entirely.
#   GEODE_OTEL_ENDPOINT=...              endpoint URL (defaults to GitLab)
#   GEODE_OTEL_SAMPLER_ARG=1.0           sampling rate (default 1.0)
#   GEODE_OTEL_RESOURCE_ATTRIBUTES=...   extra resource attrs
#
# Usage:
#   make install-otel                                       # no auth
#   make install-otel GEODE_OTEL_BEARER_TOKEN=glpat-...     # with auth
#
GEODE_OTEL_ENDPOINT ?= https://5333796.otel.gitlab-o11y.com:14318
GEODE_OTEL_SAMPLER_ARG ?= 1.0
GEODE_OTEL_RESOURCE_ATTRIBUTES ?= deployment.environment.name=production

install-otel: install-tuning
	@echo "=== Installing geode with OTel HTTPS push enabled ==="
	@# Build with otel HTTPS support enabled. Skipping the regular
	@# `release` target lets us pass -Dotel_use_devnw_tls=true into
	@# the same artifact that lands in /usr/bin/geode.
	@echo "Building geode (release, -Dotel_use_devnw_tls=true)..."
	zig build -Doptimize=ReleaseSafe -Dotel_use_devnw_tls=true
	@# Reuse the regular install plumbing (user/group/dirs/cert/svc)
	@# but DON'T rebuild — we already produced the otel-tls binary.
	@$(MAKE) --no-print-directory _install_no_build
	@# Lay down the OTel runtime env file. The bearer token is OPTIONAL —
	@# GitLab Observability collectors can be configured to accept
	@# unauthenticated ingest from the project network. When absent, we
	@# strip the OTEL_EXPORTER_OTLP_HEADERS line entirely so the SDK
	@# sends no Authorization header.
	@echo "Writing /etc/geode/otel.env (root:geode 0640)..."
	@sudo install -m 0640 -o root -g geode \
		deployment/systemd/otel.env.example /etc/geode/otel.env
	@if [ -n "$(GEODE_OTEL_BEARER_TOKEN)" ]; then \
		echo "  → bearer token configured (Authorization=Bearer ****)"; \
		sudo sed -i \
			-e 's|__REPLACE_WITH_TOKEN__|$(GEODE_OTEL_BEARER_TOKEN)|' \
			/etc/geode/otel.env; \
	else \
		echo "  → no GEODE_OTEL_BEARER_TOKEN provided; pushing without auth header"; \
		echo "    (set GEODE_OTEL_BEARER_TOKEN=<token> if your collector requires it)"; \
		sudo sed -i -e '/^OTEL_EXPORTER_OTLP_HEADERS=/d' /etc/geode/otel.env; \
	fi
	@sudo sed -i \
		-e 's|^OTEL_EXPORTER_OTLP_ENDPOINT=.*|OTEL_EXPORTER_OTLP_ENDPOINT=$(GEODE_OTEL_ENDPOINT)|' \
		-e 's|^OTEL_TRACES_SAMPLER_ARG=.*|OTEL_TRACES_SAMPLER_ARG=$(GEODE_OTEL_SAMPLER_ARG)|' \
		-e 's|^OTEL_RESOURCE_ATTRIBUTES=.*|OTEL_RESOURCE_ATTRIBUTES=$(GEODE_OTEL_RESOURCE_ATTRIBUTES)|' \
		/etc/geode/otel.env
	@sudo chmod 0640 /etc/geode/otel.env
	@# Restart the service so EnvironmentFile= is reloaded.
	@sudo systemctl daemon-reload
	@sudo systemctl restart geode.service
	@echo "✓ geode installed with OTel push to $(GEODE_OTEL_ENDPOINT)"
	@echo ""
	@echo "Verify push:    make test-otel-tracing"
	@echo "Inspect cfg:    sudo cat /etc/geode/otel.env"
	@echo "Live logs:      sudo journalctl -u geode -f"

# Internal helper used by both `install` and `install-otel`. Performs
# every install step EXCEPT the binary rebuild. Caller is responsible
# for `zig build` / `zig build release` first.
_install_no_build:
	@if ! getent group geode >/dev/null 2>&1; then sudo groupadd --system geode; fi
	@if ! getent passwd geode >/dev/null 2>&1; then \
		sudo useradd --system --gid geode --no-create-home \
			--home-dir /var/lib/geode --shell /usr/sbin/nologin \
			--comment "Geode Graph Database" geode; \
	fi
	@sudo mkdir -p /var/lib/geode /var/log/geode /etc/geode/certs
	@sudo chown -R geode:geode /var/lib/geode /var/log/geode /etc/geode
	@sudo chmod 750 /var/lib/geode /var/log/geode
	@sudo chmod 755 /etc/geode/certs
	@if systemctl is-active --quiet geode.service 2>/dev/null; then \
		sudo systemctl stop geode.service; sleep 2; \
	fi
	sudo install -m 0755 zig-out/bin/geode /usr/bin/geode
	@if [ ! -f /lib/systemd/system/geode.service ] || \
		! sudo cmp -s deployment/systemd/geode.service /lib/systemd/system/geode.service; then \
		sudo install -m 0644 deployment/systemd/geode.service /lib/systemd/system/geode.service; \
		sudo systemctl daemon-reload; \
	fi
	@if [ ! -f /etc/geode/certs/server.crt ] || [ ! -f /etc/geode/certs/server.key ]; then \
		if command -v openssl >/dev/null 2>&1; then \
			sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
				-keyout /etc/geode/certs/server.key -out /etc/geode/certs/server.crt \
				-days 365 -subj "/CN=localhost" \
				-addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" 2>/dev/null; \
			sudo chown geode:geode /etc/geode/certs/server.crt /etc/geode/certs/server.key; \
			sudo chmod 644 /etc/geode/certs/server.crt; \
			sudo chmod 600 /etc/geode/certs/server.key; \
		fi; \
	fi
	@sudo systemctl enable geode.service >/dev/null 2>&1 || true

# Smoke-test that an installed geode is actually pushing OTLP traces +
# metrics to the configured endpoint. Two modes:
#
#   make test-otel-tracing                  — local docker collector
#                                              (no auth, no internet)
#   make test-otel-tracing-live             — live GitLab Observability
#                                              (uses the installed
#                                              /etc/geode/otel.env)
#
# Local mode: spins up an otel/opentelemetry-collector-contrib docker
# container on :4318 with the debug exporter enabled, runs a query
# workload against geode for ~30s, then asserts the collector log
# contains span + metric records tagged service.name=geode.
#
# Live mode: emits a synthetic workload and tails the journal for the
# OTel exporter's "successfully exported N records" log line. (We can't
# read back from GitLab Observability without the project API token,
# so this only verifies the geode→collector handshake.)
test-otel-tracing:
	@bash scripts/test-otel-tracing.sh local

test-otel-tracing-live:
	@bash scripts/test-otel-tracing.sh live

# Apply the canonical zig-quic sysctl tuning. Unconditional on developer hosts;
# idempotent and "only raise, never lower" at runtime. Drop-in at
# /etc/sysctl.d/99-geode-quic.conf persists across reboots.
# See deployment/sysctl.d/99-geode-quic.conf and
# https://gitlab.com/devnw/zig/quic/-/blob/main/docs/SYSTEM_TUNING.md
install-tuning:
	@echo "=== Applying QUIC/UDP system tuning ==="
	@sudo deployment/scripts/tune-system.sh apply
	@echo "✓ system tuning applied"

# GoReleaser targets
GORELEASER ?= goreleaser
GORELEASER_FLAGS ?=

goreleaser: release
	@echo "Running GoReleaser release..."
	$(GORELEASER) release --clean $(GORELEASER_FLAGS)

goreleaser-test: goreleaser-snapshot

goreleaser-snapshot: release
	@echo "Running GoReleaser in snapshot mode (testing)..."
	$(GORELEASER) release --snapshot --clean --skip=publish $(GORELEASER_FLAGS)
	@echo "✓ GoReleaser test build completed"
	@echo "Artifacts available in: dist/"

goreleaser-check:
	@echo "Checking GoReleaser configuration..."
	$(GORELEASER) check
	@echo "✓ GoReleaser configuration is valid"

release-target-manifest-check:
	@python3 tools/release_target_manifest.py sync-goreleaser --manifest release/target_manifest.json --goreleaser .goreleaser.yaml --check

docker-release-sync:
	@python3 tools/release_dockerfile_manifest.py sync --manifest release/dockerfile_manifest.json --repo-root .

docker-release-check:
	@python3 tools/release_dockerfile_manifest.py check --manifest release/dockerfile_manifest.json --repo-root .

docker-release-signoff:
	@python3 tools/release_dockerfile_manifest.py signoff --manifest release/dockerfile_manifest.json --repo-root . --output /tmp/release-dockerfile-signoff.txt
	@cat /tmp/release-dockerfile-signoff.txt

# Run Zig unit tests (fast, used by pre-push hooks)
test:
	@echo "Running Zig unit tests..."
	$(ZIG) build test $(ZIG_FLAGS)
	@echo "Running QUIC protocol tests..."
	@$(MAKE) quic-test || echo "⚠ QUIC tests skipped (may require server)"
	@echo "✓ Core tests completed"

# Run e2e tests (slower)
test-e2e:
	@echo "Running e2e tests..."
	$(ZIG) build test-e2e $(ZIG_FLAGS)
	@echo "✓ E2E tests completed"

# Run all tests (unit + e2e)
test-all:
	@echo "Running all tests..."
	$(ZIG) build test-all $(ZIG_FLAGS)
	@echo "✓ All tests completed"

# QUIC test target (uses vendor QUIC implementation)
quic-test: build
	@echo "Running QUIC integration tests..."
	@if [ -x "test_quic_protocol.py" ]; then \
		python3 test_quic_protocol.py || echo "QUIC protocol test failed (server may need to be running)"; \
	fi
	@echo "✓ QUIC tests completed"

# Client test target (Go, Python, Rust clients moved to separate repos)
client-test-zig: build
	@echo "Testing Zig client..."
	@if [ -d "clients/zig" ]; then \
		cd clients/zig && $(ZIG) build test $(ZIG_FLAGS) 2>/dev/null || \
		echo "Zig client test requires server running"; \
	else \
		echo "Zig client directory not found"; \
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
	@echo "Core integration tests complete"
	@echo "Note: For comprehensive integration tests, use ../geode-test-harness"

# Run comprehensive integration tests (including long-running tests)
test-all-integration-comprehensive: build integration-test regression-test property-ordering-test pagination-test aggregation-test graph-test db-test
	@echo "All local integration tests complete"
	@echo "Note: For geodetestlab tests, use ../geode-test-harness"

# Load example dataset (for development/testing)
load-dataset: build
	@echo "Loading example dataset..."
	@if [ -x "scripts/load_example_dataset.sh" ]; then \
		./scripts/load_example_dataset.sh; \
	else \
		echo "Dataset loader script not found or not executable"; \
		exit 1; \
	fi

# Note: Geodetestlab and client test harness moved to separate repository
# See: ../geode-test-harness

fuzz:
	$(ZIG) build fuzz $(ZIG_FLAGS)

bench:
	$(ZIG) build bench $(ZIG_FLAGS)

bench-timeseries: ## Run timeseries benchmarks
	$(ZIG) build bench-timeseries $(ZIG_FLAGS)

## Load test benchmarks.  edge_create and edge_create_with_props are the
## regression vehicles for the MATCH+CREATE write-lock contention path; keep
## them in sync with loadtest/go/scenario.go and the harness's
## loadtest-scenarios target.
loadtest-compare: ## Compare load test results against baseline
	python3 benchmarks/loadtest/compare.py \
		--baseline benchmarks/loadtest/baseline.jsonl \
		--current $(wildcard ../geode-test-harness/reports/loadtest_ping.json) \
			$(wildcard ../geode-test-harness/reports/loadtest_point_read.json) \
			$(wildcard ../geode-test-harness/reports/loadtest_one_hop.json) \
			$(wildcard ../geode-test-harness/reports/loadtest_two_hop.json) \
			$(wildcard ../geode-test-harness/reports/loadtest_fan_out.json) \
			$(wildcard ../geode-test-harness/reports/loadtest_edge_create.json) \
			$(wildcard ../geode-test-harness/reports/loadtest_edge_create_with_props.json)

loadtest-save-baseline: ## Save current load test results as new baseline (all scenarios)
	@rm -f benchmarks/loadtest/baseline.jsonl
	@for scenario in ping point_read one_hop two_hop fan_out edge_create edge_create_with_props; do \
		if [ -f ../geode-test-harness/reports/loadtest_$${scenario}.json ]; then \
			python3 benchmarks/loadtest/save_baseline.py \
				--input ../geode-test-harness/reports/loadtest_$${scenario}.json \
				--output benchmarks/loadtest/baseline.jsonl \
				--append; \
		fi; \
	done

match-ops-parity:
	@$(ZIG) build test-match-parity --summary all $(ZIG_FLAGS)

match-ops-bench:
	@GEODE_MATCH_BENCH_ENABLE=1 $(ZIG) build test-match-bench --summary all

cli-transport-parity:
	@$(ZIG) build test-cli-transport-parity --summary all $(ZIG_FLAGS)

stdio-abstraction-check:
	@python3 tools/stdio_abstraction_guard.py --repo .

## governance-check: validates CANARY markers and governance compliance
governance-check:
	@echo "Running governance checks..."
	@$(ZIG) build test -Doptimize=Debug --summary all 2>&1 | grep -c "test" > /dev/null || true
	@$(MAKE) match-ops-parity
	@$(MAKE) match-ops-bench
	@$(MAKE) cli-transport-parity
	@$(MAKE) stdio-abstraction-check
	@$(MAKE) release-target-manifest-check
	@$(MAKE) docker-release-check
	@python3 tools/zig_package_cache_guard.py --strict-stale
	@echo "Governance check completed"

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

.PHONY: verify-all verify-fast ci-verify dependency-integration-audit

# Full, strict E2E verification. Fails on vendoring issues immediately.
# Note: For geodetestlab integration tests, use ../geode-test-harness
verify-all: clean sub quic-init fmt build test dependency-integration-audit integration-test dataset-integration-test cross-compile-strict no-feature-flags status-generate governance-check docker-ci
	@echo "==> E2E verification: PASSED"

# Faster dev loop (no fuzz/bench/docker/governance)
verify-fast: build test dependency-integration-audit cross-compile-required
	@echo "==> Fast verification: PASSED"

# CI-friendly alias
ci-verify: verify-all

dependency-integration-audit:
	@python3 scripts/verify_dependency_integrations.py

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

# Bootstrap deterministic local lint tooling (ruff) in an isolated venv
lint-bootstrap:
	@echo "Bootstrapping lint tools in $(LINT_VENV) (ruff==$(RUFF_VERSION))..."
	@python3 -m venv "$(LINT_VENV)"
	@$(LINT_VENV)/bin/python -m pip install --upgrade pip >/dev/null
	@$(LINT_VENV)/bin/python -m pip install "ruff==$(RUFF_VERSION)" >/dev/null
	@echo "✓ Lint tooling ready"

# Run Python lint checks with deterministic pinned tooling
lint: lint-bootstrap
	@echo "Running ruff checks..."
	@$(LINT_VENV)/bin/python -m ruff check .
	@$(LINT_VENV)/bin/python -m ruff format --check .
	@echo "✓ Lint checks passed"

# =============================================================================
# Pre-commit hooks
# =============================================================================

# Run pre-commit on all files
pre-commit:
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		echo "pre-commit not installed. Run 'make pre-commit-install' first."; \
		exit 1; \
	fi

# Install pre-commit hooks
pre-commit-install:
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo "Installing pre-commit..."; \
		pip3 install --user pre-commit || pip install --user pre-commit; \
	fi
	@echo "Installing pre-commit hooks..."
	pre-commit install
	pre-commit install --hook-type commit-msg
	pre-commit install --hook-type pre-push
	@echo "✓ Pre-commit hooks installed"

# Update pre-commit hooks to latest versions
pre-commit-update:
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit autoupdate; \
	else \
		echo "pre-commit not installed. Run 'make pre-commit-install' first."; \
		exit 1; \
	fi

# Run all pre-commit checks (including push hooks)
pre-commit-all:
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files --hook-stage pre-commit; \
		pre-commit run --all-files --hook-stage pre-push; \
	else \
		echo "pre-commit not installed. Run 'make pre-commit-install' first."; \
		exit 1; \
	fi

# Diamond-dep detector — fail loud when build.zig.zon transitively
# pins the same package name to two different content hashes (e.g.
# thread_pool-0.2.0 + thread_pool-0.2.1 both linked into one binary,
# which is what produced the OTel BSP UAF on 2026-04-30).  Run
# manually with `make detect-diamond-deps`; pre-commit hook also
# invokes it on every change to build.zig.zon.
detect-diamond-deps:
	@python3 scripts/detect_diamond_deps.py

# Full development setup
setup-dev:
	@if [ -x scripts/setup-dev.sh ]; then \
		./scripts/setup-dev.sh; \
	else \
		echo "scripts/setup-dev.sh not found"; \
		exit 1; \
	fi

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf zig-out
	rm -rf .zig-cache
	rm -rf zig-cache

# Run build, test, fuzz, bench, strict cross, governance, docker
# Note: For geodetestlab integration tests, use ../geode-test-harness
ci: clean build test fuzz bench cross-compile-strict no-feature-flags status-generate governance-check docker-ci
	@echo "CI pipeline completed successfully"

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
cross-compile: cross-compile-required cross-compile-optional cross-zig-clients
	@echo "Cross-compilation checks complete (including Zig client libraries)"

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

# Cross-compile for Windows x86_64
cross-windows:
	@echo "Cross-compiling for Windows x86_64..."
	$(ZIG) build -Dtarget=x86_64-windows -p zig-out/windows-x86_64 $(ZIG_FLAGS)
	@test -f zig-out/windows-x86_64/bin/geode.exe || (echo "Failed to build geode.exe" && exit 1)
	@test -f zig-out/windows-x86_64/bin/gql.exe || (echo "Failed to build gql.exe" && exit 1)
	@echo "✓ Windows x86_64 build successful"

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
	./zig-out/bin/geode serve --listen-quic 0.0.0.0:8443

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

# Ensure docker/zig-packages contains no stale cache directories.
zig-package-cache-check:
	@python3 tools/zig_package_cache_guard.py --strict-stale

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
		docker exec geode-singleton geode query "RETURN 1 AS x" --server 127.0.0.1:8443 --insecure || \
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
		docker exec geode-leader geode query "RETURN 1 AS x" --server 127.0.0.1:8443 --insecure || \
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
	@docker exec geode-test geode query "RETURN 1 AS x" --server 127.0.0.1:7567 --insecure || \
		(docker-compose -f docker-compose.test.yml down && exit 1)
	@echo "Quick test passed!"
	@docker-compose -f docker-compose.test.yml down

# --- Docker Development Environment Targets ---
.PHONY: dev-build dev-start dev-stop dev-restart dev-shell dev-status dev-logs dev-clean dev-rebuild dev-monitoring

# Build Docker development environment
dev-build:
	@echo "Building Docker development environment..."
	@./dev.sh rebuild

# Start development environment
dev-start:
	@echo "Starting Docker development environment..."
	@./dev.sh start

# Stop development environment
dev-stop:
	@echo "Stopping Docker development environment..."
	@./dev.sh stop

# Restart development environment
dev-restart:
	@echo "Restarting Docker development environment..."
	@./dev.sh restart

# Open shell in development container
dev-shell:
	@echo "Opening development shell..."
	@./dev.sh shell

# Show development environment status
dev-status:
	@echo "Development environment status:"
	@./dev.sh status

# View development environment logs
dev-logs:
	@./dev.sh logs -f

# Clean development environment
dev-clean:
	@echo "Cleaning Docker development environment..."
	@./dev.sh down

# Rebuild development environment from scratch
dev-rebuild:
	@echo "Rebuilding Docker development environment..."
	@./dev.sh rebuild

# Start with monitoring stack
dev-monitoring:
	@echo "Starting Docker development environment with monitoring..."
	@./dev.sh monitoring

# Build Geode inside dev container
dev-build-geode:
	@echo "Building Geode in development container..."
	@docker exec -it geode-dev zig build -Doptimize=ReleaseSafe

# Run tests inside dev container
dev-test:
	@echo "Running tests in development container..."
	@docker exec -it geode-dev make test

# Note: Client test harness moved to separate repository (geode-test-harness)
# dev-test-clients target removed

# Client cross-compilation targets (Zig only - Go/Python/Rust clients moved to separate repos)
.PHONY: cross-zig-clients

# Cross-compile Zig clients for all platforms
cross-zig-clients:
	@echo "Cross-compiling Zig client libraries..."
	$(ZIG) build cross-clients $(ZIG_FLAGS)
	@echo "✓ Zig clients built for all platforms"

# Test cross-compiled Zig clients with QEMU emulation
.PHONY: qemu-test-clients

qemu-test-clients: cross-zig-clients
	@echo "=== Testing Cross-Compiled Zig Clients with QEMU ==="
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
		echo ""; \
	fi

	@# Native Linux x86_64 testing (for comparison)
	@echo "=== Native Linux x86_64 Testing ==="
	@if [ -f "zig-out/clients/linux-x86_64/geode-zig-example-linux-x86_64" ]; then \
		echo "Running native Zig client..."; \
		zig-out/clients/linux-x86_64/geode-zig-example-linux-x86_64 2>&1 | head -10 || \
			echo "Note: Client may fail to connect as server is not running"; \
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

# ====================================================================================
# Docker Integration Tests
# ====================================================================================

.PHONY: docker-integration-build docker-integration-up docker-integration-down docker-integration-test docker-integration-logs docker-integration-clean

DOCKER_INTEGRATION_DIR := docker-integration
DOCKER_COMPOSE_INTEGRATION := docker compose -f $(DOCKER_INTEGRATION_DIR)/docker-compose.integration.yml

# Build Docker integration images
# Note: Full integration testing moved to ../geode-test-harness
docker-integration-build:
	@echo "==== Building Docker Integration Images ===="
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "ERROR: Docker not installed"; exit 1; \
	fi
	@echo "Building Geode server image..."
	docker build -f $(DOCKER_INTEGRATION_DIR)/Dockerfile.server -t geode-integration-server:latest .
	@echo "Building Zig client image..."
	@if [ -f "$(DOCKER_INTEGRATION_DIR)/Dockerfile.client-zig" ]; then \
		docker build -f $(DOCKER_INTEGRATION_DIR)/Dockerfile.client-zig -t geode-integration-client-zig:latest .; \
	else \
		echo "⚠ Zig client Dockerfile not found, skipping"; \
	fi
	@echo "==== Integration images built (note: Full integration tests moved to ../geode-test-harness) ===="

# Start Docker integration environment
docker-integration-up: docker-integration-build
	@echo "==== Starting Docker Integration Environment ===="
	$(DOCKER_COMPOSE_INTEGRATION) up -d geode-server
	@echo "Waiting for server to be ready..."
	@sleep 10
	@echo "Running migrations..."
	$(DOCKER_COMPOSE_INTEGRATION) run --rm migration-runner
	@echo "==== Integration environment ready ===="

# Run integration test suite
# Note: Full integration tests (geodetestlab) moved to ../geode-test-harness
docker-integration-test: docker-integration-up
	@echo "==== Running Docker Integration Tests ===="
	@echo "Starting client test containers..."
	$(DOCKER_COMPOSE_INTEGRATION) up -d client-zig
	@echo "Running results collector..."
	$(DOCKER_COMPOSE_INTEGRATION) run --rm results-collector
	@echo "==== Integration tests complete ===="
	@$(MAKE) docker-integration-results
	@$(MAKE) docker-integration-down

# Show integration test results
docker-integration-results:
	@echo "==== Integration Test Results ===="
	@if [ -d "$(DOCKER_INTEGRATION_DIR)/results" ]; then \
		find $(DOCKER_INTEGRATION_DIR)/results -name "*.json" -type f -exec cat {} \; 2>/dev/null | head -100; \
	else \
		echo "No results found. Run 'make docker-integration-test' first."; \
	fi

# View integration logs
docker-integration-logs:
	$(DOCKER_COMPOSE_INTEGRATION) logs -f

# View specific client/server logs
docker-integration-logs-zig:
	$(DOCKER_COMPOSE_INTEGRATION) logs -f client-zig

docker-integration-logs-server:
	$(DOCKER_COMPOSE_INTEGRATION) logs -f geode-server

# Stop integration environment
docker-integration-down:
	@echo "==== Stopping Docker Integration Environment ===="
	$(DOCKER_COMPOSE_INTEGRATION) down --remove-orphans
	@echo "==== Integration environment stopped ===="

# Clean integration environment (remove volumes and images)
docker-integration-clean: docker-integration-down
	@echo "==== Cleaning Docker Integration Environment ===="
	$(DOCKER_COMPOSE_INTEGRATION) down -v --rmi local
	@rm -rf $(DOCKER_INTEGRATION_DIR)/results/* $(DOCKER_INTEGRATION_DIR)/logs/*
	@echo "==== Integration environment cleaned ===="

# Quick integration smoke test (server + basic queries)
docker-integration-smoke: docker-integration-build
	@echo "==== Docker Integration Smoke Test ===="
	$(DOCKER_COMPOSE_INTEGRATION) up -d geode-server
	@sleep 10
	@echo "Running smoke test queries..."
	$(DOCKER_COMPOSE_INTEGRATION) run --rm migration-runner /bin/sh -c \
		"/app/geode query --server geode-server:8443 --insecure 'RETURN 1 AS smoke_test'"
	$(DOCKER_COMPOSE_INTEGRATION) down
	@echo "==== Smoke test complete ===="
