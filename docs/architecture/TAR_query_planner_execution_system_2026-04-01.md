# Technical Analysis Report: Query Planner and Execution System

Date: 2026-04-01
Author: Codex
Repository: `geode`
Branch: `codex/session-20260401-123921`
Commit: `acac0a0e8e4088f75e1af4290feeb6642d19a49e`

## A) Executive Summary

Decision: `hybrid / improve current system`, not `keep as-is`, and not an immediate full `replace`.

Key reasons:

1. The current "planner" is not the execution source of truth. Production query execution remains primarily AST-interpreted, while multiple planner-like subsystems independently synthesize hints, EXPLAIN payloads, and PROFILE payloads.
2. EXPLAIN and PROFILE are materially incorrect for simple queries. A live probe of `EXPLAIN RETURN 1 AS x` reported `Scan -> Expand -> Project`; a live probe of `PROFILE RETURN 1 AS x` reported deterministic per-operator timings and allocations (`10/20/30 ns`, `0/64/64 bytes`) that are generated from operator count, not measured execution.
3. The shared optimizer currently produces hints that execution does not consume. This creates architectural complexity without changing runtime behavior.
4. Execution is tightly coupled to the global in-memory `GraphStore` and coarse store locks, which limits scalability and complicates isolation, testability, and future physical planning.
5. RLS enforcement is transport-layer post-filtering, not an intrinsic execution operator, so enforcement depends on the caller path.
6. Tests and docs under-detect the problems: EXPLAIN/PROFILE harness coverage mostly checks status and column shape, while docs still describe placeholder timing even though the wire payload now exposes synthetic operator metrics.

Principal tradeoff:

- A full planner-driven executor replacement would offer the cleanest long-term architecture, but it is high-risk because the current executor embeds significant semantic behavior directly in AST-interpreted code paths.
- A hybrid unification approach can remove the most serious correctness gaps first by introducing one canonical operator graph for EXPLAIN, PROFILE, optimizer hints, and incremental execution lowering.

## B) Feature Scope & Requirements

### Scope

Feature under analysis: query engine planner and execution system.

User problem:

- Parse GQL statements.
- Produce a trustworthy execution strategy.
- Execute queries and mutations correctly.
- Explain and profile query behavior accurately enough for users, operators, and developers to make decisions.

In scope:

- Query analysis, planning, hint generation, EXPLAIN/PROFILE generation, execution dispatch, transport integration, locking model, and policy enforcement boundaries.
- Code in `src/planner.zig`, `src/planner/`, `src/execution*`, `src/query/query_traits.zig`, `src/server/query_plan_cache.zig`, `src/server/explain_payload.zig`, `src/server/profile_payload.zig`, `src/server/quic_connection_handler.zig`, `src/transport/grpc_server.zig`, and relevant docs/tests.

Out of scope:

- Cost model calibration against production workloads.
- Full storage engine redesign.
- End-to-end cost or incident analysis from production systems, because no dashboards, incident history, or cost exports were provided.

### Decision Question

Primary decision question: is the current planner/execution system the appropriate architecture, and what issues, incorrect implementations, and incomplete implementations must be addressed?

Allowed outcomes:

- keep
- improve
- replace
- hybrid
- defer with explicit experiments

### Inputs

- Codebase at commit `acac0a0e8e4088f75e1af4290feeb6642d19a49e`
- Documentation under `docs/`
- Specs under `../geode-test-harness/geodetestlab-cli/specs/`
- Local build and runtime probes

### Missing Information

- No production traces, latency dashboards, or flamegraphs
- No incident history or on-call data
- No cost export or infrastructure bill
- No workload corpus defining target QPS, p95 latency, or concurrency goals

Confidence impact:

- Functional and architectural findings are high confidence because they are backed by code inspection and local runtime probes.
- Operational, scale, and cost conclusions are medium confidence because they rely on code-path inference rather than production telemetry.

### Functional Requirements

The system should:

1. Produce semantically correct results for supported GQL statements.
2. Reject illegal queries consistently, including `GROUP BY` and pagination legality cases.
3. Produce EXPLAIN output that corresponds to the actual executable operator strategy.
4. Produce PROFILE output from measured runtime behavior, not heuristics.
5. Apply authz and RLS in a way that cannot be bypassed by alternate caller paths.
6. Preserve transaction/session semantics and error behavior across transports.

### Non-Functional Requirements

The system should meet these architectural criteria:

| Criterion | Desired property |
| --- | --- |
| Correctness | EXPLAIN/PROFILE are faithful to actual execution |
| Reliability | No dead planner surfaces drifting out of compile/test coverage |
| Security | Policy enforcement is intrinsic, least-privilege, and hard to bypass |
| Performance | Planner decisions can actually influence runtime behavior |
| Scalability | Avoid global singleton coupling and coarse request-wide locks where possible |
| Maintainability | One canonical plan representation, clear ownership boundaries |
| Operability | Observable operator metrics and meaningful profile fields |
| Cost | Low engineering/on-call overhead per feature addition |

### Acceptance Criteria

Recommended future-state acceptance criteria:

| Area | Acceptance criterion | Verification |
| --- | --- | --- |
| Plan fidelity | For a representative corpus, EXPLAIN operator sequence matches canonical executable plan exactly | Golden tests over query corpus |
| Profile fidelity | PROFILE timings and memory come from runtime instrumentation, not fixed formulas | Unit tests + runtime assertions + code inspection |
| Planner coupling | Execution consumes canonical plan metadata or operator graph for all read queries in scope | Integration tests and code-path trace |
| Policy enforcement | RLS is enforced inside execution via mandatory operator/filter stage | Security tests across QUIC, gRPC, and direct executor entrypoints |
| Coverage | Planner and plan-pipeline code is compiled and exercised in CI | Build graph change + CI job evidence |
| Concurrency | Lock duration limited to data access windows; no transport-only correctness assumptions | Concurrency tests and lock instrumentation |

## C) Current System: Architecture, Evidence, and Key Gaps

### Current Architecture Summary

Observed planner/execution surfaces:

1. `src/planner.zig`
   - legality and minimal heuristics
2. `src/planner/pipeline.zig`
   - synthetic instrumentation pipeline
3. `src/server/query_plan_cache.zig`
   - shared optimizer and plan cache producing advisory hints
4. `src/server/explain_payload.zig`
   - synthetic EXPLAIN payload builder from query traits
5. `src/server/profile_payload.zig`
   - synthetic PROFILE payload builder from query traits and row count
6. `src/execution/query_execution.zig` and `src/execution/statement_dispatcher.zig`
   - primary AST-driven execution path
7. Transport wrappers
   - `src/server/quic_connection_handler.zig`
   - `src/transport/grpc_server.zig`

Critical path, as implemented today:

1. Parse program
2. Derive `query_traits`
3. Optionally build shared optimizer hints
4. Execute statement or program through AST-driven execution
5. Apply RLS post-execution in transport layer
6. Build EXPLAIN or PROFILE payload from traits and row count, not from actual executed operator graph

### Evidence-Backed Findings

#### 1. The root planner is minimal and non-executable

Evidence:

- `src/planner.zig:18-21` defines `Plan` as only:
  - `ordered: bool`
  - `note: []const u8`
- `src/planner.zig:220-231` `planQuery(...)` only:
  - checks OFFSET pushdown legality
  - derives `use_index` from equality predicate presence
  - sets `note = "INDEX"` heuristically
  - validates `GROUP BY`
  - returns `{ ordered, note }`

Implication:

- This is not a logical or physical plan representation capable of driving execution, EXPLAIN, or PROFILE.

#### 2. Production execution remains AST-interpreted

Evidence:

- `src/execution/statement_dispatcher.zig:73-85` routes `.Query` to `executeQueryWithContext`.
- `src/execution/query_execution.zig:1541` defines `executeQueryWithContext(...)`.
- Repeated internal calls at `src/execution/query_execution.zig:68`, `1412`, `1421`, `1466`, `1682` show recursive query execution continues through AST-level entrypoints.

Implication:

- Planner subsystems are not the execution source of truth.

#### 3. EXPLAIN payload is synthetic and incorrect for trivial scalar queries

Evidence from code:

- `src/server/explain_payload.zig:167-193` always appends:
  - `Scan` or `IndexSeek`
  - `Expand`
  - optional `Filter`
  - optional `Aggregate`
  - `Project`
  - optional `Sort`
  - optional `Limit`
  - optional `SetOp`
- `src/query/query_traits.zig:97-118` derives traits from AST shape, not executable operator selection.
- `src/server/quic_connection_handler.zig:1760-1774` serves EXPLAIN from `buildExplainPayload(...)`.

Live probe:

Environment:

- Local transient QUIC server, Zig `0.15.1`, commit `acac0a0e8e4088f75e1af4290feeb6642d19a49e`

Command:

```bash
./zig-out/bin/geode query "EXPLAIN RETURN 1 AS x" \
  --server 127.0.0.1:3351 \
  --insecure-tls-skip-verify \
  --user geode \
  --password geode-test-password \
  --format json
```

Observed output excerpt:

```json
{
  "status_class":"00000",
  "explain":{
    "ops":[
      {"idx":0,"kind":"Scan","est_rows":1000,"cost":1},
      {"idx":1,"kind":"Expand","est_rows":8000,"cost":18},
      {"idx":2,"kind":"Project","est_rows":8000,"cost":2}
    ],
    "totals":{"est_rows":1000,"cost":22}
  }
}
```

Problem:

- `RETURN 1 AS x` should not require `Scan` or `Expand`.

Additional live probe:

```bash
./zig-out/bin/geode query "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 1" \
  --server 127.0.0.1:3351 \
  --insecure-tls-skip-verify \
  --user geode \
  --password geode-test-password \
  --format json
```

Observed output excerpt:

```json
{
  "explain":{
    "ops":[
      {"kind":"Scan"},
      {"kind":"Expand"},
      {"kind":"Project"},
      {"kind":"Sort"},
      {"kind":"Limit"}
    ]
  }
}
```

#### 4. PROFILE payload is synthetic and exposes misleading metrics

Evidence from code:

- `src/server/profile_payload.zig:37-63` assembles operators from traits, not execution.
- `src/server/profile_payload.zig:107-118` and `123-137` assign deterministic values:
  - `time_ns[idx] = 10 * (idx + 1)`
  - `cpu_time_ns[idx] = 5 * (idx + 1)`
  - `bytes_alloc[idx] = 0 or 64`
  - `bytes_out[idx] = row_count * 8`
- `src/server/profile_payload.zig:245-259` fills planner estimate error statistics with zeros and `adjusted_estimate_factor = 1`.
- `src/server/quic_connection_handler.zig:1813-1824` builds PROFILE from `traits`, `exec_result.rows.len`, and store stats.

Live probe:

```bash
./zig-out/bin/geode query "PROFILE RETURN 1 AS x" \
  --server 127.0.0.1:3351 \
  --insecure-tls-skip-verify \
  --user geode \
  --password geode-test-password \
  --format json
```

Observed output excerpt:

```json
{
  "status_class":"00000",
  "profile":{
    "ops":[
      {"op":"NodeScan","time_ns":10,"bytes_alloc":0},
      {"op":"Expand","time_ns":20,"bytes_alloc":64},
      {"op":"Project","time_ns":30,"bytes_alloc":64}
    ],
    "totals":{"time_ns":60,"peak_bytes":128},
    "planner_estimates":{
      "min_error_abs_pct":0,
      "max_error_abs_pct":0,
      "mean_error_abs_pct":0
    }
  }
}
```

Additional live probe:

```bash
./zig-out/bin/geode query "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" \
  --server 127.0.0.1:3351 \
  --insecure-tls-skip-verify \
  --user geode \
  --password geode-test-password \
  --format json
```

Observed output excerpt:

```json
{
  "profile":{
    "ops":[
      {"op":"NodeScan","time_ns":10},
      {"op":"Expand","time_ns":20},
      {"op":"Sort","time_ns":30},
      {"op":"Project","time_ns":40},
      {"op":"Limit","time_ns":50}
    ],
    "totals":{"time_ns":150,"peak_bytes":256}
  }
}
```

Problem:

- The system reports measured-looking metrics that are generated by formula, which is worse than a clearly labeled placeholder because it can mislead users and operators.

#### 5. There are multiple disconnected planner layers

Evidence:

- `src/planner.zig` supplies legality checks and tiny heuristics.
- `src/server/query_plan_cache.zig:676-821` constructs a "real plan" heuristically from store stats.
- `src/server/explain_payload.zig` and `src/server/profile_payload.zig` synthesize wire payloads independently from `query_traits`.
- `src/query/query_traits.zig:97-118` derives booleans like `ordered`, `has_group_by`, `has_where_eq`, and `has_union`.

Implication:

- There is no single canonical plan representation shared by planning, execution, EXPLAIN, and PROFILE.

#### 6. Shared optimizer hints are produced but not consumed

Evidence:

- `src/server/quic_connection_handler.zig:1682-1710` obtains `optimizer_hints_storage` from `SharedQueryOptimizer` and places it into `ExecutionContext`.
- `src/execution.zig:372-374` defines `optimizer_hints` in `ExecutionContext`.
- Repository search found no reads of `optimizer_hints` in `src/execution*`.

Implication:

- The optimization subsystem adds complexity without runtime effect.

#### 7. Shared optimizer statistics are incomplete on the QUIC path

Evidence:

- `src/server/query_plan_cache.zig:210-212` supports:
  - `node_count`
  - `edge_count`
  - `label_node_counts`
- `src/server/query_plan_cache.zig:707-710` uses `label_node_counts` when available.
- `src/server/quic_connection_handler.zig:1689-1693` populates only:
  - `node_count`
  - `edge_count`

Implication:

- Even within the shared optimizer, selectivity quality is degraded because the transport path does not supply all supported statistics.

#### 8. Planner pipeline code is synthetic and appears stale relative to current AST/planner APIs

Evidence:

- `src/planner/pipeline.zig:16-18` explicitly describes itself as synthetic.
- `src/planner/pipeline.zig:162` calls `planner_root.planQuery(q, .{})`, while current `planQuery` signature is `planQuery(allocator, q, opts)`.
- `src/planner/pipeline.zig:242-259` references `q.where.items` and `q.order.items`, while current AST uses `where_clause` and `order_by`.
- `zig build` and `zig build test` both succeeded locally, implying these stale paths are not compiled by normal validation.

Implication:

- Planner code can silently rot outside CI coverage.

#### 9. Execution is tightly coupled to the global store and coarse locking

Evidence:

- Direct reference count:

```bash
rg -n "getGlobalStore\\(|store\\.(nodes|edges|incoming_edges|outgoing_edges)" \
  src/execution src/execution.zig | wc -l
```

Observed result:

```text
198
```

- Example direct store access:
  - `src/execution/match_operations.zig:5131-5154`
- QUIC request-level locking:
  - `src/server/quic_connection_handler.zig:1731-1758`
- gRPC request-level locking:
  - `src/transport/grpc_server.zig:1376-1397`

Implication:

- Query behavior depends heavily on transport-managed coarse locking around a global singleton store.
- This limits scalability and makes future physical operator scheduling harder.

#### 10. RLS enforcement is post-execution rather than intrinsic to execution

Evidence:

- `src/execution.zig:379-383` says `rls_engine` is present for "future in-execution RLS integration".
- QUIC PROFILE/rows paths apply RLS after execution:
  - `src/server/quic_connection_handler.zig:1805-1810`
- gRPC PROFILE/rows paths apply RLS after execution:
  - `src/transport/grpc_server.zig:1440-1445`
  - `src/transport/grpc_server.zig:1491-1496`

Implication:

- Enforcement depends on transport wrapper behavior.
- Direct executor callers can avoid row filtering unless they apply it themselves.

#### 11. EXPLAIN/PROFILE tests are shallow relative to actual correctness needs

Evidence:

- `../geode-test-harness/geodetestlab-cli/specs/explain_profile_unit_tests.yml:21-137`
  - EXPLAIN assertions mostly verify `status_class` and `columns: [plan]`
- `../geode-test-harness/geodetestlab-cli/specs/explain_profile_unit_tests.yml:141-220`
  - PROFILE assertions mostly verify `status_class`, `columns: [metric, value]`, and occasional `row_count`

Implication:

- The current harness is not validating operator truthfulness or metric fidelity.

#### 12. Documentation drifts from current wire behavior

Evidence:

- `docs/EXPLAIN_PROFILE.md:442-445` says:
  - EXPLAIN has simplified plans
  - PROFILE timing is placeholder
  - PROFILE lacks operator stats and memory usage
- Current wire payload exposes per-operator stats and memory fields, but they are synthetic.

Implication:

- Docs understate the severity of the problem. The issue is not merely missing metrics; it is misleading metrics.

### Reliability, Security, Cost, and Operability Assessment

Reliability:

- Medium to low. The main risk is not immediate crashiness in the inspected path, but architectural drift and incorrect observability.
- Dead planner surfaces outside the build graph create hidden regression risk.

Security and privacy:

- Mixed. Transport-layer authz checks exist, but RLS is not guaranteed at core execution boundaries.
- No secret leakage was introduced by the tested commands; local probes used test credentials only.

Operability:

- Weak for planner introspection. EXPLAIN/PROFILE cannot currently be trusted as operational tools.

Cost:

- No infrastructure or vendor cost data was available.
- Engineering cost is likely high because the system has multiple overlapping planning abstractions with unclear ownership boundaries.

### Summary of Current-System Gaps

| Severity | Issue | Type |
| --- | --- | --- |
| High | EXPLAIN can report impossible operators for scalar queries | Incorrect |
| High | PROFILE publishes synthetic timings and memory as if measured | Incorrect |
| High | Execution does not consume shared optimizer hints | Incomplete |
| High | No canonical plan shared across planner, EXPLAIN, PROFILE, and execution | Incomplete |
| Medium | RLS is post-execution transport filtering | Incomplete / Security |
| Medium | Planner pipeline code is stale and not compiled in normal builds | Incorrect / Reliability |
| Medium | Shared optimizer receives incomplete stats on QUIC path | Incomplete |
| Medium | Executor is tightly coupled to global store and coarse locks | Architectural limitation |
| Medium | Harness validates shape more than truthfulness | Test gap |
| Low | Docs do not describe the current synthetic metrics accurately | Documentation gap |

## D) Alternatives: Options, Pros/Cons, Migration and Ops Impact

### Option 1: Keep current architecture and patch obvious defects

Description:

- Fix isolated bugs in EXPLAIN/PROFILE output and leave current layering intact.

Pros:

- Lowest short-term delivery risk
- Minimal migration

Cons:

- Does not resolve duplicated planner surfaces
- Leaves execution AST-driven and disconnected from planning
- High chance of continued drift and misleading observability

Migration and ops impact:

- Small code changes
- Ongoing operational confusion remains

Assessment:

- Not sufficient.

### Option 2: Hybrid improvement with a canonical operator graph

Description:

- Keep the current executor temporarily, but introduce one canonical operator graph / plan representation.
- Drive EXPLAIN from the canonical plan.
- Instrument PROFILE from actual runtime operator execution or adapter hooks.
- Gradually lower read-query execution onto the canonical plan.

Pros:

- Fixes the biggest correctness issues first
- Preserves existing semantics while reducing architectural duplication
- Creates an incremental migration path
- Improves testability and observability quickly

Cons:

- Requires careful adapter design between AST execution and canonical operators
- Some duplication remains during transition

Migration and ops impact:

- Moderate migration effort
- Manageable rollout by query subset
- Requires new golden tests, instrumentation, and CI coverage

Assessment:

- Best balance of correctness, delivery risk, and long-term maintainability.

### Option 3: Replace current executor with a fully planner-driven physical executor

Description:

- Design a full logical/physical plan pipeline and route all execution through it.

Pros:

- Cleanest long-term architecture
- Highest theoretical optimization and scalability ceiling

Cons:

- High migration risk
- Large semantic regression surface
- Requires replacing substantial embedded AST-execution behavior before trust is regained

Migration and ops impact:

- Highest delivery risk
- Large validation burden
- Harder rollback unless done by feature gates or query-subset routing

Assessment:

- Attractive end state, but too risky as the immediate recommendation.

### Exclusions

Excluded from serious consideration:

- Leaving EXPLAIN/PROFILE synthetic but relabeling them only in docs
  - reason: does not address architectural truthfulness
- Full storage engine replacement
  - reason: not required to fix the identified planner/executor defects

## E) Decision Matrix

Scoring scale:

- 1 = poor
- 3 = acceptable
- 5 = best

Weights sum to 100.

| Criterion | Weight | Option 1: Patch-only | Option 2: Hybrid unification | Option 3: Full replacement |
| --- | ---: | ---: | ---: | ---: |
| Correctness and semantic fidelity | 25 | 2 | 4 | 5 |
| Security and policy enforcement | 15 | 2 | 4 | 5 |
| Reliability and operability | 15 | 2 | 4 | 3 |
| Delivery risk / migration complexity | 15 | 4 | 3 | 1 |
| Performance and scalability headroom | 15 | 2 | 4 | 5 |
| Maintainability and testability | 10 | 2 | 5 | 4 |
| Engineering cost / on-call burden | 5 | 3 | 4 | 2 |
| Weighted total | 100 | 230 / 500 | 395 / 500 | 370 / 500 |

### Sensitivity Analysis

Uncertain assumptions:

1. Weight on delivery risk
2. Weight on performance headroom
3. Effort to lower executor semantics onto a canonical operator graph

Sensitivity notes:

- If delivery risk weight increases from 15 to 30, Option 2 still beats Option 3 because Option 3 loses too much on migration complexity.
- If performance headroom weight increases from 15 to 30 and delivery risk drops to 5, Option 3 approaches Option 2, but only if semantic migration risk is lower than current evidence suggests.
- If EXPLAIN/PROFILE truthfulness is the dominant near-term criterion, Option 2 remains preferred because it fixes truthfulness without requiring a full executor rewrite.

## F) Risks & Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Canonical plan becomes another disconnected layer | Repeats current architecture | Make EXPLAIN and PROFILE read only from canonical plan; ban parallel plan payload builders |
| Hybrid transition duplicates logic temporarily | Maintenance burden | Limit transition period and define query subsets and exit criteria |
| Executor semantics are lost during lowering | Query regressions | Golden corpus, differential tests between old and new execution paths |
| RLS refactor breaks policy behavior | Security regression | Add mandatory policy operator tests across transports and direct execution entrypoints |
| Coarse locking assumptions leak into new operator runtime | Performance ceiling persists | Instrument lock hold time and isolate store access behind explicit operator interfaces |
| Stale dead code continues hiding in planner path | Reliability regression | Compile planner pipeline in CI or remove it |

## G) Recommendation, Roadmap, and Verification Plan

### Recommendation

Adopt Option 2: hybrid unification around a canonical operator graph.

What this means:

1. Stop treating planner, EXPLAIN, PROFILE, and execution as separate model families.
2. Introduce one canonical logical/physical operator graph that can be serialized for EXPLAIN and instrumented for PROFILE.
3. Keep the current AST executor only as a temporary compatibility layer while read-query execution is lowered incrementally.
4. Move RLS into execution as a mandatory operator/filter stage.

### No-Regrets Improvements

1. Mark current EXPLAIN/PROFILE as synthetic or experimental until truthfulness is restored.
2. Strengthen harness assertions to validate operator sequence and measured-field provenance.
3. Compile or remove stale planner pipeline code.
4. Add a CI check ensuring `optimizer_hints` are either consumed or removed.
5. Update docs to describe current limitations accurately.

### Phased Roadmap

Phase 0: Containment

- Update docs and flags to avoid misleading users about PROFILE fidelity.
- Add golden tests for trivial scalar queries and a representative operator corpus.
- Make stale planner pipeline code compile in CI or delete it.

Phase 1: Canonical plan introduction

- Define `OperatorGraph` or equivalent canonical plan type.
- Map AST/query traits/shared optimizer outputs into that plan.
- Use canonical plan as the only EXPLAIN source.

Phase 2: Real PROFILE instrumentation

- Attach runtime counters and timers to canonical operators or execution adapters.
- Remove formula-generated timing/allocation fields.
- Emit provenance metadata for measured vs estimated fields.

Phase 3: Execution lowering

- Route read-only query subsets through canonical plan execution.
- Keep mutation and edge-case queries on the old executor until parity is proven.

Phase 4: Security and concurrency cleanup

- Move RLS into execution operators.
- Reduce transport-managed lock scope by isolating store access behind execution interfaces.

Phase 5: Retirement

- Remove duplicate explain/profile builders and unused hint-only plumbing.
- Collapse legacy AST-only execution paths where parity is complete.

### Verification Plan

1. Golden EXPLAIN tests
   - Cover scalar returns, scans, traversals, aggregation, union, sort, limit, and index usage.
2. PROFILE provenance tests
   - Assert measured fields are non-formulaic and sourced from instrumentation hooks.
3. Differential execution tests
   - Compare old executor and canonical-plan executor on shared query corpus.
4. Security tests
   - Verify RLS cannot be bypassed through QUIC, gRPC, or direct execution entrypoints.
5. Concurrency tests
   - Measure lock hold time and correctness under concurrent read/write workloads.

## H) Evidence Appendix

### Environment

```text
cwd=/home/benji/src/devnw/codepros/geode/geode-20260401-123921
branch=codex/session-20260401-123921
commit=acac0a0e8e4088f75e1af4290feeb6642d19a49e
date=2026-04-01
```

### Build and Validation Commands

```bash
zig version
zig build
zig build test
```

Observed results:

- Zig version: `0.15.1`
- `zig build`: success
- `zig build test`: success

### Key Code Inspection Commands

```bash
rg -n "pub const Plan = struct|pub fn planQuery\\(|OffsetPushdownRequiresOrder|validateGroupBy\\(|note = \\\"INDEX\\\"" src/planner.zig
rg -n "executeQueryWithContext|\\.Query =>|executeExplain\\(|executeProfile\\(" src/execution/statement_dispatcher.zig src/execution/statement_handlers.zig src/execution/query_execution.zig
rg -n "buildExplainPayload|buildOps\\(|buildProfilePayload|time_ns\\[idx\\] =|cpu_time_ns\\[idx\\] =|bytes_alloc\\[idx\\] =|planner_estimates" src/server/explain_payload.zig src/server/profile_payload.zig src/server/quic_connection_handler.zig
rg -n "optimizer_hints|generateRealPlan|label_node_counts|node_count|edge_count" src/execution.zig src/server/query_plan_cache.zig src/server/quic_connection_handler.zig
rg -n "synthetic|planQuery\\(q, \\.\\{\\}\\)|q\\.where\\.items|q\\.order\\.items" src/planner/pipeline.zig
rg -n "EXPLAIN|PROFILE|columns: \\[plan\\]|columns: \\[metric, value\\]" ../geode-test-harness/geodetestlab-cli/specs/explain_profile_unit_tests.yml
```

### Runtime Probe Commands

Ephemeral local server probe:

```bash
tmpdir=$(mktemp -d)
export GEODE_ADMIN_USERNAME=geode
export GEODE_ADMIN_PASSWORD=geode-test-password
export GEODE_DEFAULT_PASSWORD=geode-test-password
export GEODE_ALLOW_TEST_AUDIT_KEYS=1
./zig-out/bin/geode serve --data-dir "$tmpdir/data" --listen 127.0.0.1:3351
```

Probe commands:

```bash
./zig-out/bin/geode query "EXPLAIN RETURN 1 AS x" --server 127.0.0.1:3351 --insecure-tls-skip-verify --user geode --password geode-test-password --format json
./zig-out/bin/geode query "PROFILE RETURN 1 AS x" --server 127.0.0.1:3351 --insecure-tls-skip-verify --user geode --password geode-test-password --format json
./zig-out/bin/geode query "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 1" --server 127.0.0.1:3351 --insecure-tls-skip-verify --user geode --password geode-test-password --format json
./zig-out/bin/geode query "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" --server 127.0.0.1:3351 --insecure-tls-skip-verify --user geode --password geode-test-password --format json
```

Selected raw outputs:

```json
{"status_class":"00000","explain":{"schema":"cost_explain.v1","ops":[{"idx":0,"kind":"Scan","est_rows":1000,"cost":1},{"idx":1,"kind":"Expand","est_rows":8000,"cost":18},{"idx":2,"kind":"Project","est_rows":8000,"cost":2}],"totals":{"est_rows":1000,"cost":22},"profile_version":2,"properties":{"ordered":false}},"additional_statuses":[],"flagger_findings":["I:PropertyOrderingEnabled","U:NullsFirstPolicy"]}
```

```json
{"status_class":"00000","profile":{"profile_version":1,"ops":[{"op":"NodeScan","phase":"SCAN","id":0,"op_index":0,"input_rows":1,"rows":1,"time_ns":10,"cpu_time_ns":5,"bytes_out":8,"bytes_alloc":0},{"op":"Expand","phase":"EXPAND","id":0,"op_index":1,"input_rows":1,"rows":1,"time_ns":20,"cpu_time_ns":10,"bytes_out":8,"bytes_alloc":64},{"op":"Project","phase":"PROJECT","id":0,"op_index":2,"input_rows":1,"rows":1,"time_ns":30,"cpu_time_ns":15,"bytes_out":8,"bytes_alloc":64}],"totals":{"time_ns":60,"peak_bytes":128}}}
```

```json
{"status_class":"00000","explain":{"schema":"cost_explain.v1","ops":[{"idx":0,"kind":"Scan","est_rows":1000,"cost":1},{"idx":1,"kind":"Expand","est_rows":8000,"cost":18},{"idx":2,"kind":"Project","est_rows":8000,"cost":2},{"idx":3,"kind":"Sort","est_rows":8000,"cost":211},{"idx":4,"kind":"Limit","est_rows":100,"cost":0}],"totals":{"est_rows":1000,"cost":234},"profile_version":2,"properties":{"ordered":true,"limit":1}},"additional_statuses":[],"flagger_findings":["I:PropertyOrderingEnabled","U:NullsFirstPolicy","U:OrderTiebreak=LexJSON"]}
```

```json
{"status_class":"00000","profile":{"profile_version":1,"ops":[{"op":"NodeScan","time_ns":10},{"op":"Expand","time_ns":20},{"op":"Sort","time_ns":30},{"op":"Project","time_ns":40},{"op":"Limit","time_ns":50}],"totals":{"time_ns":150,"peak_bytes":256}}}
```

### Additional Observations

- I attempted to run the moved harness spec directly:

```bash
python3 -m geodetestlab.cli run \
  --spec specs/explain_profile_unit_tests.yml \
  --geode-binary /home/benji/src/devnw/codepros/geode/geode-20260401-123921/zig-out/bin/geode \
  --ci \
  --transport quic
```

- That run did not complete within the interactive analysis window and did not produce a report artifact in time, so it was not used as primary evidence.
- The harness spec itself was still useful evidence because its assertions are shallow by inspection.

## I) Open Questions / Follow-Ups

1. Which executor semantics currently live only inside AST-interpreted code and have no explicit operator representation yet?
2. What production workloads and concurrency targets should guide the canonical plan and lock-scope redesign?
3. Should the shared optimizer remain as the seed of the canonical planner, or should its logic be folded into a new operator-graph builder?
4. Are there any direct non-transport callers of execution that currently rely on the absence of in-execution RLS?
5. Should EXPLAIN/PROFILE be downgraded or gated until they are truthful, to avoid user-visible misdiagnosis?
