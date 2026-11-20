// Central CANARY registry file - collects features without duplicating implementation logic.
// Each line enumerates a requirement with minimal status (IMPL vs STUB) so docs can be derived.
// NOTE: Keep UPDATED fresh when moving to TESTED/BENCHED.
// SONNY-6613 item 7: 34 TESTED markers below named TestCANARY_* tests that no
// source defines (only REQ-GQL-016's was fixed by SONNY-6587); they are IMPL
// until a test that checks the requirement exists. A TESTED marker here must
// name a test some source under src/ or tests/ defines
// (tests/test_sonny6587_canary_markers.zig).

// CANARY: REQ=REQ-GQL-001; FEATURE="Binary Protocol Frames"; ASPECT=Wire; STATUS=IMPL; OWNER=wire; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-002; FEATURE="HELLO Capabilities"; ASPECT=Wire; STATUS=IMPL; OWNER=wire; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination Legality (US001)"; ASPECT=Planner; STATUS=IMPL; OWNER=planner; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-005; FEATURE="Set Operations"; ASPECT=Engine; STATUS=IMPL; OWNER=engine; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-010; FEATURE="Diagnostics Precedence"; ASPECT=Engine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_DiagnosticsFold,TestCANARY_REQ_GQL_010_DiagnosticsFoldExtended; BENCH=BenchmarkCANARY_REQ_GQL_010_DiagnosticsFold,BenchmarkCANARY_REQ_GQL_010_DiagnosticsFoldLarge; OWNER=engine; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-017; FEATURE="Property Access"; ASPECT=Engine; STATUS=IMPL; OWNER=engine; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot Compaction"; ASPECT=Storage; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_028_GraphStoreCompact,BenchmarkCANARY_REQ_GQL_028_SnapshotFragmentation; OWNER=storage; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot Adaptive Policy"; ASPECT=Storage; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_SnapshotAdaptivePolicy; OWNER=storage; UPDATED=2026-02-04
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints"; ASPECT=Engine; STATUS=IMPL; OWNER=schema; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Negative"; ASPECT=Engine; STATUS=IMPL; OWNER=schema; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Resume Token"; ASPECT=API; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_ResumeToken; OWNER=streaming; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-010; FEATURE="Diagnostics Large Fold"; ASPECT=Engine; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_010_DiagnosticsFoldLarge; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination Policy Override"; ASPECT=Planner; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_004_OffsetWithoutOrderPolicyToggle; OWNER=planner; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-046; FEATURE="TDE Key Rotation Throughput"; ASPECT=Storage; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_046_KeyRotateThroughput; OWNER=security; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Backfill Latency"; ASPECT=API; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_BackfillLatency; OWNER=streaming; UPDATED=2025-09-20
// SONNY-6587 item 6: REQ-GQL-016 claimed TESTED by a test no source defines;
// the weighted shortest path (algo.shortestPath.dijkstra with a weight
// property, src/execution/recursion_handler.zig executeDijkstra) has no test
// that checks a cost (tests/test_match_call_integration.zig only parses one).
// CANARY: REQ=REQ-GQL-016; FEATURE="Weighted Path Cost"; ASPECT=Planner; STATUS=IMPL; OWNER=planner; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-028; FEATURE="Recovery After Compaction"; ASPECT=Storage; STATUS=IMPL; OWNER=storage; UPDATED=2026-11-15
// NOTE: Original provisional IDs 070–073 conflicted with existing REQUIREMENTS.md (String Search, GreyCardinal, HyperledgerGraphMVCC, MvccAdvanced)
// Re-seated strategic gap IDs to 074–077 to avoid collision.
// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICMultiplexing; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_074_QUICMultiplexing; OWNER=wire; UPDATED=2026-11-14
// SONNY-6555 item 8: two REQ-GQL-075 "Query Optimizer" rows were removed
// here: AdvancedCostModel claimed TESTED by TestCANARY_REQ_GQL_075_AdvancedCostModel,
// a test that does not exist, for a cost model no query's plan is chosen by
// (docs/SERVER_FEATURES.md 4); its variance envelope is a benchmark of a
// local stand-in model that does not compile (tests/benchmark_advanced_cost_model_calibration_variance.zig).
// CANARY: REQ=REQ-GQL-076; FEATURE="Materialized Views"; ASPECT=RefreshScheduler; STATUS=IMPL; OWNER=engine; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-076; FEATURE="Materialized Views"; ASPECT=MvRefreshLatencyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_076_MvRefreshLatencyVarianceEnvelope; OWNER=engine; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-077; FEATURE="Full-Text Search"; ASPECT=InvertedIndexCore; STATUS=IMPL; OWNER=engine; UPDATED=2026-11-15

// Additional Data Types Implementation
// CANARY: REQ=REQ-GQL-080; FEATURE="Additional Data Types"; ASPECT=ValueTags; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-081; FEATURE="Numeric Types"; ASPECT=IntWidths; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-082; FEATURE="Float Types"; ASPECT=NaNForbidden; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-083; FEATURE="Decimal128"; ASPECT=ArithmeticRounding; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-084; FEATURE="String Types"; ASPECT=CharPadComparison; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-085; FEATURE="String Types"; ASPECT=VarcharBounds; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-086; FEATURE="Temporal Types"; ASPECT=DateParsing; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-087; FEATURE="Temporal Types"; ASPECT=TimestampTZNormalization; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-088; FEATURE="Temporal Types"; ASPECT=IntervalArithmetic; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-089; FEATURE="Binary Types"; ASPECT=ByteaHex; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-090; FEATURE="JSON Types"; ASPECT=JsonbCanonical; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-091; FEATURE="XML Types"; ASPECT=WellFormed; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-092; FEATURE="URL Types"; ASPECT=Normalization; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-093; FEATURE="Domain Types"; ASPECT=PunycodeHandling; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-094; FEATURE="UUID Types"; ASPECT=ParsingGeneration; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-095; FEATURE="Enum Types"; ASPECT=OrdinalComparison; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-096; FEATURE="Array Types"; ASPECT=HomogeneousOperations; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-097; FEATURE="Bit Types"; ASPECT=BitwiseOperations; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-098; FEATURE="Range Types"; ASPECT=ContainmentOverlap; STATUS=IMPL; OWNER=types; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-099; FEATURE="Specialized Indexes"; ASPECT=IntervalTreePersistence; STATUS=IMPL; OWNER=index; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-100; FEATURE="Specialized Indexes"; ASPECT=JsonbInvertedPersistence; STATUS=IMPL; OWNER=index; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-101; FEATURE="Specialized Indexes"; ASPECT=DomainTriePersistence; STATUS=IMPL; OWNER=index; UPDATED=2026-11-15
// CANARY: REQ=REQ-GQL-077; FEATURE="Full-Text Search"; ASPECT=InvertedIndexQueryLatencyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_077_InvertedIndexQueryLatencyVarianceEnvelope; OWNER=engine; UPDATED=2025-09-22

pub fn placeholder() void {
    // This file intentionally left with a no-op function so Zig build includes it.
}
