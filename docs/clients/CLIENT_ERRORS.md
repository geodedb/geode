## Client error tracking

- Updated Rust QUIC client to mirror the Python/Go protocol (newline-delimited HELLO/RUN_GQL/PULL on a persistent stream), added hostname resolution, and hardened timeouts/retries. Basic spec now passes fully via `python3 clients/test-harness/run_tests.py --clients rust --spec specs/basic.yaml`.
- Harness fix: per-test YAMLs now include spec-level setup/cleanup for all runners. This removed cross-test contamination and fixed the `transaction-with-parameters` failures across Python/Go/Rust (verified with `python3 clients/test-harness/run_tests.py --clients python,go,rust --spec specs/transactions.yaml`).
- Zig client is now passing natively with the vendor/quic transport (no delegation). `clients/test-harness/runners/zig_runner_new.zig` uses the Zig client directly and all suites pass via `make clean && make test-comprehensive`.
- Root Makefile now runs the client test harness comprehensive suite as part of both `make all` and `make geodetestlab` to keep client parity in the default workflows.
- Latest comprehensive run (`make clean && make test-comprehensive` inside `clients/test-harness`) passes across all clients (49/51 per client with 2 skips, 0 errors) and writes `clients/test-harness/reports/results.json`.
- Client cleanup: removed obsolete backup/build artifacts (old Zig runner/build scripts and legacy Rust client backups), trimmed debugging noise from the Zig vendor/quic client, and refactored the Zig test runner argument parsing into a reusable config struct for cleaner modularity.
- Vendor/quic fix: capture the server SCID when processing Initial packets on the client so short-header packets use a non-zero DCID; added trace guards to the QUIC connection code to silence noisy debug prints.
- Latest comprehensive run (`cd clients/test-harness && make test-comprehensive`) now passes across all clients with 0 failures/errors (49/51 per client, 2 skips each) after the DCID fix; reports at `clients/test-harness/reports/results.json`.
