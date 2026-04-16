# Full Codebase Audit Summary — 2026-04-16

## Repository

- **Project:** Geode (ISO GQL graph database)
- **Platform:** GitLab (`devnw/codepros/geode/geode`)
- **Languages:** Zig 0.16.0 (primary, ~276k LOC src/), Python (tools/, scripts/), Go (tools/canaryscan/), Shell (shells/)
- **Scope:** Entire repository
- **Branch:** main (HEAD `35149ed9`)
- **Prior audit:** docs/FULL_AUDIT_2026_04_06.md

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|---|---|---|
| Implemented (TESTED+BENCHED) | 3,358 | 87.4% |
| Partial (IMPL-only) | 397 | 10.4% |
| Exempt | 270 | 7.0% |
| Unique REQ IDs | 2,862 | — |

**Open gaps after Phase 3:** 12 (7 pre-existing + 5 new)
**Severity breakdown (new gaps only):** Critical 1, Medium 2, Low 2

### Code Quality

| PriorityScore band | Count |
|---|---|
| 100 (merge-blocker) | 2 |
| 80 | 3 |
| 48-64 | 4 |
| 36 | 3 |

**PriorityScore top finding:** Zig toolchain pin drift (0.15.1/0.15.2/0.16.0) — score 100, issue [#716](https://gitlab.com/devnw/codepros/geode/geode/-/work_items/716).
**Tool output:** `zig build` fails, `zig fmt` flags 30 files, `ruff` 19 errors, `shellcheck` 7, `markdownlint` 532, `gitleaks` 42 (test fixtures), `trivy` 3 CVEs.

### Performance

| PerfSeverity | Count |
|---|---|
| P0 | 3 |
| P1 | 4 |
| P2 | 2 |
| P3 | 0 |

**PerfScore top finding:** Per-row RLS alloc (`match_operations.zig:131 nodePropertiesToRLSRow`) — score 80, issue [#715](https://gitlab.com/devnw/codepros/geode/geode/-/issues/715). Expected: MATCH row-rate +30-80% single-tenant.
**Composite delta (#715+#722+#731):** p50 2.7→1.5-1.8ms, QPS +25-40% at c=2..8, zero I/O changes.
**ping_c4 regression (727→646 qps, 4 errors) attributed to #718 QUIC wake storm.**

### Security

| Risk Level | Count |
|---|---|
| Critical (Risk ≥24) | 3 |
| High (16-20) | 2 |
| Medium (7-15) | 5 |
| Low (<6) | 1 |

**Immediate actions (7-day SLA):** 3 confidential issues — [#723](https://gitlab.com/devnw/codepros/geode/geode/-/issues/723) RLS VM stack OOB, [#727](https://gitlab.com/devnw/codepros/geode/geode/-/issues/727) audit seq_no bypass, [#732](https://gitlab.com/devnw/codepros/geode/geode/-/issues/732) RLS raw-string fallthrough.
**One-keystroke remediation:** `git rm --cached audit.jsonl` + `.gitignore` sweep (SEC-AUD-02).

## Cross-Domain Summary

| Domain | Findings | Issues Created | Issues Updated | Docs Updated |
|---|---|---|---|---|
| Gap Analysis | 5 new / 2 evidence-updated | 5 (#710-714) | 0 | 2 |
| Quality | 15 ranked | 10 (#716-736) | 5 (commented) | 1 |
| Performance | 15 | 9 (#715-735) | 0 | 1 |
| Security | 13 | 11 (#723-744, 3 confidential) | 2 (commented) | 1 |
| **Total** | **48** | **35** | **7** | **5** |

## Docs Updated

| File | Domain | Action |
|---|---|---|
| docs/GAP_ANALYSIS.md | Gap | updated (12 open gaps; 5 new sections + 2 evidence updates) |
| docs/REQUIREMENTS.md | Gap | updated (5 gap entries added) |
| docs/QUALITY_GAP_ANALYSIS.md | Quality | updated (Phase 4 section, 302→362 lines) |
| docs/PERF_GAP_ANALYSIS.md | Performance | updated (April 2026 audit section with ranks 44-52) |
| docs/SECURITY_GAP_ANALYSIS.md | Security | updated (Phase 3 section prepended) |
| docs/audit/gap-phase{1,2,3}-*.md | Gap | 3 phase reports |
| docs/audit/quality-phase{1,2,3}-*.md | Quality | 3 phase reports |
| docs/audit/perf-phase{1,2,3}-*.md | Performance | 3 phase reports |
| docs/audit/security-phase{1,2,3}-*.md | Security | 3 phase reports |

## Top 10 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | Score | Issue |
|---|---|---|---|---|---|
| 1 | Gap | GAP-0538: Zig 0.16.0 build regression — `Io.File.writeAll` removed at 3 sites; `build.zig.zon:6` still pins 0.15.1 | Critical | — | [#710](https://gitlab.com/devnw/codepros/geode/geode/-/issues/710) |
| 2 | Security | SEC-RLS-01: RLS VM stack OOB — 65 `push_true` opcodes overflow fixed `[64]Value` stack; no sp bounds checks | Critical | Risk 30 | [#723](https://gitlab.com/devnw/codepros/geode/geode/-/issues/723) *(confidential)* |
| 3 | Security | SEC-AUD-01: audit verifier skips `seq_no` — tail-insert/splice undetectable | Critical | Risk 24 | [#727](https://gitlab.com/devnw/codepros/geode/geode/-/issues/727) *(confidential)* |
| 4 | Security | SEC-INFRA-01: `GEODE_CLUSTER_INSECURE` works in release across 6 modules; no audit/metric | Critical | Risk 24 | [#737](https://gitlab.com/devnw/codepros/geode/geode/-/issues/737) |
| 5 | Quality | Zig toolchain pin drift (0.15.1/0.15.2/0.16.0) in `build.zig.zon`, `.gitlab-ci.yml`, code | Merge-blocker | PS 100 | [#716](https://gitlab.com/devnw/codepros/geode/geode/-/work_items/716) |
| 6 | Security | SEC-RLS-02: RLS raw-string interpreter fallthrough — persisting `raw="1"` bypasses deny-by-default | High | Risk 16 | [#732](https://gitlab.com/devnw/codepros/geode/geode/-/issues/732) *(confidential)* |
| 7 | Perf | P0 per-row RLS alloc — `nodePropertiesToRLSRow` HashMap per node even with policy inactive (≥19 sites) | P0 | PS 80 | [#715](https://gitlab.com/devnw/codepros/geode/geode/-/issues/715) |
| 8 | Perf | P0 QUIC handler wake storm — `poll_cv.broadcast` every 500μs wakes 30+ threads for 1 progress (PERF-P1-001) | P0 | PS 72 | [#718](https://gitlab.com/devnw/codepros/geode/geode/-/issues/718) |
| 9 | Perf | P0 TDE key reload per encrypt — `loadKey()` does getenv+hex 8× per call-site | P0 | PS 72 | [#720](https://gitlab.com/devnw/codepros/geode/geode/-/issues/720) |
| 10 | Quality | Decompose 2,567-LOC `executeMatchQueryImpl` (match_operations.zig:4543) via 4-way dispatcher seam | High | PS 80 | [#719](https://gitlab.com/devnw/codepros/geode/geode/-/work_items/719) |

## Blockers

- **GAP-0538 / Quality #716 blocks the full audit re-verification.** `zig build` fails → downstream gates (tests, status-generate, canary-lint) cannot run against HEAD until the 3 `Io.File.writeAll` sites are patched and `build.zig.zon` is bumped.
- Trivy/Grype not run during Phase 2 (scanner unavailable locally) — supply-chain CVE count is reported as "suspected: 3" from a prior surface scan; rerun on the published container image before treating as ground truth.
- Platform Gap-ID collision: GitLab issues #666 ("GAP-0514: Deterministic nonce…") and #656 ("GAP-0509: Debug builds use hardcoded password…") reuse IDs whose flatfile meaning differs. Flagged inline in `GAP_ANALYSIS.md`; cross-cutting cleanup pass recommended in a separate sprint.
- hyperfine/pprof not installed on host; Phase 3 perf estimates are static-analysis derived. Quantitative confirmation requires `make loadtest-save-all-baselines` + A/B replay once Gap-0538 is patched.

## Immediate Next Actions

1. Patch GAP-0538 (`Io.File.writeAll` → 0.16 API) and bump `build.zig.zon` minimum. Unblocks everything.
2. Delete committed `audit.jsonl` history entry at `c8b7c44f`; add explicit `.gitignore` rule.
3. Confidential security triage on #723, #727, #732 within 7 days.
4. Re-run `make loadtest-save-all-baselines` to populate `point_read`/`one_hop`/`two_hop`/`fan_out` — currently only `ping` is baselined.
5. Delete `src/execution/statement_dispatcher.zig:121 executeStatementWithContext` (1,114-LOC dead clone) under issue [#717](https://gitlab.com/devnw/codepros/geode/geode/-/work_items/717) — verified no live callers.

---

*Audit harness: `/codepros:audit` (effort=max) — 16 specialized agents across 5 phases*
*Duration: ~55 min wall-clock*
*Prior audit reference: docs/FULL_AUDIT_2026_04_06.md*
