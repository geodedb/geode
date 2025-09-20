// Central CANARY registry file - collects features without duplicating implementation logic.
// Each line enumerates a requirement with minimal status (IMPL vs STUB) so docs can be derived.
// NOTE: Keep UPDATED fresh when moving to TESTED/BENCHED.

// CANARY: REQ=REQ-GQL-001; FEATURE="Binary Protocol Frames"; ASPECT=Wire; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_HelloRoundTrip; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-002; FEATURE="HELLO Capabilities"; ASPECT=Wire; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_HelloRoundTrip; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination Legality (US001)"; ASPECT=Planner; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_004_UnorderedLimitReject; OWNER=planner; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-005; FEATURE="Set Operations"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_SetOpsDistinct; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-010; FEATURE="Diagnostics Precedence"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_DiagnosticsFold; BENCH=BenchmarkCANARY_REQ_GQL_010_DiagnosticsFold; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=Planner; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_016_PathExpandBfs; BENCH=BenchmarkCANARY_REQ_GQL_016_PathPrune; OWNER=planner; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-017; FEATURE="Property Access"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_PropertyAccess; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Compaction"; ASPECT=Storage; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_028_WalCompact; BENCH=BenchmarkCANARY_REQ_GQL_028_WalCompact,BenchmarkCANARY_REQ_GQL_028_WalFragmentation; OWNER=storage; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_ConstraintEnforce; OWNER=schema; UPDATED=2025-09-20

pub fn placeholder() void {
    // This file intentionally left with a no-op function so Zig build includes it.
}
