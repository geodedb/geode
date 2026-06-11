# Performance Gap Analysis

Last updated: 2026-06-11

This file now contains only open/deferred performance gaps. Historical performance findings live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md). PERF-A/#808 (RLS row rebuild) closed 2026-06-11; LSP-F-02/#770 (LSP AST cache keystone) closed 2026-06-11 — see GAP_ANALYSIS_RESOLVED.md.

## Open / Deferred Findings

| ID | Severity | Score | Finding | Component | Evidence | Next action | Status |
|---|---|---:|---|---|---|---|---|
| _(none)_ | — | — | No open performance findings. | — | — | — | — |

## Notes

- **LSP-F-02 / #770 closed 2026-06-11 (GAP-0887b)**: per-document AST cache for the LSP parsing providers (`src/cli/lsp/ast_cache.zig`; regression `zig build test-lsp-ast-cache`). The dependent LSP subtasks that were gated on this keystone — **F-05, F-06, F-12, F-15, F-16** (2026-05-06 LSP tracking archive) — are now **unblocked**; they are future optimization work, intentionally not re-opened as rows here. If/when any is scheduled, add it back as a new open row with fresh evidence.
