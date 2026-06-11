# Quality Gap Analysis

Last updated: 2026-06-11

This file now contains only open/deferred quality gaps. Historical quality findings live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Open / Deferred Findings

| ID / Issue | Severity | Area | Finding | Status |
|---|---|---|---|---|
| #474 | High | CLI architecture | `cli/main.zig` is monolithic and high-churn; command parsing/transport/auth flows need phased extraction. | Blocked / design required |
| #520 | High | Core architecture | Mutable singleton/global-state reliance across core modules. | Blocked / context-threading design required |
| #515 | High | Transport parity | gRPC transport missing message types present in QUIC handler. | Blocked / feature sprint |
| #462 | High | Storage architecture | `GraphStore` remains a god object with many responsibilities. | Blocked / extraction plan |
| #409 | High | Query eval | Large `evalExpr` switch needs family-specific dispatch/extraction. | Blocked / design required |
| #405 | High | API shape | Functions with excessive parameters need context structs. | Blocked / high-risk migration |
| #521 | High | CLI parsing | CLI argument parsing duplicated across call sites. | Blocked / parser design required |
| #719 / #804 | High | Execution maintainability | `executeMatchQueryImpl` and sibling match functions remain too large. | Open / deferred |
| #721 | High | Error handling | `catch {}` sites need categorization and policy. **High-risk tier (security/storage/WAL/execution-write) CLOSED 2026-06-11 (GAP-0886b)**: policy written ([ERROR_HANDLING_POLICY.md](ERROR_HANDLING_POLICY.md)), every site in those trees classified A–D with justification comments, C/B violations fixed. Remaining tiers (CLI, transport, client, tools, execution read paths, etc.) tracked in the burn-down table below. | Tiered: high-risk tier Closed; remaining tiers Open |
| #556 / #809 / #810 | Medium | Error handling | `catch unreachable` / `unreachable` hot-path sites need invariant audit. **High-risk tier CLOSED 2026-06-11 (GAP-0886b)**: all 12 code sites in security/storage/execution audited — every one carries a category-D invariant comment (error-set or buffer-size proof); none required rewrites. Remaining trees (types, index, tools, cli, migration, …) in the burn-down table below. | Tiered: high-risk tier Closed; remaining tiers Open |
| #725 | Medium | Tooling/docs CI | Ruff, shellcheck, and markdownlint debt remains. | Open |
| #736 / #815 | Medium | Concurrency | Lock-tier discipline and QUIC lock TODOs need enforcement/design. | Open |
| #730 | Medium | Governance tooling | CANARY parser/generator regex coverage needs golden tests. | Open / partial |
| #733 | Medium | Tests | Parser, match, and execution hot paths need inline/unit test backfill. | Open |
| #806 | Medium | LSP maintainability | `features.zig` aggregates all LSP handlers in one large file. | Open |
| Q9/Q13/Q15/Q17/Q18/Q19 | Medium/Low | Migration quality residuals | Migration monolith, API contract, docs, and ownership residuals remain from the re-audit. | Open |

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
