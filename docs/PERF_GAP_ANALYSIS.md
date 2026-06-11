# Performance Gap Analysis

Last updated: 2026-06-11

This file now contains only open/deferred performance gaps. Historical performance findings live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md). PERF-A/#808 (RLS row rebuild) closed 2026-06-11 — see GAP_ANALYSIS_RESOLVED.md.

## Open / Deferred Findings

| ID | Severity | Score | Finding | Component | Evidence | Next action | Status |
|---|---|---:|---|---|---|---|---|
| LSP-F-02 / #770 | P1 | n/a | AST cache keystone remains open; F-05/F-06/F-12/F-15/F-16 remain gated on it. | LSP / parser cache | `docs/PERF_GAP_ANALYSIS.md` 2026-05-06 LSP tracking archive. | Finish AST cache integration for LSP parse paths and close dependent subtasks. | Deferred / Open |
