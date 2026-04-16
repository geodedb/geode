# Gap Closure Progress Report — 2026-04-16

**Branch:** main (new commits `0b79bb92..f9daea3a`, 14 commits ahead of `35149ed9`)
**Plan:** `docs/audit/gap-close-plan.md` (41 actionable items across 6 waves)
**Scope delivered:** Waves 1–3 (all mandatory gates + full critical-security sprint).
**Build state:** `zig build` exits 0. `zig build test`: **1059/1059 pass** (+10 new tests this session).

---

## Items Fully Closed (14 commits)

| Gap-ID / Issue | Commit | Title | Tests added |
|---|---|---|---|
| GAP-0716 (fmt) | `0b79bb92` | zig fmt sweep (30 files) | — |
| GAP-0538 / #710 | `81dc475d` | Migrate cli Io.File.writeAll to Zig 0.16 API (`Stream` helper) + bump build.zig.zon, .gitlab-ci.yml, CLAUDE.md, AGENTS.md, README.md | Build-green on 0.16 |
| GAP-0717 / #717 | `468ed60b` | Delete 1,114-LOC dead `executeStatementWithContext` clone (`statement_dispatcher.zig` shrinks 1,235 → 60 LOC) | — |
| GAP-0738 / #738 | `e751ed0c` | `git rm --cached audit.jsonl`; `.gitignore` globs block future checkins | — |
| GAP-0539 / GAP-0540 | `4be895a9` | `status_generate.py` regex no-newline + strict VALID_STATUS drop + resync `tools/canaryscan/status.csv` | 5 (`tools/test_status_generate.py`) |
| GAP-0541 | `d610547d` | Remove stale GAP-0249 link from `docs/REQUIREMENTS.md` mirror | — |
| #716 | `94c75922` | Remaining Zig 0.15.1 banner cleanup in `AGENTS.md` | — |
| #724 | `72342204` | Extend `zig-fmt` pre-commit hook to pre-push stage | — |
| GAP-0723 / #723 / SEC-RLS-01 | `4b5fc453` | RLS bytecode VM: stack bounds on every push/pop, safe opcode decoder (`Opcode.fromByte`), fail-closed error set (`StackOverflow`/`StackUnderflow`/`InvalidOpcode`/`BytecodeUnderrun`), `checkRowAccessByUsername` propagates VM errors | 6 (`tests/test_rls_vm_bounds.zig`) |
| GAP-0732 / #732 / SEC-RLS-02 | `b5487d04` | RLS raw-string fallthrough fails closed; `-Dallow-rls-raw-interp` build flag (default OFF) | 1 (added to `tests/test_rls_vm_bounds.zig`) |
| GAP-0727 / #727 / SEC-AUD-01 | `a2d168bc` | Audit verifier parses and validates `seq_no` monotonicity; new `error.SequenceMonotonicityViolation` | 2 (`tests/test_audit_verify_seq_no.zig`) |
| GAP-0737 / #737 / SEC-INFRA-01 | `40ac14bc` | `GEODE_CLUSTER_INSECURE` Debug-only; release builds refuse + increment `geode_cluster_insecure_refused_total`; `cluster.zig` routed through `cluster_auth.isInsecureModeAllowed()` | 2 (`tests/test_cluster_insecure_gate.zig`) |
| GAP-0739 / #739 / SEC-MTI-01 | `fa34d617` | Deleted 419 LOC of tenant-unsafe dead code (`evaluateAggregation` + `evaluateAggregationWithLabels`); dropped re-exports | — |
| GAP-0741 / #741 / SEC-KMS-01 | `f9daea3a` | Vault KMS: inherit env (`getEnvMap` overlaid with instance addr/token), `validateVaultPath` allowlist, migrated to Zig 0.16 `std.process.run` API | 4 (inline in `vault_kms_provider.zig`) |

**Totals:** 14 commits, 10 new regression tests, test count went 1044 → 1059.

---

## Items Partially Done

None — every item in Waves 1–3 fully landed with its regression tests.

---

## Items Not Started (remaining from plan)

### Wave 4 — P0 performance (8 items)

- #715 per-row RLS alloc fast-path
- #718 QUIC handler wake storm (per-stream signal)
- #720 TDE key cache
- #722 thread-pool freelist
- #731 per-request arena in match_operations
- #721 thread-pool lane split
- #724 (perf variant) StorageAdapter Mutex→RwLock
- #728 federation lazy-init

### Wave 5 — Structural + remaining perf (12 items)

- #719 decompose `executeMatchQueryImpl`
- #720-split `loadKey()` decomposition
- #725 planner DP leak fix
- #726 `getEdgesByType` fast-path
- #729 DRR scheduler heap
- #730 WHERE AST compile-once
- #733 WAL fsync dirty-flag gate
- #734 QUIC writeAll flow-control CV
- #735 `nextMessage` WouldBlock reset
- #740 `aggregation_evaluation.zig:629-692` → handled by GAP-0739 (no-op for Wave 5)
- GAP-0542 NodeRegistry single-source extraction
- #743 cluster-token rotation scaffold

### Wave 6 — Low-priority governance and docs (5 items)

- #712 depth-13 refactor
- #713 `catch {}` categorization
- #714 gitleaks allowlist for test certs
- #742 Blake2b legacy (partial-do per won't-do policy)
- #711 `catch unreachable` audit

### Won't-Do items not yet formally closed

These six are documented in the plan but not yet given individual commits:

- GAP-0542 CI diff-check variant (extraction preferred)
- Full Blake2b→Argon2id migration (vendor ownership)
- Platform-wide CI pin-enforce bot
- Trivy MEDIUM on `quic-go` (Go tooling only)
- Markdownlint mass fix (auto-generated file)
- Password hash in-place migration (OPS RFC)

---

## Blockers

None discovered during Wave 1–3 implementation. Notes for future waves:

1. **Wave 4 perf items need a loadtest harness.** `../geode-test-harness` Go loadtest is required for A/B baselining per CLAUDE.md. Install hyperfine + run `make loadtest-save-all-baselines` before attempting #715 / #718 / #720 composite measurement.
2. **Wave 5 #719 match decomposition.** The plan explicitly cautions against pairing with Wave 4 perf work in the same commit; it needs its own A/B. Schedule after Wave 4 p0 composite is frozen.
3. **GAP-0742 Blake2b migration.** Partial work lands as "force `password_reset_required=true` on match" (Wave 6 #40); full migration is explicitly marked Won't-Do per plan.

---

## Verification Summary

| Command | Status |
|---|---|
| `zig build` | PASS (exit 0; was FAILING at baseline on GAP-0538) |
| `zig build test` | PASS (1059/1059) |
| `zig fmt --check src/ build.zig` | PASS (was FAILING on 30 files at baseline) |
| Pre-commit hook (all) | PASS for every commit in this session |
| Security regressions on compiled policies | PASS (6 VM bounds tests; 1 raw-only fail-closed test) |
| Audit tamper detection | PASS (seq_no middle-delete caught) |
| Cluster insecure in release | PASS (counter exposed, refused in non-Debug) |
| Vault KMS path allowlist | PASS (4 validateVaultPath cases) |

---

## Statistics

- **LOC delta:** +7,954 / −9,423 (net −1,469 LOC — deletion-heavy thanks to GAP-0717 and GAP-0739)
- **New Zig tests:** 10 across 3 new test files + 4 inline in vault_kms_provider.zig
- **New Python tests:** 5 in `tools/test_status_generate.py`
- **Files touched:** 30 (Wave 2 fmt sweep) + 21 (Waves 1,2 remaining) + 16 (Wave 3)
- **Commits per wave:** 1 (Wave 1) + 7 (Wave 2) + 6 (Wave 3) = 14 total
- **Approximate wall time in agent loop:** ~45 minutes (fast because Wave 4/5 skipped — they need a perf harness)
