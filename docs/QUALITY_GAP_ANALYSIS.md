# Quality Gap Analysis

Last updated: 2026-06-11

This file now contains only open/deferred quality gaps. Historical quality findings live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Open / Deferred Findings

Reconciled 2026-06-11 (GAP-0886d): every remaining row carries a named unblock
condition; partial progress from the 2026-06-10/11 round is cross-referenced per
row. The architectural rows below are explicitly deferred execution batches —
each is issue-backed on GitLab and blocked on the named condition, not on triage.

| ID / Issue | Severity | Area | Finding | Status / unblock condition |
|---|---|---|---|---|
| #474 | High | CLI architecture | `src/cli/main.zig` is monolithic and high-churn (3,863 lines; parsing/transport/auth flows interleaved). | Deferred. Unblock: dedicated extraction sprint applying the proven #806 LSP pattern (per-feature modules behind a re-export facade, no new module roots); phased plan required before touching the auth/transport seams. |
| #520 | High | Core architecture | Mutable singleton/global-state reliance across core modules (e.g. the global expression-RLS engine installed via `setGlobalExprRLSEngine`, global FLE state). | Deferred. Unblock: global-singleton inventory + per-request context-threading design doc (extend `ExecutionContext` rather than invent a parallel context). Prerequisite for #405. |
| #515 | High | Transport parity | gRPC transport missing message types present in the QUIC handler. **Partial progress 2026-06-11:** GAP-0880 (commits `4e615e46` + `d9210dc1`) closed the backup-upload slice — BOTH the QUIC and gRPC upload handlers now do real ingestion via `BackupManager.ingestUploadedBackup` (previously both wrote an empty file and reported success). | Deferred. Unblock: enumerate a QUIC-handler vs gRPC-service parity matrix (message type → handler → test), then a feature sprint per missing row. |
| #462 | High | Storage architecture | `GraphStore` remains a god object with many responsibilities. | Deferred. Unblock: extraction plan; the delegation precedent is established (`fts_storage_adapter.zig`, `timeseries/timeseries.zig` wrap external engines behind narrow seams). |
| #409 | Medium | Query eval | Large `evalExpr` switch needed family-specific dispatch/extraction. **Materially reduced:** GAP-0532 deleted 947 lines of dead duplicate dispatch; GAP-0537 (closed 2026-06-11 in the GAP-0888 batch, commit `18f9fff0`) extracted 591 more lines into `src/eval/ts_call_handlers.zig` + `src/eval/quantifier_call_handlers.zig`, leaving the fallback `.Call` branch dispatch-only. `src/eval.zig` is now 4,051 lines. Severity downgraded High→Medium 2026-06-11: the handler-module pattern is proven, so remaining families are incremental extraction, not a design problem. | Open / incremental. Unblock: none required — extract remaining expression families one at a time following the `call_handlers` pattern, rooted via the named test block in `src/eval.zig`. |
| #405 | High | API shape | Functions with excessive parameters need context structs. | Deferred. Unblock: blocked behind the #520 context-threading design — the context structs should be the same shape that design produces, so doing this first would churn signatures twice. |
| #521 | High | CLI parsing | CLI argument parsing duplicated across call sites. | Deferred. Unblock: fold into the #474 extraction sprint (same file, same churn surface); a standalone parser refactor would conflict with the main.zig split. |
| #719 / #804 | High | Execution maintainability | `executeMatchQueryImpl` and sibling match functions remain too large (~2,700-line function body in the 8,635-line `src/execution/match_operations.zig`). Stage-1 decomposition helpers exist (`match_operations.zig:395`); #733 (closed 2026-06-11) added the file's first inline tests (`passesTenantFilter` contract incl. GAP-0846 hierarchy), de-risking further extraction. | Deferred. Unblock: stage-2 extraction plan that names the next helper seams; tenant-filter and RLS call sites must keep their regression cover (`test-gap0509-tenant-isolation`, `test-quality733`) green per extraction step. |
| #721 | High | Error handling | `catch {}` sites need categorization and policy. **High-risk tier (security/storage/WAL/execution-write) CLOSED 2026-06-11 (GAP-0886b)**: policy written ([ERROR_HANDLING_POLICY.md](ERROR_HANDLING_POLICY.md)), every site in those trees classified A–D with justification comments, C/B violations fixed. Remaining tiers (CLI, transport, client, tools, execution read paths, etc.) tracked in the burn-down table below. | Tiered: high-risk tier Closed; remaining tiers Open. Unblock: per-tree audit passes in burn-down order (execution read paths first — they can silently drop result rows). |
| #556 / #809 / #810 | Medium | Error handling | `catch unreachable` / `unreachable` hot-path sites need invariant audit. **High-risk tier CLOSED 2026-06-11 (GAP-0886b)**: all 12 code sites in security/storage/execution audited — every one carries a category-D invariant comment (error-set or buffer-size proof); none required rewrites. Remaining trees (types, index, tools, cli, migration, …) in the burn-down table below. | Tiered: high-risk tier Closed; remaining tiers Open. Unblock: same per-tree passes; `src/types/` (16) and `src/index/` (11) are the #556 focus. |
| #725 | Medium | Tooling/docs CI | Ruff, shellcheck, and markdownlint all run in pre-commit, but with suppressions: shellcheck at `--severity=error` only with several script/test dirs excluded, markdownlint with 9 rules disabled plus dir excludes (`.pre-commit-config.yaml:55-90`). The debt is the suppression surface, not missing tooling. | Open. Unblock: ratchet plan — remove one exclusion/disabled rule at a time, fixing the violations it exposes. |
| #736 / #815 | Medium | Concurrency | Lock-tier discipline (GAP-0278 table) lives only in CLAUDE.md prose — no runtime enforcement (`src/util/lock_tier.zig` / `OrderedMutex` not yet implemented). The two #815 lock TODOs persist: `// TODO(P1): Consider multi-graph lock acquisition` for backup and restore (`src/server/quic_connection_handler.zig:6540`, `:6650`). | Open. Unblock: implement the debug-only `OrderedMutex(tier)` wrapper per the #736 plan, adopt from tier-0 `graph_handles_mutex` outward; classify the two backup/restore TODOs against the tier table (document single-graph scope or take per-graph locks in alphabetical order per tier-1 rule). |
| (Q9 follow-up) | Low | Migration module size | `src/migration/mod.zig` regrew to 1,682 lines — past the 800-line guideline again — after the migration-signing implementation landed at `mod.zig:1411-1680`. The original Q9/#621 split (ledger.zig, lock.zig, apply.zig) still stands. | Open. Unblock: extract signing into `src/migration/signing.zig` alongside the existing sub-modules. |
| (2026-06-10 round review minors) | Low | Carried review minors — consolidated | One line each, none release-blocking: (1) `src/storage/s3_sigv4.zig` `signingKey` 256-byte secret debug-assert — UB in ReleaseFast for longer secrets (guard or error instead); (2) backup `metadata.json` load-append-overwrite race + no fsync/atomic-rename on registry write (pre-existing); (3) `generateBackupId` ms-seeded PRNG — id collision possible for backups created the same millisecond; (4) QUIC backup upload bounded by the 16MiB frame limit — chunked upload is a future item; (5) `src/planner/cbo.zig` `Predicate.matches` returns `true` unconditionally (reachable via `cost_model`); (6) FTS case folding is a minimal subset (`Geode` != `geode` outside the folded ranges; applies equally to plain search); (7) `RLSEngine.policies` map is unsynchronized — `createPolicy` races concurrent scans (fail-closed in the window; needs a lock-tier assignment); (8) `current_user='alice'` in a compiled RLS expression compiles to an int-hash-vs-string compare that is always false (fail-closed, but silently wrong); (9) `getGlobalKeyManager` pins the FIRST caller's allocator for the process-lifetime singleton (align on `global_allocator` like `getParallelPool` post-GAP-0883); (10) `test_perf_c` mutates `GEODE_MASTER_KEY` without restoring it (last-test-in-process assumption). | Open. Unblock: burn down opportunistically in the next quality round — each item is debug-only, fail-closed in the affected window, or a documented pre-existing race; fix (7)/(8)/(9) first since they touch security-adjacent paths. |

Closed 2026-09-26 (SONNY-2775): the GAP-0892 residual, the test hook in production code. `SESSION SET PROPERTY GRAPH` no longer seeds fixture graphs named `G1`/`G2` (`createTestGraphG1/G2` are removed from `src/execution.zig`); it now checks the graph permission and that the graph exists, like USE GRAPH. `tests/gql_conformance.zig` creates G1 and G2 itself.

Closed 2026-06-11 (GAP-0886c): #806 (LSP `features.zig` split into `features/` modules with a re-export facade; all LSP steps green), #730 (golden end-to-end fixture tests for the CANARY parser/generator — `make status-generate-test` + `status-generate-selftest` pre-commit hook), #733 (hot-path inline test backfill: parser 8-level nesting + error path, `passesTenantFilter` unit contract incl. hierarchy, `validateGroupBy` error branch; `zig build test-quality733`). Details in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

Stale-row correction 2026-06-11 (GAP-0886d): the former
"Q9/Q13/Q15/Q17/Q18/Q19 migration quality residuals — Open" row was wrong.
All six were already closed (Q13/Q15/Q17/Q18 on 2026-04-05; Q9/Q19 on
2026-04-10, alongside #621/#624) and are recorded in
[GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md). The only live residual is
the Q9-shaped regrowth of `src/migration/mod.zig` (now its own Low row above).

## Error-swallow burn-down (#721 + #556/#809/#810)

Policy: [ERROR_HANDLING_POLICY.md](ERROR_HANDLING_POLICY.md). Counting commands:
`rg -c "catch \{\}" src/<tree>/` and `rg -c "catch unreachable" src/<tree>/`
(note: the `catch unreachable` counts below are code-only; the raw rg count is
slightly higher because the new `// error-policy:` comments mention the pattern).

Audited 2026-06-11 (GAP-0886b) — high-risk tier. "Audited" means every site is
classified A–D with a justification comment; remaining counts are justified
category-A/D sites, not unreviewed swallows.

| Tree | `catch {}` | `catch unreachable` (code) | Status |
|---|---:|---:|---|
| `src/security/` | 16 | 5 | **Audited** — all A/D-justified; 2 violations fixed (audit tail anchor B-log, registry fsync C-propagate) |
| `src/storage/` + `src/wal.zig` | 65 (wal: 0) | 6 | **Audited** — all A/D-justified; 1 violation fixed (FTS lazy re-open B-log); bulk: txn rollback (14) + metric registration (38) |
| `src/execution/` write paths | 2 | 1 | **Audited** — 9 violations fixed (role-create C, CDC-start C, audit logged/counters C ×3, MFA rate-limit B ×2 + alloc, index-rebuild B ×3 sites); remaining 2 are A-justified (tenant cascade error-set proof, FTS errdefer cleanup) |
| `src/execution/` read paths | 57 | 0 | Next tier — 45 of these are writer-formatting in `result_utils.zig` (file-level note); the OOM-swallowing `append`/`put` sites in `match_operations.zig`/`aggregation_evaluation.zig`/`pattern_helpers.zig` can silently drop result rows and should be triaged first |
| `src/cli/` | 120 | 5 | Next round |
| `src/benchmarks/` | 82 | 2 | Next round (low risk — bench harness) |
| `src/client/` | 78 | 0 | Next round |
| `src/tools/` | 66 | 7 | Next round (low risk — dev tools) |
| `src/graph/` | 59 | 0 | Next round |
| `src/` (root files) | 29 | 8 | Next round |
| `src/server/` | 25 | 2 | Next round |
| `src/transport/` | 22 | 0 | Next round |
| `src/gql/` | 22 | 2 | Next round |
| `src/types/` | 2 | 16 | Next round (#556 focus — invariant audit) |
| `src/index/` | 0 | 11 | Next round (#556 focus — invariant audit) |
| remaining trees | ~75 | ~20 | Next round |
| **repo total** | **732** | **~75 code sites** | Bare `unreachable` (non-catch, code): 14 sites repo-wide |

Known accepted residual: the TDE tenant-key derivation "truncated" fallback
(`tde_key_manager.zig` / `tde_file_encryption.zig`) — see
[ERROR_HANDLING_POLICY.md](ERROR_HANDLING_POLICY.md) §Known accepted residual.
