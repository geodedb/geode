# NEXT — Concise Forward Backlog — Regenerated 2025-09-23 (Post Monitoring Variance Bench Promotion)

Purpose: Maintain a minimal, actionable slice backlog strictly limited to forward work. Historical landed content lives in `GAP_ANALYSIS.md` & `IMPLEMENTATION_REALITY.md`.

## 1. Global Acceptance (Machine Enforced)

1. Exactly one aspect promotion per slice (TESTED or BENCHED).
2. New or promoted aspect must add a CANARY line with `UPDATED`=today.
3. All slices must pass `./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict` prior to merge.
4. Variance benches use class thresholds (Hot≤0.18, Storage≤0.21, General≤0.22, GraphAnalytics≤0.23 CV; p95/mean caps 2.40–2.60) or add `// VARIANCE_EXCEPTION:`.
5. Bench failures emit `VARIANCE_FAIL_<TOKEN>`.
6. Freshness: regenerated within 24h (governance check).

## 2. Active Backlog (Actionable Only — Focus: Remove STUB/IMPL)

| Slice | REQ         | Title                               | WHY (Short)                   | Acceptance (Abbrev)                                                          | Class    | Owner     |
| ----- | ----------- | ----------------------------------- | ----------------------------- | ---------------------------------------------------------------------------- | -------- | --------- |
| S-103 | REQ-GQL-081 | Monitoring Prometheus Export        | Expose metrics externally     | Endpoint/core metrics TESTED; variance envelope BENCHED (cv<=0.22 p95<=2.55) | TEST/BEN | ops       |
| S-104 | REQ-GQL-082 | Backup/Restore Primitives           | Ensure recoverability         | Full & incremental backup tests; restore integrity checksum match            | DONE     | storage   |
| S-105 | REQ-GQL-083 | WAL Compaction Pipeline             | Manage log growth             | Checkpoint selection + compaction job test + variance bench (CV≤0.21)        | DONE     | storage   |
| S-106 | REQ-GQL-084 | Selectivity Estimator Framework     | Improve planner accuracy      | Frequency sampler + adaptive feedback test + variance bench (CV≤0.22)        | DONE     | optimizer |
| S-107 | REQ-GQL-085 | Structured Logging Client Parity    | Consistent client/server logs | Client parity test verifying JSON schema equivalence                         | DONE     | ops       |
| S-108 | REQ-GQL-086 | Interactive REPL Launch Prompt      | Developer usability           | Launch prompt emits `geode>` exactly once (ReplLaunchPrompt TESTED)          | DONE     | client    |
| S-109 | REQ-GQL-024 | Plan Cost Model Factors Promotion   | Remove lone IMPL risk         | Add test+bench for factors; promote IMPL→BENCHED                             | BENCH    | planner   |
| S-110 | REQ-GQL-004 | Pagination Execution Streaming Var. | Stabilize streaming latency   | Streaming bench (CV≤0.22 p95/mean≤2.55) + ordered emission test              | BENCH    | planner   |
| S-111 | REQ-GQL-010 | Governance: STUB Elimination Audit  | Maintain truthful docs        | Verify no remaining undisclosed STUB/IMPL after preceding slices             | TEST     | tooling   |

## 3. Variance Policy (Extract)

Hot≤0.18 p95/mean≤2.40; Storage/WAL≤0.21; General≤0.22; GraphAnalytics≤0.23 (p95/mean≤2.60). Exceptions require inline justification.

## 4. Governance Hooks

Run: `make governance-check` (freshness + strict verify). Stale (>24h) ⇒ fail.
Nightly (non-blocking) summary: `make governance-aggregate` emits combined delta + freshness pre-warn + dry-run JSON for observability.

## 5. Appendix (Pointer Only)

Historical slice details live in `docs/GAP_ANALYSIS.md` & `docs/IMPLEMENTATION_REALITY.md`.

## 6. Maintenance / Governance (De-Prioritized)

The following slice has been moved out of the feature-priority backlog. Governance freshness is now considered baseline hygiene, not a competitive differentiator; feature delivery (planner, storage, distributed, acceleration) takes precedence for the current cycle.

| Slice | REQ         | Title                          | Rationale (Why De-Prioritized)            | Current Evidence |
| ----- | ----------- | ------------------------------ | ----------------------------------------- | ---------------- |
| S-020 | REQ-GQL-010 | Governance Multi-Doc Freshness | Mechanism landed & enforced automatically | TEST (CANARY)    |

// CANARY: REQ=REQ-GQL-010; FEATURE="NEXT Backlog Accuracy"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceMultiDocFreshness; OWNER=tooling; UPDATED=2025-09-23

### Recent Slice Landing (Informational)

// S-112 (REQ-GQL-086 Interactive REPL MultilineBuffering) — Multiline accumulation with semicolon and blank line flush implemented; aspect promoted to TESTED (2025-09-23).
// S-113 (REQ-GQL-086 Interactive REPL HistoryPersistence) — File-backed history load/append implemented; aspect promoted to TESTED (2025-09-23).
// S-114 (REQ-GQL-086 Interactive REPL MetaCommandsBasic) — Added :help, :history, :quit meta command handling; aspect promoted to TESTED (2025-09-23).
// S-115 (REQ-GQL-086 Interactive REPL TxnPromptIndicator) — Added transaction-aware prompt (geode(txn)> ) with beginTxn/endTxn API; aspect promoted to TESTED (2025-09-23).
// S-116 (REQ-GQL-086 Interactive REPL CtrlCCancelBuffer) — Added cancelBuffer clearing in-progress multiline without persisting; aspect promoted to TESTED (2025-09-23).
// S-117 (REQ-GQL-079 RecursiveExecution ParserRecognition) — Minimal WITH RECURSIVE recognition sets has_recursive_cte on first Query; aspect promoted to TESTED (2025-09-23).
// S-118 (REQ-GQL-079 RecursiveExecution FixpointDriver) — Added generic runFixpoint driver with convergence vs exhaustion detection; aspect promoted to TESTED (2025-09-23).

### Completed Slices (Removed from Active Backlog)

- S-101 (REQ-GQL-078 Cluster Coordinator Core) — LeaderStub, ShardMapStub, RaftInterfaceValidation all TESTED (2025-09-23).
- S-102 (REQ-GQL-080 RLS/ABAC Enforcement) — PolicyCatalog, EnforcementHook, PolicyCache all TESTED (2025-09-23).

- Federation ordering mismatch flag now emitted as `U:FederationOrderMismatch` (single consumption) via lightweight `federation_flag` module decoupled from full federation engine to avoid module root collisions.
- Null ordering variance envelope benchmark added: `BenchmarkCANARY_REQ_GQL_052_FederationNullMergeVarianceEnvelope` (high NULL density).
- Pagination streaming scaffold (S-018) landed with CANARY test (no functional streaming yet) — next step will add incremental emission and latency variance envelope.
- Federation mismatch false-positive guard benchmark promoted: `BenchmarkCANARY_REQ_GQL_024_FederationMismatchFalsePositiveGuard` (STATUS=BENCHED; zero false positives over 5000 consistent iterations; single deliberate mismatch).
- Federation mismatch latency variance envelope benchmark skeleton added: `BenchmarkCANARY_REQ_GQL_024_FederationMismatchLatencyVarianceEnvelope` (STATUS=IMPL; captures raw + trimmed (5%) stats; enforcement gated by `FED_LATENCY_ENFORCE=1`; targets CV<=0.22 p95/mean<=2.55 prior to promotion).
- Federation mismatch latency variance envelope benchmark enhanced: added outlier metrics (min_ns, max_ns, outlier_count, outlier_ratio), trimmed p95, classification field (General), and optional stabilization loop (`FED_LATENCY_STABILIZE=1`) performing up to 5 passes until trimmed_cv<=0.22; promotion criteria documented (raw cv & trimmed cv ≤0.22, p95/mean ≤2.55, outlier_ratio ≤0.10) while remaining STATUS=IMPL with enforcement gated by `FED_LATENCY_ENFORCE=1`.
- Federation mismatch latency multi-run aggregation tool `fed_latency_aggregate` added (STATUS=IMPL; aspect `LatencyAggregateMultiRun`) producing aggregate JSON (avg/max cv/trim_cv/p95_ratio/outlier_ratio, promotion_ready flag). Gated failure via `FED_LATENCY_AGG_REQUIRE=1` when promotion criteria unmet; supports run count override `FED_LATENCY_AGG_RUNS`.
  - Enhancement: verbose mode (`FED_LATENCY_VERBOSE=1`) now emits `runs_detail` array (per-run cv, trim_cv, p95_mean_ratio, outlier_ratio, passes, fail_mask). Failing aggregates include `not_ready_reasons` (subset of: cv, trim_cv, p95_mean_ratio, outlier_ratio) and bit `fail_mask`. Stability rule for future BENCHED promotion: require ≥3 consecutive daily aggregates with `promotion_ready=true` and `max_cv` ≤ threshold (0.22) while raw benchmarks (single-run latency envelope) also individually meet criteria under stabilization (`FED_LATENCY_STABILIZE=1`). CI gating path (opt-in): set `FED_LATENCY_AGG_REQUIRE=1` after stability streak achieved; prior to streak, run in observe-only mode without gating.
  - Enhancement (median + summary): aggregator now also emits `median_cv`, `median_p95_mean_ratio`, and a concise `summary_reason` field (`all_criteria_met` or first failing criterion) to simplify dashboard filtering and streak evaluation.
  - Enhancement (extended medians + txt mode): added `median_trim_cv`, `median_outlier_ratio`, and optional human-readable text output via `FED_LATENCY_FORMAT=txt` (single-line summary). JSON path unchanged.
  - New tool: `fed_latency_streak` (STATUS=IMPL) computes current/longest promotion_ready streak from aggregator JSONL history and eligibility (default ≥3) with txt/JSON dual output; includes CANARY marker `LatencyAggregateStreak`.

### Upcoming REPL Aspect Micro-Slices (Post S-108)

To honor the one-aspect-per-slice rule, remaining InteractiveRepl aspects will land as separate future slices:

- S-113: HistoryPersistence -> TESTED

Each slice acceptance: implement feature + single CANARY test (no bundling).
