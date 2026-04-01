# Property Type Optimizations Technical Analysis Report

**Date**: 2026-04-01
**Status**: Analysis complete
**Repository**: `geode`
**Commit analyzed**: `acac0a0e8e4088f75e1af4290feeb6642d19a49e`
**Environment**: Zig `0.15.1`, local worktree `codex/session-20260401-124307`
**Decision question**: Identify and complete all incomplete integrations for property types and advanced types.
**Feature**: Property type optimizations
**Current system under analysis**: Property and advanced type handling implemented across `src/types`, `src/eval_extended.zig`, `src/value_types.zig`, `src/graph_store.zig`, `src/storage/graph_storage_adapter.zig`, `src/index/*`, `src/server/index_optimizer.zig`, and `src/optimizer/advanced_types_optimizer.zig`
**Confidence**: Moderate for code-path mapping and integration gaps, low for production-frequency/cost impact due missing runtime metrics and incident history

## A) Executive Summary

**Decision**: **Hybrid**. Keep the specialized type implementations and index backends, but replace the current fragmented property-type integration layer with a single canonical boundary and retire or quarantine dead optimizer paths until they are wired into the real planner/executor.

### Key reasons

1. **The current system is not end-to-end safe for advanced property types**.
   - `ExtValue` is silently lossy at the storage-adapter boundary: `src/storage/graph_storage_adapter.zig` converts `.ExtValue` to a dummy `ext` payload and converts storage `.ext` back to `.Null`.
   - `src/txn_undo_log.zig` serializes `.ExtValue` as null, so rollback can corrupt advanced properties.

2. **The runtime surface is only partially integrated**.
   - Inbound protocol params reject `ext_val` (`src/server/proto_util.zig`), while outbound protocol serialization for `ExtValue` exists.
   - Several typed literals degrade to strings during evaluation (`src/eval.zig`), so parser support does not imply type fidelity.

3. **Index and optimizer support is fragmented and partly dead code**.
   - `src/index/index_manager.zig` exposes advanced index APIs, but there are **0 non-definition callsites** for those APIs in `src/`.
   - `src/optimizer/advanced_types_optimizer.zig` has **no imports anywhere in the repo**, so it is not part of the active query-planning path.
   - `src/gql/parser.zig` still maps `IntervalTree`, `JsonbInverted`, and `DomainTrie` DDL to `.btree` “for now”.

4. **Build and test health currently overstates integration maturity**.
   - `zig build` and `zig build test` both passed on the analyzed commit.
   - That does not contradict the gaps above because several incomplete components are either dead code, only partially wired, or only covered for scalar cases.

5. **The right long-term answer is not “do nothing” and not “big-bang replacement”**.
   - Status quo risks correctness and rollback/persistence integrity.
   - Immediate full replacement would improve coherence, but the migration risk is too high for the current surface area.
   - A staged hybrid delivers correctness first, then consolidates architecture.

## B) Feature Scope & Requirements

### Scope

#### In scope

- Property-value representation and conversion across:
  - parser/AST
  - evaluation/type promotion
  - graph property storage
  - storage adapter persistence
  - protocol request/response serialization
  - undo/rollback
  - advanced index creation/use
  - optimizer/planner integration for advanced types

#### Out of scope

- Vendor/platform comparison outside the local codebase
- Production latency/cost benchmarking against live workloads
- Distributed-query optimizer behavior not directly tied to advanced property types
- Full refactor of unrelated execution/runtime duplication

### Decision outcomes allowed

- Keep current system
- Improve current system
- Replace current system
- Hybrid staged approach
- Defer with explicit experiments

### Functional requirements

1. Typed literals and constructors must preserve type semantics from parse to runtime value.
2. Advanced property values must survive:
   - insertion
   - query evaluation
   - rollback
   - persistence/reload
   - protocol roundtrip where supported
3. Supported advanced indexes must be reachable from DDL, mutation, and query execution.
4. Equality, ordering, DISTINCT, and serialization must not collapse all advanced values to a single placeholder identity.
5. Unsupported features must fail explicitly, not silently degrade to null or string.

### Non-functional requirements

1. **Correctness**: zero lossy boundary conversions for supported property types.
2. **Reliability**: rollback and reload must preserve advanced types.
3. **Security/privacy**: sensitive property handling must not be bypassed by type downgrades; unsupported inbound values should fail closed.
4. **Maintainability**: one canonical semantic boundary for property typing; fewer duplicate unions and ad hoc conversions.
5. **Operability**: build/test coverage must detect property-type regressions.
6. **Performance**: keep specialized index backends for vector/spatial/network/jsonb/domain workloads.
7. **Portability**: stay within Zig 0.15.1 and current project module structure.

### Constraints

- Must work with existing Zig/module layout and current `graph_storage` adapter model.
- Must preserve backward compatibility where possible for scalar properties.
- No authoritative production dashboards, traces, incident data, or cost exports were available in this analysis.

### Acceptance criteria

1. `zig build` and `zig build test` pass after changes.
2. Roundtrip tests exist for at least:
   - `UUID`
   - `Url`
   - `Domain`
   - `Jsonb`
   - `IntRange`
   - `IpAddr` / `Subnet`
   - `VectorF32`
3. Advanced property values survive:
   - graph-store write/read
   - storage-adapter persist/reload
   - transaction rollback
4. No property boundary module contains silent lossy fallback for supported types.
   - Verification target modules:
     - `src/storage/graph_storage_adapter.zig`
     - `src/txn_undo_log.zig`
     - `src/eval/type_promotion.zig`
     - `src/gql/match.zig`
5. Advanced index families that are exposed in DDL have at least one production call path from DDL -> mutation sync -> query use, or are explicitly removed/deferred.

## C) Current System: Architecture, Evidence, and Gaps

### Current architecture

The property-type system is split across multiple overlapping representations:

1. **`src/types/extended.zig`**
   - Experimental type system for formatting/parsing/basic ops.
   - Mostly used by `src/types/extended_functions.zig`.
   - Not the canonical runtime/storage representation.

2. **`src/eval_extended.zig`**
   - Active advanced-type union: `ExtValue`.
   - Hosts constructors and advanced functions.

3. **`src/value_types.zig`**
   - Core query-engine value union.
   - Includes many advanced built-in types plus `ExtValue`.

4. **`src/graph_store.zig`**
   - Property storage union: `String | Int | Float | Bool | Null | Decimal | ExtValue`.
   - This is the actual graph property boundary.

5. **`src/storage/heap.zig`**
   - Storage encoding layer with richer type coverage.

6. **Index and optimization layers**
   - `src/index/advanced_types_index.zig`
   - `src/index/index_manager.zig`
   - `src/server/index_optimizer.zig`
   - `src/optimizer/advanced_types_optimizer.zig`

### Baseline evidence collected

- Build baseline:
  - `zig build` -> exit `0`
  - `zig build test` -> exit `0`
- Static code metrics:
  - `ExtValue` appears in **26 source files**
  - Advanced index API callsites outside `src/index/index_manager.zig`: **0**
  - Placeholder / “for now” / lossy-fallback hits in `src/`: **148**

### Strengths in the current system

1. **There is real advanced-type implementation depth**.
   - `src/eval_extended.zig`, `src/storage/heap.zig`, `src/value_types.zig`, and several type modules provide non-trivial coverage.

2. **GraphStore memory handling for many advanced values is explicit**.
   - `copyExtValue()` / `freeExtValue()` in `src/graph_store.zig` cover many variants.

3. **Some security and validation work is already present**.
   - JSONB depth guard in `src/types/jsonb.zig`
   - Advanced index input validation in `src/index/advanced_types_index.zig`
   - Protocol fails closed for unsupported inbound `ext_val`

4. **Outbound protocol serialization partially supports advanced values**.
   - `src/server/proto_util.zig` has `extValueToProto()` and serializes `ExtValue` in responses.

### Decision-critical gaps

#### 1. Persistence is lossy for advanced property values

`src/storage/graph_storage_adapter.zig`:

- `toStorageProperty()` maps `.ExtValue` to `.{ .ext = .{ .type_tag = 0, .data = "" } }`
- `fromStorageProperty()` maps storage `.ext` back to `.Null`

**Impact**:

- Advanced property values do not have a trustworthy storage-engine roundtrip.
- Persisted graphs can silently lose advanced property information after reload.

#### 2. Rollback is lossy for advanced property values

`src/txn_undo_log.zig`:

- `SerializedProperty.fromPropertyValue()` maps `.ExtValue` to null

**Impact**:

- Transaction rollback can restore the wrong value for advanced properties.
- This is a correctness and reliability failure, not just missing feature polish.

#### 3. Protocol support is asymmetric

`src/server/proto_util.zig`:

- Inbound `.ext_val` params return `error.UnsupportedParamType`
- Outbound `ExtValue` serialization exists

**Impact**:

- Server responses can describe advanced values, but clients cannot submit them through the same protocol surface.
- API behavior is inconsistent and complicates client adoption.

#### 4. Typed literals are parsed but not materialized as typed values

`src/eval.zig`:

- `JsonbLit`, `UrlLit`, `DomainLit`, `UuidLit` all evaluate to `Value.Str`
- `SmallIntLit` / `BigIntLit` downgrade to plain integers
- `RealLit` / `DoubleLit` are converted to decimal approximations

**Impact**:

- Parser-level feature claims overstate actual runtime type semantics.
- Downstream optimizers and index routing cannot rely on typed literals.

#### 5. JSONB constructor is not integrated as JSONB

`src/eval_extended.zig`:

- `constructJsonb()` validates syntax, then returns `.Str`

**Impact**:

- `Jsonb` is not a faithful runtime type through this constructor path.
- JSONB-specific indexing and semantics cannot rely on constructor output.

#### 6. Vector KNN function is stubbed

`src/eval_extended.zig`:

- `vectorKnn()` returns an empty list “for MVP”

**Impact**:

- The function surface exists without real query/index execution integration.

#### 7. Advanced index DDL is downgraded in the parser

`src/gql/parser.zig`:

- `IntervalTree`, `JsonbInverted`, and `DomainTrie` all map to `.btree` “for now”

**Impact**:

- Specialized index families exist in code, but DDL does not preserve their intent.
- The system exposes capabilities it does not route correctly.

#### 8. Advanced index manager APIs exist but are not wired into production call paths

`src/index/index_manager.zig`:

- `createAdvancedVectorIndex()`
- `createAdvancedSpatialIndex()`
- `createAdvancedNetworkIndex()`
- `createAdvancedSignatureIndex()`
- insert/query methods

Static search result:

- **0 non-definition callsites** in `src/`

**Impact**:

- Advanced index implementation exists largely as an isolated subsystem.
- There is no evidence of automatic property mutation -> advanced index sync.

#### 9. Mutation notifications are wired to WAL, not advanced index maintenance

`src/graph_store.zig`:

- `notifyMutation()` is only installed by WAL-related code found in `src/wal.zig`

**Impact**:

- No evidence that property writes update advanced indexes automatically.

#### 10. The “advanced types optimizer” is not on the active planner path

`src/optimizer/advanced_types_optimizer.zig`:

- custom `QueryPlan`
- placeholder `reorderOperations()`
- zero imports in repository search

**Impact**:

- This optimizer is not the current system of record for property type optimization.
- Its CANARY/test annotations do not prove production integration.

#### 11. Comparison and serialization semantics still contain placeholder behavior

`src/exec.zig`:

- `ExtValue` compares equal “for now”
- encoded key for `ExtValue` is fixed token

`src/execution/value_utilities.zig`:

- Node/edge property serialization writes `"<ExtValue>"` placeholder in some paths

**Impact**:

- DISTINCT, ordering, grouping, hashing, and JSON output may be incorrect or lossy in older/runtime-specific code paths.

#### 12. Type promotion still drops unsupported advanced types to null

`src/eval/type_promotion.zig`:

- several conversions map unsupported advanced values to `.Null`

**Impact**:

- Lossiness is still embedded in conversion boundaries rather than isolated to explicit unsupported-feature errors.

### Security and privacy assessment

#### Positive findings

- JSONB depth guard reduces DoS risk.
- Protocol rejects unsupported inbound `ext_val` instead of attempting unsafe partial decode.
- GraphStore FLE handling exists for string properties.

#### Risks

1. **Silent type degradation can weaken control boundaries**
   - Example: type dropped to string/null instead of explicit failure.

2. **FLE appears string-focused**
   - `setNodeProperty()` / `setEdgeProperty()` only encrypt `.String`.
   - No evidence in this analysis that advanced binary/JSON/domain/URL types participate in the same field-level controls.

3. **Dead code can create false assurance**
   - Optimizer/index modules may appear “implemented” while not participating in live paths.

### Operability and testability assessment

#### Positive findings

- Project-level build/test is healthy.
- Many source modules contain inline unit tests.

#### Gaps

1. Storage-adapter tests cover scalar roundtrip only, not `ExtValue`.
2. Undo-log tests do not exercise advanced property rollback fidelity.
3. No evidence of integration tests proving:
   - advanced property persist/reload
   - advanced property rollback
   - advanced index DDL/mutation/query roundtrip
4. Build/test passing therefore has limited value for this feature.

### Cost analysis

No cloud/service/vendor cost data was available.

This report therefore limits cost analysis to engineering and operational cost:

- **Current system cost**: high ongoing maintenance cost due duplicate unions, lossy shims, and dead subsystems.
- **Incremental improvement cost**: moderate.
- **Full replacement cost**: high upfront, lower long-term maintenance.
- **Hybrid staged cost**: moderate upfront, best balance of near-term correctness and long-term simplification.

## D) Alternatives

### Option 1: Keep Current System

**Summary**: Leave architecture intact, document gaps, accept partial integration.

**Pros**

- No migration work
- No short-term feature risk from refactoring

**Cons**

- Persistence and rollback remain unsafe for advanced property types
- Feature claims remain overstated relative to actual integration
- Ongoing maintenance and debugging cost stays high

**Migration / ops impact**

- Minimal change cost
- High long-term operational ambiguity

### Option 2: Improve Current System In Place

**Summary**: Keep all current type layers, but patch every known lossy boundary.

**Required changes**

- Implement real `ExtValue` codec in storage adapter
- Add undo-log serialization for advanced properties
- Support inbound protocol `ext_val`
- Materialize typed literals
- Replace placeholder comparison/serialization
- Wire advanced index DDL and mutation sync

**Pros**

- Lowest migration risk
- Preserves existing module topology
- Fastest path to correctness for the worst gaps

**Cons**

- Retains architectural duplication
- Risk of fixing the same semantics in multiple places
- Dead/parallel type systems remain

**Migration / ops impact**

- Moderate code churn
- Moderate risk of inconsistent patches unless tightly coordinated

### Option 3: Replace with a Single Canonical Property Value Model Now

**Summary**: Collapse property-type handling around one canonical runtime/storage representation and remove most bridging.

**Required changes**

- Replace `graph_store.PropertyValue`/`ExtValue` boundary with canonical value type
- Rewrite adapter, undo log, protocol, evaluation, and index routing around that model
- Delete or quarantine duplicate experimental stacks

**Pros**

- Best long-term maintainability
- Lowest semantic ambiguity
- Simplifies testing and planner/index routing

**Cons**

- Highest migration risk
- Touches many files and hot paths simultaneously
- Harder rollback if partial migration lands

**Migration / ops impact**

- High delivery/schedule risk
- Strong long-term payoff

### Option 4: Hybrid Staged Convergence (Recommended)

**Summary**: Keep specialized backends and the active `ExtValue` surface for now, but replace lossy boundaries first and then converge toward a single canonical integration layer.

**Required changes**

- Stage 1: correctness and boundary integrity
- Stage 2: wire real planner/index paths or remove dead ones
- Stage 3: consolidate duplicate type layers

**Pros**

- Fixes the most dangerous correctness issues first
- Preserves specialized performance backends
- Reduces architectural duplication over time
- Lower migration risk than big-bang replacement

**Cons**

- Takes multiple milestones
- Requires discipline to prevent “temporary” shims from becoming permanent

**Migration / ops impact**

- Moderate delivery cost
- Best balance of correctness, maintainability, and rollout safety

## E) Decision Matrix

### Criteria and weights

| Criterion | Weight |
|---|---:|
| Data integrity / correctness | 25 |
| Maintainability / architectural coherence | 20 |
| Integration completeness | 20 |
| Delivery risk / migration complexity | 15 |
| Performance / specialized-index leverage | 10 |
| Security / operability / testability | 10 |

### Scores (1 = worst, 5 = best)

| Option | Integrity | Maintainability | Integration | Delivery Risk | Performance | Sec/Ops/Test | Weighted Score |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1. Keep current | 1 | 1 | 1 | 5 | 2 | 2 | 1.80 |
| 2. Improve in place | 3 | 3 | 3 | 4 | 3 | 3 | 3.15 |
| 3. Replace now | 5 | 5 | 5 | 1 | 4 | 4 | 4.20 |
| 4. Hybrid staged convergence | 4 | 4 | 5 | 5 | 4 | 4 | **4.35** |

### Scoring notes

- **Option 1** scores high only on short-term delivery risk because it changes nothing; it fails the decision question.
- **Option 2** is viable, but architectural duplication remains.
- **Option 3** is strongest architecturally, but the migration risk is materially higher than the codebase currently justifies.
- **Option 4** keeps most of Option 3’s benefits while reducing risk by sequencing the work.

### Sensitivity analysis

1. **If maintainability weight rises from 20 to 30 and delivery-risk weight drops from 15 to 5**, Option 3 nearly matches or can slightly beat Option 4.
   - Interpretation: if the team can absorb a large refactor now, full replacement becomes more attractive.

2. **If delivery-risk weight rises from 15 to 30**, Option 4 clearly dominates Option 3.
   - Interpretation: when schedule safety matters, staged convergence is the more defensible choice.

3. **If performance weight falls to 0**, Option 4 still remains ahead because the main problem is correctness and integration, not raw index speed.

## F) Risks & Mitigations

### Risk 1: Advanced property values are lost during persistence/reload

**Severity**: High

**Mitigation**

- Implement explicit `ExtValue` storage codec in `src/storage/graph_storage_adapter.zig`
- Add persist/reload tests for representative advanced types

### Risk 2: Rollback restores null instead of original advanced value

**Severity**: High

**Mitigation**

- Extend `SerializedProperty` to encode advanced values or use canonical property codec
- Add rollback tests covering advanced properties on nodes and edges

### Risk 3: Planner/index work lands without real runtime wiring

**Severity**: High

**Mitigation**

- Treat zero-caller advanced APIs as non-production until wired
- Require end-to-end tests from DDL -> mutation -> query

### Risk 4: Placeholder semantics break DISTINCT / ORDER / serialization

**Severity**: Medium

**Mitigation**

- Replace placeholder equality/key encoding with canonical `value_types.eqVals` / typed serializer behavior
- Add targeted DISTINCT/ORDER/JSON serialization tests for advanced values

### Risk 5: Security policy coverage is inconsistent across non-string types

**Severity**: Medium

**Mitigation**

- Decide explicitly whether FLE applies only to string properties or to structured advanced values
- Document and test the policy

### Risk 6: Hybrid approach stalls before consolidation

**Severity**: Medium

**Mitigation**

- Tie each temporary shim to an ADR-backed milestone
- Delete dead modules or clearly mark them as dormant/non-production if not wired by milestone 2

## G) Recommendation, Roadmap, and Verification Plan

### Recommendation

Adopt **Option 4: Hybrid staged convergence**.

#### What to keep

- Specialized advanced-type implementations in `src/types/*`
- Specialized storage/index backends in `src/storage/heap.zig`, `src/index/advanced_types_index.zig`, and related index modules

#### What to replace or reshape

- Lossy `PropertyValue` / `ExtValue` boundary conversions
- Placeholder comparison/serialization behavior
- Parser DDL downgrades for advanced index types
- Dead optimizer surfaces presented as if production-ready

### Phased roadmap

#### Phase 1: Correctness first

1. Implement canonical advanced-property codec at:
   - storage adapter
   - undo log
   - protocol input
   - DML/property conversion boundaries
2. Make typed literals materialize to typed values.
3. Replace silent null/string fallback with explicit unsupported errors where a type is not yet supported.

**Exit criteria**

- Advanced property roundtrip tests pass for persistence and rollback.

#### Phase 2: Real query/index integration

1. Map parser DDL for interval/jsonb/domain/vector/network/spatial to real specialized index types.
2. Add mutation-to-index synchronization path.
3. Provide real production call paths for advanced index query execution.
4. Remove or quarantine advanced index APIs that remain unused.

**Exit criteria**

- At least one end-to-end test exists per exposed specialized index family.

#### Phase 3: Planner/runtime consolidation

1. Decide canonical semantic source:
   - recommended direction: one canonical query/runtime property model with explicit storage codec
2. Remove or quarantine `src/types/extended.zig` experimental stack if it remains unused outside helper functions.
3. Either wire `src/optimizer/advanced_types_optimizer.zig` into the real planner/executor or delete it.

**Exit criteria**

- No dead optimizer path marketed as active production behavior.

### No-regrets improvements

1. Add coverage for `ExtValue` in storage-adapter tests.
2. Add rollback tests for advanced property types.
3. Replace placeholder comments with explicit `error.Unsupported...` where behavior is intentionally deferred.
4. Add static CI checks for known lossy patterns in property-boundary modules.

### Verification plan

1. **Build verification**
   - `zig build`
   - `zig build test`

2. **Correctness verification**
   - Unit tests for scalar + advanced property roundtrip
   - Undo-log rollback tests with advanced properties
   - Protocol request/response tests for `ext_val`

3. **Integration verification**
   - DDL create index -> property mutation -> query use tests for each specialized index family

4. **Regression verification**
   - DISTINCT / ORDER / serialization tests with multiple unequal `ExtValue` instances

5. **Static guard verification**
   - Repo checks that property-boundary modules no longer contain known lossy fallbacks for supported types

## H) Evidence Appendix

### Environment

- Timestamp: `2026-04-01T12:53:02-04:00`
- Zig: `0.15.1`
- Commit: `acac0a0e8e4088f75e1af4290feeb6642d19a49e`
- Worktree status before edits: clean

### Commands run

```bash
git rev-parse HEAD
git branch --show-current
zig version
zig build
zig build test
rg -n "property type|PropertyType|AdvancedType|advanced type|TODO|FIXME|STUB|CANARY" src/types src/optimizer
rg -n "advanced_types_optimizer" src build.zig
rg -n "createAdvancedVectorIndex\\(|insertIntoAdvancedVectorIndex\\(|queryAdvancedVectorIndex\\(|createAdvancedSpatialIndex\\(|insertIntoAdvancedSpatialIndex\\(|createAdvancedNetworkIndex\\(|createAdvancedSignatureIndex\\(" src
rg -n "ExtValue round-trip is lossy|Treat ExtValue as null|UnsupportedParamType|map to btree for now|return .{ .Str = json_str }|compare equal for now" src
```

### Raw outputs captured

#### Build

```text
zig build -> exit 0
zig build test -> exit 0
```

#### Static counts

```text
extvalue_files=26
advanced_index_callsites=7
advanced_index_nondef_callsites=0
placeholder_hits=148
```

### Key authoritative code artifacts

- `src/storage/graph_storage_adapter.zig`
- `src/txn_undo_log.zig`
- `src/server/proto_util.zig`
- `src/eval.zig`
- `src/eval_extended.zig`
- `src/eval/type_promotion.zig`
- `src/gql/parser.zig`
- `src/index/index_manager.zig`
- `src/index/advanced_types_index.zig`
- `src/optimizer/advanced_types_optimizer.zig`
- `src/graph_store.zig`
- `src/execution/value_utilities.zig`
- `src/exec.zig`

## I) Open Questions / Follow-Ups

1. Should advanced property types be first-class in the external graph-storage engine, or should Geode own an explicit codec over the engine’s generic `ext` field?
2. Should inbound protocol support for advanced values land immediately, or only after canonical storage/rollback semantics are fixed?
3. Is `src/types/extended.zig` still intended as production architecture, or should it be explicitly scoped as helper/experimental only?
4. Does field-level encryption need to cover structured advanced types, or is string-only FLE the intended policy?
5. Should `src/optimizer/advanced_types_optimizer.zig` be wired into the real planner, or removed to avoid false confidence?
