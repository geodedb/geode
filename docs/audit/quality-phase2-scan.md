# Geode Quality Audit - Phase 2 Scan

**Generated:** 2026-04-16
**Toolchain:** Zig 0.16.0 (mise), ruff 0.15.10 (uvx), markdownlint-cli 0.48.0 (npx), shellcheck/gitleaks/trivy 0.60.0 (docker), jq 1.7.

## Scanner Results

| Tool | Exit | Findings |
|------|:---:|---------|
| `zig fmt --check src/ build.zig` | 1 | **30 files need reformat** (incl. `src/cli/main.zig`, `src/gql/main.zig`, `src/server/quic_connection_handler.zig`, `src/transport/grpc_server.zig`, `src/exec.zig`). |
| `zig build --summary all` | **1** | **Build fails:** `src/cli/transport_response.zig:171:16` calls `writeAll` on `Io.File` (Zig 0.16 API drift). Caller: `render__anon_576702` at `src/client/query_result_accumulator.zig:145:69`, `executeQueryOnGrpc` at `src/cli/main.zig:1897`. |
| `ruff check scripts/ tools/` | 1 | **19 errors:** UP006×10, UP035×4, SIM102×2, C414×2, B007×1 — deprecated `typing.Set` in `tools/canary_check.py`, `tools/status_generate.py`. |
| shellcheck on 79 `.sh` | 1 | **7 errors:** `scripts/comprehensive_graph_test.sh:103` SC1089 unterminated quote; `scripts/modularization/generate_final_metrics.sh:279` SC2287. |
| markdownlint `docs/**/*.md` | 1 | **532 violations:** MD031×208, MD032×196, MD022×47, MD012×42, MD056×16. Worst files: `docs/testing/SHELL_TEST_ISSUES.md` (247), `FINAL_VERIFICATION_CHECKLIST.md` (66). |
| `gitleaks detect` (2 584 commits) | 0 | **42 leaks** — all history/test fixtures: FLE/TDE hex keys in `geodetestlab/specs/*.yml` (e.g. `tde_plaintext_verification_page.yml:44`), stale CLAUDE.md revisions, `clients/test-harness/certs/server.key.{bak,ec,rsa.bak}`. Not in `.gitleaks.toml` → blocks CI. |
| `trivy fs --scanners vuln,secret` | 0 | **HIGH:** CVE-2025-4565, CVE-2026-0994 in `protobuf@4.25.1` (`zig-pkg/grpc_zig-…/integration_test/requirements.txt`). **MEDIUM:** CVE-2025-64702 in `quic-go@v0.54.1` (`go.mod`, HTTP/3 QPACK DoS). Secret: `certs/server.key`. |

## Duplication (Phase 1 Hypotheses)

- `eval.zig` vs `eval_extended.zig` — **not duplicates**; domain split (`Value` vs `ExtValue`), 0 `pub fn` overlap.
- `execution.zig` vs `exec.zig` — not clones but both use `logging.scoped("execution")`; 0 `pub fn` overlap. `exec.runGroupedQuery` has one caller (`src/gql/main.zig:539`). Consolidation candidate.
- **Confirmed dead clone:** `src/execution/statement_dispatcher.zig:121 pub fn executeStatementWithContext` — 1,114-LOC orphan; all callers use `src/execution.zig:919` (`quic_connection_handler.zig:2440`, `grpc_server.zig:2131`, `statement_handlers.zig:989`). Only `ensureAdvancedRuntimeIndex` + `runtimeAdvancedIndexTypeFromCatalog` live via `execution.zig:{1264,1353}`.

## Functions > 500 LOC

| File:Line | Function | LOC |
|---|---|---:|
| `src/execution/match_operations.zig:4543` | `executeMatchQueryImpl` | **2 567** |
| same file (internal) | `executeMatchWithOptionalPatterns` | 1 564 |
| `src/eval.zig:677` | `evalExpr` | 1 163 |
| `src/execution/statement_dispatcher.zig:121` | `executeStatementWithContext` (dead) | 1 114 |
| `src/gql/main.zig:35` | `main` | 878 |
| `src/execution.zig:919` | `executeStatementWithContext` | 807 |
| `src/execution/query_execution.zig:63` | `executeQueryChain` | 713 |
| `src/execution/match_operations.zig` | `executeMultiChainRelationshipMatch` | 709 |
| `src/cli/user_mgmt_cli.zig:154` | `cmdUser` | 689 |
| `src/cli/main.zig` | `cmdQuery` | 650 |

## Nesting Depth ≥ 12

`src/transport/grpc_server.zig:1905` (13), `src/server/quic_connection_handler.zig:2185` (13), `src/execution/match_operations.zig:1196` (13), `src/security/mtls_provider.zig:714` (12), `src/execution/crud_operations.zig:2398` (12), `src/execution/aggregation_evaluation.zig:264` (12), `src/client/repl/repl_dispatch.zig:1296` (12).

## Top 10 Quality Problems

1. **`zig build` fails** at `src/cli/transport_response.zig:171:16`. `confidence::confirmed`.
2. **Zig version pin drift** — zon 0.15.1, CI 0.15.2, HEAD needs 0.16.0. `confidence::confirmed`.
3. **Dead 1,114-LOC dispatcher** `src/execution/statement_dispatcher.zig:121`. `confidence::confirmed`.
4. **2,567-LOC MATCH kernel** `src/execution/match_operations.zig:4543`. `confidence::confirmed`.
5. **Depth-13 nesting** in `grpc_server.zig`, `quic_connection_handler.zig`, `match_operations.zig`. `confidence::confirmed`.
6. **30 files fail `zig fmt --check`** → CI `zig-format@v1.2.1` will reject HEAD. `confidence::confirmed`.
7. **2 HIGH + 1 MEDIUM CVEs** (`protobuf@4.25.1`, `quic-go@v0.54.1`). `confidence::confirmed`.
8. **42 gitleaks history hits** unallowlisted. `confidence::confirmed`.
9. **532 markdownlint violations** (docs/testing/ concentrated). `confidence::confirmed`.
10. **19 ruff errors on governance scripts** (`tools/canary_check.py`, `tools/status_generate.py`). `confidence::confirmed`.

## Deferred

No Python type-checker, no duplication tool (jscpd/dupl), no Go tooling for `tools/canaryscan/`. Dead-code findings use `grep` reverse-import + `pub fn` signature search.

**Logs:** `/tmp/quality-audit/{zig-fmt,zig-build,ruff,shellcheck,markdownlint,gitleaks,trivy}.log`.
