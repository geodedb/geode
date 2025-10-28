.PHONY: help setup test test-python test-go test-rust test-zig test-all clean build-all build-go build-rust build-zig report-html test-all-html test-auth test-perf analyze-perf analyze-coverage test-with-coverage

help:
	@echo "Client Library Test Harness"
	@echo ""
	@echo "Available targets:"
	@echo "  setup            - Install dependencies and build all runners"
	@echo "  build-all        - Build all language runners"
	@echo "  build-go         - Build Go runner"
	@echo "  build-rust       - Build Rust runner"
	@echo "  build-zig        - Build Zig runner"
	@echo "  test             - Run basic tests on all clients"
	@echo "  test-python      - Run tests on Python client only"
	@echo "  test-go          - Run tests on Go client only"
	@echo "  test-rust        - Run tests on Rust client only"
	@echo "  test-zig         - Run tests on Zig client only"
	@echo "  test-all         - Run all test suites on all clients (JSON report)"
	@echo "  test-all-html    - Run all tests and generate HTML report"
	@echo "  test-auth        - Run authentication tests"
	@echo "  test-perf        - Run performance benchmarks"
	@echo "  test-with-coverage - Run tests and generate coverage report"
	@echo "  report-html      - Generate HTML report from existing JSON results"
	@echo "  analyze-perf     - Analyze performance results"
	@echo "  analyze-coverage - Analyze test coverage across clients"
	@echo "  clean            - Remove build artifacts"
	@echo ""
	@echo "Usage:"
	@echo "  make setup"
	@echo "  make test SERVER=localhost:8443"
	@echo "  make test-python SPEC=specs/basic.yaml"
	@echo "  make test-all-html"
	@echo "  make test-with-coverage"
	@echo "  make analyze-coverage REPORT=reports/results.json"

setup:
	@echo "Setting up client test harness..."
	@echo "Checking Python dependencies..."
	@if [ -n "$$NIX_BUILD_TOP" ] || [ -n "$$GEODE_NIX_BUILD" ]; then \
		echo "Nix environment detected - dependencies should be pre-installed"; \
		echo "Checking for required packages..."; \
		python3 -c "import yaml; import asyncio" 2>/dev/null || { \
			echo "WARNING: Missing dependencies. Please exit and re-enter the nix shell:"; \
			echo "  exit"; \
			echo "  nix develop"; \
			exit 1; \
		}; \
	else \
		echo "Installing dependencies via pip..."; \
		if command -v pip3 >/dev/null 2>&1; then \
			pip3 install -r requirements.txt 2>/dev/null || python3 -m pip install -r requirements.txt --user; \
		elif command -v pip >/dev/null 2>&1; then \
			pip install -r requirements.txt 2>/dev/null || python3 -m pip install -r requirements.txt --user; \
		else \
			python3 -m pip install -r requirements.txt --user; \
		fi; \
	fi
	@echo "Making scripts executable..."
	@chmod +x runners/python_runner.py 2>/dev/null || true
	@chmod +x run_tests.py 2>/dev/null || true
	@chmod +x generate_html_report.py 2>/dev/null || true
	@chmod +x analyze_performance.py 2>/dev/null || true
	@chmod +x analyze_coverage.py 2>/dev/null || true
	@echo "Building language runners..."
	@$(MAKE) build-all
	@echo "✓ Setup complete!"

build-all:
	@echo "Building available language runners..."
	@$(MAKE) build-go || echo "⚠ Go runner build skipped (go not available)"
	@$(MAKE) build-rust || echo "⚠ Rust runner build skipped (cargo not available)"
	@$(MAKE) build-zig || echo "⚠ Zig runner build skipped (zig not available)"
	@echo "✓ Build complete (available runners built)"

build-go:
	@echo "Building Go runner..."
	@command -v go >/dev/null 2>&1 || { echo "Go not found, skipping"; exit 1; }
	@cd runners && go mod tidy && go build -o go_runner go_runner.go

build-rust:
	@echo "Building Rust runner (this may take a minute)..."
	@command -v cargo >/dev/null 2>&1 || { echo "Cargo not found, skipping"; exit 1; }
	@cd runners/rust_runner && cargo build --release

build-zig:
	@echo "Building Zig runner..."
	@command -v zig >/dev/null 2>&1 || { echo "Zig not found, skipping"; exit 1; }
	@cd runners && zig build

test: setup
	@echo "Running basic tests on all clients..."
	python3 run_tests.py --spec specs/basic.yaml --verbose

test-python: setup
	@echo "Running tests on Python client..."
	python3 run_tests.py --clients python --verbose

test-go: setup
	@echo "Running tests on Go client..."
	python3 run_tests.py --clients go --verbose

test-rust: setup
	@echo "Running tests on Rust client..."
	python3 run_tests.py --clients rust --verbose

test-zig: setup
	@echo "Running tests on Zig client..."
	python3 run_tests.py --clients zig --verbose

test-all: setup
	@echo "Running all test suites on all clients..."
	python3 run_tests.py --verbose --report-json reports/results.json

test-transactions: setup
	@echo "Running transaction tests..."
	python3 run_tests.py --spec specs/transactions.yaml --verbose

test-connections: setup
	@echo "Running connection tests..."
	python3 run_tests.py --spec specs/connections.yaml --verbose

clean:
	@echo "Cleaning build artifacts..."
	rm -f runners/go_runner
	rm -rf runners/rust_runner/target
	rm -rf runners/zig-out
	rm -rf reports/*.json
	rm -rf reports/*.html
	@echo "Clean complete!"

# Server management
start-server:
	@echo "Starting Geode server..."
	@cd ../../.. && ./zig-out/bin/geode serve --listen 0.0.0.0:8443 &
	@sleep 3
	@echo "Server started on port 8443"

stop-server:
	@echo "Stopping Geode server..."
	@pkill -f "geode serve" || true
	@echo "Server stopped"

# Reporting
test-all-html: setup
	@echo "Running all tests and generating HTML report..."
	@mkdir -p reports
	python3 run_tests.py --verbose --report-json reports/results.json --report-html reports/test_report.html
	@echo ""
	@echo "Reports generated:"
	@echo "  JSON: reports/results.json"
	@echo "  HTML: reports/test_report.html"

report-html:
	@echo "Generating HTML report from JSON results..."
	@mkdir -p reports
	python3 generate_html_report.py ${REPORT:-reports/results.json} --output reports/test_report.html
	@echo "HTML report generated: reports/test_report.html"

# Authentication tests
test-auth: setup
	@echo "Running authentication tests..."
	python3 run_tests.py --spec specs/auth.yaml --verbose

# Performance benchmarking
test-perf: setup
	@echo "Running performance benchmarks..."
	@mkdir -p reports
	python3 run_tests.py --spec specs/performance.yaml --verbose --report-json reports/perf_results.json

analyze-perf:
	@echo "Analyzing performance results..."
	python3 analyze_performance.py reports/perf_results.json --verbose --markdown reports/perf_report.md
	@echo "Performance analysis complete!"
	@echo "  Report: reports/perf_report.md"

# Coverage analysis
analyze-coverage:
	@echo "Analyzing test coverage..."
	python3 analyze_coverage.py ${REPORT:-reports/results.json} --verbose --markdown reports/coverage_report.md
	@echo "Coverage analysis complete!"
	@echo "  Report: reports/coverage_report.md"

test-with-coverage: setup
	@echo "Running all tests with coverage analysis..."
	@mkdir -p reports
	python3 run_tests.py --verbose --report-json reports/results.json
	python3 analyze_coverage.py reports/results.json --verbose --markdown reports/coverage_report.md
	@echo ""
	@echo "Coverage report generated: reports/coverage_report.md"
