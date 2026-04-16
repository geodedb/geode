# Geode Quality Audit - Phase 3 Deep Review

**Generated:** 2026-04-16
**Method:** Read-only; findings cross-checked with Phase 1 inventory and Phase 2 tool output.
**PriorityScore:** 1 (cosmetic) → 5 (merge-blocker).

## Top 20 Findings

| # | Finding | File:Line | Root Cause | Confidence | Priority |
|---|---|---|---|:-:|:-:|
| 1 | Build broken on Zig 0.16 | `src/cli/transport_response.zig:171-213` | `writeAll` called on `std.Io.File` (API removed); 16 call-sites in one function. Fix: use `File.deprecatedWriter()` or thread a writer. | confirmed | 5 |
| 2 | Zig toolchain pin drift | `build.zig.zon` 0.15.1 / CI 0.15.2 / HEAD 0.16.0 | Three versions referenced; `make setup-dev` installs wrong toolchain; pre-commit disagrees with CI. | confirmed | 5 |
| 3 | Dead 1,114-LOC clone of `executeStatementWithContext` | `src/execution/statement_dispatcher.zig:121` vs live `src/execution.zig:919` | Identical `pub fn` signature; only 3 helpers (lines 42-89) are used. Body is orphaned. Safe-delete after moving helpers to `execution/index_runtime.zig`. | confirmed | 5 |
| 4 | 2,567-LOC `executeMatchQueryImpl` | `src/execution/match_operations.zig:4543` | Four-way dispatcher at line 4585 already exists; remaining bulk is the `continue_processing` branch. Decompose by aggregation / GROUP-BY-with-rel (4604-4638) / single-node-scan / rel-scan — zero hot-path overhead, dispatcher already routes. | confirmed | 4 |
| 5 | 30 files fail `zig fmt --check` | `/tmp/quality-audit/zig-fmt.log` | Includes `cli/main.zig`, `server/quic_connection_handler.zig`, `transport/grpc_server.zig`, `gql/main.zig`. Merge-blocker under CI `zig-format@v1.2.1`. One-shot fix: `zig fmt src/ build.zig`. | confirmed | 5 |
| 6 | Depth-13 nesting hides errors | `transport/grpc_server.zig:1905`, `server/quic_connection_handler.zig:2185`, `execution/match_operations.zig:1196` | Correlates with swallow density: `grpc_server.zig`=8 `catch {}`, `quic.zig`=14. Guard-clause refactor cuts 5+ levels. | confirmed | 3 |
| 7 | 653 `catch {}` — 29 in CLI/transport hot paths | `cli/transport_response.zig:29`, `cli/main.zig:57`, `transport/quic.zig:14`, `transport/grpc_server.zig:8` | `result_utils.zig:13` documents display-write policy; `quic.zig:399-1190` "best-effort cleanup" on close/poll masks socket errors with no log. Categorize and log. | confirmed | 4 |
| 8 | Governance scripts fail ruff (19 errors) + untested regex | `tools/canary_lint.py`, `tools/status_generate.py`, `tools/canary_check.py` | UP006/UP035 blocks `governance-canary-lint` CI job; same job drives the 71% TESTED number in CLAUDE.md. Regex at `status_generate.py:15-25` has no unit test and handles escaped/unescaped `FEATURE=` in one branch — malformed input can stall the CSV regen. | confirmed | 4 |
| 9 | 42 unallowlisted gitleaks hits | `clients/test-harness/certs/server.key.{bak,ec,rsa.bak}`; `geodetestlab/specs/tde_plaintext_verification_page.yml:44` | Test fixtures, but `.gitleaks.toml` doesn't cover `.bak`/`.ec`/`.rsa.bak` suffixes or `geodetestlab/specs/tde_*.yml`. | confirmed | 4 |
| 10 | 24 modules rely on mutable singletons | `graph_store.zig` (16 globals incl. `global_store`, `g_persist_pool`), `execution.zig` (`global_catalog_instance`), `wal.zig` (`g_wal`, `g_wal_storage`), `distributed/twophase.zig`, `fle_integration.zig` | `setGlobalExprRLSEngine` pattern (GAP-0510) is undiscoverable and blocks unit-testability; pass state through `ExecutionContext` (already threaded). | confirmed | 3 |
| 11 | 84 `catch unreachable` — some in parsed-input paths | `types/jsonb.zig:30`, `types/datetime.zig:14`, `graph_store.zig:21`, `cli/main.zig:4` | Converts recoverable errors to panics; untested input crashes the server. Replace with `catch \|err\| return err` on IO/parse; keep only for provably-unreachable branches. | confirmed | 4 |
| 12 | `parser.zig` 6,640 LOC, 84 fn, 3 inline tests | `src/gql/parser.zig` | ISO 70/70 suite covers surface, not lookahead/error-recovery/span preservation. A refactor regression can pass ISO tests while breaking messages. Add `tests/test_parser_internals.zig` targeting the 10 most-branched productions. | suspected | 3 |
| 13 | `graph_store.zig` lock-tier discipline lives only in CLAUDE.md | `src/graph_store.zig:store_mutex` (tier 1), `g_store_rwlock`, 16 globals | No runtime assertion enforces the CLAUDE.md lock-ordering table; any contributor can invert `store_mutex` → `catalog_mutex`. Add debug-only `LockTier` wrapper + header runbook. | confirmed | 3 |
| 14 | `repl_dispatch.zig` 5,122 LOC, 64 fn, 35 `catch {}` + mutable globals | `src/client/repl/repl_dispatch.zig` | Giant command switch; `g_sourced_file_hashes`, `g_repl_background_pool` leak under fast reconnect. Split by command family (auth/graph/admin/query). | confirmed | 3 |
| 15 | `exec.zig` (2,731 LOC) called exactly once | `src/exec.zig` via `src/gql/main.zig:539` for `runGroupedQuery` | 0 `pub fn` overlap with `execution.zig` but shares `logging.scoped("execution")`. Fold into `query_execution.zig` or rename to reflect narrow responsibility. | confirmed | 2 |
| 16 | `execution.zig:50-150` — 80 re-exports turn dispatcher into god-module | `src/execution.zig:50-150` | Can't tell dispatch from delegation. Move re-exports to `execution/re_exports.zig`; lowers load on the #4-churn file (125 commits/3mo). | suspected | 2 |
| 17 | `eval.zig` 4,517 LOC, 1,163-LOC `evalExpr` switch | `src/eval.zig:677` | ADR cites refactor in progress; 70 commits/3mo touched it with no visible decomposition. Split by expression family, mirroring the already-done `eval_extended.zig` split. | suspected | 3 |
| 18 | `cli/main.zig` 3,666 LOC — #1 churn (177 commits/3mo), 57 `catch {}`, 650-LOC `cmdQuery` | `src/cli/main.zig` | Highest churn + highest swallow count. Adjacent `cmdUser` is 689 LOC. Use per-command struct + dispatch table (the `cli_dispatcher.zig` pattern). | confirmed | 3 |
| 19 | No `SECURITY.md` at root; 532 markdownlint violations (247 in one file) | root (missing); `docs/testing/SHELL_TEST_ISSUES.md` | Missing file breaks GitHub/GitLab security-reporting convention. One-file concentration = auto-generated doc, never curated. 5 ADRs in `docs/architecture/` + loose files in `specs/adrs/` need an index. | confirmed | 2 |
| 20 | Inline test coverage absent in the three largest hot paths | `gql/parser.zig` (0 inline), `execution/match_operations.zig` (0 inline), `execution.zig` (1 inline) vs `graph_store.zig` (32 inline) | 4,019 `tests/` + 2,154 inline, but none in the megafiles. Parity with 97.4% pass rate masks internal-regression exposure. Backfill targeted tests for the dispatcher branches at `match_operations.zig:4585`. | confirmed | 3 |

## Cross-Cutting Recommendations

**Hot-path decomposition (finding 3 then 4).** Delete the dead `statement_dispatcher` clone first — 1,114 LOC removed, no caller risk confirmed by `grep` of all `@import("execution/statement_dispatcher")`. Then extract the four `executeMatchQueryImpl` branches already identified at line 4585; the dispatcher is the natural seam and the hot path is already a switch.

**Error-handling policy.** Add `result_utils.zig:13`-style policy comments to every file where `catch {}` count > 5. Distinguish (a) display-only writes, (b) best-effort shutdown cleanup, (c) bugs; (c) becomes `log.warn` or `return err`. Ban bare `catch {}` in new code via a pre-commit regex.

**Governance hygiene (finding 8).** Merge-blocking *and* it compromises the CANARY generator behind CLAUDE.md's 71% TESTED figure. Fix ruff and add golden-CSV + malformed-input unit tests for `CANARY_PATTERN`.

**Lock-ordering (finding 13).** Lift the CLAUDE.md lock-tier table into a debug-only `LockTier` wrapper (~60 LOC in `src/util/lock_tier.zig`), adopt incrementally starting with the isolated tier-0 `graph_handles_mutex`.
