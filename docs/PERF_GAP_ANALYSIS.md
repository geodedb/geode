# Performance Gap Analysis

Last updated: 2026-06-10

This file now contains only open/deferred performance gaps. Historical performance findings live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Open / Deferred Findings

| ID | Severity | Score | Finding | Component | Evidence | Next action | Status |
|---|---|---:|---|---|---|---|---|
| PERF-A / #808 | P1 | 40 | RLS row rebuild dominates per-row cost: `nodePropertiesToRLSRowInto` rebuilds a `StringHashMap` per row across 17 call sites. | Execution / Security | `src/security/rls_value_bridge.zig:83-95`; `src/execution/match_operations.zig` entry `passesRLSExprFilter`. | Run `/bench-optimize`; skip row rebuild when bytecode has no `load_row`, or memoize by `(node.id, auth_version)`. | Open |
| LSP-F-02 / #770 | P1 | n/a | AST cache keystone remains open; F-05/F-06/F-12/F-15/F-16 remain gated on it. | LSP / parser cache | `docs/PERF_GAP_ANALYSIS.md` 2026-05-06 LSP tracking archive. | Finish AST cache integration for LSP parse paths and close dependent subtasks. | Deferred / Open |
