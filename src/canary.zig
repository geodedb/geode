// Central CANARY registry file - collects features without duplicating implementation logic.
// Each line enumerates a requirement with minimal status (IMPL vs STUB) so docs can be derived.
// NOTE: Keep UPDATED fresh when moving to TESTED/BENCHED.

// CANARY: REQ=REQ-GQL-001; FEATURE="Binary Protocol Frames"; ASPECT=Wire; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_HelloRoundTrip,TestCANARY_REQ_GQL_001_WireMalformedFrame; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-002; FEATURE="HELLO Capabilities"; ASPECT=Wire; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_HelloRoundTrip,TestCANARY_REQ_GQL_002_WireUnsupportedCapability; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination Legality (US001)"; ASPECT=Planner; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_004_UnorderedLimitReject; OWNER=planner; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-005; FEATURE="Set Operations"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_SetOpsDistinct; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-010; FEATURE="Diagnostics Precedence"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_DiagnosticsFold; BENCH=BenchmarkCANARY_REQ_GQL_010_DiagnosticsFold,BenchmarkCANARY_REQ_GQL_010_DiagnosticsFoldLarge; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=Planner; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_016_PathExpandBfs; BENCH=BenchmarkCANARY_REQ_GQL_016_PathPrune; OWNER=planner; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-017; FEATURE="Property Access"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_PropertyAccess,TestCANARY_REQ_GQL_017_PropertyAccessNull,TestCANARY_REQ_GQL_017_PropertyAccessMissing,TestCANARY_REQ_GQL_017_PropertyAccessDecimalFormat; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Compaction"; ASPECT=Storage; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_028_WalCompact; BENCH=BenchmarkCANARY_REQ_GQL_028_WalCompact,BenchmarkCANARY_REQ_GQL_028_WalFragmentation; OWNER=storage; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Adaptive Policy"; ASPECT=Storage; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_WalAdaptivePolicy; OWNER=storage; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_ConstraintEnforce,TestCANARY_REQ_GQL_032_ConstraintUniqueViolation,TestCANARY_REQ_GQL_032_ConstraintRange; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Negative"; ASPECT=Engine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_032_ConstraintUniqueViolation,TestCANARY_REQ_GQL_032_ConstraintTypeMismatch; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Resume Token"; ASPECT=API; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_ResumeToken; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-010; FEATURE="Diagnostics Large Fold"; ASPECT=Engine; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_010_DiagnosticsFoldLarge; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination Policy Override"; ASPECT=Planner; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_004_OffsetWithoutOrderPolicyToggle; OWNER=planner; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-046; FEATURE="TDE Key Rotation Throughput"; ASPECT=Storage; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_046_KeyRotateThroughput; OWNER=security; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Backfill Latency"; ASPECT=API; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_BackfillLatency; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-016; FEATURE="Weighted Path Cost"; ASPECT=Planner; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_PathWeightedCost; OWNER=planner; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-028; FEATURE="Recovery After Compaction"; ASPECT=Storage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_RecoveryAfterCompaction; OWNER=storage; UPDATED=2025-09-20

pub fn placeholder() void {
    // This file intentionally left with a no-op function so Zig build includes it.
}
