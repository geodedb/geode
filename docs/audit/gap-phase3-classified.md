# Gap Analysis — Phase 3: Classified Gap Ledger

**Generated:** 2026-04-16
**Auditor:** Claude Opus 4.7 (1M context)
**Inputs:** `docs/audit/gap-phase1-requirements.md`, `docs/audit/gap-phase2-scan.md`, existing `docs/GAP_ANALYSIS.md`, `docs/GAP_ANALYSIS_RESOLVED.md`, `docs/MIGRATION_GAP_ANALYSIS.md`.
**Next available Gap-ID:** **GAP-0538** (highest prior: GAP-0537 in MIGRATION_GAP_ANALYSIS.md).

---

## Summary

- **Total requirements analyzed:** 2,862 unique REQ IDs (CANARY) + 154 open tracker issues + ~60 REQ-DOC-* mirrors
- **Implemented:** 3,417 TESTED rows + 219 BENCHED + 307 EXEMPT = **84.6% of CANARY ledger verified**
- **Partial:** 397 IMPL-only (GAP-0514 rollup)
- **Not Implemented:** 5 distinct new findings below
- **Unknown:** 0 (build failure blocks only test-delta verification, not classification of the 9 new gaps)
- **New gaps found:** **5** (GAP-0538 through GAP-0542)
- **Previously open gaps updated (evidence changed):** 2 (GAP-0514, GAP-0249 doc mirror)
- **Previously open gaps resolved this pass:** 0 (build regression prevents closure validation)
- **Total open gaps (after this phase):** 7 existing + 5 new = **12**

---

## New Gaps

### GAP-0538: Zig 0.16.0 build regression — `Io.File.writeAll` removed

- **Category:** Bug (build-blocker)
- **Severity:** **Critical**
- **Requirement source:** REQ-0008 (Platform & Build, GitLab #246); `build.zig.zon:6` pins `minimum_zig_version = "0.15.1"` while commits `3f06a9e1…35149ed9` migrated to 0.16.0; no tracker issue exists.
- **Current state (evidence):**
  - `src/cli/transport_response.zig:171` — `no field 'writeAll' in 'Io.File'`
  - `src/client/query_result_accumulator.zig:145` — same API call
  - `src/cli/main.zig:1897` — same API call
  - `build.zig.zon:6` — `.minimum_zig_version = "0.15.1"` (not bumped)
  - `CLAUDE.md:267` — documents "Zig 0.15.1+" (stale)
  - `zig build` output: 32/35 steps succeed then hard-fails on these 3 refs
- **Why this is a gap:** Debug build is broken on the toolchain the recent commit series migrated to; no tracker issue captures the regression; `.minimum_zig_version` pin is inconsistent with the actual target.
- **Impact/Risk:** Blocks all downstream CI, release artifacts, `make verify-fast`, pre-commit push hooks, and full-scan test verification. Every PR lands red until fixed.
- **Recommended fix:** Replace `file.writeAll(bytes)` with `file.deprecatedWriter().writeAll(bytes)` or migrate to `std.Io.Writer` at 3 call sites; bump `build.zig.zon` to `0.16.0`; update `CLAUDE.md` Zig version banner; add CI job that pins the exact toolchain via the `setup-zig` action.
- **Acceptance criteria:** `zig build` returns 0; `zig build test` succeeds; `CLAUDE.md` Zig version matches `build.zig.zon`; new GitLab issue opened with `type::bug` + `priority::critical`.

### GAP-0539: `tools/status_generate.py` emits schema-invalid CSV rows

- **Category:** CI-CD / Tooling
- **Severity:** **Medium**
- **Requirement source:** REQ-0007 (Tooling & Governance, #245); CANARY governance schema `{TESTED, IMPL, EXEMPT, BENCHED}`.
- **Current state (evidence):**
  - 4 rows in freshly regenerated `docs/status.csv` with `STATUS=COMPLETE` (e.g. `docs/status.csv:233` `REQ-AUTH-001,UserManagement,Authentication,COMPLETE`) — not in schema
  - 16 rows with blank `STATUS` column parsed from Terraform-style block titles in docs (e.g. `"REQ-GQL-SET-OPERATIONS" {`)
  - Phase 2 §1 tabulates: TESTED 3417, IMPL 397, EXEMPT 307, BENCHED 219, **COMPLETE 4, blank 16**
- **Why this is a gap:** Generator accepts inputs the downstream lint rejects; inflates/falsifies governance counts; violates the one-source-of-truth principle stated in CLAUDE.md.
- **Impact/Risk:** Skews GAP-0514 coverage metrics and any dashboard that counts rows by status. Low functional impact; moderate governance-integrity impact.
- **Recommended fix:** Reject non-schema STATUS values in `status_generate.py`; fail the run or skip-with-warning; add a regex guard against HCL-style `"REQ-...":` / `"REQ-..." {` false positives when scanning Markdown or `tf` files; update CANARY lint to flag schema violations.
- **Acceptance criteria:** `python3 tools/status_generate.py` output contains zero `COMPLETE` rows and zero blank-status rows; CI check enforces it.

### GAP-0540: Committed `tools/canaryscan/status.csv` lags working-tree regeneration by 210 REQ IDs

- **Category:** CI-CD / Docs
- **Severity:** **Low**
- **Requirement source:** REQ-0007 (Tooling & Governance); `CLAUDE.md` "Evidence-based development" principle.
- **Current state (evidence):**
  - Committed `tools/canaryscan/status.csv`: 3,986 rows, 2,652 unique REQ IDs (last mtime `2026-04-11 17:47`)
  - Freshly generated `docs/status.csv` (from Phase 2 run): 4,356 rows, 2,862 unique REQ IDs
  - Delta: +210 REQs, +318 TESTED, +39 IMPL, +37 EXEMPT, −40 BENCHED
- **Why this is a gap:** Source-of-truth ledger committed to tree does not reflect current code; any downstream tool (dashboards, CLAUDE.md counts) quoting the committed file cites stale data.
- **Impact/Risk:** Low; purely governance drift.
- **Recommended fix:** Make `make status-generate` mandatory in pre-push hook (it currently runs only on MR pipelines); add a CI diff check that fails if `tools/canaryscan/status.csv` is not in sync with a fresh regen.
- **Acceptance criteria:** CI job "status-csv-drift" fails on stale ledger; committed file re-synced in this PR.

### GAP-0541: `docs/REQUIREMENTS.md` still links GAP-0249 as open (mirror stale)

- **Category:** Docs
- **Severity:** **Low**
- **Requirement source:** REQ-0007 (Tooling & Governance).
- **Current state (evidence):**
  - `docs/REQUIREMENTS.md:82` lists GAP-0249 as an open requirement item linked to issue #542
  - `docs/GAP_ANALYSIS.md:480, 1932` marks GAP-0249 **CLOSED 2026-03-13** ("Concurrent MERGE data race — already fixed")
  - `docs/GAP_ANALYSIS_RESOLVED.md` archives it as resolved
- **Why this is a gap:** `docs/REQUIREMENTS.md` is the declared "flatfile mirror" of tracker state; the mirror is stale. Contradiction with `GAP_ANALYSIS.md` creates reader confusion.
- **Impact/Risk:** Low; docs-only.
- **Recommended fix:** Remove GAP-0249 line from `docs/REQUIREMENTS.md:82`; verify GitLab issue #542 is closed and label it `status::done`; add `make sync-requirements-mirror` target that diffs against tracker API.
- **Acceptance criteria:** GAP-0249 absent from `REQUIREMENTS.md`; mirror-sync target in Makefile.

### GAP-0542: NodeRegistry inline-clone drift risk untracked by CI

- **Category:** Code Quality (duplication / drift)
- **Severity:** **Medium**
- **Requirement source:** CLAUDE.md "Known Limitations" — distributed section notes "inline copy — see that file's note about drift risk".
- **Current state (evidence):**
  - `src/distributed/test_query_transport_node_registry.zig:53-112` is a literal inline clone of `src/distributed/query_transport.zig:607-664` (NodeRegistry struct + 6 methods)
  - No CI check enforces equivalence; no single-source-of-truth import
  - File-header comment acknowledges drift risk but offers no mitigation
- **Why this is a gap:** Cosmetic drift acknowledged, concrete drift will silently pass; once the two copies diverge, the test validates nothing.
- **Impact/Risk:** Medium — a subsequent change to `query_transport.zig:NodeRegistry` will ship while the test still pins the old behavior, invalidating distributed-transport regression coverage.
- **Recommended fix:** Extract `NodeRegistry` into its own module `src/distributed/node_registry.zig`; both production and test import it; delete the inline copy. Alternatively, add a byte-identical diff check in CI.
- **Acceptance criteria:** `src/distributed/node_registry.zig` exists as the sole definition; inline copy in test file removed; `zig build test` still green.

---

## Updated Gaps (evidence changed)

| Gap-ID   | Change | Updated Evidence |
|----------|--------|------------------|
| GAP-0514 | IMPL coverage improved from documented 15% → observed 10.4% (397 of 3,820 non-exempt rows). Hotspot shifted from `execution.zig`/`graph_store.zig` to REPL/CLI/QUIC layer. | Phase 2 §1 fresh scan; hotspot files: `src/client/repl/repl_dispatch.zig` (36), `src/cli/main.zig` (27), `src/server/quic_connection_handler.zig` (22), `src/client/repl/repl_loop.zig` (19), `src/transport/grpc_server.zig` (17). |
| GAP-0509 residual | Reconfirmed: `src/execution/aggregation_evaluation.zig:629-690` dead-but-unsafe, explicit `GAP-0509 WARNING` marker in source. No CI enforcement yet. | Phase 2 §3 trace; REQ-GAP-0509-AGG-TENANT-WARNING CANARY `STATUS=IMPL`. |

---

## Resolved Gaps (ready to close)

None this pass. The Zig 0.16.0 build regression (GAP-0538) blocks any re-verification of previously-open gaps that require a working build. Closure validation for GAP-0509/0510/0511/0513 residuals requires full test pass.

---

## Gap Priority Matrix

| Severity | Count | Gap-IDs                                                   |
|----------|-------|-----------------------------------------------------------|
| Critical | 2     | **GAP-0538 (new)**, GAP-0256 (existing, blocked)          |
| High     | 2     | GAP-0526, GAP-0527 (existing)                             |
| Medium   | 4     | **GAP-0539 (new)**, **GAP-0542 (new)**, GAP-0528 (existing), GAP-0514 (existing, improving) |
| Low      | 4     | **GAP-0540 (new)**, **GAP-0541 (new)**, GAP-0529 (existing), GAP-0509 residual (existing) |

---

## Classification Breakdown by Status

| Status          | Count      | Notes                                                                |
|-----------------|-----------:|----------------------------------------------------------------------|
| Implemented     | ~3,636     | TESTED (3,417) + BENCHED (219); GQL 100% (70/70); distributed closed |
| Partial         | 397 + 3    | CANARY IMPL-only rows + GAP-0509/0510/0514 residuals                 |
| Not Implemented | 5          | GAP-0538, GAP-0539, GAP-0540, GAP-0541, GAP-0542                     |
| Unknown         | 0          | Build failure blocks retest of *closed* gaps but does not leave any new finding unclassified |

---

## Hand-off to Phase 4

1. **Open new GitLab issues** for GAP-0538 (critical, `type::bug`), GAP-0539 (medium, `type::code-quality`), GAP-0540 (low, `type::ci-cd`), GAP-0541 (low, `type::docs`), GAP-0542 (medium, `type::code-quality`).
2. **GAP-0538 blocks everything downstream** — patch it first so Phase 5 can re-run `zig build test` for full coverage validation.
3. **GAP-0509 residual** still warrants a tracking comment on existing issue noting the dead-but-unsafe code path in `aggregation_evaluation.zig:629-690`; either wire a tenant parameter or delete the functions before they get called.
