# Geode Quality Audit - Phase 1 Inventory

**Generated:** 2026-04-16
**Scope:** Map the repo's quality tooling and surface area (formatters/linters/typecheckers, complexity indicators, test infrastructure, doc coverage).
**Method:** Read-only static analysis of configs, build files, and repo tree.

---

## Repo Inventory

- **Root:** `/home/benji/src/devnw/codepros/geode/geode`
- **Platform:** GitLab (`git@gitlab.com:devnw/codepros/geode/geode.git`)
- **Primary language:** Zig (pinned `0.15.1` in `build.zig.zon`, `0.15.2` in `.gitlab-ci.yml` and `protobuf` dep comment)
- **Secondary languages:** Python 3.9+ (scripts/tools), Bash (scripts/tests), Go (`tools/canaryscan/` + top-level `go.mod`/`go.sum`)
- **Frameworks / key deps:** 24 first-party Zig packages from `gitlab.com/devnw/zig/*` (uri, yaml, toml, strings, repl, vulkan, json, quic, slog, config, cli, dns, thread_pool, mcp, protobuf, grpc_zig, geode_client_zig, uuid, wal, graph_storage, raft, audit, hnsw, rtree, advanced_types, fle, gql, timeseries, auth) — pinned by commit hash in `build.zig.zon`.
- **Package managers:** Zig (`build.zig.zon`, all `.url` + `.hash` — `.path` deps banned via pre-commit), pip/pre-commit for Python tooling, Go modules for `tools/canaryscan/`.
- **Entrypoints:**
  - `src/main.zig`, `src/unified_entry.zig`, `src/cli/main.zig` (unified binary; `./zig-out/bin/geode`)
  - `src/server/main.zig` (server boot, RLS engine wiring)
  - `src/lib.zig`, `src/root.zig` (library roots)
  - `build.zig` (2801 LOC; 42 exposed build steps including `test`, `test-e2e`, `fuzz`, `bench-*`, `canary`, `doccheck`, `generate-*`)

### Scale

- `src/` Zig files: **522** / **276,334 LOC**
- `tests/` Zig files: **~868** (plus 69 shell, 1 Python) / **127,472 LOC**
- `benchmarks/*.zig`: **43** top-level + **184** `benchmark_*.zig` across the tree
- `fuzz/`: 2 harness files, corpora + dictionaries present
- Zig test blocks: **4019** in `tests/` + **2154** inside `src/` (co-located)
- CANARY markers: **~2271 occurrences across 533 files** (CLAUDE.md quotes ~2224 total)
- Makefile targets: **130** (`help` target exposes menu)
- GitLab CI top-level jobs: **~26** across 6 stages (`lint`, `governance`, `test`, `security`, `release`, `publish`)

---

## Quality Tooling

| Category | Tool | Config File | Command |
|----------|------|-------------|---------|
| Zig formatter (check) | `zig fmt --check` | `.pre-commit-config.yaml` `zig-fmt` hook + CI component `zig-format@v1.2.1` | `make fmt`; `zig fmt src/ build.zig` |
| Zig build (compile) | `zig build` | `build.zig` (42 steps) | `make build` / `make release` |
| Zig unit tests | `zig build test` | `build.zig` step `test` (line 1147) | `make test` |
| Zig e2e/integration | `zig build test-e2e`, `test-all`, `test-match-parity`, `test-cli-transport-parity`, `test-advanced-property-ga`, `test-limit-pushdown`, `test-limitations-fixes`, `test-quic-streams`, `test-thread-pool-parallel`, `test-gpu`, `canary`, `cpa_accept` | `build.zig` | `make test-all` etc. |
| Zig benchmarks | `zig build bench`, `bench-timeseries`, `bench-merge`, `bench-transport`, `bench-gpu`, `bench-quic-streams`, `bench-thread-pool-parallel`, `benchmark`, `stress`, `variance`, `delta` | `build.zig` | `make loadtest-compare`, `make loadtest-save-baseline` |
| Fuzzing | Zig native + LLVM libFuzzer | `fuzz/` (corpora, dicts, `fuzz_parser_comprehensive.zig`, `fuzz_distributed_features.zig`); build step `fuzz`; scaffolder `build.zig` step `gen-fuzz` | `zig build test --fuzz=10s`; `zig build test --fuzz=60m -- -Denable-llvm-fuzzer=true` |
| Python linter + formatter | `ruff` v0.14.14 (select: E,W,F,I,B,C4,UP,SIM; 120-col) | `pyproject.toml`, `.pre-commit-config.yaml` | `pre-commit run ruff` |
| Python typecheck | NONE detected | — | — |
| Shell linter | `shellcheck` v0.11.0.1 (`--severity=error`) | `.pre-commit-config.yaml` (broad exclude list of fixture scripts) | `pre-commit run shellcheck` |
| Markdown linter | `markdownlint-cli` v0.43.0 (disables MD013/033/041/024/060/036/051/052/055) | `.pre-commit-config.yaml` | `pre-commit run markdownlint` |
| YAML pretty-formatter | `pretty-format-yaml` v2.16.0 (2-space indent) | `.pre-commit-config.yaml` (excludes `.gitlab-ci.yml`, compose files) | `pre-commit run pretty-format-yaml` |
| Dockerfile linter | `hadolint` v2.14.0 (ignores DL3008/3013/3018/3015/4006/3042) | `.pre-commit-config.yaml` (excludes `Dockerfile.dev`) | `pre-commit run hadolint-docker` |
| Commit-msg validator | `commitizen` v4.12.1 (Conventional Commits) | `.cz.yaml` | git `commit-msg` hook |
| Secret scanner (pre-commit) | `pre-commit-hooks/detect-private-key` + `check-added-large-files` (1024 KB) | `.pre-commit-config.yaml` | `pre-commit run --all-files` |
| Secret scanner (CI) | `gitleaks` | `.gitleaks.toml` (allowlist of certs/fixtures) + CI job `security-secrets` | CI only |
| Vulnerability scan | `trivy` | CI job `security-trivy` (line 879) | CI only |
| Release/packaging | `goreleaser` v2.13.3 | `.goreleaser.yaml` + `goreleaser check` local hook | `make release` |
| Build-system hygiene | `zon-no-path-deps` local hook (bans `.path =` deps) | `.pre-commit-config.yaml` | pre-commit |
| CANARY governance | `tools/canary_lint.py`, `tools/canary_normalize.py`, `tools/status_generate.py`, `tools/canaryscan/` (Go) | `.pre-commit-config.yaml` hooks `canary-lint`, `canary-verify`, `status-csv-check`, `canaryscan-verify`; CI `governance-*` jobs (`governance-canary-drift`, `governance-canary-lint`, `governance-canaryscan-verify`, `governance-status-check`, `governance-no-feature-flags`, `governance-no-page-allocator`, `governance-stdio-abstraction`, `governance-release-manifests`, `governance-req-doc-reports`, `governance-conformance-sync`, `governance-match-ops-campaign`) | `make canary`, `make status-generate`, `make governance-check` |
| Feature-flag guard | `tools/no_feature_flags_check.py` | pre-push hook `no-feature-flags` + CI `governance-no-feature-flags` | — |
| Cross-compile check | `make cross-compile-required` (linux x86_64/arm64/riscv64, macos x86_64/arm64) | `.pre-commit-config.yaml` `cross-compile-check`; CI `test-cross-build` | `make cross-compile-strict` |
| Code coverage | CI job `test-code-coverage` (line 678) | `.gitlab-ci.yml` | CI only; no repo-side coverage config |
| GQL conformance | CI `test-gql-compliance` (line 739); `scripts/conformance_sync.zig`, `scripts/regen_conformance.zig` | — | `docs/GQL_COMPLIANCE.md` |
| Load-test regression | `benchmarks/loadtest/baseline.jsonl` + `make loadtest-compare` | CI job `loadtest-regression` (`allow_failure: true`) | `make loadtest-compare` |
| Perf benchmarks | CI `test-performance-benchmarks`, `bench-timeseries` | `benchmarks/history/`, `benchmarks/loadtest/` | `make benchmark` |
| Integration harness | `../geode-test-harness` (sibling repo, pinned `GEODE_TEST_HARNESS_REF=4631418f...`) | CI `test-harness-integration` | `make geodetestlab-comprehensive` |

### Missing / absent tooling

- **No Zig static-analysis tool beyond `zig build`** — Zig has no ecosystem equivalent of `clippy`/`golangci-lint`; the repo relies on compiler warnings plus custom governance scripts. Not a defect, but worth noting.
- **No Python type checker** (`mypy`/`pyright`/`ty`) despite ~60+ Python scripts in `scripts/` and `tools/`.
- **No dedicated duplication detector** (e.g. `jscpd`, `dupl`). Given the 7110-LOC `match_operations.zig` and 6640-LOC `parser.zig`, copy-paste risk is hand-reviewed only.
- **No cyclomatic-complexity gate** (`lizard`, `gocyclo`, etc.); `tools/modularization/` scripts reshape hotspots case-by-case.
- **No auto-generated API reference from code**; `docs/API_REFERENCE_GENERATED.md` exists but the `generate-api-docs` build step (scripts/generate_api_docs.zig) is invoked manually.
- **No SBOM generation** wired into CI (despite pinned deps + `goreleaser`).
- **Code coverage numbers not enforced**: `test-code-coverage` job exists but `docs/KNOWN_TEST_ISSUES.md` is the canonical truth (1644/1688 = 97.4%), and there's no threshold gate.
- **Zig version drift:** `build.zig.zon` pins `minimum_zig_version = "0.15.1"`, CI runs `ZIG_VERSION=0.15.2`, but recent commits (`3f06a9e1`, `339050c2`) migrated to **Zig 0.16.0** — these pins are stale and should be bumped.

---

## High-Risk Areas

Load-bearing modules where a regression has the widest blast radius:

- `src/execution/match_operations.zig` (7110 LOC, 73 changes in 3mo): MATCH/tenant-isolation path — explicit GAP-0509 closure lives here. Touching a scan or a `passesTenantFilter` site is high risk per project memory.
- `src/gql/parser.zig` (6640 LOC, 45 changes): entire ISO/IEC 39075 front end. 100% conformance hinges on this file.
- `src/graph_store.zig` (6560 LOC, 160 changes in 3mo — **the #1 churn file**): core storage state, `store_mutex` tier 1, at the centre of the lock-ordering rules in CLAUDE.md.
- `src/client/repl/repl_dispatch.zig` (5122 LOC, 74 changes): end-user surface, drives UX bugs.
- `src/eval.zig` (4517 LOC, 70 changes) + `src/exec.zig` (2731 LOC) + `src/eval_extended.zig` (2677 LOC): expression engine, ADR cites an ongoing refactor (`docs/architecture/ADR_execution_eval_refactor.md`).
- `src/cli/main.zig` (3666 LOC, 177 changes — #2 churn): CLI dispatcher, user-facing.
- `src/server/quic_connection_handler.zig` (3335 LOC, 148 changes): transport, concurrency tier 3 mutexes.
- `src/security/rls_core.zig` (3103 LOC): RLS engine — GAP-0510 closure depends on `passesRLSExprFilter` here.
- `src/execution.zig` (3035 LOC, 125 changes): dispatch/catalog mutex tier 2 — concurrency-sensitive.
- `src/storage/graph_storage_adapter.zig` (2951 LOC, 53 changes): adapter between `graph_storage` package and in-tree store; tier 0/1 lock ordering.
- `src/transport/grpc_server.zig` (2968 LOC, 61 changes): second transport, parity with QUIC.

## High-Churn Areas (commits touching file, last 3 months)

| Rank | File | Commits |
|------|------|---------|
| 1 | `src/graph_store.zig` | 160 |
| 2 | `src/cli/main.zig` | 177 (includes renames) |
| 3 | `src/server/quic_connection_handler.zig` | 148 |
| 4 | `src/execution.zig` | 125 |
| 5 | `src/execution/match_operations.zig` | 73 |
| 6 | `src/server/main.zig` | 62 |
| 7 | `src/transport/grpc_server.zig` | 61 |
| 8 | `src/client/repl/repl_dispatch.zig` | 61 |
| 9 | `src/transport/quic.zig` | 55 |
| 10 | `src/storage/graph_storage_adapter.zig` | 53 |

## Module LOC Heatmap (top 10 directories)

| Module | Files | LOC |
|--------|------:|----:|
| `src/execution/` | 28 | 32,645 |
| `src/security/` | 41 | 26,210 |
| `src/cli/` | 31 | 22,611 |
| `src/distributed/` | 31 | 19,446 |
| `src/server/` | 31 | 18,642 |
| `src/client/` | 25 | 14,195 |
| `src/gql/` | 9 | 13,662 |
| `src/planner/` | 24 | 9,119 |
| `src/graph/` | 45 | 7,877 |
| `src/storage/` | 10 | 7,644 |

---

## Test Infrastructure

- **Unit tests:** 4019 `test` blocks in `tests/*.zig`, 2154 more co-located in `src/*.zig`.
- **Integration suite:** `../geode-test-harness` sibling repo (198 specs, ~25 min with 2 workers per CLAUDE.md), pinned via `GEODE_TEST_HARNESS_REF`.
- **Fuzz:** `fuzz/` with corpora, dictionaries, targets; 2 entrypoints; build step exposed. Runner: `zig build test --fuzz=10s`.
- **Benchmarks:** 43 top-level + 184 `benchmark_*.zig`; baselines tracked in `benchmarks/loadtest/baseline.jsonl`, JSONL with QPS/p50 thresholds (20% regression trips).
- **Parity campaigns:** `test-match-parity`, `test-cli-transport-parity`, `test-match-bench` — run locally as pre-push hook `match-ops-campaign`.
- **Governance:** ~2271 CANARY markers tracked; `status.csv` kept in sync via pre-commit auto-regenerate.
- **Conformance:** ISO/IEC 39075:2024 GQL suite, 70/70 passing per `docs/GQL_COMPLIANCE.md`; BNF source in `grammar/ISO_IEC_39075(en).bnf.txt`.
- **Known test gaps:** See `docs/KNOWN_TEST_ISSUES.md` (141 lines), `docs/QUALITY_GAP_ANALYSIS.md` (302 lines).

---

## API Contracts & Drift Surfaces

- **GQL front-end** (ISO/IEC 39075:2024): single source of truth in `grammar/ISO_IEC_39075(en).bnf.{txt,xml}`; parser in `src/gql/parser.zig` and the external `gql` Zig dep. CANARY: CLAUDE.md forbids departing from the standard. Drift guard: `scripts/conformance_sync.zig`, `docs/kb/CONFORMANCE_SYNC.md`, CI `test-gql-compliance`.
- **Wire protocol (QUIC):** `docs/BINARY_PROTOCOL.md`; transport in `src/transport/quic.zig` + `src/transport/grpc_server.zig`. Drift risk: second gRPC transport implements the same semantics as QUIC; parity enforced by `test-cli-transport-parity`.
- **Protobuf schemas:** `src/proto/schema.zig` (1409 LOC) and the `protobuf` Zig dep; `migrations/*.gql` hold DDL migrations (001-008).
- **MCP:** `src/mcp/` (7 files, 2488 LOC) — CLAUDE.md flags `subscribeResource`/`unsubscribeResource` as intentionally-unimplemented; parent agent should watch drift between Geode's MCP handlers and the MCP spec.
- **CANARY registry** ↔ `docs/GAP_ANALYSIS.md` (2238 lines): `tools/canaryscan/` (Go binary) verifies claims match markers; CI `governance-canaryscan-verify` blocks merges.
- **status.csv** ↔ Zig source: `tools/status_generate.py` plus pre-commit `status-csv-check` auto-stages updates.
- **REQ ↔ docs:** `tools/req_doc_report.py` + `scripts/scan_requirements.zig`; CI `governance-req-doc-reports`.

## Doc Coverage

- `docs/` contains **205 markdown files** (95 at root, rest in subdirs `architecture/`, `development/`, `deployment/`, `docker/`, `kb/`, `completion_reports/`, `examples/`, `security/`, `testing/`, `clients/`, `loadtest/`, `gql/`).
- ADRs in `docs/architecture/` (5 files) + `specs/adrs/`.
- Quality/gap/audit docs: `FULL_AUDIT_2026_04_06.md`, `FULL_AUDIT_2026_04_07.md`, `FULL_AUDIT_2026_04_09.md`, `QUALITY_GAP_ANALYSIS.md`, `PERF_GAP_ANALYSIS.md`, `SECURITY_GAP_ANALYSIS.md`, `DISTRIBUTED_*_GAP_ANALYSIS.md`, `GQL_*_GAP_ANALYSIS.md`, `MIGRATION_GAP_ANALYSIS.md`.
- `CONTRIBUTING.md` + `CLAUDE.md` + `AGENTS.md` + `GAP_REGISTER.md` at repo root.
- No `SECURITY.md` at root (security docs under `docs/security/` instead).

---

## Missing Tooling (gaps)

| Gap | Why it matters |
|---|---|
| **Zig version pin drift** (`0.15.1`/`0.15.2` vs actual `0.16.0` migration in recent commits) | Pre-commit and CI may reject or mis-compile code; contributor onboarding via `make setup-dev` installs wrong toolchain. **Highest-priority fix.** |
| **No Python type-checker** (mypy/pyright) | `tools/*.py` and `scripts/test/*.py` are governance-critical (CANARY generation, status.csv sync) — silent type errors propagate into CI gating. |
| **No duplication detector** (jscpd, dupl equivalent) | Top-10 files are 2500-7000 LOC; copy-paste between `eval.zig`/`eval_extended.zig`, `execution.zig`/`exec.zig`, and the dual transport stacks is visible in filenames. |
| **No complexity gate** | `match_operations.zig` at 7110 LOC and `parser.zig` at 6640 LOC are unbounded; CLAUDE.md flags them as multi-gap-closure sites. A cyclomatic/size budget (e.g. "warn >3000 LOC per file") would make regressions visible. |
| **No Python test runner hooked to CI** | 60+ Python test scripts in `scripts/test/` — no `pytest` config, no invocation from `.gitlab-ci.yml`, not gated by pre-commit. |
| **No coverage threshold** | `test-code-coverage` job runs but doesn't fail the pipeline; 97.4% pass rate is maintained by hand-audit of `KNOWN_TEST_ISSUES.md`. |
| **No SBOM / supply-chain attestation** | `goreleaser` produces artefacts but no SBOM (syft/cyclonedx) job; 24 Zig deps pinned by hash (good) but no reproducibility proof. |
| **No dependency-age watchdog** | Zig deps are hash-pinned; no automation flags when upstream `devnw/zig/*` repos advance. |
| **No license-header enforcement** | `LICENSE_HEADER` file exists at root; `scripts/license.py` present, but not invoked from `.pre-commit-config.yaml`. |
| **`Dockerfile.dev` excluded from hadolint** (BuildKit heredocs) | Dev image drifts silently from prod Dockerfile lint rules. |
| **Pre-commit skips heavy gates in `pre-commit.ci`** (line 329: `zig-fmt, zig-build, zig-test, cross-compile-check, no-feature-flags, canary-verify, canaryscan-verify, match-ops-campaign`) | Self-hosted CI must shoulder all heavy lifting; any contributor who disables local pre-push can land unverified code if CI is skipped. |
| **No Go lint for `tools/canaryscan/`** | 1 Go binary, test file (`scan_test.go`) exists; no `golangci-lint` or `go vet` in pre-commit or CI. |

---

## Summary

Geode has an unusually mature governance layer (CANARY markers + `canaryscan` verifier + status.csv auto-regen + 11 dedicated governance CI jobs) and excellent build-system hygiene (42 build steps, pinned deps, `.path` deps banned). Language-level linting is weaker: Zig has nothing beyond `zig fmt` and `zig build`, Python has ruff but no type checker, Go has neither. The biggest quality risks are (1) **Zig version pin drift** (0.15.x pins vs 0.16.0 migration in `HEAD`), (2) unbounded file size in the execution/parser hotspots, and (3) no duplication or complexity gates on a codebase where 7000-LOC files are load-bearing.
