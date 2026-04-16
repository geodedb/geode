# Gap Closure Plan — 2026-04-16

**Branch:** main (HEAD `35149ed9`)
**Generator:** Step 1 — Discovery & Planning (read-only)
**Input audits:** `docs/audit/FULL_AUDIT_2026_04_16.md` + 12 phase reports
**Scope:** 35 GitLab issues #710-744 + 5 new GAP-0538..0542 + residual doc-tracked items

---

## Gap Files Discovered

All `*GAP_ANALYSIS*.md` under the repo (excluding `zig-pkg/` vendor copies which are read-only dependency artifacts):

| File | Domain | Role |
|------|--------|------|
| `/home/benji/src/devnw/codepros/geode/geode/docs/GAP_ANALYSIS.md` | General | Authoritative ledger — 12 open gaps (7 existing + 5 new) |
| `/home/benji/src/devnw/codepros/geode/geode/docs/GAP_ANALYSIS_RESOLVED.md` | General | Archive (reference only) |
| `/home/benji/src/devnw/codepros/geode/geode/docs/PERF_GAP_ANALYSIS.md` | Performance | April 2026 audit section w/ ranks 44-52 |
| `/home/benji/src/devnw/codepros/geode/geode/docs/QUALITY_GAP_ANALYSIS.md` | Code Quality | Phase 4 section (302→362 lines) |
| `/home/benji/src/devnw/codepros/geode/geode/docs/SECURITY_GAP_ANALYSIS.md` | Security | Phase 3 section prepended |
| `/home/benji/src/devnw/codepros/geode/geode/docs/DISTRIBUTED_GAP_ANALYSIS.md` | Distributed | All closed per commit `68ff42c4` |
| `/home/benji/src/devnw/codepros/geode/geode/docs/DISTRIBUTED_PERF_GAP_ANALYSIS.md` | Distributed perf | Historical |
| `/home/benji/src/devnw/codepros/geode/geode/docs/DISTRIBUTED_QUALITY_GAP_ANALYSIS.md` | Distributed quality | Historical |
| `/home/benji/src/devnw/codepros/geode/geode/docs/DISTRIBUTED_SECURITY_GAP_ANALYSIS.md` | Distributed sec | Historical |
| `/home/benji/src/devnw/codepros/geode/geode/docs/MIGRATION_GAP_ANALYSIS.md` | Migration | GAP-0537 was highest prior |
| `/home/benji/src/devnw/codepros/geode/geode/docs/MIGRATION_GAP_ANALYSIS_RESOLVED.md` | Migration | Archive |
| `/home/benji/src/devnw/codepros/geode/geode/docs/GQL_GAP_ANALYSIS.md` | GQL conformance | All 70/70 ISO tests passing |
| `/home/benji/src/devnw/codepros/geode/geode/docs/GQL_CONFORMANCE_GAP_ANALYSIS.md` | GQL conformance | Archive |

### Roll-up (active ledgers only)

| File | Open | Partial | Closed | Blocked | Won't Do | Total |
|------|-----:|--------:|-------:|--------:|---------:|------:|
| `docs/GAP_ANALYSIS.md` | 10 | 2 | many | 0 | 0 | 12 |
| `docs/PERF_GAP_ANALYSIS.md` (Phase 3 ranks 44-52) | 9 | 0 | — | 0 | 0 | 9 |
| `docs/QUALITY_GAP_ANALYSIS.md` (Top 20 ≥ PS 3) | 15 | 0 | — | 0 | 0 | 15 |
| `docs/SECURITY_GAP_ANALYSIS.md` (Top 12) | 11 | 0 | — | 0 | 1 | 12 |
| **Cross-domain tracker (#710-744)** | **35** | 0 | 0 | 0 | 0 | 35 |

---

## Build/Test Tooling

| Action | Command | Config Source |
|--------|---------|---------------|
| Build (debug) | `zig build` | `build.zig` + `build.zig.zon` |
| Build (release) | `zig build -Doptimize=ReleaseFast` (Makefile: `make release`) | same |
| Unit tests | `zig build test` / `make test` | `build.zig` test step |
| Integration tests | `python3 scripts/test/extended_test_runner.py` or `make geodetestlab-comprehensive` | external harness `../geode-test-harness` |
| Lint (Zig format) | `zig fmt --check src/ build.zig` | — |
| Lint (Python) | `ruff check scripts/ tools/` | `pyproject.toml` / default |
| Lint (Shell) | `shellcheck` on `shells/**/*.sh` | — |
| Lint (Markdown) | `markdownlint docs/**/*.md` | `.markdownlint.yml` if present |
| Secret scan | `gitleaks detect` | `.gitleaks.toml` |
| CVE scan | `trivy fs --scanners vuln,secret .` | — |
| Governance | `make status-generate` → `tools/status_generate.py` | `tools/canaryscan/` |
| Pre-commit | `make pre-commit` / `pre-commit run --all-files` | `.pre-commit-config.yaml` |
| Load test | `make loadtest-compare` / `make loadtest-save-baseline` | `benchmarks/loadtest/baseline.jsonl` |

---

## Baseline Test Results (captured 2026-04-16)

### `zig build` — **FAIL** (expected; this is GAP-0538)

```
compile exe geode Debug native 1 errors
src/cli/transport_response.zig:171:16: error: no field or member function named 'writeAll' in 'Io.File'
        try out.writeAll(json_out);
referenced by:
    render__anon_576714: src/client/query_result_accumulator.zig:145:69
    executeQueryOnGrpc:  src/cli/main.zig:1897:26
Build Summary: 32/35 steps succeeded (1 failed)
```

Exactly three call sites as documented. `zig build test`, `zig build test --summary all`, `make verify-fast`, `make status-generate` downstream checks are all BLOCKED until GAP-0538 resolves.

### `zig fmt --check src/ build.zig` — **FAIL** (30 files)

Full list (merge-blocker under CI `zig-format@v1.2.1`):

```
src/benchmarks/adaptive_replan_autotune_variance.zig
src/benchmarks/variance_config.zig
src/client/repl/session_state.zig
src/client/repl/repl_config.zig
src/client/repl/spinner.zig
src/client/repl/test_repl_advanced_features.zig
src/client/repl.zig
src/distributed/sharding.zig
src/distributed/nonce_tracker.zig
src/distributed/test_query_transport_node_registry.zig
src/distributed/raft_consensus.zig
src/execution/statement_handlers.zig
src/execution/call_operations.zig
src/txn_undo_log.zig
src/index/selectivity.zig
src/schema/fle_catalog.zig
src/schema/catalog.zig
src/ml/integration_enhanced.zig
src/gql/main.zig
src/exec.zig
src/cli/backup_cli.zig
src/cli/main.zig
src/cli/lsp/server.zig
src/cli/user_management.zig
src/cli/cli_dispatcher.zig
src/server/quic_connection_handler.zig
src/storage/s3_backup.zig
src/transport/grpc_server.zig
src/security/tde_key_manager.zig
src/security/external_kms_client.zig
```

### Other scanners (already captured by Phase 2)

| Tool | Result |
|------|--------|
| `ruff check` | 19 errors (UP006×10, UP035×4, SIM102×2, C414×2, B007×1) |
| `shellcheck` | 7 errors (e.g. `scripts/comprehensive_graph_test.sh:103` SC1089) |
| `markdownlint` | 532 violations (MD031×208, MD032×196, MD022×47) |
| `gitleaks` | 42 unallowlisted hits (test fixtures + `audit.jsonl` tree entry) |
| `trivy fs` | 2 HIGH (protobuf 4.25.1 CVE-2025-4565, CVE-2026-0994) + 1 MEDIUM (quic-go v0.54.1 CVE-2025-64702) |
| `canary_lint.py` | PASS |
| `status_generate.py` | PASS with 4 `STATUS=COMPLETE` + 16 blank rows (schema violation) |

---

## Actionable Items (Ordered for Implementation)

Severity → severity label from audit; Effort = XS (≤30min) / S (≤2h) / M (≤½day) / L (≤2d) / XL (>2d).
Commit strategy: one commit per GAP-ID/issue where isolated; grouped where natural (e.g. all ruff auto-fixes).

### Wave 1 — Unblock the build (MUST land first)

| Order | Gap-ID | Issue | Title | Severity | Effort | Acceptance Criteria | Affected Areas |
|:----:|---|---:|---|---|:---:|---|---|
| 1 | GAP-0538 | #710 | Zig 0.16.0 build regression — `Io.File.writeAll` removed | **Critical** | S | `zig build` exits 0; `zig build test` succeeds; `build.zig.zon:6` set to `0.16.0`; `CLAUDE.md:267` banner updated | `src/cli/transport_response.zig:171`, `src/client/query_result_accumulator.zig:145`, `src/cli/main.zig:1897`, `build.zig.zon:6`, `CLAUDE.md` |

**Dependency root:** every later wave depends on wave 1. Do not interleave.

### Wave 2 — Quick-win hygiene (batchable in a single PR)

| Order | Issue | Title | Severity | Effort | Acceptance Criteria | Affected Areas |
|:----:|---:|---|---|:---:|---|---|
| 2 | (internal) | `zig fmt src/ build.zig` sweep across 30 listed files | merge-blocker | XS | `zig fmt --check` exits 0 on `src/` and `build.zig` | 30 files (see baseline list) |
| 3 | #717 | Delete `statement_dispatcher.zig:121` 1,114-LOC dead `executeStatementWithContext` clone; move live helpers to `execution/index_runtime.zig` | High | S | Build + tests green; grep for `statement_dispatcher.executeStatementWithContext` returns 0 hits; `ensureAdvancedRuntimeIndex`/`runtimeAdvancedIndexTypeFromCatalog` callable from new file | `src/execution/statement_dispatcher.zig`, `src/execution.zig`, callers (none) |
| 4 | #738 | SEC-AUD-02 one-keystroke remediation: `git rm --cached audit.jsonl`; extend `.gitignore` for `audit.jsonl*` + `*.key` beside logs | Medium | XS | `audit.jsonl` absent from `git ls-files`; `.gitignore` covers `audit.jsonl`, `audit.jsonl.key`, `*/audit.jsonl*` | `.gitignore`, git tree (history entry at `c8b7c44f` noted but not rewritten) |
| 5 | #736 | Governance scripts ruff-clean: auto-fix 19 errors in `tools/canary_check.py`, `tools/status_generate.py` | Medium | XS | `ruff check scripts/ tools/` exits 0; `make status-generate` still produces identical CSV | `tools/canary_check.py`, `tools/status_generate.py`, `scripts/*.py` (UP006/UP035 imports) |
| 6 | (GAP-0539) | `status_generate.py`: reject non-schema STATUS; guard HCL `"REQ-... {` false positives | Medium | S | `docs/status.csv` has 0 rows with `STATUS=COMPLETE`, 0 blank-status rows; CI check added | `tools/status_generate.py`, test fixture under `tools/canaryscan/` |
| 7 | (GAP-0540) | Re-generate + commit `tools/canaryscan/status.csv` to resync 210 REQ-ID delta; add pre-push sync check | Low | XS | `tools/canaryscan/status.csv` byte-equal to freshly-generated `docs/status.csv`; CI `status-csv-drift` job added | `tools/canaryscan/status.csv`, `.gitlab-ci.yml` |
| 8 | (GAP-0541) | Remove GAP-0249 stale link at `docs/REQUIREMENTS.md:82` | Low | XS | Line gone; `glab issue view 542 --state` confirms closed | `docs/REQUIREMENTS.md` |
| 9 | #716 | Bump `.gitlab-ci.yml` Zig pin to 0.16.0 (unblocks CI after wave 1); reconcile pre-commit config | Merge-blocker | XS | CI green on main; `grep -n 0.15` in `.gitlab-ci.yml`, `build.zig.zon`, `CLAUDE.md` returns only historical comments | `.gitlab-ci.yml`, `.pre-commit-config.yaml` |

### Wave 3 — Critical security (7-day SLA)

| Order | Issue | Title | Severity | Effort | Acceptance Criteria | Affected Areas |
|:----:|---:|---|---|:---:|---|---|
| 10 | #723 *(conf)* | SEC-RLS-01: RLS VM stack OOB — add `sp` bounds + `@enumFromInt` safe-cast | **Critical** (Risk 30) | M | Fuzz policy with 65 `push_true` returns `error.StackOverflow`, no crash; new test in `tests/test_rls_vm_fuzz.zig`; `@enumFromInt` replaced by `@intFromEnum`-returning validator | `src/security/rls_core.zig:642-848` |
| 11 | #727 *(conf)* | SEC-AUD-01: audit verifier validates `seq_no` per line | **Critical** (Risk 24) | S | `geode_audit_verify.zig` asserts `parsed.seq_no == expected_seq`; forged-gap test case rejects; regression test added | `src/cli/geode_audit_verify.zig:60-128` |
| 12 | #737 | SEC-INFRA-01: `GEODE_CLUSTER_INSECURE` Debug-gate + audit log + startup banner + metric counter | **Critical** (Risk 24) | M | Release build refuses insecure env unless `GEODE_ACKNOWLEDGE_INSECURE=yes`; insecure boot emits single audit event + counter `geode_cluster_insecure_total` | `src/distributed/cluster_auth.zig`, `src/distributed/federation.zig`, `src/server/main.zig`, plus 3 more modules |
| 13 | #732 *(conf)* | SEC-RLS-02: reject `expr.raw != null and expr.compiled == null` (fail-closed fallthrough) | High (Risk 16) | S | `evaluateExpression` returns `error.UnsafePolicy` when only raw-string available; persistence path refuses to store raw-only policy; regression test | `src/security/rls_core.zig:631, 1441-1532` |
| 14 | #739 | SEC-M1: Vault KMS env inheritance + `key_path` validation | Medium (Risk 12) | S | `env_map = try std.process.getEnvMap(alloc)` (inherited); `key_path` validated against allowlist; failure of inherit logged | `src/security/vault_kms_provider.zig:163,167,251,270` |
| 15 | #741 | SEC-M3: metrics server — require bind auth or pin to loopback in release | Medium (Risk 6) | S | Release build rejects non-loopback bind without `GEODE_METRICS_AUTH` token; regression test | `src/monitoring/metrics_server.zig:47-97` |
| 16 | #744 | SEC-L4: `--insecure-tls-skip-verify` flag gated in release | Low (Risk 6) | XS | CLI refuses flag unless `GEODE_ENV != production`; help text warns | `src/cli/main.zig:1054`, `src/cli/cli_dispatcher.zig:490` |

### Wave 4 — P0 performance wins (compose into single A/B benchmark)

| Order | Issue | Title | Severity | Effort | Acceptance Criteria | Affected Areas |
|:----:|---:|---|---|:---:|---|---|
| 17 | #715 | P0-1 per-row RLS alloc fast-path — engine-null check BEFORE `nodePropertiesToRLSRow` | P0 (PS 80) | S | Tracking-allocator test `MATCH (n:L) RETURN n LIMIT 1000 × 10k` shows <100 allocs (pre ≥20k); new micro-benchmark in `src/benchmarks/` | `src/execution/match_operations.zig:104-145`, `src/security/rls_value_bridge.zig:55-69` |
| 18 | #718 | P0-2 QUIC handler wake storm — switch `poll_cv.broadcast` to per-stream signal | P0 (PS 72) | M | `ping_c4` restores to ≥700 qps (currently 646); flamegraph `poll_cv.broadcast` not in top 10 | `src/transport/quic.zig:389-404`, `src/server/quic_connection_handler.zig:329-337` |
| 19 | #720 | P0-3 TDE key cache — cache `AES ctx` + hex-decoded key per file | P0 (PS 72) | S | `make bench-tde` shows ≥4× throughput (30→120+ MB/s); per-page 3μs→<100ns | `src/storage/tde_file_encryption.zig:59-96, 135-143, 190-203` |
| 20 | #722 | P0-4 thread-pool freelist — reuse `SubmittedTask` slabs | P0 (PS 64) | S | `perf record` shows no `allocator.create(SubmittedTask)` in top 50 | `src/transport/thread_pool.zig:262-274` |
| 21 | #731 | P1 per-request arena in `match_operations.zig` for `evalExpr` | P1 (PS 64) | M | `checkPushedPredicates`/`checkNodeProperty`/`matchesEdgeProperties` all take arena; `MATCH` error-path leak fixed; test harness `matchOps` snapshot | `src/execution/match_operations.zig:183-267, 864-946, 1542-1577` |
| 22 | #721 | P1 thread-pool lane split (CPU vs I/O) | P1 | S | `submit(.cpu)` and `submit(.io)` both accept work; CPU MATCH doesn't stall behind I/O | `src/transport/thread_pool.zig:203-214` |
| 23 | #724 | P1 StorageAdapter `Mutex` → `RwLock` on 7 read-only accessors | P1 | M | Concurrent reads scale linearly through c=16; lock-ordering table unchanged (still tier-0) | `src/storage/graph_storage_adapter.zig:668-750` |
| 24 | #728 | P1 per-stream federation init gated by `GEODE_CLUSTER_TOKEN` | P1 | S | Stream accept 200-500μs → <50μs when not in cluster mode; federation objects lazy-init on first federated query | `src/server/quic_connection_handler.zig:704-745` |

### Wave 5 — Higher-effort structural + remaining perf

| Order | Issue | Title | Severity | Effort | Acceptance Criteria | Affected Areas |
|:----:|---:|---|---|:---:|---|---|
| 25 | #719 | Decompose 2,567-LOC `executeMatchQueryImpl` via existing 4-way dispatcher seam (line 4585) | High (PS 80) | L | Each branch ≤500 LOC in its own file under `src/execution/match/`; dispatcher unchanged; zero perf regression | `src/execution/match_operations.zig:4543-7000+` |
| 26 | #720-split | Decompose `loadKey()` path (companion to #720) | High | S | 8 call sites route through `tdeKeyCache.get()`; cache hit path is branch-predictable | `src/storage/tde_file_encryption.zig` |
| 27 | #725 | Planner DP leak fix — arena + free unused | P1 | M | `perf record` p99 tail reduced; RSS growth on long sessions flat | `src/planner/cbo.zig:166-240` |
| 28 | #726 | `getEdgesByType` — drop `bufPrint` composite key, null-tenant fast-path | P1 | S | Two-hop benchmark shows −30-50% on type-filtered | `src/graph_store.zig:3021-3076` |
| 29 | #729 | DRR scheduler — top-K heap replaces full 256-sort | P2 | M | Per-call 5μs→1μs; fan_out c=32 +≤8% | `src/transport/stream_scheduler.zig:111-184` |
| 30 | #730 | `checkPushedPredicates` — compile-once-at-plan WHERE AST | P2 | M | Pairs with #731 arena; 2× WHERE-heavy perf | `src/execution/match_operations.zig:183-267, 879-884` |
| 31 | #733 | WAL fsync — dirty-flag gate | P2 | S | `iostat -x 1` idle write IOPS 1→0 | `src/graph_store.zig:5184-5205`, `src/wal.zig:241-248` |
| 32 | #734 | QUIC `writeAll` CV-on-window-update | P2 | M | p99 10s spin → sub-ms; no HOL on flow-control | `src/transport/quic.zig:705-728` |
| 33 | #735 | `nextMessage` WouldBlock counter reset on activity | P2 | S | Idle ctx-switch reduction; pairs with #718 | `src/server/quic_connection_handler.zig:282-356` |
| 34 | #740 | SEC-M2 dead-code hardening: delete or `@compileError` guard on `aggregation_evaluation.zig:629-692` | Medium (Risk 10) | S | Either functions deleted or `comptime builtin.is_test` guard; regression: cross-tenant `COUNT(*)` test asserts dead path unreachable | `src/execution/aggregation_evaluation.zig:629-692` |
| 35 | (GAP-0542) | NodeRegistry single-source — extract to `src/distributed/node_registry.zig`; delete inline copy in test | Medium | S | Sole definition in new module; test imports it; `zig build test` green | `src/distributed/query_transport.zig:607-664`, `src/distributed/test_query_transport_node_registry.zig:53-112` |
| 36 | #743 | SEC-M4 cluster-token rotation scaffold (per-node mTLS pinning intent) | Medium (Risk 15) | L | `GEODE_CLUSTER_TOKEN` hash-compare still works; new `cluster_auth.rotateToken()` API callable; docs reference SPIFFE migration | `src/distributed/cluster_auth.zig:17-56` |

### Wave 6 — Low-priority governance and docs

| Order | Issue | Title | Severity | Effort | Acceptance Criteria | Affected Areas |
|:----:|---:|---|---|:---:|---|---|
| 37 | #712 | Depth-13 nesting refactor — guard-clause in `grpc_server.zig:1905`, `quic_connection_handler.zig:2185`, `match_operations.zig:1196` | Medium (PS 3) | M | Max nesting ≤10 in the three files; same behavior; tests pass | 3 files listed |
| 38 | #713 | `catch {}` categorization + logging policy (653→≤100) | Medium (PS 4) | L | Top-20 files carry `result_utils.zig:13`-style policy comment; `grep -c 'catch {}'` per-file ≤5 except in documented display-write paths | Top files: `cli/transport_response.zig`, `cli/main.zig`, `transport/quic.zig`, `transport/grpc_server.zig` |
| 39 | #714 | `gitleaks` allowlist for `.bak`/`.ec`/`.rsa.bak` test cert fixtures + `tde_*.yml` | Medium (PS 4) | XS | `gitleaks detect` clean; `.gitleaks.toml` covers cited paths | `.gitleaks.toml`, `clients/test-harness/certs/`, `geodetestlab/specs/tde_*.yml` |
| 40 | #742 | SEC-M4 Blake2b legacy — force `password_reset_required=true` on match; log migration event | Medium (Risk 9) | S — see Won't-Do | Partial-do: flag is set on match; upstream migration ownership noted | `src/security/geode_auth_lib.zig:1068-1092` |
| 41 | #711 | `catch unreachable` audit — replace 84 instances at parse/IO sites with `catch \|err\| return err` | Medium (PS 4) | M | `grep -n 'catch unreachable'` in `types/jsonb.zig`, `types/datetime.zig`, `graph_store.zig`, `cli/main.zig` drops to zero on non-comptime paths | 4+ files |

---

## Won't-Do Candidates

| Item | Source | Reason |
|---|---|---|
| GAP-0542 CI byte-identical diff check for NodeRegistry | Alt to single-source extraction | **Recommend DO the extraction instead** (Wave 5 #35). CI diff check treats the symptom (drift detection) not the cause (duplication); Zig's module system supports extraction cheaply. Extraction is chosen; CI-only variant is Won't-Do. |
| SEC-AUTH-01 / #742 Blake2b upstream migration path | Security phase 3 finding #9 | Partial-fix (force `password_reset_required`) is in scope (Wave 6 #40). Full migration to Argon2id for already-stored Blake2b hashes requires upstream `auth` vendor library coordination. **Won't-Do:** plumbed through to vendor (not this repo's control). The single-line "force reset flag" lands; everything else waits on `zig/auth` vendor update. |
| Platform-wide CI pin-enforce bot | Quality #716 follow-on | Pre-commit.ci / GitLab CI pinning of exact runner image is out of scope for the repo PR. **Won't-Do within this sprint;** opens follow-up ticket for platform-infra team. |
| Docker base-image CVE remediation (Trivy MEDIUM on `quic-go@v0.54.1` in go tooling only) | Phase 2 trivy output | Affects `tools/` Go loadtest only, not shipping runtime. **Won't-Do:** noted, scheduled for next tooling refresh, not a blocker. |
| markdownlint 532 violations mass-fix (docs/testing/SHELL_TEST_ISSUES.md 247 lines) | Quality finding #19 | File is auto-generated; fixing by hand will regress on next regen. **Won't-Do:** instead fix the generator or allow-list auto-generated files. |
| Full Blake2b → Argon2id hash migration in-place | Security finding #9 | Requires user re-auth or upgrade migration plan. Out of scope for engineering PR. **Won't-Do:** tracked as separate OPS-owned RFC. |

---

## Dependencies

- **Wave 1 (GAP-0538) blocks all waves 2-6.** No other plan item can be tested until `zig build` exits 0.
- **Wave 2 item #3 (delete dead clone) depends on wave 2 item #2 (fmt sweep)** — the dead file is in the fmt list; deleting avoids a pointless reformat.
- **Wave 2 item #5 (ruff auto-fix) depends on item #4 (tree cleanup)** — auto-fix touches same files; easier on a clean tree.
- **Wave 4 items #17+#20+#21 (P0 composite)** need to land together for the loadtest A/B baseline to be interpretable; expected `#715+#722+#731` composite p50 2.7→1.5-1.8ms, QPS +25-40%.
- **Wave 4 #18 QUIC wake storm** must land before rerunning `make loadtest-save-baseline`; `ping_c4` 727→646 regression must first recover, otherwise new baseline will codify the regression.
- **Wave 3 #10 RLS VM OOB fix (#723)** blocks any forward wire of a GQL→bytecode policy path; until OOB fix lands, `CREATE POLICY` parser work is unsafe to enable. (Confirms Known Limitation "policies must be pinned with a pre-compiled `CompiledExpression`".)
- **Wave 4 #23 StorageAdapter `Mutex → RwLock`** requires no tier-inversion per CLAUDE.md `graph_handles_mutex` tier-0 ordering — verify before committing.
- **Wave 5 #25 match decomposition (#719)** should not pair with Wave 4 perf work in the same commit; decomposition needs its own loadtest A/B to attribute any perf delta correctly.

---

## Blockers

- **Platform-level** collision: GitLab issues #666 ("GAP-0514: Deterministic nonce…") and #656 ("GAP-0509: Debug builds use hardcoded password…") reuse flatfile Gap-IDs whose meaning differs. Not a closure blocker, but will cause confusion during verification. Flag to project maintainers; recommend a cross-cutting cleanup sprint *after* wave 1.
- **Trivy scanner** not run locally during Phase 2 beyond the captured 3 CVEs. Re-run `trivy image` on the published container image before treating supply-chain surface as ground truth.
- **Hyperfine / pprof** not installed on host; Phase 3 perf estimates are static-analysis derived. After wave 1 lands, install `hyperfine` + run `make loadtest-save-all-baselines` (currently only `ping` is baselined) to populate quantitative regression thresholds for `point_read`/`one_hop`/`two_hop`/`fan_out`.
- **Gap 710 vs 715 ordering** — GAP-0538 (#710) strictly precedes perf P0s. Tooling that captures `perf record` / allocator-tracking requires the build to work.

---

## Ambiguous Acceptance / Missing-File Flags

- **#742 Blake2b migration path:** acceptance text says "audits and returns `true` but does not set `password_reset_required`" — the file-line `src/security/geode_auth_lib.zig:1068-1092` exists, but the "migration enforcement" mechanism (where is the flag read?) needs explicit call-site identification before the patch lands. Add a trace-through step in Wave 6 prep.
- **GAP-0540 (`status-csv-drift` CI job):** requires `.gitlab-ci.yml` edit; assuming runner capability exists. If not, add as a pre-push hook in `make pre-commit` instead.
- **Wave 6 #37 (depth-13 refactor):** target depth is specified as ≤10 but audit numbers vary (some files at 12, some at 13). Clarify per-file target in the implementation commits.
- **#743 cluster-token rotation** scaffold acceptance criterion ("per-node mTLS pinning intent") is forward-looking. The actual runtime rotation is deferred; only API shape and docs land this wave.

---

## Summary Stats

| Metric | Value |
|---|---|
| Total actionable items | 41 (1 wave-1, 8 wave-2, 7 wave-3, 8 wave-4, 12 wave-5, 5 wave-6) |
| Won't-Do items | 6 |
| Estimated commit count | **~26 commits** (wave-1 1, wave-2 3-4 batched, wave-3 7, wave-4 8, wave-5 ~10 split, wave-6 5) |
| Total effort estimate | ~18-22 engineer-days (1 dev, serial); ~10-12 days parallel (2-3 devs respecting wave gates) |
| Baseline state at T=0 | `zig build` FAIL (GAP-0538), `zig fmt --check` 30 files dirty, `ruff` 19, `shellcheck` 7, `gitleaks` 42, `markdownlint` 532, `trivy` 3 CVEs |

Estimated breakpoints in commit plan:

- **Commits 1-4:** wave 1 + wave 2 hygiene (build unblock, fmt sweep, dead-clone, .gitignore)
- **Commits 5-7:** wave 2 tooling (ruff, status-generate, REQUIREMENTS.md, CI pin)
- **Commits 8-14:** wave 3 security (one per issue, confidential branch protection)
- **Commits 15-22:** wave 4 P0 perf (P0 composite in 3 commits, P1s separate)
- **Commits 23-32:** wave 5 structural decomposition (#719 alone may be 2-3 commits)
- **Commits 33-36:** wave 6 governance/docs

---

*Next step: ask for confirmation to begin Wave 1 implementation (GAP-0538 / #710 only). Do not touch later waves until `zig build` is green.*
