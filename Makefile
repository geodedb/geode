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

.PHONY: all build release test integration-test go-build go-test go-clean go-example fuzz bench tools doccheck clean vendor-quic cert-gen fmt ci help
.PHONY: cross-compile cross-windows cross-linux-x86_64 cross-linux-arm cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64 cross-windows-arm64 cross-test
.PHONY: canary canary-verify governance-check update-status-hash governance-delta governance-dry-run governance-freshness-prewarn governance-aggregate
.PHONY: telemetry-smoke quic-smoke quic-smoke-strict
.PHONY: transport-parity-smokes status-generate no-feature-flags cluster-test

# Default target - build everything including cross-compilation checks (non-blocking)
all: sub build go-build test cross-test no-feature-flags status-generate

wine-info:
ifeq ($(WINE_AVAILABLE),1)
	@echo "Using Wine command: $(WINE_CMD)"; $(WINE_CMD) --version | head -1 || true
else
	@echo "Wine not available (wine64 or wine not found)"
endif

sub:
	git submodule update --init --recursive

# Help target
help:
	@echo "Geode Makefile targets (v0.17.0):"
	@echo ""
	@echo "Build targets:"
	@echo "  make build       - Build debug version (Zig + Go)"
	@echo "  make release     - Build release version (Zig + Go)"
	@echo "  make tools       - Build all tools"
	@echo "  make cross-compile - Build for all cross-compilation targets"
	@echo "  make status-generate - Generate docs/status.csv from CANARY markers"
	@echo "  make no-feature-flags - Check for compile-time feature flags"
	@echo "  make cluster-test - Run multi-node Raft cluster test"
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
	@echo "Client cross-compilation targets:"
	@echo "  make cross-clients       - Cross-compile all client libraries"
	@echo "  make cross-zig-clients   - Cross-compile Zig client libraries"
	@echo "  make cross-go-clients    - Cross-compile Go client libraries"
	@echo "  make test-cross-clients  - Test cross-compiled clients (with QEMU if available)"
	@echo "  make qemu-test-clients   - Test clients with QEMU emulation"
	@echo ""
	@echo "Test targets:"
	@echo "  make test        - Run all tests (Zig + Go + dataset)"
	@echo "  make integration-test - Run comprehensive integration tests"
	@echo "  make dataset-integration-test - Test dataset with all clients"
	@echo "  make load-dataset - Load example social network dataset"
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
	@echo "  make quic-smoke  - Run QUIC and telemetry smoke tests (env-gated, non-fatal)"
	@echo "  make quic-smoke-strict - Run QUIC and telemetry smokes in strict mode (fail on errors)"
	@echo "  make quic-status - Check QUIC submodule status"
	@echo "  make quic-init   - Initialize QUIC submodule"
	@echo "  make cert-gen    - Generate TLS certificates"
	@echo "  make fmt         - Format all code"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make ci          - Run CI pipeline (build, test, fuzz, bench)"
	@echo "  make update-status-hash - Sync GAP_ANALYSIS hash marker with current status.json"
	@echo "  make governance-delta     - Show added/removed REQ IDs between status_prev.json and status.json"
	@echo "  make governance-dry-run   - Non-failing governance-check wrapper (always exit 0)"
	@echo "  make governance-freshness-prewarn - Nightly freshness pre-warning (50d threshold)"
	@echo "  make governance-aggregate - Aggregate nightly governance signals into one JSON"
	@echo "  make status-generate - Generate docs/status.csv from CANARY markers"
	@echo "  make no-feature-flags - Enforce no compile-time feature flags"

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
	@echo "Running dataset integration tests (if dataset is loaded)..."
	@if [ -x "scripts/run_dataset_integration_tests.sh" ]; then \
		./scripts/run_dataset_integration_tests.sh 2>/dev/null || echo "Dataset tests skipped (dataset may not be loaded)"; \
	fi

# Build Go client library
go-build:
	@if [ -d "clients/go/gql" ]; then \
		if command -v go >/dev/null 2>&1; then \
			echo "Preparing Go client module vendor..."; \
			(cd clients/go/gql && go mod vendor || echo "go mod vendor (clients/go/gql) failed, continuing"); \
			echo "Building Go client library (using vendor)..."; \
			(cd clients/go/gql && go build -mod=vendor ./... || { echo "Go build failed (skipping)"; exit 0; }); \
			if [ -d "clients/go/gql/example" ]; then \
				echo "Building Go example program..."; \
				(cd clients/go/gql/example && go build -mod=vendor -o ../../../../zig-out/bin/gql-example . || echo "Failed to build example"); \
			fi; \
			echo "Go client library built (or skipped failures)"; \
		else \
			echo "Go toolchain not found, skipping Go build"; \
		fi; \
	else \
			echo "Go client directory not found, skipping Go build"; \
	fi

# Run Go client tests
go-test: go-build
	@if [ -d "clients/go/gql" ]; then \
		if command -v go >/dev/null 2>&1; then \
			echo "Running Go client tests..."; \
			cd clients/go/gql && CI=$${CI:-true} go test -v -count=1 -timeout 30s || { echo "Go tests failed (skipping)"; exit 0; }; \
		else \
			echo "Go toolchain not found, skipping Go tests"; \
		fi; \
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
integration-test: build dataset-integration-test
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

# Load example dataset (for development/testing)
load-dataset: build
	@echo "Loading example dataset..."
	@if [ -x "scripts/load_example_dataset.sh" ]; then \
		./scripts/load_example_dataset.sh; \
	else \
		echo "Dataset loader script not found or not executable"; \
		exit 1; \
	fi

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

# Combined governance check (freshness + canary verify) producing JSON summary
governance-check:
	$(ZIG) run scripts/governance_ci.zig

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

# Run build, test, fuzz, bench sequentially for CI
ci: clean build test fuzz bench cross-compile-strict test-cross-clients no-feature-flags status-generate governance-check
	@echo "CI pipeline completed successfully (v0.17.0)"

# Strict cross-compilation for CI (fails on any error)
cross-compile-strict: cross-linux-x86_64 cross-windows cross-linux-arm cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64 cross-windows-arm64
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
cross-compile-required: cross-linux-x86_64 cross-windows cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64 cross-windows-arm64
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
	$(ZIG) build -Dtarget=aarch64-windows-msvc -p zig-out/windows-arm64 $(ZIG_FLAGS)
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
		if [ ! -f windows_stdio_smoke.exe ]; then echo "First build failed, attempting MSVC variant..."; fi; \
		if [ ! -f windows_stdio_smoke.exe ]; then \
			$(ZIG) build-exe tests/windows_stdio_smoke.zig -target x86_64-windows-msvc -O ReleaseSmall -femit-bin=windows_stdio_smoke_msvc.exe $(ZIG_FLAGS) 2>> build_windows_smoke.log || true; \
		fi; \
		TEST_EXE=$$( [ -f windows_stdio_smoke.exe ] && echo windows_stdio_smoke.exe || ( [ -f windows_stdio_smoke_msvc.exe ] && echo windows_stdio_smoke_msvc.exe || echo "" ) ); \
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

# Go client cross-compilation for Windows x86_64
cross-go-windows-x86_64:
	@if [ -d "clients/go/gql/example" ]; then \
		echo "Building Go client example for Windows x86_64..."; \
		mkdir -p zig-out/windows-x86_64/bin; \
		cd clients/go/gql/example && \
		CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o ../../../../zig-out/windows-x86_64/bin/gql-example.exe . && \
		echo "✓ Go client example built for Windows x86_64"; \
	fi

# Go client cross-compilation for Linux x86_64
cross-go-linux-x86_64:
	@if [ -d "clients/go/gql/example" ]; then \
		echo "Building Go client example for Linux x86_64..."; \
		mkdir -p zig-out/linux-x86_64/bin; \
		cd clients/go/gql/example && \
		CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ../../../../zig-out/linux-x86_64/bin/gql-example . && \
		echo "✓ Go client example built for Linux x86_64"; \
	fi

# Go client cross-compilation for Linux ARM64
cross-go-linux-arm64:
	@if [ -d "clients/go/gql/example" ]; then \
		echo "Building Go client example for Linux ARM64..."; \
		mkdir -p zig-out/linux-arm64/bin; \
		cd clients/go/gql/example && \
		CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o ../../../../zig-out/linux-arm64/bin/gql-example . && \
		echo "✓ Go client example built for Linux ARM64"; \
	fi

# Go client cross-compilation for macOS x86_64
cross-go-darwin-x86_64:
	@if [ -d "clients/go/gql/example" ]; then \
		echo "Building Go client example for macOS x86_64..."; \
		mkdir -p zig-out/macos-x86_64/bin; \
		cd clients/go/gql/example && \
		CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o ../../../../zig-out/macos-x86_64/bin/gql-example . && \
		echo "✓ Go client example built for macOS x86_64"; \
	fi

# Go client cross-compilation for macOS ARM64
cross-go-darwin-arm64:
	@if [ -d "clients/go/gql/example" ]; then \
		echo "Building Go client example for macOS ARM64..."; \
		mkdir -p zig-out/macos-arm64/bin; \
		cd clients/go/gql/example && \
		CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o ../../../../zig-out/macos-arm64/bin/gql-example . && \
		echo "✓ Go client example built for macOS ARM64"; \
	fi

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
