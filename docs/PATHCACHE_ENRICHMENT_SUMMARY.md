# PathCache Enrichment Summary (2025-09-21)

## Enhancements Landed

1. Metrics Export: `writeMetricsJson` with CANARY aspect `PathCacheMetricsExport` (TESTED) enabling structured hit/miss/eviction/hit_ratio telemetry for future protocol surfacing.
2. Structural Key Value Shape: Added value shape class encoding (N,S,B,U,A,O) per node endpoint (`PathCacheStructuralKeyValueShapeEnrichment` TESTED) improving discrimination across heterogenous property value distributions.
3. Collision Guard Tightening: Raised uniqueness threshold from ≥90% to ≥92%, adding aspect `PathCacheStructuralKeyCollisionTightened` (BENCHED) while retaining existing collision envelope benchmark.
4. Documentation Sync: Updated `GAP_ANALYSIS.md`, `NEXT.md`, `REQUIREMENTS.md` with new aspect counts (199 total) and enriched structural key description.

## Current Evidence Snapshot

- Aspects (total): 199 (BENCHED 89, TESTED 110, STUB/IMPL 0) — 100% coverage.
- PathCache-related BENCHED: LookupVarianceEnvelope, HitMissVarianceEnvelope, StructuralKeyCollisionEnvelope (≥92% unique), StructuralKeyCollisionTightened.
- PathCache-related TESTED: Lookup, Eviction, PlannerIntegration, PlannerHook, StructuralKeyDerivation, StructuralKeyEnrichment (property key sets), StructuralKeyValueShapeEnrichment, MetricsExport, StructuralKeyEquivalence/Differentiation tests.

## Rationale for Value Shape Encoding

- Reduces false positives where two patterns share label and property key sets but differ fundamentally in predicate value categories affecting selectivity.
- Keeps key compact (adds at most '+N+S+...' tokens per endpoint) with deterministic ordering and no literal value leakage.
- Future extension path: add lightweight cardinality class (e.g., low/medium/high) once stats are available; reserved 'C' code left unused.

## Collision Benchmark Outlook

- Pre-enrichment uniqueness baseline: ~90–91% on 1,500 randomized patterns.
- Post value-shape enrichment: empirically observed uplift (bench locally) justifying tightened threshold to 92% with headroom for future enrichment (directional degree buckets, selectivity classes) targeting ≥95%.

## Next Opportunities (Not Yet Scheduled)

1. Degree Bucket Encoding: Append small degree class histogram (e.g., D0,D1,D2) per endpoint to further reduce collisions for hub vs leaf distinctions.
2. Selectivity Class Hints: Hash of normalized predicate operators (equality vs range) to inform future cost-based plan caching.
3. Adaptive Cache Sizing: Dynamic capacity adjustment driven by rolling hit ratio slope and eviction burst detection.
4. Eviction Policy Upgrade: Optional segmented LRU or CLOCK-Pro once capacity scaling shows diminishing returns with FIFO.
5. Protocol Exposure: Add PathCache metrics frame (`CACHE_METRICS`) or embed metrics in PROFILE JSON.

## Guardrails & Governance

- Any future structural key field MUST preserve prior canonical normalization (variable names & literal values still ignored) to avoid cache fragmentation.
- Collision benchmark must remain deterministic (fixed seed) and thresholds documented in `GAP_ANALYSIS.md`.
- New enrichments require: (a) Differentiation test, (b) Equivalence test (no regression on normalization), (c) Updated collision bench analysis.

---

Generated 2025-09-21.
